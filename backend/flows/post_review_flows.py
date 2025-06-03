import sys
import os
from pathlib import Path

# --- Prefect Imports ---
from prefect import flow, get_run_logger

# --- Project Root Setup ---
project_root_inside_container = Path(__file__).resolve().parent.parent
if str(project_root_inside_container) not in sys.path:
    sys.path.insert(0, str(project_root_inside_container))

# --- Local Module Imports (relative to project root /app) ---
from tasks.keyframe import extract_keyframes_task
from tasks.embed import generate_embeddings_task
from db.sync_db import (
    update_clip_state_sync,
    get_db_connection,
    release_db_connection
)

# --- Configuration ---
DEFAULT_KEYFRAME_STRATEGY = os.getenv("DEFAULT_KEYFRAME_STRATEGY", "midpoint")
DEFAULT_EMBEDDING_MODEL = os.getenv("DEFAULT_EMBEDDING_MODEL", "openai/clip-vit-base-patch32")
KEYFRAME_TIMEOUT = int(os.getenv("KEYFRAME_TIMEOUT", 600))
EMBEDDING_TIMEOUT = int(os.getenv("EMBEDDING_TIMEOUT", 900))

@flow(log_prints=True)
def process_clip_post_review(
    clip_id: int,
    keyframe_strategy: str = DEFAULT_KEYFRAME_STRATEGY,
    model_name: str = DEFAULT_EMBEDDING_MODEL,
    environment: str = "development"
    ):
    logger = get_run_logger()
    logger.info(f"FLOW: Starting post-review processing for clip_id: {clip_id}, Env: {environment}")

    initial_state_updated = False
    try:
        # Expect 'post_review_initiated' (from initiator) or 'review_approved' (for direct/manual runs)
        if update_clip_state_sync(
            environment=environment,
            clip_id=clip_id,
            new_state='processing_post_review',
            expected_old_state=['post_review_initiated', 'review_approved']
        ):
            logger.info(f"Clip {clip_id} state transitioned to 'processing_post_review'.")
            initial_state_updated = True
        else:
            # Fetch current state for better logging if update failed
            current_state_on_fail = "unknown"
            conn_check_fail = None
            try:
                conn_check_fail = get_db_connection(environment)
                conn_check_fail.autocommit = True
                with conn_check_fail.cursor() as cur_check_fail:
                    cur_check_fail.execute("SELECT ingest_state FROM clips WHERE id = %s", (clip_id,))
                    res = cur_check_fail.fetchone()
                    if res: current_state_on_fail = res[0]
            except Exception as e_log_state:
                logger.warning(f"Could not fetch current state for clip {clip_id} on initial update failure: {e_log_state}")
            finally:
                if conn_check_fail: release_db_connection(conn_check_fail, environment)

            logger.warning(
                f"Failed to transition clip {clip_id} from ['post_review_initiated', 'review_approved'] to 'processing_post_review'. "
                f"Actual current state: '{current_state_on_fail}'. Item may have been processed or state changed. Skipping further processing."
            )
            return # Gracefully exit if state transition fails
    except Exception as e_state_update:
        logger.error(f"Error transitioning clip {clip_id} state for post-review processing: {e_state_update}", exc_info=True)
        return # Exit on error

    keyframe_task_succeeded_or_skipped = False
    final_flow_status = "failed_keyframing" # Default to a failure state for tracking within the flow

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
            logger.error(f"Keyframing task failed for clip {clip_id}. Status: {keyframe_status}. Post-review flow terminating.")
            final_flow_status = "keyframing_task_failed"
            raise RuntimeError(f"Keyframing task failed (status: {keyframe_status}) for clip {clip_id}")
        else: # Unknown status
            logger.error(f"Keyframing task for clip {clip_id} returned an unknown status: {keyframe_status}. Post-review flow terminating.")
            final_flow_status = "keyframing_task_unknown_status"
            # Attempt to set a generic failure state if task didn't.
            update_clip_state_sync(environment=environment, clip_id=clip_id, new_state='keyframe_extraction_failed', error_message=f"Flow: Unknown keyframe task status: {keyframe_status}")
            raise RuntimeError(f"Keyframing task for clip {clip_id} returned unknown status: {keyframe_status}")

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
                final_flow_status = "success"
            elif embed_status in embed_acceptable_skip_statuses:
                logger.info(f"Embedding task for clip {clip_id} status '{embed_status}'. Assuming acceptable skip.")
                final_flow_status = "success_embedding_skipped"
            elif embed_status in embed_failure_statuses:
                logger.error(f"Embedding task failed for clip {clip_id}. Status: {embed_status}. Post-review flow terminating.")
                final_flow_status = "embedding_task_failed"
                raise RuntimeError(f"Embedding task failed (status: {embed_status}) for clip {clip_id}")
            else: # Unknown status
                logger.error(f"Embedding task for clip {clip_id} returned an unknown status: {embed_status}. Post-review flow terminating.")
                final_flow_status = "embedding_task_unknown_status"
                update_clip_state_sync(environment=environment, clip_id=clip_id, new_state='embedding_failed', error_message=f"Flow: Unknown embedding task status: {embed_status}")
                raise RuntimeError(f"Embedding task for clip {clip_id} returned unknown status: {embed_status}")
        else:
            logger.warning(f"Skipping embedding for clip {clip_id} due to prior keyframing outcome.")
            final_flow_status = "keyframed_embedding_skipped" # Keyframing was ok/skipped, but embedding not run.

    except Exception as e:
        stage_failed = "embedding" if keyframe_task_succeeded_or_skipped and final_flow_status.startswith("embedding_") else "keyframing"
        logger.error(f"Error during post-review processing flow (stage: {stage_failed}, env: {environment}) for clip_id {clip_id}: {e}", exc_info=True)
        
        if initial_state_updated: # Only try to set failure state if initial transition happened
            conn_check = None
            try:
                conn_check = get_db_connection(environment)
                conn_check.autocommit = True
                with conn_check.cursor() as cur_check:
                    cur_check.execute("SELECT ingest_state FROM clips WHERE id = %s", (clip_id,))
                    current_db_state_on_error_row = cur_check.fetchone()
                    current_db_state_on_error = current_db_state_on_error_row[0] if current_db_state_on_error_row else None
                    
                    # Set a general flow failure state only if a specific task failure state isn't already set
                    if current_db_state_on_error == 'processing_post_review':
                        update_clip_state_sync(
                            environment=environment,
                            clip_id=clip_id,
                            new_state='post_review_processing_failed',
                            error_message=f"Flow failed at {stage_failed} stage: {str(e)[:200]}"
                        )
                        logger.info(f"Set clip {clip_id} state to 'post_review_processing_failed' due to flow error.")
                    else:
                        logger.warning(f"Flow error for clip {clip_id}, but current state is '{current_db_state_on_error}', not 'processing_post_review'. Not overwriting with generic flow failure state.")
            except Exception as e_final_update:
                logger.error(f"Failed to update clip {clip_id} state on flow error: {e_final_update}")
            finally:
                if conn_check: release_db_connection(conn_check, environment)
        raise # Re-raise to mark the flow run as failed

    logger.info(f"FLOW: Finished post-review processing flow for clip_id: {clip_id}, Env: {environment}. Final Status Hint: {final_flow_status}") 