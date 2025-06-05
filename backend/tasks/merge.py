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
    from db.sync_db import get_db_connection, release_db_connection, update_clip_state_sync, initialize_db_pool
    from config import get_s3_resources
except ImportError as e:
    print(f"ERROR importing db_utils or config in merge.py: {e}")
    def get_db_connection(environment: str, cursor_factory=None): raise NotImplementedError("Dummy DB connection")
    def release_db_connection(conn, environment: str): pass
    def update_clip_state_sync(environment: str, clip_id: int, new_state: str, error_message: str | None = None): pass
    def initialize_db_pool(environment: str): raise NotImplementedError("Dummy initialize_db_pool")
    def get_s3_resources(environment: str, logger=None): raise NotImplementedError("Dummy S3 resource getter")

# Module-level constants that are not S3 client/bucket specific
FFMPEG_PATH = os.getenv("FFMPEG_PATH", "ffmpeg")
CLIP_S3_PREFIX = os.getenv("CLIP_S3_PREFIX", "clips/") # Used for constructing new S3 keys
ARTIFACT_TYPE_SPRITE_SHEET = "sprite_sheet" # Example, if you need to log specific artifact types

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

# --- S3 Artifact Deletion Helper ---
def _delete_clip_s3_artifacts(conn_cursor, clip_id: int, s3_client, s3_bucket_name: str, logger_instance):
    """
    Fetches artifact S3 keys for a clip_id, deletes them from S3,
    and then deletes their records from clip_artifacts table using the provided cursor.
    """
    conn_cursor.execute("SELECT id, s3_key FROM clip_artifacts WHERE clip_id = %s;", (clip_id,))
    artifact_records = conn_cursor.fetchall()
    
    s3_keys_for_db_delete_confirmation = []

    if artifact_records:
        logger_instance.info(f"Found {len(artifact_records)} S3 artifact(s) for clip {clip_id} to process for deletion.")
        for artifact_record in artifact_records:
            s3_key_to_delete = artifact_record['s3_key']
            artifact_db_id = artifact_record['id']
            if s3_key_to_delete:
                try:
                    logger_instance.info(f"Deleting S3 artifact: s3://{s3_bucket_name}/{s3_key_to_delete} (DB ID: {artifact_db_id}) for clip {clip_id}")
                    s3_client.delete_object(Bucket=s3_bucket_name, Key=s3_key_to_delete)
                    s3_keys_for_db_delete_confirmation.append(s3_key_to_delete)
                    logger_instance.info(f"Successfully deleted S3 artifact {s3_key_to_delete} for clip {clip_id}.")
                except ClientError as e_s3_art:
                    error_code = e_s3_art.response.get("Error", {}).get("Code", "Unknown")
                    if error_code == "NoSuchKey":
                        logger_instance.warning(f"S3 artifact {s3_key_to_delete} for clip {clip_id} not found (NoSuchKey). Assuming already deleted.")
                        s3_keys_for_db_delete_confirmation.append(s3_key_to_delete) # Still counts as processed for DB deletion
                    else:
                        logger_instance.error(f"Failed to delete S3 artifact {s3_key_to_delete} for clip {clip_id}. Code: {error_code}, Error: {e_s3_art}. Artifact DB record will NOT be deleted.")
                        # Do not add to s3_keys_for_db_delete_confirmation if S3 deletion failed for reasons other than NoSuchKey
            else:
                logger_instance.warning(f"Clip artifact DB record ID {artifact_db_id} for clip {clip_id} has no s3_key. Skipping S3 deletion for this record.")
                # We might still want to delete this DB record if it's considered invalid.
                # For now, only targeting records where S3 deletion was attempted or key was null.
                # If s3_key is NULL, it means no S3 object to delete, so its DB record can be cleaned up.
                s3_keys_for_db_delete_confirmation.append(None) # Representing a DB record to delete without S3 counterpart

    # Delete all artifact DB records for the clip_id, regardless of S3 success for individual keys.
    # The primary goal is that post-merge, the original clips should not have any artifact associations.
    # Failures in S3 deletion for specific artifacts are logged.
    if artifact_records: # If there were any records fetched
        logger_instance.info(f"Deleting {len(artifact_records)} clip_artifacts DB record(s) for clip {clip_id}.")
        conn_cursor.execute("DELETE FROM clip_artifacts WHERE clip_id = %s;", (clip_id,))
        logger_instance.info(f"Finished delete attempt for {conn_cursor.rowcount} artifact DB records for clip {clip_id}.")
    else:
        logger_instance.info(f"No S3 artifacts found in DB for clip {clip_id}.")

