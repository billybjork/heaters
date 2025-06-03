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
from botocore.exceptions import ClientError, NoCredentialsError # Keep for S3 error handling

# --- Project Root Setup & Utility Imports ---
try:
    project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
    if project_root not in sys.path:
        sys.path.insert(0, project_root)
    from db.sync_db import get_db_connection, release_db_connection, update_clip_state_sync
    from config import get_s3_resources # Import the new S3 utility function
except ImportError as e:
    print(f"ERROR importing db_utils or config in split.py: {e}")
    def get_db_connection(environment: str, cursor_factory=None): raise NotImplementedError("Dummy DB connection")
    def release_db_connection(conn, environment: str): pass
    def update_clip_state_sync(environment: str, clip_id: int, new_state: str, error_message: str | None = None): pass
    def get_s3_resources(environment: str, logger=None): raise NotImplementedError("Dummy S3 resource getter")

# Module-level constants that are not S3 client/bucket specific
FFMPEG_PATH = os.getenv("FFMPEG_PATH", "ffmpeg")
CLIP_S3_PREFIX = os.getenv("CLIP_S3_PREFIX", "clips/")
MIN_CLIP_DURATION_SECONDS = float(os.getenv("MIN_CLIP_DURATION_SECONDS_SPLIT", 1.0)) # Specific or fallback

# --- Helper functions (defined locally as the import from .splice is removed) ---
def run_ffmpeg_command(cmd_list, step_name="ffmpeg command", cwd=None):
    logger = get_run_logger() # Assumes this is called within a task context
    logger.info(f"Executing FFMPEG Step: {step_name} in split.py")
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
        logger.error(f"ERROR in split.py: {cmd_list[0]} command not found at path '{FFMPEG_PATH}'.")
        raise
    except subprocess.CalledProcessError as exc:
        stderr_to_log = exc.stderr if len(exc.stderr) < 2000 else exc.stderr[:2000] + "... (truncated)"
        logger.error(f"ERROR in split.py: {step_name} failed. Exit code: {exc.returncode}. Stderr:\n{stderr_to_log}")
        raise

def sanitize_filename(name):
    name = str(name)
    name = re.sub(r'[^\w\.\-]+', '_', name)
    name = re.sub(r'_+', '_', name).strip('_')
    return name[:150] if name else "default_filename_fallback"

# Constants for artifact types (if needed for deletion)
ARTIFACT_TYPE_SPRITE_SHEET = "sprite_sheet"
ARTIFACT_TYPE_KEYFRAME = "keyframe"
# Add other artifact types if they need to be cleaned up during a split operation

