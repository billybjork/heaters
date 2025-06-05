import sys
import os
from pathlib import Path
import time
import psycopg2
import psycopg2.extras

# --- Project Root Setup ---
# Path(__file__).parent.parent is /app (This is our project root inside the Docker container)
project_root_inside_container = Path(__file__).resolve().parent.parent
if str(project_root_inside_container) not in sys.path:
    sys.path.insert(0, str(project_root_inside_container))
    print(f"DEBUG: Added to sys.path: {str(project_root_inside_container)}")
    print(f"DEBUG: Current sys.path: {sys.path}")

# --- Prefect Imports ---
from prefect import flow, get_run_logger
from prefect.deployments import run_deployment

# --- Local Module Imports (relative to /app) ---
from tasks.intake import intake_task
from tasks.splice import splice_video_task
from tasks.sprite import generate_sprite_sheet_task
from tasks.merge import merge_clips_task
from tasks.split import split_clip_task

from db.sync_db import (
    get_all_pending_work,
    get_source_input_from_db,
    get_pending_merge_pairs,
    get_pending_split_jobs,
    initialize_db_pool,
    update_clip_state_sync,
    update_source_video_state_sync,
    get_db_connection,
    release_db_connection
)

# --- Configuration ---
TASK_SUBMIT_DELAY = float(os.getenv("TASK_SUBMIT_DELAY", 0.1)) # Delay between task submissions
ACTION_COMMIT_GRACE_PERIOD_SECONDS = int(os.getenv("ACTION_COMMIT_GRACE_PERIOD_SECONDS", 10))
MAX_NEW_SUBMISSIONS_PER_CYCLE = int(os.getenv("MAX_NEW_SUBMISSIONS_PER_CYCLE", 10)) # Limit submissions per initiator cycle
MAX_TASK_RETRIES = int(os.getenv("MAX_TASK_RETRIES", 3)) # Max retries for a task before it's not picked up by initiator
DEFAULT_BATCH_SIZE = int(os.getenv("DEFAULT_BATCH_SIZE", 5)) # Number of tasks to submit in one batch
DEFAULT_BATCH_DELAY = int(os.getenv("DEFAULT_BATCH_DELAY", 2)) # Seconds to wait between batches