# --- Task Definition ---
@task(name="Merge Clips Backward", retries=1, retry_delay_seconds=30, tags=["merging"])
def merge_clips_task(clip_id_target: int, clip_id_source: int, environment: str = "development"):
    """
    Merges the source clip (N) into the target clip (N-1) using ffmpeg concat.
    The target clip (N-1) is updated with the combined content, its artifacts
    are deleted, and it's sent for sprite regeneration.
    The source clip (N) is archived, and its artifacts are deleted.
    """
    logger = get_run_logger()
    logger.info(f"TASK [Merge Backward]: Starting merge of Source Clip {clip_id_source} into Target Clip {clip_id_target}")

    # --- Initialize DB Pool for this task's environment ---    
    try:
        initialize_db_pool(environment)
        logger.info(f"DB pool for '{environment}' initialized or verified by merge_clips_task.")
    except Exception as pool_init_err:
        logger.error(f"CRITICAL: Failed to initialize DB pool for '{environment}' in merge_clips_task: {pool_init_err}", exc_info=True)
        # This task has complex error handling, raising directly to let the main try/except handle state updates.
        raise RuntimeError(f"DB Pool initialization failed in merge_clips_task for env '{environment}'") from pool_init_err

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
    s3_client_for_task, s3_bucket_name_for_task = get_s3_resources(environment, logger=logger)

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
                     # Depending on strictness, could raise error here. Current logic allows proceeding.
                if clip_source_data['ingest_state'] != expected_source_state and clip_source_data['ingest_state'] != 'merge_failed':
                     logger.warning(f"Source clip {clip_id_source} state is '{clip_source_data['ingest_state']}' (expected '{expected_source_state}' or 'merge_failed').")
                     # Depending on strictness, could raise error here. Current logic allows proceeding.

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

                # Delete S3 artifacts and their DB records for original clips
                logger.info(f"Processing S3 artifact deletion for original target clip {clip_id_target}")
                _delete_clip_s3_artifacts(cur, clip_id_target, s3_client_for_task, s3_bucket_name_for_task, logger)
                logger.info(f"Processing S3 artifact deletion for original source clip {clip_id_source}")
                _delete_clip_s3_artifacts(cur, clip_id_source, s3_client_for_task, s3_bucket_name_for_task, logger)
                
                # Insert new merged clip record
                new_clip_start_frame = clip_target_data['start_frame']
                new_clip_end_frame = clip_source_data['end_frame'] # from original source clip data
                new_clip_start_time = clip_target_data['start_time_seconds']
                new_clip_end_time = clip_source_data['end_time_seconds'] # from original source clip data

                insert_new_clip_sql = sql.SQL("""
                    INSERT INTO clips (
                        source_video_id, clip_filepath, clip_identifier,
                        start_frame, end_frame, start_time_seconds, end_time_seconds,
                        ingest_state, processing_metadata, last_error
                    ) VALUES (
                        %s, %s, %s, %s, %s, %s, %s, %s, %s, %s
                    ) RETURNING id;
                """)
                new_clip_metadata = {
                    "merged_from_clips": [clip_id_target, clip_id_source],
                    "original_target_identifier": clip_target_data.get('clip_identifier'),
                    "original_source_identifier": clip_source_data.get('clip_identifier')
                }
                cur.execute(insert_new_clip_sql, (
                    source_video_id, updated_clip_s3_key, updated_clip_identifier,
                    new_clip_start_frame, new_clip_end_frame, new_clip_start_time, new_clip_end_time,
                    'pending_sprite_generation', psycopg2.extras.Json(new_clip_metadata), None
                ))
                new_merged_clip_id = cur.fetchone()[0]
                if not new_merged_clip_id:
                    raise RuntimeError("Failed to get new clip ID after insert.")
                logger.info(f"Created new merged clip record with ID: {new_merged_clip_id}")

                # Update original target clip
                update_original_clip_sql = sql.SQL("""
                    UPDATE clips
                    SET
                        ingest_state = 'archived', 
                        processing_metadata = %s::jsonb,
                        last_error = %s,
                        keyframed_at = NULL, embedded_at = NULL,
                        reviewed_at = NULL, action_committed_at = NULL,
                        updated_at = NOW()
                    WHERE id = %s AND ingest_state IN (%s, 'merge_failed'); 
                """) # Allow update if it was already 'merge_failed' from a previous attempt

                target_final_metadata = {"merged_into_clip_id": new_merged_clip_id}
                cur.execute(update_original_clip_sql, (
                    psycopg2.extras.Json(target_final_metadata),
                    f'Merged to new clip {new_merged_clip_id}',
                    clip_id_target, expected_target_state
                ))
                if cur.rowcount == 0:
                    logger.error(f"Original target clip {clip_id_target} update to 'archived' failed. Row not found or state not '{expected_target_state}' or 'merge_failed'.")
                    # This could be critical, consider raising an error to rollback
                    raise RuntimeError(f"Target clip {clip_id_target} update to 'archived' failed due to state mismatch or deletion.")
                logger.info(f"Updated original target clip {clip_id_target} to state 'archived'.")

                # Update original source clip
                source_final_metadata = {"merged_into_clip_id": new_merged_clip_id}
                cur.execute(update_original_clip_sql, (
                    psycopg2.extras.Json(source_final_metadata),
                    f'Merged to new clip {new_merged_clip_id}',
                    clip_id_source, expected_source_state
                ))
                if cur.rowcount == 0:
                    logger.error(f"Original source clip {clip_id_source} update to 'archived' failed. Row not found or state not '{expected_source_state}' or 'merge_failed'.")
                    # This could be critical, consider raising an error to rollback
                    raise RuntimeError(f"Source clip {clip_id_source} update to 'archived' failed due to state mismatch or deletion.")
                logger.info(f"Updated original source clip {clip_id_source} to state 'archived'.")

                # logger.info(f"S3 Video Cleanup eventually needed for ORIGINAL clips (now in 'merged_to_new' state): s3://{s3_bucket_name_for_task}/{clip_target_data['clip_filepath']} and s3://{s3_bucket_name_for_task}/{clip_source_data['clip_filepath']}")

            conn.commit()
            logger.info(f"Merge DB changes committed. New clip {new_merged_clip_id} created. Originals {clip_id_target}, {clip_id_source} updated to 'archived'.")
            task_outcome = "success"

            # Attempt to delete original S3 video files AFTER successful DB commit
            original_s3_videos_to_delete = [
                (clip_target_data['clip_filepath'], clip_id_target, "target"),
                (clip_source_data['clip_filepath'], clip_id_source, "source")
            ]
            for s3_key, original_id, clip_role in original_s3_videos_to_delete:
                if s3_key:
                    try:
                        logger.info(f"Attempting to delete original S3 video file for {clip_role} clip {original_id}: s3://{s3_bucket_name_for_task}/{s3_key}")
                        s3_client_for_task.delete_object(Bucket=s3_bucket_name_for_task, Key=s3_key)
                        logger.info(f"Successfully deleted original S3 video file for {clip_role} clip {original_id}.")
                    except ClientError as e_s3_vid_del:
                        error_code = e_s3_vid_del.response.get("Error", {}).get("Code", "Unknown")
                        if error_code == "NoSuchKey":
                            logger.warning(f"Original S3 video file for {clip_role} clip {original_id} (s3://{s3_bucket_name_for_task}/{s3_key}) not found (NoSuchKey). Assuming already deleted.")
                        else:
                            logger.error(f"Failed to delete original S3 video file for {clip_role} clip {original_id} (s3://{s3_bucket_name_for_task}/{s3_key}). Code: {error_code}, Error: {e_s3_vid_del}")
                    except Exception as e_s3_vid_del_generic:
                        logger.error(f"Unexpected error deleting original S3 video for {clip_role} clip {original_id} (s3://{s3_bucket_name_for_task}/{s3_key}): {e_s3_vid_del_generic}", exc_info=True)
                else:
                    logger.warning(f"No S3 filepath found for original {clip_role} clip {original_id}, cannot delete from S3.")

            return {"status": "success", "new_clip_id": new_merged_clip_id, "original_clips_processed": [clip_id_target, clip_id_source]}

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