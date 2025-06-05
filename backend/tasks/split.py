import os
import subprocess
import tempfile
from pathlib import Path
import shutil
import time
import re
import sys
import json
from datetime import datetime

from prefect import task, get_run_logger
import psycopg2
from psycopg2 import sql, extras
from botocore.exceptions import ClientError, NoCredentialsError

# --- Project Root Setup & Utility Imports ---
try:
    project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
    if project_root not in sys.path:
        sys.path.insert(0, project_root)
    from db.sync_db import get_db_connection, release_db_connection, update_clip_state_sync, initialize_db_pool
    from config import get_s3_resources
    from utils.process_utils import run_ffmpeg_command, run_ffprobe_command
except ImportError as e:
    print(f"ERROR importing db_utils, config or process_utils in split.py: {e}")
    def get_db_connection(environment: str, cursor_factory=None): raise NotImplementedError("Dummy DB connection")
    def release_db_connection(conn, environment: str): pass
    def update_clip_state_sync(environment: str, clip_id: int, new_state: str, error_message: str | None = None): pass
    def initialize_db_pool(environment: str): raise NotImplementedError("Dummy initialize_db_pool")
    def get_s3_resources(environment: str, logger=None): raise NotImplementedError("Dummy S3 resource getter")
    def run_ffmpeg_command(cmd_list, step_name="ffmpeg command", cwd=None, ffmpeg_executable=None):
        raise NotImplementedError("Dummy run_ffmpeg_command from split.py fallback")
    def run_ffprobe_command(cmd_list, step_name="ffprobe command", cwd=None, ffprobe_executable=None):
        raise NotImplementedError("Dummy run_ffprobe_command from split.py fallback, expected to return (stdout, stderr)")

# Module-level constants that are not S3 client/bucket specific - FFMPEG_PATH REMOVED
# CLIP_S3_PREFIX and MIN_CLIP_DURATION_SECONDS remain as they are specific to this task's logic
CLIP_S3_PREFIX = os.getenv("CLIP_S3_PREFIX", "clips/")
MIN_CLIP_DURATION_SECONDS = float(os.getenv("MIN_CLIP_DURATION_SECONDS_SPLIT", 0.5))

# Constants for artifact types (if needed for deletion)
ARTIFACT_TYPE_SPRITE_SHEET = "sprite_sheet"
ARTIFACT_TYPE_KEYFRAME = "keyframe"
# Add other artifact types if they need to be cleaned up during a split operation

# sanitize_filename kept local as it's a general utility not specific to process execution
def sanitize_filename(name):
    name = str(name)
    name = re.sub(r'[^\w\.\-]+', '_', name)
    name = re.sub(r'_+', '_', name).strip('_')
    return name[:150] if name else "default_filename_fallback"

