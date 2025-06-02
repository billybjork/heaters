import os
import sys
import re
import subprocess
import tempfile
from pathlib import Path
import shutil
import json
import math
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
    from db.sync_db import get_db_connection, release_db_connection
    from config import get_s3_resources # Import the new S3 utility function
except ImportError as e:
    # Fallback for db_utils and config - critical for task operation
    print(f"ERROR: Cannot import db_utils or config in sprite.py. {e}", file=sys.stderr)
    def get_db_connection(cursor_factory=None): raise NotImplementedError("Dummy DB getter")
    def release_db_connection(conn): pass
    def get_s3_resources(environment: str, logger=None): raise NotImplementedError("Dummy S3 resource getter")

# FFMPEG_PATH can remain a module-level constant if it's universally applicable
FFMPEG_PATH = os.getenv("FFMPEG_PATH", "ffmpeg")

# --- Helper functions (defined locally as the import from .splice is removed) ---
def run_ffmpeg_command(cmd_list, step_name="ffmpeg command", cwd=None):
    logger = get_run_logger() # Assumes this is called within a task context
    logger.info(f"Executing FFMPEG Step: {step_name} in sprite.py")
    logger.debug(f"Command: {' '.join(cmd_list)}")
    try:
        result = subprocess.run(
            cmd_list, capture_output=True, text=True, check=True, cwd=cwd,
            encoding='utf-8', errors='replace'
        )
        # Limit logging of stdout to avoid overwhelming logs for large outputs
        stdout_snippet = result.stdout[:1000] + ("..." if len(result.stdout) > 1000 else "")
        logger.debug(f"FFMPEG Output (snippet):\n{stdout_snippet}")
        if result.stderr:
            stderr_snippet = result.stderr[:1000] + ("..." if len(result.stderr) > 1000 else "")
            logger.warning(f"FFMPEG Stderr for {step_name} (snippet):\n{stderr_snippet}")
        return result
    except FileNotFoundError:
        logger.error(f"ERROR in sprite.py: {cmd_list[0]} command not found at path '{FFMPEG_PATH}'.")
        raise
    except subprocess.CalledProcessError as exc:
        logger.error(f"ERROR in sprite.py: {step_name} failed. Exit code: {exc.returncode}")
        # Log full stderr on error if it's not excessively long, otherwise a snippet
        stderr_to_log = exc.stderr if len(exc.stderr) < 2000 else exc.stderr[:2000] + "... (truncated)"
        logger.error(f"Stderr:\n{stderr_to_log}")
        raise

def sanitize_filename(name):
    name = str(name) # Ensure it's a string
    name = re.sub(r'[^\w\.\-]+', '_', name) # Replace non-alphanumeric (excluding ., -) with _
    name = re.sub(r'_+', '_', name).strip('_') # Collapse multiple underscores and strip leading/trailing
    return name[:150] if name else "default_filename_fallback" # Limit length and provide fallback

# --- Constants ---
SPRITE_SHEET_S3_PREFIX = os.getenv("SPRITE_SHEET_S3_PREFIX", "clip_artifacts/sprite_sheets/")
SPRITE_TILE_WIDTH = int(os.getenv("SPRITE_TILE_WIDTH", 480))
SPRITE_TILE_HEIGHT = int(os.getenv("SPRITE_TILE_HEIGHT", -1))
SPRITE_FPS = int(os.getenv("SPRITE_FPS", 24))
SPRITE_COLS = int(os.getenv("SPRITE_COLS", 5))
ARTIFACT_TYPE_SPRITE_SHEET = "sprite_sheet"


