import os
import subprocess
import tempfile
from pathlib import Path
import shutil
import json
import re
import time
import sys

from prefect import task, get_run_logger
import psycopg2
from psycopg2 import sql, extras
from botocore.exceptions import ClientError, NoCredentialsError

# --- Project Root Setup & Utility Imports ---
try:
    project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
    if project_root not in sys.path: sys.path.insert(0, project_root)
    from db.sync_db import get_db_connection, release_db_connection, update_clip_state_sync
    from config import get_s3_resources # Import the new S3 utility function
except ImportError as e:
    print(f"ERROR importing db_utils or config in merge.py: {e}")
    def get_db_connection(environment: str, cursor_factory=None): raise NotImplementedError("Dummy DB connection")
    def release_db_connection(conn, environment: str): pass
    def update_clip_state_sync(environment: str, clip_id: int, new_state: str, error_message: str | None = None): pass
    def get_s3_resources(environment: str, logger=None): raise NotImplementedError("Dummy S3 resource getter")

# Module-level constants that are not S3 client/bucket specific
FFMPEG_PATH = os.getenv("FFMPEG_PATH", "ffmpeg")
CLIP_S3_PREFIX = os.getenv("CLIP_S3_PREFIX", "clips/") # Used for constructing new S3 keys

# --- Helper functions (defined locally as the import from .splice is removed) ---
def run_ffmpeg_command(cmd_list, step_name="ffmpeg command", cwd=None):
    logger = get_run_logger() # Assumes this is called within a task context
    logger.info(f"Executing FFMPEG Step: {step_name} in merge.py")
    logger.debug(f"Command: {' '.join(cmd_list)}")
    try:
        result = subprocess.run(
            cmd_list, capture_output=True, text=True, check=True, cwd=cwd,
            encoding='utf-8', errors='replace'
        )
        stdout_snippet = result.stdout[:1000] + ("..." if len(result.stdout) > 1000 else "")
        logger.debug(f"FFMPEG Output (snippet):\n{stdout_snippet}")
        if result.stderr:
            stderr_snippet = result.stderr[:1000] + ("..." if len(result.stderr) > 1000 else "")
            logger.warning(f"FFMPEG Stderr for {step_name} (snippet):\n{stderr_snippet}")
        return result
    except FileNotFoundError:
        logger.error(f"ERROR in merge.py: {cmd_list[0]} command not found at path '{FFMPEG_PATH}'.")
        raise
    except subprocess.CalledProcessError as exc:
        stderr_to_log = exc.stderr if len(exc.stderr) < 2000 else exc.stderr[:2000] + "... (truncated)"
        logger.error(f"ERROR in merge.py: {step_name} failed. Exit code: {exc.returncode}. Stderr:\n{stderr_to_log}")
        raise

def sanitize_filename(name):
    name = str(name)
    name = re.sub(r'[^\w\.\-]+', '_', name)
    name = re.sub(r'_+', '_', name).strip('_')
    return name[:150] if name else "default_filename_fallback"

