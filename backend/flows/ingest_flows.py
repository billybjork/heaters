import sys
import os
from pathlib import Path
import traceback
import time
import psycopg2
import psycopg2.extras
from datetime import timedelta, timezone
import logging

# --- Project Root Setup ---
# Path(__file__).parent.parent is /app (This is our project root inside the Docker container)
project_root_inside_container = Path(__file__).resolve().parent.parent
if str(project_root_inside_container) not in sys.path:
    sys.path.insert(0, str(project_root_inside_container))
    print(f"DEBUG: Added to sys.path: {str(project_root_inside_container)}")
    print(f"DEBUG: Current sys.path: {sys.path}")

# --- Prefect Imports ---
from prefect import flow, get_run_logger, task
from prefect.deployments import run_deployment

# --- Local Module Imports (relative to /app) ---
from tasks.intake import intake_task
from tasks.splice import splice_video_task
from tasks.sprite import generate_sprite_sheet_task
from tasks.keyframe import extract_keyframes_task
from tasks.embed import generate_embeddings_task
from tasks.merge import merge_clips_task
from tasks.split import split_clip_task

from config import get_s3_resources

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

_flow_bootstrap_logger = logging.getLogger(__name__) # For logging import errors
try:
    from db.async_db import get_db_connection as get_async_db_connection, get_db_pool, close_db_pool
    ASYNC_DB_CONFIGURED = True
except ImportError as e:
    _flow_bootstrap_logger.error(
        f"CRITICAL: Failed to import async DB utilities from db.async_db: {e}. "
        "Async cleanup flow will not function.",
        exc_info=True
    )
    ASYNC_DB_CONFIGURED = False
    get_async_db_connection, get_db_pool, close_db_pool = None, None, None

try:
    from botocore.exceptions import ClientError
    S3_CONFIGURED = True
except ImportError:
     S3_CONFIGURED = False
     ClientError = Exception

# --- Configuration ---
DEFAULT_KEYFRAME_STRATEGY = os.getenv("DEFAULT_KEYFRAME_STRATEGY", "midpoint")
DEFAULT_EMBEDDING_MODEL = os.getenv("DEFAULT_EMBEDDING_MODEL", "openai/clip-vit-base-patch32")
DEFAULT_EMBEDDING_STRATEGY_LABEL = f"keyframe_{DEFAULT_KEYFRAME_STRATEGY}"
TASK_SUBMIT_DELAY = float(os.getenv("TASK_SUBMIT_DELAY", 0.1)) # Delay between task submissions
KEYFRAME_TIMEOUT = int(os.getenv("KEYFRAME_TIMEOUT", 600)) # Timeout for keyframe task result
EMBEDDING_TIMEOUT = int(os.getenv("EMBEDDING_TIMEOUT", 900)) # Timeout for embedding task result
CLIP_CLEANUP_DELAY_MINUTES = int(os.getenv("CLIP_CLEANUP_DELAY_MINUTES", 30))
ACTION_COMMIT_GRACE_PERIOD_SECONDS = int(os.getenv("ACTION_COMMIT_GRACE_PERIOD_SECONDS", 10))

# Configuration for limiting submissions per initiator cycle
MAX_NEW_SUBMISSIONS_PER_CYCLE = int(os.getenv("MAX_NEW_SUBMISSIONS_PER_CYCLE", 15))