@task(name="Split Clip at Frame", retries=1, retry_delay_seconds=45)
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
    if not FFMPEG_PATH or not shutil.which(FFMPEG_PATH):
        raise FileNotFoundError(f"ffmpeg not found at '{FFMPEG_PATH}'.")
    if not shutil.which("ffprobe"):
        logger.warning("ffprobe not found. FPS calculation might be less accurate.")

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
                    AND ingest_state IN ('pending_split', 'split_failed'); -- Allow transition if it's a retry from pending_split or from a failed state
                    """,
                    (clip_id,)
                )
                if cur.rowcount == 0 and current_state != 'splitting': # If it was already splitting, rowcount 0 is okay.
                     # If it wasn't 'splitting' and update failed, then state was unexpected.
                     cur.execute("SELECT ingest_state FROM clips WHERE id = %s", (clip_id,))
                     actual_current_state_on_fail = cur.fetchone()[0] if cur.fetchone() else "NOT_FOUND"
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
            # Determine FPS
            clip_fps = 0.0
            ffprobe_path = shutil.which("ffprobe")
            original_clip_s3_path = original_clip_data['clip_filepath']
            local_probe_path = None

            if ffprobe_path and original_clip_s3_path:
                try:
                    probe_dir_obj = tempfile.TemporaryDirectory(prefix=f"heaters_split_probe_{clip_id}_")
                    local_probe_path = Path(probe_dir_obj.name) / Path(original_clip_s3_path).name
                    logger.info(f"Downloading clip for FPS probe: s3://{s3_bucket_name_for_task}/{original_clip_s3_path} to {local_probe_path}")
                    s3_client_for_task.download_file(s3_bucket_name_for_task, original_clip_s3_path, str(local_probe_path))
                    result = subprocess.run(
                        [ffprobe_path, "-v", "error", "-select_streams", "v:0",
                         "-show_entries", "stream=r_frame_rate",
                         "-of", "default=noprint_wrappers=1:nokey=1", str(local_probe_path)],
                        capture_output=True, text=True, check=True
                    )
                    num, den = map(int, result.stdout.strip().split('/'))
                    clip_fps = num / den if den > 0 else 0.0
                    if local_probe_path and probe_dir_obj.name: # Check if probe_dir_obj was created
                        try:
                            probe_dir_obj.cleanup()
                            logger.debug("Cleaned up FPS probe temp directory.")
                        except Exception as e_probe_cleanup:
                            logger.warning(f"Error cleaning up FPS probe temp directory: {e_probe_cleanup}")
                except Exception as probe_err:
                    logger.warning(f"FPS probe failed: {probe_err}. Falling back.")
                    if local_probe_path and probe_dir_obj.name:
                        probe_dir_obj.cleanup()

            if clip_fps <= 0:
                clip_fps = original_clip_data.get('source_video_fps', 0)
                if clip_fps <= 0:
                    raise ValueError(f"Cannot determine FPS for clip {clip_id}.")
                logger.warning(f"Using source video FPS: {clip_fps:.3f}")

            # Calculate split time
            relative_split_frame = split_request_frame
            original_start_time = original_clip_data['start_time_seconds']
            original_end_time = original_clip_data['end_time_seconds']
            time_offset = relative_split_frame / clip_fps
            final_absolute_split_time = original_start_time + time_offset
            logger.info(f"FPS: {clip_fps:.3f}, split frame {relative_split_frame} → {final_absolute_split_time:.4f}s")

            # Download source video
            source_s3_key = original_clip_data['source_video_filepath']
            local_source_path = temp_dir / Path(source_s3_key).name
            logger.info(f"Downloading source video s3://{s3_bucket_name_for_task}/{source_s3_key} to {local_source_path}")
            s3_client_for_task.download_file(s3_bucket_name_for_task, source_s3_key, str(local_source_path))

            # Prepare ffmpeg options
            clips_to_create = []
            base_id = original_clip_data['clip_identifier']
            prefix = f"{source_video_id}"
            s3_base = CLIP_S3_PREFIX.strip('/') + '/'
            ffmpeg_opts = [
                '-map', '0:v:0?', '-map', '0:a:0?',
                '-c:v', 'libx264', '-preset', 'medium', '-crf', '23',
                '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '128k',
                '-movflags', '+faststart'
            ]

            # Clip A
            clip_a_start = original_start_time
            clip_a_end = final_absolute_split_time
            clip_a_dur = clip_a_end - clip_a_start
            if clip_a_dur > 0:
                start_f_a = original_clip_data['start_frame']
                end_f_a = start_f_a + relative_split_frame - 1
                id_a = f"{prefix}_{start_f_a}_{end_f_a}_splA"
                fn_a = f"{sanitize_filename(id_a)}.mp4"
                local_a = temp_dir / fn_a
                s3_key_a = f"{s3_base}{sanitized_source_title}/{fn_a}"
                logger.info(f"Extracting A: {id_a} ({clip_a_start:.3f}-{clip_a_end:.3f}s)")
                cmd_a = [FFMPEG_PATH, '-y', '-i', str(local_source_path),
                         '-ss', str(clip_a_start), '-to', str(clip_a_end),
                         *ffmpeg_opts, str(local_a)]
                run_ffmpeg_command(cmd_a, "ffmpeg Extract Clip A")
                clips_to_create.append((id_a, local_a, s3_key_a, clip_a_start, clip_a_end, start_f_a, end_f_a))
            else:
                logger.warning(f"Skipping Clip A; zero duration.")

            # Clip B
            clip_b_start = final_absolute_split_time
            clip_b_end = original_end_time
            clip_b_dur = clip_b_end - clip_b_start
            if clip_b_dur > 0:
                start_f_b = original_clip_data['start_frame'] + relative_split_frame
                end_f_b = original_clip_data['end_frame']
                id_b = f"{prefix}_{start_f_b}_{end_f_b}_splB"
                fn_b = f"{sanitize_filename(id_b)}.mp4"
                local_b = temp_dir / fn_b
                s3_key_b = f"{s3_base}{sanitized_source_title}/{fn_b}"
                logger.info(f"Extracting B: {id_b} ({clip_b_start:.3f}-{clip_b_end:.3f}s)")
                cmd_b = [FFMPEG_PATH, '-y', '-ss', str(clip_b_start), '-i', str(local_source_path),
                         '-to', str(clip_b_end - clip_b_start), *ffmpeg_opts, str(local_b)]
                run_ffmpeg_command(cmd_b, "ffmpeg Extract Clip B")
                clips_to_create.append((id_b, local_b, s3_key_b, clip_b_start, clip_b_end, start_f_b, end_f_b))
            else:
                logger.warning(f"Skipping Clip B; zero duration.")

            if not clips_to_create:
                raise ValueError("No segments to create after split.")
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
                        raise RuntimeError(f"Missing file: {local_path}")
                    s3_client_for_task.upload_fileobj(open(local_path, "rb"), s3_bucket_name_for_task, s3_key)
                    cur.execute(
                        """
                        INSERT INTO clips (
                        source_video_id, clip_filepath, clip_identifier,
                        start_frame, end_frame, start_time_seconds, end_time_seconds,
                        ingest_state
                        -- inserted_at and updated_at will use DB defaults
                        ) VALUES (%s, %s, %s, %s, %s, %s, %s, 'pending_sprite_generation')
                        RETURNING id;
                        """,
                        (source_video_id, s3_key, identifier, sf, ef, st, et)
                    )
                    new_id = cur.fetchone()[0]
                    new_clip_ids.append(new_id)
                    logger.info(f"Created clip ID {new_id}")
                final_original_state = 'archived'
                msg = f"Split into {new_clip_ids}"
                logger.info(f"Archiving original clip {clip_id}")
                cur.execute(
                    """
                    UPDATE clips SET
                      ingest_state=%s,
                      last_error=%s,
                      processing_metadata=NULL,
                      updated_at=NOW(),
                      keyframed_at=NULL,
                      embedded_at=NULL
                    WHERE id=%s AND ingest_state='splitting'; -- Conditional on active state
                    """,
                    (final_original_state, msg, clip_id)
                )
                if cur.rowcount == 0:
                    # This means the state was not 'splitting' when we tried to archive it.
                    logger.error(f"Failed to archive original clip {clip_id}. Expected state 'splitting', but was different. This indicates a potential concurrency issue or logic error.")
                    raise RuntimeError(f"Failed to archive original clip {clip_id} - state was not 'splitting'.")
                cur.execute("DELETE FROM clip_artifacts WHERE clip_id=%s", (clip_id,))
                logger.info(f"Deleted artifacts for clip {clip_id}")
            conn.commit()
            logger.info(f"Split task finished for clip {clip_id}")
            try:
                s3_client_for_task.delete_object(Bucket=s3_bucket_name_for_task, Key=original_clip_data.get('clip_filepath'))
                logger.info("Deleted original S3 object")
            except ClientError as del_err:
                logger.warning(f"Could not delete original S3 object: {del_err}")
            return {"status":"success","new_clip_ids":new_clip_ids}
        except Exception as final_err:
            logger.error(f"Error in final DB phase for clip {clip_id}: {final_err}", exc_info=True)
            if conn: conn.rollback()
            final_original_state = 'split_failed'
            task_exception = final_err
            raise
    except Exception as e:
        logger.error(f"TASK FAILED [Split]: clip {clip_id} - {e}", exc_info=True)
        # Attempt error-state update
        try:
            error_conn = get_db_connection(environment, cursor_factory=extras.DictCursor)
            if error_conn:
                error_conn.autocommit = True
                with error_conn.cursor() as er_cur:
                    err_msg = f"Split failed: {type(e).__name__}: {str(e)[:450]}"
                    er_cur.execute(
                        """
                        UPDATE clips SET
                          ingest_state='split_failed',
                          last_error=%s,
                          processing_metadata=processing_metadata - 'split_at_frame',
                          updated_at=NOW()
                        WHERE id=%s AND ingest_state IN ('splitting','pending_split', 'split_failed'); -- Allow update if it failed at various points
                        """,
                        (err_msg, clip_id)
                    )
                release_db_connection(error_conn, environment)
        except Exception as db_err:
            logger.error(f"Failed error-state update: {db_err}", exc_info=True)
        raise
    finally:
        if conn:
            try:
                conn.autocommit = True
                conn.rollback()
            except Exception:
                pass
            release_db_connection(conn, environment)
        if temp_dir_obj:
            try:
                shutil.rmtree(temp_dir)
            except Exception:
                pass
        logger.info(f"Cleanup complete for clip {clip_id}: final state {final_original_state}")