# --- Task Definition ---
@task(name="Merge Clips Backward", retries=1, retry_delay_seconds=30)
def merge_clips_task(clip_id_target: int, clip_id_source: int, environment: str = "development"):
    """
    Merges the source clip (N) into the target clip (N-1) using ffmpeg concat.
    The target clip (N-1) is updated with the combined content, its artifacts
    are deleted, and it's sent for sprite regeneration.
    The source clip (N) is archived, and its artifacts are deleted.
    """
    logger = get_run_logger()
    logger.info(f"TASK [Merge Backward]: Starting merge of Source Clip {clip_id_source} into Target Clip {clip_id_target}")

    # --- Resource & State Variables ---
    conn = None
    temp_dir_obj = None
    temp_dir = None
    source_video_id = None # Store common source video ID
    clip_target_data = None
    clip_source_data = None
    # Expected states set by the initiator flow
    expected_target_state = 'merging_target' 
    expected_source_state = 'merging_source'
    task_outcome = "failed" # Default task outcome

    # --- Get S3 Resources ---
    s3_client_for_task, s3_bucket_name_for_task = get_s3_resources(environment, logger=get_run_logger())

    # --- Pre-checks ---
    if clip_id_target == clip_id_source: raise ValueError("Cannot merge a clip with itself.")
    if not s3_client_for_task or not s3_bucket_name_for_task:
        logger.error(f"S3 client or bucket name not configured. Client: {s3_client_for_task}, Bucket: {s3_bucket_name_for_task}")
        raise RuntimeError("S3 client or bucket name is not configured for merge.py.")
    if not FFMPEG_PATH or not shutil.which(FFMPEG_PATH):
        raise FileNotFoundError(f"ffmpeg command not found at '{FFMPEG_PATH}'.")

    try:
        conn = get_db_connection(environment, cursor_factory=extras.DictCursor)
        if conn is None: raise ConnectionError("Failed to get database connection.")
        conn.autocommit = False

        # === Database Operations: Initial Fetch and Validation ===
        try:
            with conn.cursor(cursor_factory=extras.DictCursor) as cur:
                cur.execute("SELECT pg_advisory_xact_lock(2, %s)", (clip_id_target,))
                cur.execute("SELECT pg_advisory_xact_lock(2, %s)", (clip_id_source,))
                logger.debug(f"Acquired locks for target {clip_id_target} and source {clip_id_source}")

                cur.execute(
                    """
                    SELECT
                        c.id, c.clip_filepath, c.clip_identifier, c.start_frame, c.end_frame,
                        c.start_time_seconds, c.end_time_seconds, c.source_video_id,
                        c.ingest_state, c.processing_metadata,
                        sv.title AS source_title
                    FROM clips c
                    JOIN source_videos sv ON c.source_video_id = sv.id
                    WHERE c.id = ANY(%s::int[]) FOR UPDATE OF c, sv;
                    """, ([clip_id_target, clip_id_source],)
                )
                results = cur.fetchall()
                if len(results) != 2: raise ValueError(f"Could not find/lock both clips {clip_id_target}, {clip_id_source}.")

                clip_target_data = next((r for r in results if r['id'] == clip_id_target), None)
                clip_source_data = next((r for r in results if r['id'] == clip_id_source), None)
                if not clip_target_data or not clip_source_data: raise ValueError("Mismatch fetching clip data.")

                if clip_target_data['source_video_id'] != clip_source_data['source_video_id']:
                    raise ValueError("Clips do not belong to the same source video.")
                source_video_id = clip_target_data['source_video_id']
                source_title = clip_target_data.get('source_title', f'source_{source_video_id}')

                if clip_target_data['ingest_state'] != expected_target_state and clip_target_data['ingest_state'] != 'merge_failed':
                     logger.warning(f"Target clip {clip_id_target} state is '{clip_target_data['ingest_state']}' (expected '{expected_target_state}' or 'merge_failed').")
                     # Depending on strictness, could raise error here.
                if clip_source_data['ingest_state'] != expected_source_state and clip_source_data['ingest_state'] != 'merge_failed':
                     logger.warning(f"Source clip {clip_id_source} state is '{clip_source_data['ingest_state']}' (expected '{expected_source_state}' or 'merge_failed').")
                     # Depending on strictness, could raise error here.

                target_meta = clip_target_data.get('processing_metadata') or {}
                source_meta = clip_source_data.get('processing_metadata') or {}
                if target_meta.get('merge_source_clip_id') != clip_id_source: logger.warning(f"Target {clip_id_target} metadata missing/incorrect source link. Metadata: {target_meta}")
                if source_meta.get('merge_target_clip_id') != clip_id_target: logger.warning(f"Source {clip_id_source} metadata missing/incorrect target link. Metadata: {source_meta}")

                if not clip_target_data['clip_filepath'] or not clip_source_data['clip_filepath']:
                    raise ValueError("One or both clips are missing S3 filepaths.")
            
            # Do not commit here, keep transaction open for main processing if DB ops are part of it.
            # However, for merge, the main processing is ffmpeg and S3, so releasing row locks might be okay.
            # For simplicity and safety, let's assume we commit after validation and before long I/O
            conn.commit()
            logger.info(f"Clips validated and initial transaction committed. Target: {clip_id_target}, Source: {clip_id_source}")

        except (ValueError, psycopg2.DatabaseError) as db_err:
             logger.error(f"DB Error during initial checks/locking for merge: {db_err}", exc_info=True)
             if conn: conn.rollback()
             task_outcome = "failed_db_initial_check"
             raise

        # === Main Processing: Download, Merge, Upload ===
        if source_title is None:
            raise RuntimeError("Source title could not be determined before processing.")

        temp_dir_obj = tempfile.TemporaryDirectory(prefix=f"heaters_merge_{source_video_id}_")
        temp_dir = Path(temp_dir_obj.name)
        logger.info(f"Using temporary directory: {temp_dir}")

        local_clip_target_path = temp_dir / Path(clip_target_data['clip_filepath']).name
        local_clip_source_path = temp_dir / Path(clip_source_data['clip_filepath']).name
        concat_list_path = temp_dir / "concat_list.txt"

        logger.info(f"Downloading clips to {temp_dir}...")
        try:
            logger.debug(f"Downloading target: s3://{s3_bucket_name_for_task}/{clip_target_data['clip_filepath']} to {local_clip_target_path}")
            s3_client_for_task.download_file(s3_bucket_name_for_task, clip_target_data['clip_filepath'], str(local_clip_target_path))
            logger.debug(f"Downloading source: s3://{s3_bucket_name_for_task}/{clip_source_data['clip_filepath']} to {local_clip_source_path}")
            s3_client_for_task.download_file(s3_bucket_name_for_task, clip_source_data['clip_filepath'], str(local_clip_source_path))
        except ClientError as s3_err:
            logger.error(f"Failed to download clips from S3: {s3_err}", exc_info=True)
            # No open transaction to rollback here if initial commit was done
            task_outcome = "failed_s3_download"
            raise RuntimeError(f"S3 download failed") from s3_err

        with open(concat_list_path, "w", encoding='utf-8') as f: # Specify encoding
            # Ensure paths are POSIX-style for ffmpeg concat file, especially on Windows
            f.write(f"file '{local_clip_target_path.resolve().as_posix()}'\n")
            f.write(f"file '{local_clip_source_path.resolve().as_posix()}'\n")

        new_end_frame = clip_source_data['end_frame']
        new_end_time = clip_source_data['end_time_seconds']
        sanitized_source_title = sanitize_filename(source_title)

        source_prefix = f"{clip_target_data['source_video_id']}" # Should be same as source_video_id
        updated_clip_identifier = f"{source_prefix}_{clip_target_data['start_frame']}_{new_end_frame}_merged"
        updated_clip_filename = f"{sanitize_filename(updated_clip_identifier)}.mp4"
        updated_local_clip_path = temp_dir / updated_clip_filename

        s3_base_prefix_for_clips = CLIP_S3_PREFIX.strip('/') + '/'
        updated_clip_s3_key = f"{s3_base_prefix_for_clips}{sanitized_source_title}/{updated_clip_filename}"

        ffmpeg_merge_cmd_copy = [ FFMPEG_PATH, '-y', '-f', 'concat', '-safe', '0', '-i', str(concat_list_path), '-c', 'copy', str(updated_local_clip_path) ]
        try:
            run_ffmpeg_command(ffmpeg_merge_cmd_copy, "ffmpeg Merge (copy)", cwd=str(temp_dir))
        except Exception as e:
            logger.warning(f"FFmpeg copy merge failed ({e}), attempting re-encode...")
            ffmpeg_merge_cmd_reencode = [
                FFMPEG_PATH, '-y', '-f', 'concat', '-safe', '0', '-i', str(concat_list_path),
                '-c:v', 'libx264', '-preset', 'medium', '-crf', '23', '-pix_fmt', 'yuv420p',
                '-c:a', 'aac', '-b:a', '128k', '-movflags', '+faststart',
                str(updated_local_clip_path)
            ]
            try:
                run_ffmpeg_command(ffmpeg_merge_cmd_reencode, "ffmpeg Merge (re-encode)", cwd=str(temp_dir))
            except Exception as reencode_err:
                logger.error(f"FFmpeg re-encode merge also failed: {reencode_err}", exc_info=True)
                task_outcome = "failed_ffmpeg_merge"
                raise RuntimeError("FFmpeg merge failed") from reencode_err

        if not updated_local_clip_path.is_file() or updated_local_clip_path.stat().st_size == 0:
             task_outcome = "failed_ffmpeg_output"
             raise RuntimeError(f"Merged output file missing or empty: {updated_local_clip_path}")

        logger.info(f"Uploading merged clip to s3://{s3_bucket_name_for_task}/{updated_clip_s3_key}")
        try:
            with open(updated_local_clip_path, "rb") as f_up:
                s3_client_for_task.upload_fileobj(f_up, s3_bucket_name_for_task, updated_clip_s3_key)
        except ClientError as s3_err:
            logger.error(f"Failed to upload merged clip to S3: {s3_err}", exc_info=True)
            task_outcome = "failed_s3_upload"
            raise RuntimeError(f"S3 upload failed") from s3_err

        # === Final Database Updates (New Transaction) ===
        conn.autocommit = False # Ensure manual transaction control for this block
        try:
            with conn.cursor() as cur:
                # Re-acquire advisory locks for this transaction
                cur.execute("SELECT pg_advisory_xact_lock(2, %s)", (clip_id_target,))
                cur.execute("SELECT pg_advisory_xact_lock(2, %s)", (clip_id_source,))
                logger.debug(f"Re-acquired locks for final DB update of target {clip_id_target} and source {clip_id_source}")

                delete_artifacts_sql = sql.SQL("DELETE FROM clip_artifacts WHERE clip_id = ANY(%s);")
                affected_clips_list = [clip_id_target, clip_id_source]
                cur.execute(delete_artifacts_sql, (affected_clips_list,))
                logger.info(f"Deleted {cur.rowcount} existing artifact(s) for clips {clip_id_target} and {clip_id_source}.")

                update_target_sql = sql.SQL("""
                    UPDATE clips
                    SET
                        clip_filepath = %s, clip_identifier = %s,
                        end_frame = %s, end_time_seconds = %s,
                        ingest_state = %s, processing_metadata = NULL,
                        last_error = 'Merged with clip ' || %s::text,
                        keyframed_at = NULL, embedded_at = NULL,
                        reviewed_at = NULL, -- Reset for new review cycle
                        action_committed_at = NULL -- Reset for new review cycle
                    WHERE id = %s AND ingest_state = %s; -- Concurrency check on expected state
                """)
                cur.execute(update_target_sql, (
                    updated_clip_s3_key, updated_clip_identifier, new_end_frame,
                    new_end_time, 'pending_sprite_generation',
                    clip_id_source, clip_id_target, expected_target_state # Check against original expected state from initiator
                ))
                if cur.rowcount == 0:
                    logger.error(f"Target clip {clip_id_target} update failed. Row not found or state changed from '{expected_target_state}'.")
                    raise RuntimeError(f"Target clip {clip_id_target} update failed due to state mismatch or deletion.")
                logger.info(f"Updated target clip {clip_id_target}. State -> 'pending_sprite_generation'.")

                archive_source_sql = sql.SQL("""
                    UPDATE clips
                    SET
                        ingest_state = 'merged',
                        processing_metadata = jsonb_set(COALESCE(processing_metadata, '{}'::jsonb), '{merged_into_clip_id}', %s::jsonb),
                        last_error = 'Merged into clip ' || %s::text,
                        keyframed_at = NULL, embedded_at = NULL
                    WHERE id = %s AND ingest_state = %s; -- Concurrency check
                """)
                cur.execute(archive_source_sql, (
                    json.dumps(clip_id_target),
                    clip_id_target, clip_id_source, expected_source_state # Check against original expected state from initiator
                ))
                if cur.rowcount == 0:
                    logger.error(f"Source clip {clip_id_source} archival failed. Row not found or state changed from '{expected_source_state}'.")
                    # This might be acceptable if target update succeeded, but log warning.
                    # For stricter consistency, could raise error.
                    logger.warning(f"Source clip {clip_id_source} archival failed due to state mismatch or deletion. Target was updated.")
                else:
                    logger.info(f"Archived source clip {clip_id_source} with state 'merged'.")

                logger.info(f"S3 Cleanup eventually needed for ORIGINAL clips: s3://{s3_bucket_name_for_task}/{clip_target_data['clip_filepath']} and s3://{s3_bucket_name_for_task}/{clip_source_data['clip_filepath']}")

            conn.commit()
            logger.info(f"Merge DB changes committed. Target clip {clip_id_target} updated, source clip {clip_id_source} (attempted) archived.")
            task_outcome = "success"
            return {"status": "success", "updated_clip_id": clip_id_target, "archived_clip_id": clip_id_source}

        except (ValueError, psycopg2.DatabaseError, RuntimeError) as db_err:
            logger.error(f"DB Error during final update for merge: {db_err}", exc_info=True)
            if conn: conn.rollback()
            task_outcome = "failed_db_final_update"
            raise

    except Exception as e:
        logger.error(f"TASK FAILED [Merge Backward]: Target {clip_id_target}, Source {clip_id_source} - {e}", exc_info=True)
        error_message_for_db = f"Merge failed: {type(e).__name__}: {str(e)[:450]}"
        
        # Use a new connection for error state update
        error_conn = None
        try:
            # If the main conn was used and failed mid-transaction, it should be rolled back by the exception handler.
            # This new connection is for a separate, atomic update.
            error_conn = get_db_connection(environment, cursor_factory=extras.DictCursor)
            if error_conn:
                error_conn.autocommit = True # For simple error update
                with error_conn.cursor() as err_cur:
                    # Revert both clips to 'merge_failed' state if they were in the expected pre-merge states
                    # This attempts to reset their states for potential re-processing or manual review.
                    err_cur.execute(
                        """
                        UPDATE clips SET ingest_state = 'merge_failed', last_error = %s,
                                        processing_metadata = NULL, -- Clear merge-related metadata
                                        retry_count = COALESCE(retry_count, 0) + 1
                        WHERE id = ANY(%s::int[]) AND ingest_state IN (%s, %s, 'merge_failed'); -- Allow update if already merge_failed
                        """,
                        (error_message_for_db, [clip_id_target, clip_id_source], expected_target_state, expected_source_state)
                    )
                logger.info(f"Attempted to revert clips {clip_id_target}, {clip_id_source} states to 'merge_failed'. Status: {err_cur.statusmessage if 'err_cur' in locals() else 'N/A'}")
            else:
                logger.error("Could not obtain DB connection to update error state after merge failure.")
        except Exception as db_err_on_fail:
            logger.error(f"CRITICAL: Failed to update error state in DB after merge failure: {db_err_on_fail}")
        finally:
            if error_conn:
                release_db_connection(error_conn, environment)
        
        # Ensure task_outcome reflects the failure if not already set by a specific phase
        if task_outcome != "failed" and not task_outcome.startswith("failed_"):
            task_outcome = "failed_unknown" # Generic if not caught by specific phase
        
        raise e # Re-raise the original exception

    finally:
        if conn: # Main connection
            try:
                conn.autocommit = True # Reset state
                conn.rollback() # Ensure clean state before releasing
            except Exception as conn_cleanup_err:
                logger.warning(f"Error during final cleanup of main DB connection: {conn_cleanup_err}")
            finally:
                release_db_connection(conn, environment)
                logger.debug("Main DB connection released.")
        
        if temp_dir_obj:
            try:
                shutil.rmtree(temp_dir)
                logger.info(f"Cleaned up temp dir: {temp_dir}")
            except Exception as cleanup_err:
                 logger.warning(f"Error cleaning up temp dir {temp_dir}: {cleanup_err}")
        
        logger.info(f"Merge task for target {clip_id_target} and source {clip_id_source} concluded. Final outcome: {task_outcome}")