# =============================================================================
# ===                        COMMIT WORKER LOGIC                            ===
# =============================================================================
def _commit_pending_review_actions(environment: str, grace_period_seconds: int):
    """
    Find the newest 'selected_*' event for every clip that is still in
    'pending_review', has survived the grace period and was *not* undone,
    then atomically:

      • (for grouping) populate grouped_with_clip_id
      • (for splitting) populate processing_metadata with split_request_at_frame
      • move the clip to its post‑review ingest_state
      • stamp action_committed_at
    """
    logger = get_run_logger()

    if grace_period_seconds <= 0:
        logger.debug("Commit grace period ≤ 0 – skipping.")
        return 0

    committed_count = 0
    conn = None
    try:
        conn = get_db_connection(environment, cursor_factory=psycopg2.extras.RealDictCursor)

        with conn:                              # Outer transaction for all actions
            with conn.cursor() as cur:

                find_sql = """
                WITH latest AS (
                  SELECT  ce.clip_id,
                          ce.action,
                          ce.created_at,
                          ce.event_data,
                          ROW_NUMBER() OVER (PARTITION BY ce.clip_id
                                             ORDER BY ce.created_at DESC) AS rn
                  FROM    clip_events ce
                  WHERE   ce.action LIKE 'selected_%%'
                    AND   ce.action <> 'selected_undo'
                )
                SELECT  l.clip_id,
                        l.action,
                        l.event_data,
                        l.created_at AS action_time
                FROM    latest l
                JOIN    clips  c ON c.id = l.clip_id
                WHERE   l.rn = 1
                  AND   c.ingest_state = 'pending_review'
                  AND   l.created_at < (NOW() - INTERVAL %s)
                  AND   (c.action_committed_at IS NULL OR l.created_at > c.action_committed_at)
                  AND   NOT EXISTS (
                         SELECT 1
                         FROM   clip_events u
                         WHERE  u.clip_id = l.clip_id
                           AND  u.action  = 'selected_undo'
                           AND  u.created_at > l.created_at )
                ORDER BY l.created_at;
                """
                cur.execute(find_sql, (f'{grace_period_seconds} seconds',))
                actions = cur.fetchall()

                if not actions:
                    logger.debug(f"No review actions ready for commit in env '{environment}'.")
                    return 0

                logger.info(f"Committing {len(actions)} clip actions in env '{environment}'…")

                for row in actions:
                    clip_id    = row["clip_id"]
                    action     = row["action"]
                    # Ensure event_data is a dict, even if NULL/None from DB
                    event_data = row.get("event_data") or {}
                    target_state = None
                    processing_metadata_update_payload = None # For actions that need to update this field

                    if   action == "selected_approve":
                        target_state = "review_approved"
                    elif action == "selected_skip":
                        target_state = "skipped"
                    elif action == "selected_archive":
                        target_state = "archived_pending_deletion"
                    elif action == "selected_merge_source":
                        target_state = "marked_for_merge_into_previous"
                    elif action == "selected_merge_target":
                        target_state = "pending_merge_target"
                    elif action == "selected_group_source":
                        target_state = "review_approved"
                    elif action == "selected_group_target":
                        target_state = "review_approved"
                    elif action == "selected_split":
                        target_state = "pending_split"
                        split_at_frame_val = event_data.get("split_at_frame")

                        if split_at_frame_val is not None:
                            try:
                                frame_to_split = int(split_at_frame_val)
                                processing_metadata_update_payload = psycopg2.extras.Json({
                                    "split_request_at_frame": frame_to_split
                                })
                                logger.debug(f"[Clip {clip_id}, Env {environment}] Action '{action}' will set processing_metadata with split_request_at_frame: {frame_to_split}")
                            except (ValueError, TypeError):
                                logger.warning(
                                    f"[Clip {clip_id}, Env {environment}] 'selected_split' action for clip {clip_id} has invalid "
                                    f"'split_at_frame' ('{split_at_frame_val}') in event_data. Skipping commit for this action."
                                )
                                continue # Skip this action if data is bad
                        else:
                            logger.warning(
                                f"[Clip {clip_id}, Env {environment}] 'selected_split' action for clip {clip_id} is missing "
                                f"'split_at_frame' in event_data. Skipping commit for this action."
                            )
                            continue # Skip if essential data is missing
                    else:
                        logger.warning(f"[Clip {clip_id}, Env {environment}] Unknown action '{action}' encountered during commit. Skipping.")
                        continue

                    # Inner transaction per clip effectively (managed by outer `with conn:` and loop structure)
                    try:
                        # Specific pre-update logic for 'selected_group_source'
                        if action == "selected_group_source":
                            group_target_id = None
                            if "group_with_clip_id" in event_data:
                                try:
                                    group_target_id = int(event_data["group_with_clip_id"])
                                except (ValueError, TypeError):
                                    logger.warning(f"[Clip {clip_id}, Env {environment}] Invalid group_with_clip_id '{event_data.get('group_with_clip_id')}' in event_data for grouping.")
                                    group_target_id = None # Ensure it's None if conversion fails


                            if not group_target_id: # Fallback for very old events
                                cur.execute(
                                    """
                                    SELECT event_data ->> 'group_with_clip_id'
                                    FROM   clip_events
                                    WHERE  clip_id = %s AND action  = 'selected_group_source'
                                    ORDER  BY created_at DESC LIMIT  1;
                                    """, (clip_id,))
                                res = cur.fetchone()
                                if res and res[0]: # res[0] is the value of event_data ->> 'group_with_clip_id'
                                    try:
                                        group_target_id = int(res[0])
                                    except (ValueError, TypeError):
                                        logger.warning(f"[Clip {clip_id}, Env {environment}] Invalid group_with_clip_id '{res[0]}' from DB fallback for grouping.")
                                        group_target_id = None


                            if group_target_id:
                                cur.execute(
                                    "UPDATE clips SET grouped_with_clip_id = %s WHERE id = %s;",
                                    (group_target_id, clip_id)
                                )
                                logger.info(f"[Clip {clip_id}, Env {environment}] Updated grouped_with_clip_id to {group_target_id} for action '{action}'.")
                            else:
                                logger.warning(
                                    f"[Clip {clip_id}, Env {environment}] Group requested but no valid target id found for '{action}'. "
                                    "Leaving grouped_with_clip_id NULL or unchanged."
                                )

                        # General update for ingest_state, action_committed_at, and conditionally processing_metadata
                        if processing_metadata_update_payload:
                            # This is for actions that need to update processing_metadata (e.g., split)
                            cur.execute(
                                """
                                UPDATE clips
                                SET    ingest_state = %s,
                                       action_committed_at = NOW(),
                                       updated_at = NOW(),
                                       processing_metadata = COALESCE(processing_metadata, '{}'::jsonb) || %s::jsonb
                                WHERE  id = %s AND ingest_state = 'pending_review';
                                """, (target_state, processing_metadata_update_payload, clip_id)
                            )
                        else:
                            # This is for actions that DO NOT update processing_metadata
                            cur.execute(
                                """
                                UPDATE clips
                                SET    ingest_state = %s,
                                       action_committed_at = NOW(),
                                       updated_at = NOW()
                                WHERE  id = %s AND ingest_state = 'pending_review';
                                """, (target_state, clip_id)
                            )

                        if cur.rowcount == 1:
                            committed_count += 1
                            logger.info(f"[Clip {clip_id}, Env {environment}] Action '{action}' → state '{target_state}' committed.")
                            if processing_metadata_update_payload:
                                logger.info(f"[Clip {clip_id}, Env {environment}] Also updated processing_metadata for action '{action}'.")
                        else:
                            logger.warning(
                                f"[Clip {clip_id}, Env {environment}] State may have changed concurrently, item not found, or not in 'pending_review'; "
                                f"commit for action '{action}' skipped (rowcount: {cur.rowcount}). Expected state 'pending_review'."
                            )
                    except Exception as e_inner:
                        logger.error(f"[Clip {clip_id}, Env {environment}] Inner commit transaction failed for action '{action}': {e_inner}", exc_info=True)
                        # This error, if not re-raised, allows other clips to be processed.
                        # The outer 'with conn:' block ensures atomicity for the entire batch if an error
                        # propagates out of this loop (e.g., from db_err below).
                        # For now, log and continue with other clips as per original structure.

    except (Exception, psycopg2.Error) as db_err: # Catch psycopg2 specific errors too
        logger.error(f"Commit-worker (env: {environment}) encountered a database error: {db_err}", exc_info=True)
        # If this block is hit, the 'with conn:' context manager will trigger a rollback for all actions in this cycle.
    finally:
        if conn:
            release_db_connection(conn, environment)

    logger.info(f"Finished commit step for env '{environment}'. Committed {committed_count} clip action(s).")
    return committed_count


