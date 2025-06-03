import sys
import os
from pathlib import Path
from datetime import timedelta
import logging # For potential bootstrap logging, though may be simplified

# --- Prefect Imports ---
from prefect import flow, get_run_logger

# --- Project Root Setup ---
project_root_inside_container = Path(__file__).resolve().parent.parent
if str(project_root_inside_container) not in sys.path:
    sys.path.insert(0, str(project_root_inside_container))

# --- Local Module Imports (relative to project root /app) ---
from config import get_s3_resources

# --- Async DB Setup ---
_flow_bootstrap_logger = logging.getLogger(__name__) # Optional: for logging import errors
try:
    from db.async_db import get_db_connection as get_async_db_connection
    ASYNC_DB_CONFIGURED = True
except ImportError as e:
    _flow_bootstrap_logger.error(
        f"CRITICAL: Failed to import async DB utilities from db.async_db: {e}. "
        "Async cleanup flow may not function correctly if it relies on this.",
        exc_info=True
    )
    ASYNC_DB_CONFIGURED = False
    get_async_db_connection = None # Ensure it's defined even on failure

# --- S3 ClientError Setup ---
try:
    from botocore.exceptions import ClientError
    S3_CONFIGURED = True # Indicates botocore is available
except ImportError:
    _flow_bootstrap_logger.warning(
        "botocore.exceptions.ClientError could not be imported. S3 operations might fail if botocore is missing."
    )
    S3_CONFIGURED = False
    ClientError = Exception # Define a fallback for ClientError to avoid NameError

# --- Configuration --- 
CLIP_CLEANUP_DELAY_MINUTES = int(os.getenv("CLIP_CLEANUP_DELAY_MINUTES", 30))

# --- Constants ---
ARTIFACT_TYPE_SPRITE_SHEET = "sprite_sheet"

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

    s3_client_for_flow, s3_bucket_name_for_flow = get_s3_resources(environment, logger=logger)

    if not s3_client_for_flow or not s3_bucket_name_for_flow:
        logger.error("S3 Client/Bucket Name not available from get_s3_resources. Exiting cleanup flow.")
        return

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
                return

            for clip_record in clips_to_cleanup:
                clip_id = clip_record["id"]
                current_state = clip_record["ingest_state"]
                log_prefix = f"[Cleanup Clip {clip_id}, Env {environment}]"
                logger.info(f"{log_prefix} Processing for state: {current_state}")

                sprite_artifact_s3_key = None
                s3_deletion_successful = False

                try:
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
                        s3_deletion_successful = True

                    if sprite_artifact_s3_key and not s3_deletion_successful:
                        if not s3_bucket_name_for_flow:
                            logger.error(f"{log_prefix} S3_BUCKET_NAME_FOR_FLOW is not configured. Cannot delete artifact.")
                            error_count += 1
                            s3_deletion_successful = False
                        else:
                            try:
                                logger.info(f"{log_prefix} Deleting S3 object: s3://{s3_bucket_name_for_flow}/{sprite_artifact_s3_key}")
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
                                    s3_deletion_successful = True
                                else:
                                    logger.error(f"{log_prefix} Failed to delete S3 object s3://{s3_bucket_name_for_flow}/{sprite_artifact_s3_key}. Code: {error_code}, Error: {e}")
                                    s3_deletion_successful = False
                                    error_count += 1
                            except Exception as e_s3:
                                logger.error(f"{log_prefix} Unexpected error during S3 deletion: {e_s3}", exc_info=True)
                                s3_deletion_successful = False
                                error_count += 1

                    if s3_deletion_successful:
                        final_state_map = {
                            "approved_pending_deletion": "review_approved",
                            "archived_pending_deletion": "archived",
                        }
                        final_clip_state = final_state_map.get(current_state)

                        if not final_clip_state:
                            logger.error(f"{log_prefix} Logic error: No final state mapping for current state '{current_state}'.")
                            error_count += 1
                            continue

                        async with conn.transaction():
                            logger.debug(f"{log_prefix} Starting DB transaction for final updates.")
                            if sprite_artifact_s3_key:
                                delete_artifact_sql = """
                                DELETE FROM clip_artifacts WHERE clip_id = $1 AND artifact_type = $2;
                                """
                                del_res_str = await conn.execute(
                                    delete_artifact_sql, clip_id, ARTIFACT_TYPE_SPRITE_SHEET
                                )
                                deleted_artifact_rows = int(del_res_str.split()[-1]) if del_res_str and del_res_str.startswith("DELETE") else 0
                                if deleted_artifact_rows > 0:
                                    logger.info(f"{log_prefix} Deleted {deleted_artifact_rows} artifact record(s) from DB.")
                                    db_artifact_deleted_count += deleted_artifact_rows
                                else:
                                    logger.warning(f"{log_prefix} No clip_artifact record found/deleted for S3 key {sprite_artifact_s3_key}.")

                            update_clip_sql = """
                            UPDATE clips
                               SET ingest_state = $1,
                                   updated_at = NOW(),
                                   action_committed_at = NULL,
                                   last_error = NULL
                             WHERE id = $2 AND ingest_state = $3;
                            """
                            upd_res_str = await conn.execute(
                                update_clip_sql, final_clip_state, clip_id, current_state
                            )
                            updated_clip_rows = int(upd_res_str.split()[-1]) if upd_res_str and upd_res_str.startswith("UPDATE") else 0

                            if updated_clip_rows == 1:
                                logger.info(f"{log_prefix} Successfully updated clip state to '{final_clip_state}'.")
                                db_clip_updated_count += 1
                            else:
                                logger.warning(
                                    f"{log_prefix} Clip state update to '{final_clip_state}' affected {updated_clip_rows} rows (expected 1). State might have changed. Transaction will rollback."
                                )
                                raise RuntimeError(f"Concurrent state change detected for clip {clip_id}")
                        logger.debug(f"{log_prefix} DB transaction committed.")
                    else:
                        logger.warning(f"{log_prefix} Skipping DB updates for clip {clip_id} due to S3 deletion failure or config issue.")

                except Exception as inner_err:
                    logger.error(f"{log_prefix} Error processing clip for cleanup: {inner_err}", exc_info=True)
                    error_count += 1

    except Exception as outer_err:
        logger.error(f"FATAL Error during scheduled clip cleanup flow: {outer_err}", exc_info=True)
        error_count += 1

    logger.info(
        f"FLOW: Scheduled Clip Cleanup complete. "
        f"Clips Found: {processed_count}, S3 Objects Deleted: {s3_deleted_count}, "
        f"DB Artifacts Deleted: {db_artifact_deleted_count}, DB Clips Updated: {db_clip_updated_count}, "
        f"Env: {environment}, Bucket Used: {s3_bucket_name_for_flow if s3_client_for_flow else 'N/A'}, Errors: {error_count}"
    ) 