@task(name="Split Clip at Frame", retries=1, retry_delay_seconds=45, concurrency_limit=5)
def split_clip_task(clip_id: int, environment: str = "development"):
    """
    Splits a single clip into two based on a FRAME NUMBER specified in its metadata.
    Downloads the original source video, uses ffmpeg to extract two new clips,
    uploads them to S3 under a source-video-specific directory, creates new DB
    records, and archives the original clip.
    Also deletes artifacts associated with the original clip.
    """
    logger = get_run_logger()
    logger.info(f"TASK [Split]: Starting for original clip_id: {clip_id}")

    # --- Initialize DB Pool for this task's environment ---    
    try:
        initialize_db_pool(environment)
        logger.info(f"DB pool for '{environment}' initialized or verified by split_clip_task.")
    except Exception as pool_init_err:
        logger.error(f"CRITICAL: Failed to initialize DB pool for '{environment}' in split_clip_task: {pool_init_err}", exc_info=True)
        # This task has complex error handling for the original clip state, so just raising here
        # and letting the main try/except handle the state update might be best.
        raise RuntimeError(f"DB Pool initialization failed in split_clip_task for env '{environment}'") from pool_init_err

    # --- Resource & State Variables ---
    conn = None
    temp_dir_obj = None
    temp_dir = None
    new_clip_ids = []
    original_clip_data = {}
    source_video_id = None
    source_title = None
    sanitized_source_title = None
    final_original_state = "split_failed"
    task_exception = None

    # --- Get S3 Resources ---
    s3_client_for_task, s3_bucket_name_for_task = get_s3_resources(environment, logger=get_run_logger())

    # --- Pre-checks ---
    if not all([s3_client_for_task, s3_bucket_name_for_task]):
        raise RuntimeError("S3 client or bucket name not configured.")
    if not shutil.which("ffprobe"):
        logger.warning("ffprobe not found by shutil.which. run_ffprobe_command will try its default or FFMPEG_PATH.")

    try:
        conn = get_db_connection(environment, cursor_factory=extras.DictCursor)
        if conn is None:
            raise ConnectionError("Failed to get database connection.")
        conn.autocommit = False
        temp_dir_obj = tempfile.TemporaryDirectory(prefix=f"heaters_split_{clip_id}_")
        temp_dir = Path(temp_dir_obj.name)
        logger.info(f"Using temporary directory: {temp_dir}")

        # Phase 1: Initial DB Check and State Update
        split_request_frame = None
        try:
            with conn.cursor(cursor_factory=extras.DictCursor) as cur:
                cur.execute("SELECT pg_advisory_xact_lock(2, %s)", (clip_id,))
                logger.debug(f"Acquired lock for original clip {clip_id}")

                cur.execute(
                    """
                    SELECT
                        c.clip_filepath, c.clip_identifier, c.start_time_seconds, c.end_time_seconds,
                        c.source_video_id, c.ingest_state, c.processing_metadata,
                        c.start_frame, c.end_frame,
                        COALESCE(sv.fps, 0) AS source_video_fps,
                        sv.filepath AS source_video_filepath,
                        sv.title AS source_title
                    FROM clips c
                    JOIN source_videos sv ON c.source_video_id = sv.id
                    WHERE c.id = %s
                    FOR UPDATE OF c, sv;
                    """,
                    (clip_id,)
                )
                original_clip_data = cur.fetchone()
                if not original_clip_data:
                    raise ValueError(f"Original clip {clip_id} not found.")
                current_state = original_clip_data['ingest_state']
                if current_state not in ['splitting', 'split_failed']:
                    raise ValueError(f"Clip {clip_id} not in 'splitting' or 'split_failed' state (state: '{current_state}'). Initiator should set this.")
                if not original_clip_data['source_video_filepath']:
                    raise ValueError(f"Missing source video filepath for clip {clip_id}.")

                source_video_id = original_clip_data['source_video_id']
                source_title = original_clip_data.get('source_title') or f'source_{source_video_id}'
                sanitized_source_title = sanitize_filename(source_title)

                metadata = original_clip_data['processing_metadata']
                if not isinstance(metadata, dict) or 'split_at_frame' not in metadata:
                    raise ValueError(f"Missing 'split_at_frame' in metadata for clip {clip_id}.")
                try:
                    split_request_frame = int(metadata['split_at_frame'])
                except (ValueError, TypeError) as e:
                    raise ValueError(f"Invalid 'split_at_frame': {metadata.get('split_at_frame')} - {e}")

                logger.debug(f"Source video {source_video_id} locked via FOR UPDATE.")
                cur.execute(
                    """
                    UPDATE clips SET ingest_state = 'splitting', updated_at = NOW(), last_error = NULL WHERE id = %s
                    AND ingest_state IN ('pending_split', 'split_failed');
                    """,
                    (clip_id,)
                )
                if cur.rowcount == 0 and current_state != 'splitting':
                     cur.execute("SELECT ingest_state FROM clips WHERE id = %s", (clip_id,))
                     res_fetch = cur.fetchone()
                     actual_current_state_on_fail = res_fetch[0] if res_fetch else "NOT_FOUND"
                     logger.error(f"Failed to set clip {clip_id} to 'splitting'. Expected 'pending_split' or 'split_failed', found '{actual_current_state_on_fail}'.")
                     raise RuntimeError(f"Failed to transition clip {clip_id} to 'splitting' state. Current state: {actual_current_state_on_fail}")
                logger.info(f"Clip {clip_id} state confirmed/set to 'splitting' (was: '{current_state}')")
            conn.commit()
            logger.debug("Phase 1 committed.")
        except (ValueError, psycopg2.DatabaseError, TypeError) as err:
            logger.error(f"Error in Phase 1 for clip {clip_id}: {err}", exc_info=True)
            if conn: conn.rollback()
            task_exception = err
            raise

        # Phase 2: Main Processing
        try:
            clip_fps = 0.0
            ffprobe_path_explicit = shutil.which("ffprobe") # Get explicit path for clarity
            original_clip_s3_path = original_clip_data['clip_filepath']
            local_probe_path = None
            probe_dir_obj = None # Initialize for potential cleanup

            if ffprobe_path_explicit and original_clip_s3_path:
                try:
                    probe_dir_obj = tempfile.TemporaryDirectory(prefix=f"heaters_split_probe_{clip_id}_")
                    local_probe_path = Path(probe_dir_obj.name) / Path(original_clip_s3_path).name
                    logger.info(f"Downloading clip for FPS probe: s3://{s3_bucket_name_for_task}/{original_clip_s3_path} to {local_probe_path}")
                    s3_client_for_task.download_file(s3_bucket_name_for_task, original_clip_s3_path, str(local_probe_path))
                    
                    ffprobe_cmd_list = [
                        "-v", "error", "-select_streams", "v:0",
                        "-show_entries", "stream=r_frame_rate",
                        "-of", "default=noprint_wrappers=1:nokey=1", str(local_probe_path)
                    ]
                    stdout, _ = run_ffprobe_command(ffprobe_cmd_list, 
                                                      step_name="FFprobe for FPS", 
                                                      ffprobe_executable=ffprobe_path_explicit)
                    num, den = map(int, stdout.strip().split('/'))
                    clip_fps = num / den if den > 0 else 0.0
                except Exception as probe_err:
                    logger.warning(f"FPS probe failed: {probe_err}. Falling back.")
                finally:
                    if probe_dir_obj: # Check if it was created
                        try: probe_dir_obj.cleanup(); logger.debug("Cleaned up FPS probe temp directory.")
                        except Exception as e_probe_cleanup: logger.warning(f"Error cleaning up FPS probe temp directory: {e_probe_cleanup}")
            
            if clip_fps <= 0:
                clip_fps = original_clip_data.get('source_video_fps', 0)
                if clip_fps <= 0:
                    raise ValueError(f"Cannot determine FPS for clip {clip_id}.")
                logger.warning(f"Using source video FPS: {clip_fps:.3f}")

            relative_split_frame = split_request_frame
            original_start_time = original_clip_data['start_time_seconds']
            original_end_time = original_clip_data['end_time_seconds']
            time_offset = relative_split_frame / clip_fps
            final_absolute_split_time = original_start_time + time_offset
            logger.info(f"FPS: {clip_fps:.3f}, split frame {relative_split_frame} -> {final_absolute_split_time:.4f}s relative to clip start, abs time: {final_absolute_split_time:.4f}s")

            source_s3_key = original_clip_data['source_video_filepath']
            local_source_path = temp_dir / Path(source_s3_key).name
            logger.info(f"Downloading source video s3://{s3_bucket_name_for_task}/{source_s3_key} to {local_source_path}")
            s3_client_for_task.download_file(s3_bucket_name_for_task, source_s3_key, str(local_source_path))

            clips_to_create = []
            base_id_parts = original_clip_data['clip_identifier'].split('_')
            # Try to maintain original prefix if it was like sourceID_startF_endF
            # If not, use source_video_id as prefix.
            if len(base_id_parts) >= 3 and all(p.isdigit() for p in base_id_parts[:1]): # Check if first part is numeric (source_video_id)
                prefix = base_id_parts[0]
            else:
                prefix = str(source_video_id) # Fallback to just source_video_id

            s3_base = CLIP_S3_PREFIX.strip('/') + '/'
            ffmpeg_base_opts = [
                "-map", "0:v:0?", "-map", "0:a:0?",
                "-c:v", "libx264", "-preset", "medium", "-crf", "23",
                "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k",
                "-movflags", "+faststart"
            ]

            # Clip A
            clip_a_start_abs = original_start_time
            clip_a_end_abs = final_absolute_split_time 
            clip_a_dur = clip_a_end_abs - clip_a_start_abs

            if clip_a_dur >= MIN_CLIP_DURATION_SECONDS:
                start_f_a = original_clip_data['start_frame']
                # end_f_a is the frame *before* the split point, relative to source video
                end_f_a = original_clip_data['start_frame'] + relative_split_frame -1 
                id_a = f"{prefix}_{start_f_a}_{end_f_a}_splA"
                fn_a = f"{sanitize_filename(id_a)}.mp4"
                local_a = temp_dir / fn_a
                s3_key_a = f"{s3_base}{sanitized_source_title}/{fn_a}"
                logger.info(f"Extracting Clip A: {id_a} (Source Time {clip_a_start_abs:.3f}s - {clip_a_end_abs:.3f}s)")
                cmd_a = [
                    "-y", "-i", str(local_source_path),
                    "-ss", str(clip_a_start_abs), 
                    "-to", str(clip_a_end_abs),
                    *ffmpeg_base_opts, str(local_a)
                ]
                run_ffmpeg_command(cmd_a, "ffmpeg Extract Clip A")
                clips_to_create.append((id_a, local_a, s3_key_a, clip_a_start_abs, clip_a_end_abs, start_f_a, end_f_a))
            else:
                logger.warning(f"Skipping Clip A; duration {clip_a_dur:.3f}s < min {MIN_CLIP_DURATION_SECONDS}s.")

            # Clip B
            clip_b_start_abs = final_absolute_split_time 
            clip_b_end_abs = original_end_time
            clip_b_dur = clip_b_end_abs - clip_b_start_abs

            if clip_b_dur >= MIN_CLIP_DURATION_SECONDS:
                # start_f_b is the split_request_frame itself, relative to source video
                start_f_b = original_clip_data['start_frame'] + relative_split_frame 
                end_f_b = original_clip_data['end_frame']
                id_b = f"{prefix}_{start_f_b}_{end_f_b}_splB"
                fn_b = f"{sanitize_filename(id_b)}.mp4"
                local_b = temp_dir / fn_b
                s3_key_b = f"{s3_base}{sanitized_source_title}/{fn_b}"
                logger.info(f"Extracting Clip B: {id_b} (Source Time {clip_b_start_abs:.3f}s - {clip_b_end_abs:.3f}s)")
                # For Clip B, -ss should be before -i for faster seeking if it's a keyframe, then -to for duration from that point
                # Or, use -ss before -i, and specify absolute end time with -to if your ffmpeg supports it well.
                # Simpler: -ss (absolute start of B) -i ... -t (duration of B)
                cmd_b = [
                    "-y", "-ss", str(clip_b_start_abs), "-i", str(local_source_path),
                    "-t", str(clip_b_dur), # Duration of B
                    *ffmpeg_base_opts, str(local_b)
                ]
                run_ffmpeg_command(cmd_b, "ffmpeg Extract Clip B")
                clips_to_create.append((id_b, local_b, s3_key_b, clip_b_start_abs, clip_b_end_abs, start_f_b, end_f_b))
            else:
                logger.warning(f"Skipping Clip B; duration {clip_b_dur:.3f}s < min {MIN_CLIP_DURATION_SECONDS}s.")

            if not clips_to_create:
                raise ValueError("No valid clip segments (A or B) to create after split attempt (e.g. too short, or split at boundary).")
        except Exception as phase2_err:
            logger.error(f"Error in Phase 2 for clip {clip_id}: {phase2_err}", exc_info=True)
            task_exception = phase2_err
            final_original_state = 'split_failed'
            raise

        # Phase 3: Final DB Updates
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT pg_advisory_xact_lock(2, %s)", (clip_id,))
                cur.execute("SELECT pg_advisory_xact_lock(1, %s)", (source_video_id,))
                logger.debug("Re-locked rows for final update")

                logger.info(f"Uploading {len(clips_to_create)} new clip(s)")
                for identifier, local_path, s3_key, st, et, sf, ef in clips_to_create:
                    if not local_path.is_file() or local_path.stat().st_size == 0:
                        raise RuntimeError(f"Missing file for upload: {local_path}")
                    with open(local_path, "rb") as f_upload:
                         s3_client_for_task.upload_fileobj(f_upload, s3_bucket_name_for_task, s3_key)
                    cur.execute(
                        """
                        INSERT INTO clips (
                        source_video_id, clip_filepath, clip_identifier,
                        start_frame, end_frame, start_time_seconds, end_time_seconds,
                        ingest_state
                        ) VALUES (%s, %s, %s, %s, %s, %s, %s, 'pending_sprite_generation')
                        ON CONFLICT (clip_identifier) DO UPDATE SET
                            clip_filepath = EXCLUDED.clip_filepath,
                            start_frame = EXCLUDED.start_frame,
                            end_frame = EXCLUDED.end_frame,
                            start_time_seconds = EXCLUDED.start_time_seconds,
                            end_time_seconds = EXCLUDED.end_time_seconds,
                            ingest_state = EXCLUDED.ingest_state,
                            last_error = NULL,
                            processing_metadata = NULL,
                            keyframed_at = NULL,
                            embedded_at = NULL,
                            updated_at = NOW()
                        RETURNING id;
                        """,
                        (source_video_id, s3_key, identifier, sf, ef, st, et)
                    )
                    new_id_result = cur.fetchone()
                    if not new_id_result: raise psycopg2.DatabaseError("Failed to get ID for new clip after INSERT/UPDATE.")
                    new_id = new_id_result[0]
                    new_clip_ids.append(new_id)
                    logger.info(f"Created/Updated clip record ID {new_id} for identifier {identifier}")
                
                final_original_state = 'archived' # Mark original as archived
                archive_message = f"Successfully split into new clip IDs: {new_clip_ids}"
                logger.info(f"Archiving original clip {clip_id}: {archive_message}")
                cur.execute(
                    """
                    UPDATE clips SET
                      ingest_state=%s,
                      last_error=%s,
                      processing_metadata = processing_metadata - 'split_at_frame', -- Remove split request key
                      updated_at=NOW(),
                      keyframed_at=NULL, -- Reset downstream processing for original
                      embedded_at=NULL
                    WHERE id=%s AND ingest_state='splitting';
                    """,
                    (final_original_state, archive_message, clip_id)
                )
                if cur.rowcount == 0:
                    logger.error(f"Failed to archive original clip {clip_id}. Expected state 'splitting', but was different. Concurrency issue or logic error.")
                    raise RuntimeError(f"Failed to archive original clip {clip_id} - state was not 'splitting'.")
                
                # Delete artifacts associated with the original clip
                cur.execute("DELETE FROM clip_artifacts WHERE clip_id=%s", (clip_id,))
                logger.info(f"Deleted {cur.rowcount} artifacts for original clip {clip_id}")
            conn.commit()
            logger.info(f"Split task finished successfully for original clip {clip_id}. New clips: {new_clip_ids}")
            
            # Try to delete the original S3 object for the clip that was split
            if original_clip_data.get('clip_filepath'):
                try:
                    s3_client_for_task.delete_object(Bucket=s3_bucket_name_for_task, Key=original_clip_data['clip_filepath'])
                    logger.info(f"Deleted original S3 object for clip {clip_id}: {original_clip_data['clip_filepath']}")
                except ClientError as del_err:
                    logger.warning(f"Could not delete original S3 object {original_clip_data['clip_filepath']} for clip {clip_id}: {del_err}")
            
            return {"status":"success", "original_clip_id": clip_id, "new_clip_ids":new_clip_ids}
        except Exception as final_err:
            logger.error(f"Error in final DB phase for clip {clip_id}: {final_err}", exc_info=True)
            if conn: conn.rollback()
            final_original_state = 'split_failed' # Ensure this reflects failure
            task_exception = final_err
            raise
    except Exception as e:
        # This is the main task-level exception handler
        logger.error(f"TASK FAILED [Split]: original clip {clip_id} - {e}", exc_info=True)
        if not task_exception: task_exception = e # Ensure task_exception is set
        
        # Attempt to update the original clip's state to 'split_failed'
        error_update_conn = None
        try:
            error_update_conn = get_db_connection(environment, cursor_factory=extras.DictCursor)
            if error_update_conn:
                error_update_conn.autocommit = True
                with error_update_conn.cursor() as er_cur:
                    err_msg_for_db = f"Split failed: {type(task_exception).__name__}: {str(task_exception)[:450]}"
                    # Only update if it was in a state that should be revertible to split_failed
                    er_cur.execute(
                        """
                        UPDATE clips SET
                          ingest_state='split_failed',
                          last_error=%s,
                          processing_metadata = processing_metadata - 'split_at_frame', -- Attempt to clear split request
                          updated_at=NOW()
                        WHERE id=%s AND ingest_state IN ('splitting','pending_split', 'split_failed');
                        """,
                        (err_msg_for_db, clip_id)
                    )
                    logger.info(f"Attempted to set original clip {clip_id} state to 'split_failed' due to error: {err_msg_for_db}")
        except Exception as db_err_on_fail:
            logger.error(f"CRITICAL: Failed to update original clip {clip_id} to error state in DB: {db_err_on_fail}", exc_info=True)
        finally:
            if error_update_conn: release_db_connection(error_update_conn, environment)
        
        raise task_exception # Re-raise the original/captured exception to mark Prefect task as failed
    finally:
        if conn: # Main connection for the task
            try: conn.autocommit = True; conn.rollback() # Ensure any lingering transaction is rolled back
            except Exception: pass
            release_db_connection(conn, environment)
        if temp_dir_obj:
            try: shutil.rmtree(temp_dir)
            except Exception: pass
        logger.info(f"Cleanup actions for original clip {clip_id} completed. Final state of original clip was intended to be: {final_original_state}")