# =============================================================================
# ===                        PROCESSING FLOWS                               ===
# =============================================================================

@flow(log_prints=True)
def scheduled_ingest_initiator(
    limit_per_stage: int = 50,
    environment: str | None = None,
    batch_size: int = DEFAULT_BATCH_SIZE,
    batch_delay_seconds: int = DEFAULT_BATCH_DELAY
):
    """
    The main initiator flow that runs on a schedule.
    It finds all pending work items in the database and creates Prefect task/flow runs for them.
    Work is processed in batches to avoid overwhelming the system.
    """
    logger = get_run_logger()
    # Determine the operating environment from the parameter, or the worker's APP_ENV as a fallback.
    effective_env = environment if environment else os.getenv("APP_ENV", "development")
    worker_app_env_actual = os.getenv("APP_ENV", "<APP_ENV not set>") # Store for logging
    logger.info(f"INITIATOR FLOW: Running in environment: '{effective_env}'. Provided param: '{environment}', Worker actual APP_ENV: '{worker_app_env_actual}'.")

    submitted_futures = [] # List to store futures of submitted tasks

    # Initialize DB pool for the determined environment *once* per flow run if not already done
    try:
        logger.info(f"Initializing DB pool for environment: '{effective_env}' in initiator flow...")
        initialize_db_pool(environment=effective_env)
        logger.info(f"DB pool for '{effective_env}' should be initialized.")
    except Exception as pool_init_err:
        logger.error(f"Failed to initialize DB pool for '{effective_env}' in initiator: {pool_init_err}", exc_info=True)
        raise # Critical failure, cannot proceed without DB pool

    submitted_this_cycle = 0

    # --- 1. Commit Review Actions ---
    logger.info(f"INITIATOR ('{effective_env}'): Checking for review actions to commit...")
    try:
        committed_count = _commit_pending_review_actions(environment=effective_env, grace_period_seconds=ACTION_COMMIT_GRACE_PERIOD_SECONDS)
        logger.info(f"Committed {committed_count} review actions in '{effective_env}'.")
    except Exception as e_commit:
        logger.error(f"Error committing review actions in '{effective_env}': {e_commit}", exc_info=True)

    # --- 2. Process General Pending Work (Intake, Splice, Post-Review, Sprite Generation) ---
    if submitted_this_cycle < MAX_NEW_SUBMISSIONS_PER_CYCLE:
        logger.info(f"INITIATOR ('{effective_env}'): Checking for general pending work (intake, splice, sprite, post-review)... Max retries for tasks: {MAX_TASK_RETRIES}")
        try:
            items_to_process = get_all_pending_work(environment=effective_env, limit_per_stage=limit_per_stage, max_retries=MAX_TASK_RETRIES)
            logger.info(f"Found {len(items_to_process)} general pending work items in '{effective_env}'.")

            post_review_items = [] # Defer post-review items for batched processing

            if not items_to_process:
                logger.info(f"No general pending work found across any stage in '{effective_env}'.")
            else:
                for item in items_to_process:
                    if submitted_this_cycle >= MAX_NEW_SUBMISSIONS_PER_CYCLE:
                        logger.info(f"Reached max submissions ({MAX_NEW_SUBMISSIONS_PER_CYCLE}), deferring further general tasks for '{effective_env}'.")
                        break

                    item_id = item.get('id')
                    stage = item.get('stage')
                    logger.info(f"Processing item ID: {item_id}, Stage: {stage} in '{effective_env}'")

                    try:
                        if stage == 'intake':
                            logger.info(f"Attempting to set state to 'downloading' for source_video_id {item_id} in '{effective_env}' before submitting intake task.")
                            # Initiator looks for 'new' or 'download_failed'
                            if update_source_video_state_sync(environment=effective_env, source_video_id=item_id, new_state='downloading', expected_old_state='new') or \
                               update_source_video_state_sync(environment=effective_env, source_video_id=item_id, new_state='downloading', expected_old_state='download_failed'):
                                input_val = get_source_input_from_db(source_video_id=item_id, environment=effective_env)
                                if input_val:
                                    logger.info(f"State successfully set to 'downloading' for source_video_id {item_id}. Submitting intake_task with input '{input_val[:50]}...'.")
                                    future = intake_task.submit(source_video_id=item_id, input_source=input_val, environment=effective_env)
                                    submitted_futures.append(future)
                                    submitted_this_cycle += 1
                                else:
                                    logger.warning(f"State set to 'downloading' for source_video_id {item_id}, but no input_source found in DB. Reverting state or marking as error might be needed.")
                                    update_source_video_state_sync(environment=effective_env, source_video_id=item_id, new_state='download_failed', error_message='Missing input_source in DB after state transition for intake.')
                            else:
                                logger.warning(f"Failed to update state to 'downloading' for source_video_id {item_id} (expected 'new' or 'download_failed'). Skipping intake task submission. Current state might have been changed by another process.")

                        elif stage == 'splice':
                            logger.info(f"Attempting to set state to 'splicing' for source_video_id {item_id} in '{effective_env}' before submitting splice task.")
                            if update_source_video_state_sync(environment=effective_env, source_video_id=item_id, new_state='splicing', expected_old_state='downloaded') or \
                               update_source_video_state_sync(environment=effective_env, source_video_id=item_id, new_state='splicing', expected_old_state='splicing_failed'):
                                logger.info(f"State successfully set to 'splicing' for source_video_id {item_id}. Submitting splice_video_task.")
                                future = splice_video_task.submit(source_video_id=item_id, environment=effective_env)
                                submitted_futures.append(future)
                                submitted_this_cycle += 1
                            else:
                                logger.warning(f"Failed to update state to 'splicing' for source_video_id {item_id} (expected 'downloaded' or 'splicing_failed'). Skipping splice task submission.")
                        
                        elif stage == 'pending_sprite_generation':
                            logger.info(f"Attempting to set state to 'generating_sprite' for clip_id {item_id} in '{effective_env}' before submitting sprite task.")
                            if update_clip_state_sync(environment=effective_env, clip_id=item_id, new_state='generating_sprite', expected_old_state='pending_sprite_generation'):
                                logger.info(f"State successfully set to 'generating_sprite' for clip_id {item_id}. Submitting generate_sprite_sheet_task.")
                                future = generate_sprite_sheet_task.submit(clip_id=item_id, environment=effective_env, overwrite_existing=False)
                                submitted_futures.append(future)
                                submitted_this_cycle += 1
                            else:
                                logger.warning(f"Failed to update state to 'generating_sprite' for clip_id {item_id} (expected 'pending_sprite_generation'). Skipping sprite task submission.")

                        elif stage == 'post_review':
                            # Defer for batched submission later
                            post_review_items.append(item)
                        
                        else:
                            logger.warning(f"Unknown stage '{stage}' for item_id {item_id} in general processing. Skipping.")

                    except psycopg2.Error as db_err_item_processing:
                        logger.error(f"Database error processing general item ID {item_id}, Stage {stage} in '{effective_env}': {db_err_item_processing}", exc_info=True)
                    except Exception as e_item:
                        logger.error(f"Error submitting task for general item ID {item_id}, Stage {stage} in '{effective_env}': {e_item}", exc_info=True)
        
        except psycopg2.Error as db_err_main_loop:
            logger.error(f"Database error in general processing loop of initiator (env '{effective_env}'): {db_err_main_loop}", exc_info=True)
            # Not raising here to allow merge/split to potentially run
        except Exception as e_main:
            logger.error(f"General error in general processing loop of initiator (env '{effective_env}'): {e_main}", exc_info=True)
            # Not raising here

    # --- 3. Process Pending Merge Pairs ---
    if submitted_this_cycle < MAX_NEW_SUBMISSIONS_PER_CYCLE:
        logger.info(f"INITIATOR ('{effective_env}'): Checking for pending merge pairs... Max retries for tasks: {MAX_TASK_RETRIES}")
        try:
            pending_merges = get_pending_merge_pairs(environment=effective_env, max_retries=MAX_TASK_RETRIES)
            if pending_merges:
                logger.info(f"Found {len(pending_merges)} merge pairs to process in '{effective_env}'.")
                for target_id, source_id in pending_merges:
                    if submitted_this_cycle >= MAX_NEW_SUBMISSIONS_PER_CYCLE:
                        logger.info(f"Reached max submissions ({MAX_NEW_SUBMISSIONS_PER_CYCLE}), deferring further merge tasks for '{effective_env}'.")
                        break
                    try:
                        logger.info(f"Attempting state updates for merge: Target {target_id} ('pending_merge_target' -> 'merging_target'), Source {source_id} ('marked_for_merge_into_previous' -> 'merging_source')")
                        target_updated = update_clip_state_sync(environment=effective_env, clip_id=target_id, new_state='merging_target', expected_old_state='pending_merge_target')
                        source_updated = False # Initialize
                        if target_updated:
                            source_updated = update_clip_state_sync(environment=effective_env, clip_id=source_id, new_state='merging_source', expected_old_state='marked_for_merge_into_previous')
                        
                        if target_updated and source_updated:
                            logger.info(f"States successfully updated for merge. Submitting merge_clips_task for target {target_id}, source {source_id} in '{effective_env}'.")
                            future = merge_clips_task.submit(clip_id_target=target_id, clip_id_source=source_id, environment=effective_env)
                            submitted_futures.append(future)
                            submitted_this_cycle += 1
                            time.sleep(TASK_SUBMIT_DELAY) # Small delay
                        else:
                            logger.warning(f"Failed to update states for merge pair (Target: {target_id}, Source: {source_id}). Target update: {target_updated}, Source update: {source_updated}. Skipping submission.")
                            if target_updated and not source_updated: # Rollback target if source failed
                                logger.info(f"Rolling back target clip {target_id} state to 'pending_merge_target'.")
                                update_clip_state_sync(environment=effective_env, clip_id=target_id, new_state='pending_merge_target', expected_old_state='merging_target')
                            # If target_updated is false, source_updated wouldn't have been attempted or would be false.

                    except Exception as e_merge_submit:
                        logger.error(f"Failed to submit merge_clips_task for target {target_id}, source {source_id} in '{effective_env}': {e_merge_submit}", exc_info=True)
            else:
                logger.info(f"No pending merge pairs found in '{effective_env}'.")
        except Exception as e_get_merges:
            logger.error(f"Error fetching pending merge pairs in '{effective_env}': {e_get_merges}", exc_info=True)

    # --- 4. Process Pending Split Jobs ---
    if submitted_this_cycle < MAX_NEW_SUBMISSIONS_PER_CYCLE:
        logger.info(f"INITIATOR ('{effective_env}'): Checking for pending split jobs... Max retries for tasks: {MAX_TASK_RETRIES}")
        try:
            pending_splits = get_pending_split_jobs(environment=effective_env, max_retries=MAX_TASK_RETRIES) # Pass environment and max_retries
            if pending_splits:
                logger.info(f"Found {len(pending_splits)} split jobs to process in '{effective_env}'.")
                for original_clip_id, split_frame in pending_splits: # Assuming get_pending_split_jobs returns this tuple
                    if submitted_this_cycle >= MAX_NEW_SUBMISSIONS_PER_CYCLE:
                        logger.info(f"Reached max submissions ({MAX_NEW_SUBMISSIONS_PER_CYCLE}), deferring further split tasks for '{effective_env}'.")
                        break
                    try:
                        logger.info(f"Attempting state update for split: Clip {original_clip_id} ('pending_split' -> 'splitting')")
                        if update_clip_state_sync(environment=effective_env, clip_id=original_clip_id, new_state='splitting', expected_old_state='pending_split'):
                            logger.info(f"State updated to 'splitting' for clip {original_clip_id}. Submitting split_clip_task for frame {split_frame} in '{effective_env}'.")
                            future = split_clip_task.submit(clip_id=original_clip_id, environment=effective_env)
                            submitted_futures.append(future)
                            submitted_this_cycle += 1
                            time.sleep(TASK_SUBMIT_DELAY)
                        else:
                            logger.warning(f"Failed to update state to 'splitting' for clip {original_clip_id} (expected 'pending_split'). Skipping submission.")
                    except Exception as e_split_submit:
                        logger.error(f"Failed to submit split_clip_task for clip {original_clip_id} in '{effective_env}': {e_split_submit}", exc_info=True)
            else:
                logger.info(f"No pending split jobs found in '{effective_env}'.")
        except Exception as e_get_splits:
            logger.error(f"Error fetching pending split jobs in '{effective_env}': {e_get_splits}", exc_info=True)

    # --- 5. Process Post-Review Clips (Batched) ---
    if post_review_items:
        logger.info(f"Found {len(post_review_items)} 'post_review' clips to process in batches.")
        
        submitted_in_batch_count = 0
        for i in range(0, len(post_review_items), batch_size):
            batch = post_review_items[i:i + batch_size]
            logger.info(f"Processing batch {i//batch_size + 1}/{(len(post_review_items) + batch_size - 1)//batch_size} "
                        f"with {len(batch)} clips.")

            for clip_data in batch:
                clip_id = clip_data['id']
                
                # Check submission limit before processing this item
                if (submitted_this_cycle + submitted_in_batch_count) >= MAX_NEW_SUBMISSIONS_PER_CYCLE:
                    logger.info(f"Reached max submissions ({MAX_NEW_SUBMISSIONS_PER_CYCLE}) during batch processing. Deferring remaining post-review clips.")
                    break # Break from inner loop (current batch)

                logger.info(f"Attempting to set state to 'post_review_initiated' for clip_id {clip_id} (expected 'review_approved') in '{effective_env}'.")
                if update_clip_state_sync(
                    environment=effective_env,
                    clip_id=clip_id,
                    new_state='post_review_initiated',
                    expected_old_state='review_approved'
                ):
                    logger.info(f"State for clip {clip_id} successfully set to 'post_review_initiated'. Submitting 'process-clip-post-review' deployment.")
                    try:
                        run_deployment(
                            name="process-clip-post-review/process-clip-post-review-default",
                            parameters={"clip_id": clip_id, "environment": effective_env},
                            timeout=0,  # Fire-and-forget
                        )
                        submitted_in_batch_count += 1
                        time.sleep(TASK_SUBMIT_DELAY)
                    except Exception as e:
                        logger.error(f"Failed to submit deployment for clip_id {clip_id}: {e}", exc_info=True)
                        # Optionally, revert state if submission fails
                        update_clip_state_sync(environment=effective_env, clip_id=clip_id, new_state='review_approved', expected_old_state='post_review_initiated', error_message=f"Deployment submission failed: {e}")
                else:
                    logger.warning(f"Failed to update state for clip {clip_id} from 'review_approved' to 'post_review_initiated'. It may have been processed by another worker. Skipping.")
            
            # After each batch, check if we should break from the outer loop
            if (submitted_this_cycle + submitted_in_batch_count) >= MAX_NEW_SUBMISSIONS_PER_CYCLE:
                break 

            if i + batch_size < len(post_review_items):
                logger.info(f"Batch submitted. Waiting for {batch_delay_seconds}s before next batch...")
                time.sleep(batch_delay_seconds)
        
        submitted_this_cycle += submitted_in_batch_count
        if submitted_in_batch_count > 0:
            logger.info(f"Total of {submitted_in_batch_count} 'process-clip-post-review' flow runs submitted in batches.")

    # --- Wait for all submitted task futures to complete ---
    if submitted_futures:
        logger.info(f"INITIATOR FLOW: Waiting for {len(submitted_futures)} submitted tasks to complete or fail...")
        for i, task_future in enumerate(submitted_futures):
            try:
                # Wait indefinitely for this specific task to finish
                logger.info(f"Waiting for task future {i+1}/{len(submitted_futures)} (Task: {task_future.task_run.name if hasattr(task_future, 'task_run') else 'Unknown'})...")
                task_future.result(timeout=None) 
                logger.info(f"Task future {i+1}/{len(submitted_futures)} completed (result collected).")
            except Exception as e_wait:
                # This will catch task failures if .result() re-raises them,
                # or other errors during waiting.
                logger.error(f"Error or task failure while waiting for future {i+1}/{len(submitted_futures)}: {type(e_wait).__name__} - {str(e_wait)[:500]}", exc_info=False)
        logger.info(f"INITIATOR FLOW: All {len(submitted_futures)} submitted tasks have been waited upon.")
    else:
        logger.info("INITIATOR FLOW: No tasks were submitted in this cycle to wait for.")

    logger.info(f"INITIATOR FLOW: Finished processing cycle in '{effective_env}'. Submitted {submitted_this_cycle} tasks/deployments.") 