@task(name="Generate Sprite Sheet", retries=1, retry_delay_seconds=45)
def generate_sprite_sheet_task(clip_id: int, overwrite_existing: bool = False, environment: str = "development"):
    """
    Generates a sprite sheet for a given clip, uploads it to S3,
    and records it as an artifact in the clip_artifacts table.
    Updates the clip state upon success or failure.
    """
    logger = get_run_logger()
    logger.info(f"TASK [SpriteGen]: Starting for clip_id: {clip_id}")

    # --- Resource Management & State ---
    conn = None
    temp_dir_obj = None
    temp_dir = None
    clip_data = {}
    task_outcome = "failed" # Default outcome status
    intended_success_state = "pending_review"
    failure_state = "sprite_generation_failed"
    error_message = None
    sprite_s3_key = None
    sprite_artifact_id = None

    # --- Get S3 Resources using the utility function ---
    s3_client_for_task, s3_bucket_name_for_task = get_s3_resources(environment, logger=logger)
    # Error handling for missing S3 resources is now within get_s3_resources

    # --- Dependency Checks (FFMPEG only, S3 client handled by get_s3_resources) ---
    if not shutil.which(FFMPEG_PATH):
        logger.error(f"ffmpeg command ('{FFMPEG_PATH}') not found in PATH.")
        # Update state to failed before raising
        _update_clip_state_on_error(clip_id, "ffmpeg_not_found", "FFMPEG executable not found.", logger)
        raise FileNotFoundError(f"ffmpeg command not found at '{FFMPEG_PATH}'.")
    if not shutil.which("ffprobe"):
         logger.warning("ffprobe command not found in PATH. Metadata extraction may fail or be inaccurate.")

    try:
        # === Phase 1: DB Check, Lock, and Verify State ===
        conn = get_db_connection(cursor_factory=extras.DictCursor)
        if conn is None: raise ConnectionError("Failed to get DB connection.")
        conn.autocommit = False # Manual transaction control

        try:
            with conn.cursor() as cur:
                # 1. Acquire Lock
                cur.execute("SELECT pg_try_advisory_xact_lock(2, %s)", (clip_id,))
                lock_acquired_result = cur.fetchone() # fetchone returns a DictRow
                if not lock_acquired_result or not lock_acquired_result['pg_try_advisory_xact_lock']:
                    logger.warning(f"Could not acquire DB lock for clip_id: {clip_id}. Skipping.")
                    conn.rollback()
                    return {"status": "skipped_lock", "reason": "Could not acquire lock", "clip_id": clip_id}
                logger.info(f"Acquired DB lock for clip {clip_id}.")

                # 2. Fetch clip data AND source title, locking the row
                cur.execute(
                    """
                    SELECT
                        c.clip_filepath, c.clip_identifier, c.start_time_seconds, c.end_time_seconds,
                        c.source_video_id, c.ingest_state, c.start_frame, c.end_frame,
                        sv.title AS source_title
                    FROM clips c
                    JOIN source_videos sv ON c.source_video_id = sv.id
                    WHERE c.id = %s FOR UPDATE;
                    """, (clip_id,)
                )
                clip_data = cur.fetchone() # Fetches a dictionary row

                if not clip_data:
                     raise ValueError(f"Clip {clip_id} not found.")

                current_state = clip_data['ingest_state']
                logger.info(f"Fetched clip {clip_id}. Current State: '{current_state}'")

                # 3. Validate clip filepath before state check
                if not clip_data['clip_filepath']:
                     raise ValueError(f"Clip {clip_id} is missing required 'clip_filepath'.")

                # --- UPDATED State Checking Logic ---
                expected_processing_state = 'generating_sprite'
                allow_processing = current_state == expected_processing_state or \
                                   current_state == 'sprite_generation_failed'

                if current_state == 'pending_review' and not overwrite_existing:
                    logger.warning(f"Clip {clip_id} is already 'pending_review'. Skipping sprite generation.")
                    allow_processing = False
                    task_outcome = "skipped_already_done"

                if not allow_processing:
                    logger.warning(f"Skipping sprite task for clip {clip_id}. Current state: '{current_state}' (expected '{expected_processing_state}' or 'sprite_generation_failed').")
                    conn.rollback()

                    skip_reason = f"State '{current_state}' not runnable"
                    if task_outcome == "skipped_already_done": skip_reason = "Already processed (pending_review)"

                    return {"status": "skipped_state", "reason": skip_reason, "clip_id": clip_id}

                conn.commit()
                logger.info(f"Verified state '{current_state}' is runnable for sprite generation ID {clip_id}. Proceeding...")

        except (ValueError, psycopg2.DatabaseError) as db_err:
            logger.error(f"DB Error during initial check/update for sprite gen clip {clip_id}: {db_err}", exc_info=True)
            if conn: conn.rollback()
            error_message = f"DB Init Error: {str(db_err)[:500]}"
            task_outcome = "failed_db_init"
            raise


        # === Phase 2: Main Processing (Download, Probe, Generate, Upload) ===
        clip_s3_key_from_db = clip_data['clip_filepath'] # Use a distinct variable name
        clip_identifier = clip_data['clip_identifier']

        temp_dir_obj = tempfile.TemporaryDirectory(prefix=f"heaters_spritegen_{clip_id}_")
        temp_dir = Path(temp_dir_obj.name)
        local_clip_path = temp_dir / Path(clip_s3_key_from_db).name

        logger.info(f"Downloading clip s3://{s3_bucket_name_for_task}/{clip_s3_key_from_db} to {local_clip_path}...")
        try:
             s3_client_for_task.download_file(s3_bucket_name_for_task, clip_s3_key_from_db, str(local_clip_path))
        except ClientError as s3_err:
             logger.error(f"Failed to download clip {clip_s3_key_from_db} from S3: {s3_err}")
             raise RuntimeError(f"S3 download failed for {clip_s3_key_from_db}") from s3_err

        duration = 0.0
        fps = 0.0
        total_frames_in_clip = 0
        sprite_metadata = None

        try:
             logger.info(f"Probing downloaded clip: {local_clip_path}")
             ffprobe_cmd = [
                 "ffprobe", "-v", "error", "-select_streams", "v:0",
                 "-show_entries", "stream=duration,r_frame_rate,nb_frames",
                 "-count_frames",
                 "-of", "json", str(local_clip_path)
             ]
             result = subprocess.run(ffprobe_cmd, capture_output=True, text=True, check=True, encoding='utf-8', errors='replace')
             probe_data_list = json.loads(result.stdout).get('streams', [])
             if not probe_data_list:
                 raise ValueError(f"ffprobe found no video streams in {local_clip_path}")
             probe_data = probe_data_list[0]
             logger.debug(f"ffprobe result for clip {clip_id}: {probe_data}")

             duration_str = probe_data.get('duration')
             if duration_str:
                 try: duration = float(duration_str)
                 except (ValueError, TypeError): logger.warning(f"Could not parse duration '{duration_str}' to float.")
             
             fps_str = probe_data.get('r_frame_rate', '0/1')
             if '/' in fps_str:
                 num_str, den_str = fps_str.split('/')
                 try:
                     num, den = int(num_str), int(den_str)
                     if den > 0: fps = num / den
                 except (ValueError, TypeError): logger.warning(f"Could not parse r_frame_rate: {fps_str}")

             nb_frames_str = probe_data.get('nb_frames')
             if nb_frames_str:
                 try:
                     total_frames_in_clip = int(nb_frames_str)
                     logger.info(f"Using ffprobe nb_frames: {total_frames_in_clip}")
                 except (ValueError, TypeError): logger.warning(f"Could not parse nb_frames '{nb_frames_str}' to int.")

             if total_frames_in_clip <= 0 and duration > 0 and fps > 0:
                 calc_frames = math.ceil(duration * fps)
                 total_frames_in_clip = calc_frames + 1 if calc_frames > 0 else 0
                 logger.info(f"Calculated total frames from duration*fps: {total_frames_in_clip} (using ceil+1)")

             if duration <= 0 or fps <= 0 or total_frames_in_clip <= 0:
                  raise ValueError(f"Unable to establish valid duration ({duration:.3f}s), fps ({fps:.3f}), or total frames ({total_frames_in_clip}) for clip {clip_id}.")
             logger.info(f"Clip {clip_id} Probe Results: Duration={duration:.3f}s, FPS={fps:.3f}, Total Frames={total_frames_in_clip}")

        except subprocess.CalledProcessError as probe_err:
             logger.error(f"ffprobe command failed for {local_clip_path}. Error: {probe_err.stderr}", exc_info=False)
             raise ValueError(f"ffprobe failed, cannot generate sprite sheet.") from probe_err
        except (json.JSONDecodeError, KeyError, IndexError) as parse_err:
             logger.error(f"Failed to parse ffprobe JSON output for {local_clip_path}: {parse_err}", exc_info=True)
             raise ValueError(f"ffprobe JSON parsing failed.") from parse_err
        except ValueError as val_err:
             logger.error(f"Metadata validation failed: {val_err}", exc_info=False)
             raise
        except Exception as probe_err:
             logger.error(f"Unexpected error during ffprobe/metadata calculation: {probe_err}", exc_info=True)
             raise ValueError(f"Metadata calculation failed.") from probe_err

        num_sprite_frames = math.ceil(duration * SPRITE_FPS)

        if num_sprite_frames <= 0:
            logger.warning(f"Clip {clip_id} duration too short ({duration:.3f}s) or SPRITE_FPS ({SPRITE_FPS}) too low. Skipping sprite sheet generation ({num_sprite_frames} frames calculated).")
            task_outcome = "success_no_sprite"
            sprite_s3_key = None
            sprite_metadata = None
        else:
            source_title = clip_data.get('source_title', f'source_{clip_data["source_video_id"]}')
            sanitized_source_title = sanitize_filename(source_title)
            safe_clip_identifier = sanitize_filename(clip_identifier)
            timestamp = datetime.now().strftime("%Y%m%d%H%M%S")
            sprite_filename = f"{safe_clip_identifier}_sprite_{SPRITE_FPS}fps_w{SPRITE_TILE_WIDTH}_c{SPRITE_COLS}_{timestamp}.jpg"
            local_sprite_path = temp_dir / sprite_filename
            s3_base_prefix = SPRITE_SHEET_S3_PREFIX.strip('/') + '/'
            sprite_s3_key = f"{s3_base_prefix}{sanitized_source_title}/{sprite_filename}"

            num_rows = max(1, math.ceil(num_sprite_frames / SPRITE_COLS))
            vf_filter = f"fps={SPRITE_FPS},scale={SPRITE_TILE_WIDTH}:{SPRITE_TILE_HEIGHT}:flags=neighbor,tile={SPRITE_COLS}x{num_rows}"
            ffmpeg_sprite_cmd = [
                FFMPEG_PATH, '-y', '-i', str(local_clip_path),
                '-vf', vf_filter, '-an', '-qscale:v', '3',
                '-vframes', str(num_sprite_frames), # Ensure num_sprite_frames is a string
                str(local_sprite_path)
            ]

            logger.info(f"Generating {SPRITE_COLS}x{num_rows} sprite sheet ({num_sprite_frames} frames) for clip {clip_id}...")
            try:
                run_ffmpeg_command(ffmpeg_sprite_cmd, "ffmpeg Generate Sprite Sheet")
            except Exception as ffmpeg_err:
                 logger.error(f"ffmpeg sprite generation failed: {ffmpeg_err}", exc_info=True)
                 raise RuntimeError("FFmpeg sprite generation failed") from ffmpeg_err

            if not local_sprite_path.is_file() or local_sprite_path.stat().st_size == 0:
                 raise RuntimeError(f"FFmpeg completed but output sprite file is missing or empty: {local_sprite_path}")

            logger.info(f"Uploading sprite sheet to s3://{s3_bucket_name_for_task}/{sprite_s3_key}")
            try:
                with open(local_sprite_path, "rb") as f:
                    s3_client_for_task.upload_fileobj(f, s3_bucket_name_for_task, sprite_s3_key)
            except ClientError as s3_upload_err:
                 logger.error(f"Failed to upload sprite sheet {sprite_s3_key}: {s3_upload_err}")
                 raise RuntimeError(f"S3 upload failed for sprite sheet {sprite_s3_key}") from s3_upload_err

            calculated_tile_height = None
            sprite_probe_dir_obj = None
            try:
                # Create a unique temp dir for probing the sprite to avoid filename clashes if main temp_dir is reused quickly
                sprite_probe_dir_obj = tempfile.TemporaryDirectory(prefix=f"heaters_sprite_probe_{clip_id}_")
                local_probe_sprite_path = Path(sprite_probe_dir_obj.name) / local_sprite_path.name
                shutil.copy2(local_sprite_path, local_probe_sprite_path) # Copy for probing

                logger.info(f"Probing generated sprite sheet: {local_probe_sprite_path}")
                probe_sprite_cmd = ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "json", str(local_probe_sprite_path)]
                result_sprite = subprocess.run(probe_sprite_cmd, capture_output=True, text=True, check=True, encoding='utf-8', errors='replace')
                
                sprite_dims_list = json.loads(result_sprite.stdout).get('streams', [])
                if not sprite_dims_list:
                    raise ValueError(f"ffprobe found no video streams in generated sprite {local_probe_sprite_path}")
                sprite_dims = sprite_dims_list[0]


                total_sprite_height = int(sprite_dims.get('height', 0))
                if total_sprite_height > 0 and num_rows > 0:
                     calculated_tile_height = math.floor(total_sprite_height / num_rows)
                     logger.info(f"Calculated sprite tile height from probe: {calculated_tile_height}")
                else: logger.warning("Could not calculate valid tile height from sprite probe.")

            except Exception as sprite_probe_err:
                logger.warning(f"Could not probe generated sprite sheet dimensions: {sprite_probe_err}. Tile height will be null.")
            finally:
                if sprite_probe_dir_obj:
                    try: shutil.rmtree(sprite_probe_dir_obj.name)
                    except Exception as sp_cleanup_err: logger.warning(f"Error cleaning sprite probe temp dir: {sp_cleanup_err}")


            sprite_metadata = {
                 "tile_width": SPRITE_TILE_WIDTH,
                 "tile_height_calculated": calculated_tile_height,
                 "cols": SPRITE_COLS,
                 "rows": num_rows,
                 "total_sprite_frames": num_sprite_frames,
                 "clip_fps_source": round(fps, 3),
                 "clip_total_frames_source": total_frames_in_clip
             }
            logger.info(f"Sprite sheet generated and uploaded for clip {clip_id}. Metadata: {json.dumps(sprite_metadata)}")


        # === Phase 3: Final DB Update (Insert Artifact, Update Clip State) ===
        conn.autocommit = False
        try:
            with conn.cursor() as cur:
                 logger.debug(f"Starting final DB transaction for clip {clip_id}...")
                 # Re-acquire lock for this transaction
                 cur.execute("SELECT pg_try_advisory_xact_lock(2, %s)", (clip_id,))
                 lock_acquired_final_result = cur.fetchone()
                 if not lock_acquired_final_result or not lock_acquired_final_result['pg_try_advisory_xact_lock']:
                     # This is unlikely if first lock worked, but possible if another process snuck in
                     raise RuntimeError("Failed to re-acquire lock for final DB update in sprite task.")
                 logger.info(f"Re-acquired DB lock for final update of clip {clip_id}.")


                 if sprite_s3_key and sprite_metadata:
                     logger.info(f"Inserting/updating sprite artifact record for clip {clip_id}")
                     artifact_insert_sql = sql.SQL("""
                        INSERT INTO clip_artifacts (
                            clip_id, artifact_type, strategy, tag, s3_key, metadata, created_at, updated_at
                        ) VALUES (%s, %s, %s, %s, %s, %s, NOW(), NOW())
                        ON CONFLICT (clip_id, artifact_type, strategy, tag) DO UPDATE SET
                            s3_key = EXCLUDED.s3_key,
                            metadata = EXCLUDED.metadata,
                            updated_at = NOW()
                        RETURNING id;
                    """)
                     artifact_strategy = None
                     artifact_tag = None
                     cur.execute(
                        artifact_insert_sql,
                        (clip_id, ARTIFACT_TYPE_SPRITE_SHEET, artifact_strategy, artifact_tag,
                        sprite_s3_key, extras.Json(sprite_metadata))
                    )
                     inserted_artifact = cur.fetchone()
                     if inserted_artifact:
                          sprite_artifact_id = inserted_artifact['id']
                          logger.info(f"Successfully inserted/updated artifact record, ID: {sprite_artifact_id}")
                     else:
                          logger.error("Artifact insert/update query did not return an ID.")
                          raise psycopg2.DatabaseError("Artifact insert/update failed unexpectedly.")

                 logger.info(f"Updating clip {clip_id} state to '{intended_success_state}'")
                 clip_update_sql = sql.SQL("""
                     UPDATE clips
                     SET ingest_state = %s,
                         updated_at = NOW(),
                         last_error = NULL
                     WHERE id = %s AND ingest_state = 'generating_sprite';
                 """)
                 cur.execute(clip_update_sql, (intended_success_state, clip_id))

                 if cur.rowcount == 1 or cur.statusmessage == "UPDATE 1":
                      logger.info(f"Successfully updated clip {clip_id} state.")
                      task_outcome = task_outcome if task_outcome == "success_no_sprite" else "success"
                 else:
                      logger.error(f"Final clip state update failed for clip {clip_id}. Status: '{cur.statusmessage}', Rowcount: {cur.rowcount}. State mismatch or row deleted? Rolling back transaction.")
                      task_outcome = "failed_db_update_state_mismatch"
                      raise RuntimeError(f"Failed to update clip {clip_id} final state (expected 1 row, got {cur.rowcount}).")

            conn.commit()
            logger.debug(f"Final DB transaction committed for clip {clip_id}.")

        except (psycopg2.DatabaseError, psycopg2.OperationalError, RuntimeError) as db_err:
            logger.error(f"DB Error during final update/artifact insert for clip {clip_id}: {db_err}", exc_info=True)
            if conn: conn.rollback()
            task_outcome = "failed_db_final_update"
            error_message = f"DB Final Update Error: {str(db_err)[:500]}"
            raise


    except Exception as e:
        logger.error(f"TASK FAILED [SpriteGen]: clip_id {clip_id} - {type(e).__name__}: {e}", exc_info=True)
        if not task_outcome.startswith("failed"): task_outcome = "failed"
        if not error_message: error_message = f"Task Error: {type(e).__name__}: {str(e)[:450]}"

        if conn:
            try:
                conn.rollback()
            except Exception as rb_err:
                logger.warning(f"Error during rollback before failure update: {rb_err}")
        
        error_conn = None
        try:
             error_conn = get_db_connection()
             if not error_conn:
                 logger.critical(f"CRITICAL: Failed to get separate DB connection to update error state for clip {clip_id}")
             else:
                error_conn.autocommit = True
                with error_conn.cursor() as err_cur:
                    logger.info(f"Attempting to set clip {clip_id} state to '{failure_state}' after error...")
                    err_cur.execute(
                        """
                        UPDATE clips SET
                            ingest_state = %s,
                            last_error = %s,
                            retry_count = COALESCE(retry_count, 0) + 1,
                            updated_at = NOW()
                        WHERE id = %s AND ingest_state = 'generating_sprite';
                        """,
                        (failure_state, error_message, clip_id)
                    )
                    logger.info(f"DB update executed to set clip {clip_id} to '{failure_state}'. Status: {err_cur.statusmessage}")
        except Exception as db_err_update:
             logger.critical(f"CRITICAL: Failed to update error state in DB for clip {clip_id}: {db_err_update}")
        finally:
             if error_conn:
                 release_db_connection(error_conn)
        raise e

    finally:
        log_message = f"TASK [SpriteGen] Result: clip_id={clip_id}, outcome={task_outcome}"
        final_db_state_expected = ""
        if task_outcome == "success":
            final_db_state_expected = intended_success_state
            log_message += f", new_state={final_db_state_expected}, artifact_id={sprite_artifact_id}, sprite_key={sprite_s3_key}"
            logger.info(log_message)
        elif task_outcome == "success_no_sprite":
            final_db_state_expected = intended_success_state
            log_message += f", new_state={final_db_state_expected} (no sprite generated)"
            logger.info(log_message)
        elif task_outcome.startswith("skipped"): # Handles skipped_lock and skipped_state
            log_message += f" ({task_outcome})" # Add specific skip reason
            logger.warning(log_message)
        else:
            final_db_state_expected = failure_state
            log_message += f", final_state_attempted={final_db_state_expected}, error='{error_message}'"
            logger.error(log_message)

        if conn:
            try:
                conn.autocommit = True
                conn.rollback()
            except Exception as conn_cleanup_err:
                logger.warning(f"Exception during final connection cleanup for clip {clip_id}: {conn_cleanup_err}")
            finally:
                release_db_connection(conn)
                logger.debug(f"DB connection released for clip {clip_id}.")
        if temp_dir_obj:
            try:
                shutil.rmtree(temp_dir_obj.name, ignore_errors=True)
                logger.info(f"Cleaned up temporary directory: {temp_dir_obj.name}")
            except Exception as cleanup_err:
                 logger.warning(f"Error cleaning up temp dir {temp_dir_obj.name}: {cleanup_err}")

    return {
        "status": task_outcome,
        "clip_id": clip_id,
        "sprite_sheet_key": sprite_s3_key,
        "sprite_artifact_id": sprite_artifact_id,
        "final_db_state": final_db_state_expected,
        "error": error_message,
        "s3_bucket_used": s3_bucket_name_for_task if 's3_bucket_name_for_task' in locals() else None # Include bucket used
    }