# --- Constants ---
ARTIFACT_TYPE_SPRITE_SHEET = "sprite_sheet"


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
                          ce.event_data, -- Ensure event_data is selected
                          ROW_NUMBER() OVER (PARTITION BY ce.clip_id
                                             ORDER BY ce.created_at DESC) AS rn
                  FROM    clip_events ce
                  WHERE   ce.action LIKE 'selected_%%'
                    AND   ce.action <> 'selected_undo'
                )
                SELECT  l.clip_id,
                        l.action,
                        l.event_data, -- Ensure event_data is selected
                        l.created_at AS action_time
                FROM    latest l
                JOIN    clips  c ON c.id = l.clip_id
                WHERE   l.rn = 1
                  AND   c.ingest_state = 'pending_review'
                  AND   l.created_at < (NOW() - INTERVAL %s)
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
                                # The split_clip_task expects "split_request_at_frame"
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
                                    """, (clip_id,)
                                )
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
def process_clip_post_review(
    clip_id: int,
    keyframe_strategy: str = DEFAULT_KEYFRAME_STRATEGY,
    model_name: str = DEFAULT_EMBEDDING_MODEL,
    environment: str = "development"
    ):
    """Processes an approved clip: keyframing and embedding."""
    logger = get_run_logger()
    logger.info(f"FLOW: Starting post-review processing for approved clip_id: {clip_id}, Env: {environment}")
    keyframe_task_succeeded_or_skipped = False

    try:
        # --- 1. Keyframing ---
        logger.info(f"Submitting keyframe task for clip_id: {clip_id} with strategy: {keyframe_strategy}, Env: {environment}")
        keyframe_job = extract_keyframes_task.submit(clip_id=clip_id, strategy=keyframe_strategy, overwrite=False, environment=environment)
        logger.info(f"Waiting for keyframe task result for clip {clip_id} (timeout: {KEYFRAME_TIMEOUT}s)")
        keyframe_result = keyframe_job.result(timeout=KEYFRAME_TIMEOUT) # Wait for result

        keyframe_status = None
        if isinstance(keyframe_result, dict): keyframe_status = keyframe_result.get("status")
        elif keyframe_result is None: keyframe_status = "skipped_or_success" # Treat None as acceptable skip/success
        else: keyframe_status = "failed_unexpected_result"

        keyframe_failure_statuses = ["failed", "failed_db_phase1", "failed_processing", "failed_state_update", "failed_db_update", "failed_unexpected", "failed_unexpected_result"]
        keyframe_acceptable_skip_statuses = ["skipped_exists", "skipped_state", "skipped_logic", "skipped_or_success"]

        if keyframe_status == "success":
            logger.info(f"Keyframing task OK for clip_id: {clip_id}.")
            keyframe_task_succeeded_or_skipped = True
        elif keyframe_status in keyframe_acceptable_skip_statuses:
            logger.info(f"Keyframing task for clip {clip_id} status '{keyframe_status}'. Assuming acceptable skip.")
            keyframe_task_succeeded_or_skipped = True
        elif keyframe_status in keyframe_failure_statuses:
            raise RuntimeError(f"Keyframing task failed for clip {clip_id}. Status: {keyframe_status}")
        else: # Unknown status
            raise RuntimeError(f"Keyframing task for clip {clip_id} returned an unknown status: {keyframe_status}")

        # --- 2. Embedding ---
        if keyframe_task_succeeded_or_skipped:
            embedding_strategy_label = f"keyframe_{keyframe_strategy}_avg" if keyframe_strategy == "multi" else f"keyframe_{keyframe_strategy}"
            logger.info(f"Submitting embedding task for clip_id: {clip_id}, model: {model_name}, strategy: {embedding_strategy_label}, Env: {environment}")
            embedding_job = generate_embeddings_task.submit(clip_id=clip_id, model_name=model_name, generation_strategy=embedding_strategy_label, overwrite=False, environment=environment)
            logger.info(f"Waiting for embedding task result for clip {clip_id} (timeout: {EMBEDDING_TIMEOUT}s)")
            embed_result = embedding_job.result(timeout=EMBEDDING_TIMEOUT) # Wait for result

            embed_status = None
            if isinstance(embed_result, dict): embed_status = embed_result.get("status")
            elif embed_result is None: embed_status = "skipped_or_success" # Treat None as acceptable skip/success
            else: embed_status = "failed_unexpected_result"

            embed_failure_statuses = ["failed", "failed_db_phase1", "failed_processing", "failed_state_update", "failed_db_update", "failed_unexpected", "failed_unexpected_result"]
            embed_acceptable_skip_statuses = ["skipped_exists", "skipped_state", "skipped_or_success"]

            if embed_status == "success":
                logger.info(f"Embedding task OK for clip_id: {clip_id}.")
            elif embed_status in embed_acceptable_skip_statuses:
                logger.info(f"Embedding task for clip {clip_id} status '{embed_status}'. Assuming acceptable skip.")
            elif embed_status in embed_failure_statuses:
                raise RuntimeError(f"Embedding task failed for clip {clip_id}. Status: {embed_status}")
            else: # Unknown status
                raise RuntimeError(f"Embedding task for clip {clip_id} returned an unknown status: {embed_status}")
        else:
            logger.warning(f"Skipping embedding for clip {clip_id} due to prior keyframing outcome.")

    except Exception as e:
        stage = "embedding" if keyframe_task_succeeded_or_skipped else "keyframing"
        logger.error(f"Error during post-review processing flow (stage: {stage}, env: {environment}) for clip_id {clip_id}: {e}", exc_info=True)
        raise # Re-raise to mark the flow run as failed
    logger.info(f"FLOW: Finished post-review processing flow for clip_id: {clip_id}, Env: {environment}")


@flow(name="Scheduled Ingest Initiator", log_prints=True)
def scheduled_ingest_initiator(limit_per_stage: int = 50, environment: str | None = None):
    """
    Main Prefect flow to periodically check for pending work across various ingest stages.
    The environment for this flow and the tasks it triggers is determined by the
    explicit 'environment' parameter, falling back to the worker's APP_ENV if not provided.
    """
    logger = get_run_logger()
    # Determine the operating environment from the parameter, or the worker's APP_ENV as a fallback.
    effective_env = environment if environment else os.getenv("APP_ENV", "development")
    logger.info(f"INITIATOR FLOW: Running in environment: '{effective_env}'. Provided param: '{environment}', Worker APP_ENV fallback: '{os.getenv("APP_ENV")}'.")

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

    # --- 2. Process Pending Merge Pairs (before general work to prioritize merges) ---
    if submitted_this_cycle < MAX_NEW_SUBMISSIONS_PER_CYCLE:
        logger.info(f"INITIATOR ('{effective_env}'): Checking for pending merge pairs...")
        try:
            pending_merges = get_pending_merge_pairs(environment=effective_env)
            if pending_merges:
                logger.info(f"Found {len(pending_merges)} merge pairs to process in '{effective_env}'.")
                for target_id, source_id in pending_merges:
                    if submitted_this_cycle >= MAX_NEW_SUBMISSIONS_PER_CYCLE:
                        logger.info(f"Reached max submissions ({MAX_NEW_SUBMISSIONS_PER_CYCLE}), deferring further merge tasks for '{effective_env}'.")
                        break
                    try:
                        logger.info(f"Submitting merge_clips_task for target {target_id}, source {source_id} in '{effective_env}'.")
                        merge_clips_task.submit(clip_id_target=target_id, clip_id_source=source_id, environment=effective_env)
                        submitted_this_cycle += 1
                        time.sleep(TASK_SUBMIT_DELAY) # Small delay
                    except Exception as e_merge_submit:
                        logger.error(f"Failed to submit merge_clips_task for target {target_id}, source {source_id} in '{effective_env}': {e_merge_submit}", exc_info=True)
            else:
                logger.info(f"No pending merge pairs found in '{effective_env}'.")
        except Exception as e_get_merges:
            logger.error(f"Error fetching pending merge pairs in '{effective_env}': {e_get_merges}", exc_info=True)

    # --- 3. Process Pending Split Jobs (before general work to prioritize splits) ---
    if submitted_this_cycle < MAX_NEW_SUBMISSIONS_PER_CYCLE:
        logger.info(f"INITIATOR ('{effective_env}'): Checking for pending split jobs...")
        try:
            pending_splits = get_pending_split_jobs(environment=effective_env) # Pass environment
            if pending_splits:
                logger.info(f"Found {len(pending_splits)} split jobs to process in '{effective_env}'.")
                for original_clip_id, split_frame in pending_splits: # Assuming get_pending_split_jobs returns this tuple
                    if submitted_this_cycle >= MAX_NEW_SUBMISSIONS_PER_CYCLE:
                        logger.info(f"Reached max submissions ({MAX_NEW_SUBMISSIONS_PER_CYCLE}), deferring further split tasks for '{effective_env}'.")
                        break
                    try:
                        logger.info(f"Submitting split_clip_task for original clip {original_clip_id} at frame {split_frame} in '{effective_env}'.")
                        split_clip_task.submit(clip_id=original_clip_id, environment=effective_env)
                        submitted_this_cycle += 1
                        time.sleep(TASK_SUBMIT_DELAY)
                    except Exception as e_split_submit:
                        logger.error(f"Failed to submit split_clip_task for clip {original_clip_id} in '{effective_env}': {e_split_submit}", exc_info=True)
            else:
                logger.info(f"No pending split jobs found in '{effective_env}'.")
        except Exception as e_get_splits:
            logger.error(f"Error fetching pending split jobs in '{effective_env}': {e_get_splits}", exc_info=True)

    # --- 4. Process General Pending Work (Intake, Splice, Post-Review) ---
    logger.info(f"INITIATOR ('{effective_env}'): Checking for general pending work (intake, splice, post-review)...")
    try:
        items_to_process = get_all_pending_work(environment=effective_env, limit_per_stage=limit_per_stage)
        logger.info(f"Found {len(items_to_process)} general pending work items in '{effective_env}'.")

        if not items_to_process:
            logger.info(f"No pending work found across any stage in '{effective_env}'.")
        else:
            for item in items_to_process:
                if submitted_this_cycle >= MAX_NEW_SUBMISSIONS_PER_CYCLE:
                    logger.info(f"Reached max submissions ({MAX_NEW_SUBMISSIONS_PER_CYCLE}), deferring further tasks for '{effective_env}'.")
                    break

                item_id = item.get('id')
                stage = item.get('stage')
                logger.info(f"Processing item ID: {item_id}, Stage: {stage} in '{effective_env}'")

                try:
                    if stage == 'intake':
                        input_val = get_source_input_from_db(source_video_id=item_id, environment=effective_env)
                        if input_val:
                            logger.info(f"Submitting intake_task for source_video_id {item_id} with input '{input_val[:50]}...' in '{effective_env}'")
                            intake_task.submit(source_video_id=item_id, input_source=input_val, environment=effective_env)
                            submitted_this_cycle += 1
                        else:
                            logger.warning(f"Skipping intake for source_video_id {item_id}: No input_source found in DB (env: '{effective_env}').")
                            update_source_video_state_sync(environment=effective_env, source_video_id=item_id, new_state='download_failed', error_message='Missing input_source in DB')

                    elif stage == 'splice':
                        logger.info(f"Submitting splice_video_task for source_video_id {item_id} in '{effective_env}'.")
                        splice_video_task.submit(source_video_id=item_id, environment=effective_env)
                        submitted_this_cycle += 1

                    elif stage == 'sprite': # This was 'sprite' from get_all_pending_work, now interpreted as post-review
                        logger.info(f"Submitting process_clip_post_review deployment for clip_id {item_id} in '{effective_env}'.")
                        run_deployment(
                            name="process-clip-post-review/process-clip-post-review-default",
                            parameters={
                                "clip_id": item_id,
                                "environment": effective_env # Pass the determined environment
                            },
                            timeout=0 # Fire and forget
                        )
                        submitted_this_cycle += 1
                    else:
                        logger.warning(f"Unknown stage '{stage}' for item_id {item_id}. Skipping.")

                    time.sleep(TASK_SUBMIT_DELAY) # Small delay after each submission

                except psycopg2.Error as db_err_item_processing: # Catch DB errors specific to item processing
                    logger.error(f"Database error processing item ID {item_id}, Stage {stage} in '{effective_env}': {db_err_item_processing}", exc_info=True)
                    # Optionally update state to failed for this specific item if appropriate
                except Exception as e_item:
                    logger.error(f"Error submitting task for item ID {item_id}, Stage {stage} in '{effective_env}': {e_item}", exc_info=True)
                    # Log and continue to next item

    except psycopg2.Error as db_err_main_loop:
        logger.error(f"Database error in main processing loop of initiator (env '{effective_env}'): {db_err_main_loop}", exc_info=True)
        raise # Critical failure
    except Exception as e_main:
        logger.error(f"General error in scheduled_ingest_initiator (env '{effective_env}'): {e_main}", exc_info=True)
        raise # Re-raise to make Prefect aware of the failure for the flow run

    logger.info(f"INITIATOR FLOW: Finished processing cycle in '{effective_env}'. Submitted {submitted_this_cycle} tasks/deployments.")


# =============================================================================
# ===                  CLEANUP FLOW                                         ===
# =============================================================================

@flow(name="Scheduled Clip Cleanup", log_prints=True)
async def cleanup_reviewed_clips_flow(
    cleanup_delay_minutes: int = CLIP_CLEANUP_DELAY_MINUTES,
    environment: str = "development"
):
    """
    Cleans up reviewed clips by deleting associated S3 artifacts (sprite sheets)
    and updating their database state. Uses asyncpg for DB operations.
    """
    logger = get_run_logger()
    logger.info(
        f"FLOW: Running Scheduled Clip Cleanup (Delay: {cleanup_delay_minutes} mins, Env: {environment})..."
    )

    # Get S3 resources for this flow run
    s3_client_for_flow, s3_bucket_name_for_flow = get_s3_resources(environment, logger=logger)

    # Check if S3 client was successfully obtained (get_s3_resources raises error on failure, but defensive check)
    if not s3_client_for_flow or not s3_bucket_name_for_flow:
        logger.error("S3 Client/Bucket Name not available from get_s3_resources. Exiting cleanup flow.")
        return # S3_CONFIGURED check is implicitly handled by get_s3_resources

    if not ASYNC_DB_CONFIGURED or not get_async_db_connection:
        logger.error("Async DB not configured or get_async_db_connection function unavailable. Exiting cleanup flow.")
        return

    processed_count = 0
    s3_deleted_count = 0
    db_artifact_deleted_count = 0
    db_clip_updated_count = 0
    error_count = 0

    try:
        async with get_async_db_connection(environment) as conn:
            logger.info("Acquired asyncpg connection via context manager for cleanup flow.")

            delay_interval = timedelta(minutes=cleanup_delay_minutes)
            pending_states = [
                "approved_pending_deletion",
                "archived_pending_deletion",
            ]
            query_clips = """
            SELECT id, ingest_state
              FROM clips
             WHERE ingest_state = ANY($1::text[])
               AND action_committed_at IS NOT NULL
               AND action_committed_at < (NOW() - $2::INTERVAL)
             ORDER BY id ASC;
            """

            clips_to_cleanup = await conn.fetch(
                query_clips, pending_states, delay_interval
            )
            processed_count = len(clips_to_cleanup)
            logger.info(f"Found {processed_count} clips ready for S3 artifact cleanup.")

            if not clips_to_cleanup:
                logger.info("No clips require S3 artifact cleanup at this time.")
                return # Exit early if no work

            for clip_record in clips_to_cleanup:
                clip_id = clip_record["id"]
                current_state = clip_record["ingest_state"]
                log_prefix = f"[Cleanup Clip {clip_id}, Env {environment}]"
                log_prefix = f"[Cleanup Clip {clip_id}]"
                logger.info(f"{log_prefix} Processing for state: {current_state}")

                sprite_artifact_s3_key = None
                s3_deletion_successful = False # Assume failure until success

                try:
                    # 1. Retrieve sprite artifact S3 key
                    artifact_query = """
                    SELECT s3_key FROM clip_artifacts
                     WHERE clip_id = $1 AND artifact_type = $2 LIMIT 1;
                    """
                    artifact_record = await conn.fetchrow(
                        artifact_query, clip_id, ARTIFACT_TYPE_SPRITE_SHEET
                    )

                    if artifact_record and artifact_record["s3_key"]:
                        sprite_artifact_s3_key = artifact_record["s3_key"]
                    else:
                        logger.warning(f"{log_prefix} No sprite sheet artifact found in DB. Assuming S3 deletion step can be skipped.")
                        s3_deletion_successful = True # No S3 key to delete, so "success" for this step

                    # 2. Delete from S3 if key exists
                    if sprite_artifact_s3_key:
                        # Use s3_bucket_name_for_flow obtained from get_s3_resources
                        if not s3_bucket_name_for_flow:
                            logger.error(f"{log_prefix} S3_BUCKET_NAME_FOR_FLOW is not configured (should not happen if get_s3_resources worked). Cannot delete artifact.")
                            error_count += 1
                            s3_deletion_successful = False
                        else:
                            try:
                                logger.info(f"{log_prefix} Deleting S3 object: s3://{s3_bucket_name_for_flow}/{sprite_artifact_s3_key}")
                                # Use s3_client_for_flow obtained from get_s3_resources
                                # Note: s3_client.delete_object is synchronous. For a fully async flow with many S3 ops,
                                # an async S3 client (e.g. aioboto3) would be better, but for a few deletions this is okay.
                                s3_client_for_flow.delete_object(
                                    Bucket=s3_bucket_name_for_flow,
                                    Key=sprite_artifact_s3_key,
                                )
                                logger.info(f"{log_prefix} Successfully deleted S3 object.")
                                s3_deletion_successful = True
                                s3_deleted_count += 1
                            except ClientError as e:
                                error_code = e.response.get("Error", {}).get("Code", "Unknown")
                                if error_code == "NoSuchKey":
                                    logger.warning(f"{log_prefix} S3 object s3://{s3_bucket_name_for_flow}/{sprite_artifact_s3_key} not found (NoSuchKey). Assuming already deleted.")
                                    s3_deletion_successful = True # Treat as success for workflow progression
                                else:
                                    logger.error(f"{log_prefix} Failed to delete S3 object s3://{s3_bucket_name_for_flow}/{sprite_artifact_s3_key}. Code: {error_code}, Error: {e}")
                                    s3_deletion_successful = False
                                    error_count += 1
                            except Exception as e_s3: # Catch other unexpected S3 errors
                                logger.error(f"{log_prefix} Unexpected error during S3 deletion: {e_s3}", exc_info=True)
                                s3_deletion_successful = False
                                error_count += 1

                    # 3. Proceed with DB updates ONLY if S3 deletion was successful (or skipped appropriately)
                    if s3_deletion_successful:
                        final_state_map = {
                            "approved_pending_deletion": "review_approved",
                            "archived_pending_deletion": "archived",
                        }
                        final_clip_state = final_state_map.get(current_state)

                        if not final_clip_state:
                            logger.error(f"{log_prefix} Logic error: No final state mapping for current state '{current_state}'.")
                            error_count += 1
                            continue # Skip to next clip

                        # Start a DB transaction for artifact deletion and clip state update
                        async with conn.transaction():
                            logger.debug(f"{log_prefix} Starting DB transaction for final updates.")
                            # Delete artifact record from DB if it existed
                            if sprite_artifact_s3_key: # Only delete if we had a key
                                delete_artifact_sql = """
                                DELETE FROM clip_artifacts WHERE clip_id = $1 AND artifact_type = $2;
                                """
                                del_res_str = await conn.execute(
                                    delete_artifact_sql, clip_id, ARTIFACT_TYPE_SPRITE_SHEET
                                )
                                # Parse "DELETE N" string
                                deleted_artifact_rows = int(del_res_str.split()[-1]) if del_res_str and del_res_str.startswith("DELETE") else 0
                                if deleted_artifact_rows > 0:
                                    logger.info(f"{log_prefix} Deleted {deleted_artifact_rows} artifact record(s) from DB.")
                                    db_artifact_deleted_count += deleted_artifact_rows
                                else:
                                    logger.warning(f"{log_prefix} No clip_artifact record found/deleted for S3 key {sprite_artifact_s3_key}. This might be okay if S3 key was stale.")


                            # Update clip state and clear action_committed_at
                            update_clip_sql = """
                            UPDATE clips
                               SET ingest_state = $1,
                                   updated_at = NOW(),
                                   action_committed_at = NULL, -- Clear this as action is now complete
                                   last_error = NULL           -- Clear any previous errors
                             WHERE id = $2 AND ingest_state = $3; -- Ensure current state matches
                            """
                            upd_res_str = await conn.execute(
                                update_clip_sql, final_clip_state, clip_id, current_state
                            )
                            # Parse "UPDATE N" string
                            updated_clip_rows = int(upd_res_str.split()[-1]) if upd_res_str and upd_res_str.startswith("UPDATE") else 0

                            if updated_clip_rows == 1:
                                logger.info(f"{log_prefix} Successfully updated clip state to '{final_clip_state}'.")
                                db_clip_updated_count += 1
                            else:
                                # This could happen if the state was changed by another process after fetching clips_to_cleanup
                                logger.warning(
                                    f"{log_prefix} Clip state update to '{final_clip_state}' affected {updated_clip_rows} rows "
                                    f"(expected 1). State might have changed concurrently from '{current_state}'. Transaction will rollback."
                                )
                                # Raise an error to ensure transaction rollback for this clip
                                raise RuntimeError(f"Concurrent state change detected for clip {clip_id}")
                        logger.debug(f"{log_prefix} DB transaction committed.")
                    else:
                        logger.warning(f"{log_prefix} Skipping DB updates for clip {clip_id} due to S3 deletion failure or configuration issue.")

                except Exception as inner_err: # Catch errors within the loop for a single clip
                    logger.error(f"{log_prefix} Error processing clip for cleanup: {inner_err}", exc_info=True)
                    error_count += 1
                    # Continue to the next clip

    except Exception as outer_err: # Catch errors related to DB connection or the overall flow
        logger.error(f"FATAL Error during scheduled clip cleanup flow: {outer_err}", exc_info=True)
        error_count += 1
    # No explicit pool or connection management needed here, context manager handles it.

    logger.info(
        f"FLOW: Scheduled Clip Cleanup complete. "
        f"Clips Found: {processed_count}, S3 Objects Deleted: {s3_deleted_count}, "
        f"DB Artifacts Deleted: {db_artifact_deleted_count}, DB Clips Updated: {db_clip_updated_count}, "
        f"Env: {environment}, Bucket Used: {s3_bucket_name_for_flow if s3_client_for_flow else 'N/A'}, Errors: {error_count}"
    )

@flow(name="Intake Source Video")
def intake_source_flow(
    source_video_id: int,
    input_source: str,
    re_encode_for_qt: bool = True,
    overwrite_existing: bool = False,
    environment: str = "development"
):
    # simply invoke the existing task
    return intake_task(
      source_video_id=source_video_id,
      input_source=input_source,
      re_encode_for_qt=re_encode_for_qt,
      overwrite_existing=overwrite_existing,
      environment=environment
    )