# Helper function to update clip state on error, encapsulated to reduce repetition
def _update_clip_state_on_error(clip_id, new_state, error_msg_for_db, logger, artifact_id_to_clear=None):
    conn = None
    try:
        conn = get_db_connection() # Uses default cursor
        if conn is None: 
            logger.error(f"[StateUpdateHelper] Failed to get DB connection for clip {clip_id} to set state '{new_state}'.")
            return
        
        conn.autocommit = True # Simple update, use autocommit
        with conn.cursor() as cur:
            # If an artifact ID was created but the process failed later (e.g., S3 upload fails after DB insert for artifact)
            # we might want to clear it or mark the artifact as failed.
            # For now, just updating clip state and error.
            if artifact_id_to_clear:
                 logger.warning(f"[StateUpdateHelper] An artifact ID {artifact_id_to_clear} was generated for clip {clip_id} but an error occurred. Consider cleanup for this artifact.")
                # Optionally, you could delete the clip_artifacts record here if appropriate:
                # cur.execute("DELETE FROM clip_artifacts WHERE id = %s", (artifact_id_to_clear,))
                # logger.info(f"[StateUpdateHelper] Deleted placeholder artifact record {artifact_id_to_clear} due to error.")

            query = sql.SQL("""
                UPDATE clips
                SET ingest_state = %s,
                    last_error = %s,
                    updated_at = NOW(),
                    retry_count = COALESCE(retry_count, 0) + CASE WHEN %s = 'sprite_generation_failed' THEN 1 ELSE 0 END
                WHERE id = %s AND ingest_state != %s; -- Avoid overwriting a final success state like 'pending_review'
            """)
            # Avoid incrementing retry if it's just a skip or already processed
            is_failure_state = new_state == 'sprite_generation_failed' # Check specific failure state for retry increment
            cur.execute(query, (new_state, error_msg_for_db, is_failure_state, clip_id, 'pending_review'))
            if cur.rowcount > 0:
                logger.info(f"[StateUpdateHelper] Updated clip {clip_id} state to '{new_state}' due to error: {error_msg_for_db}")
            else:
                logger.warning(f"[StateUpdateHelper] Failed to update clip {clip_id} state to '{new_state}' (or already in a final state). Current state might be unchanged or was 'pending_review'.")
    except Exception as e_db_update:
        logger.error(f"[StateUpdateHelper] CRITICAL: DB error while updating clip {clip_id} to error state '{new_state}': {e_db_update}", exc_info=True)
    finally:
        if conn:
            release_db_connection(conn)