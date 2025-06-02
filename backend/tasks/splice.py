import os
import shutil
import subprocess
import tempfile
from pathlib import Path
import re
import time
import cv2
import numpy as np
import boto3
from botocore.exceptions import ClientError, NoCredentialsError
from prefect import task, get_run_logger
import psycopg2
from psycopg2 import sql
import sys # Added for sys.path manipulation in fallback

try:
    from db.sync_db import get_db_connection, release_db_connection # Added release_db_connection
    from config import get_s3_resources # Import the new utility function
except ImportError:
    # sys = __import__('sys') # Not needed, import sys directly
    project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
    if project_root not in sys.path:
        sys.path.insert(0, project_root)
    try:
        from db.sync_db import get_db_connection, release_db_connection # Added release_db_connection
        from config import get_s3_resources # Import again in fallback
    except ImportError as e:
        print(f"Failed to import db_utils or config in splice.py: {e}")
        def get_db_connection(environment: str, cursor_factory=None): raise NotImplementedError("Dummy get_db_connection") # Add environment
        def release_db_connection(conn, environment: str): raise NotImplementedError("Dummy release_db_connection") # Add environment
        def get_s3_resources(env, logger=None): raise NotImplementedError("Dummy get_s3_resources")

# Module-level APP_ENV can be used for general worker context if needed outside tasks
# APP_ENV = os.getenv("APP_ENV", "production")

# AWS_REGION for S3 client will be handled by get_s3_resources
# S3_BUCKET_NAME will be handled by get_s3_resources

# --- Task Configuration ---
CLIP_S3_PREFIX = "clips/"
# Scene Detection Config
SCENE_DETECT_THRESHOLD = float(os.getenv("SCENE_DETECT_THRESHOLD", 0.6))
_hist_methods_map = { "CORREL": cv2.HISTCMP_CORREL, "CHISQR": cv2.HISTCMP_CHISQR, "INTERSECT": cv2.HISTCMP_INTERSECT, "BHATTACHARYYA": cv2.HISTCMP_BHATTACHARYYA }
_hist_method_str = os.getenv("SCENE_DETECT_METHOD", "CORREL").upper()
SCENE_DETECT_METHOD = _hist_methods_map.get(_hist_method_str, cv2.HISTCMP_CORREL)
if _hist_method_str not in _hist_methods_map:
    # Use a print here if logger might not be configured, or get a basic logger
    print(f"Warning: Invalid SCENE_DETECT_METHOD '{_hist_method_str}'. Defaulting to CORREL.")

MIN_CLIP_DURATION_SECONDS = float(os.getenv("MIN_CLIP_DURATION_SECONDS", 1.0))
FFMPEG_PATH = "ffmpeg"
FFMPEG_CRF = os.getenv("FFMPEG_CRF", "23")
FFMPEG_PRESET = os.getenv("FFMPEG_PRESET", "medium")
FFMPEG_AUDIO_BITRATE = os.getenv("FFMPEG_AUDIO_BITRATE", "128k")


def sanitize_filename(name):
    """Removes potentially problematic characters for filenames and S3 keys."""
    if not name: return "untitled"
    name = str(name)
    name = re.sub(r'[^\w\s\-.]', '', name)
    name = re.sub(r'\s+', '_', name).strip('_')
    return name[:150] if name else "sanitized_untitled"

def run_ffmpeg_command(cmd_list, step_name="ffmpeg command", cwd=None):
    """Runs an ffmpeg command, logs output, raises error on failure."""
    logger = get_run_logger()
    cmd_str = ' '.join(cmd_list)
    logger.info(f"Running {step_name}: {cmd_str}")
    try:
        process = subprocess.Popen(
            cmd_list, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding='utf-8', errors='replace', # Handle potential encoding errors
            cwd=cwd
        )
        stdout, stderr = process.communicate()

        if process.returncode != 0:
            logger.error(f"Error during '{step_name}': Failed with exit code {process.returncode}.")
            if stderr: logger.error(f"FFmpeg STDERR:\n{stderr}")
            if stdout: logger.error(f"FFmpeg STDOUT:\n{stdout}")
            raise subprocess.CalledProcessError(process.returncode, cmd_list, output=stdout, stderr=stderr)

        logger.info(f"{step_name} completed successfully.")
        # logger.debug(f"FFmpeg STDERR (snippet):\n{stderr[:1000]}") # Log some stderr even on success
        return True
    except FileNotFoundError:
        logger.error(f"Error during '{step_name}': Command '{FFMPEG_PATH}' not found. Is it installed and in PATH?")
        raise
    except Exception as e:
        logger.error(f"An unexpected error occurred during '{step_name}': {e}", exc_info=True)
        raise


# --- OpenCV Scene Detection Functions ---

def calculate_histogram(frame, bins=256, ranges=[0, 256]):
    """Calculates and normalizes the BGR histogram for a frame."""
    # TODO: Consider converting to HSV/LAB color space for potentially better results
    b, g, r = cv2.split(frame)
    hist_b = cv2.calcHist([b], [0], None, [bins], ranges)
    hist_g = cv2.calcHist([g], [0], None, [bins], ranges)
    hist_r = cv2.calcHist([r], [0], None, [bins], ranges)
    hist = np.concatenate((hist_b, hist_g, hist_r))
    cv2.normalize(hist, hist) # Normalize in place
    return hist

def detect_scenes(video_path: str, threshold: float, hist_method: int):
    """
    Detects scene cuts in a video file using histogram comparison.
    Returns scene list [(start_frame, end_frame)], fps, frame_size, total_frames.
    Uses Prefect logger.
    """
    logger = get_run_logger()
    logger.info(f"Opening video for scene detection: {video_path}")
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        logger.error(f"Error: Could not open video file: {video_path}")
        return None, None, None, None

    fps = cap.get(cv2.CAP_PROP_FPS)
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))

    if fps <= 0 or total_frames <= 0:
        logger.error(f"Invalid video properties: FPS={fps}, Frames={total_frames}. Cannot detect scenes.")
        cap.release()
        return None, None, None, None

    logger.info(f"Video Info: {width}x{height}, {fps:.2f} FPS, {total_frames} Frames")

    prev_hist = None
    cut_frames = [0] # Start first scene at frame 0
    frame_number = 0
    processed_frame_count = 0
    last_log_time = time.time()

    logger.info(f"Detecting scenes using threshold={threshold}, method={hist_method}...")

    while True:
        ret, frame = cap.read()
        if not ret:
            logger.info("End of video reached.")
            break

        # Optimization: Process every Nth frame? For now, process all.
        try:
            current_hist = calculate_histogram(frame)
            if prev_hist is not None:
                score = cv2.compareHist(prev_hist, current_hist, hist_method)

                # Determine if it's a cut based on method and threshold
                is_cut = False
                if hist_method in [cv2.HISTCMP_CORREL, cv2.HISTCMP_INTERSECT]:
                    if score < threshold: is_cut = True
                elif hist_method in [cv2.HISTCMP_CHISQR, cv2.HISTCMP_BHATTACHARYYA]:
                     if score > threshold: is_cut = True
                else: # Default assumption (correlation-like)
                    if score < threshold: is_cut = True

                if is_cut:
                    if frame_number > cut_frames[-1]: # Avoid duplicate frame numbers if cut detected rapidly
                        cut_frames.append(frame_number)
                        logger.debug(f"Scene cut detected at frame {frame_number} (Score: {score:.4f})")
                    else:
                         logger.debug(f"Skipping duplicate cut detection at frame {frame_number}")

            prev_hist = current_hist
            frame_number += 1
            processed_frame_count += 1

            # Log progress periodically
            current_time = time.time()
            if current_time - last_log_time >= 10.0: # Log every 10 seconds
                logger.info(f"Scene detection progress: Frame {frame_number}/{total_frames} ({frame_number/total_frames*100:.1f}%)")
                last_log_time = current_time

        except cv2.error as cv_err:
            logger.warning(f"OpenCV error processing frame {frame_number}: {cv_err}. Skipping frame.")
            frame_number += 1 # Ensure frame count progresses
            prev_hist = None # Reset prev_hist after error
        except Exception as e:
             logger.error(f"Unexpected error processing frame {frame_number}: {e}. Stopping detection.", exc_info=True)
             break # Stop processing on unexpected error

    # Ensure the last frame is included as the end of the last scene
    if total_frames > 0 and cut_frames[-1] < total_frames:
        cut_frames.append(total_frames)

    cap.release()
    logger.info(f"Finished analyzing {processed_frame_count} frames.")

    # Create scene list (start_frame, end_frame_exclusive)
    scenes = []
    if len(cut_frames) > 1:
        for i in range(len(cut_frames) - 1):
            start_frame = cut_frames[i]
            end_frame_exclusive = cut_frames[i + 1]
            # Ensure start is strictly less than end
            if start_frame < end_frame_exclusive:
                scenes.append((start_frame, end_frame_exclusive))
            else:
                 logger.warning(f"Skipping invalid scene range: start={start_frame}, end={end_frame_exclusive}")

    logger.info(f"Detected {len(scenes)} potential scenes.")
    return scenes, fps, (width, height), total_frames


# --- Main Splice Task ---

@task(name="Splice Source Video into Clips", retries=1, retry_delay_seconds=60)
def splice_video_task(source_video_id: int, environment: str = "development"):
    """
    Downloads source video, detects scenes using OpenCV, splices using ffmpeg,
    uploads clips to S3, and creates 'clips' table records.

    Args:
        source_video_id (int): The ID of the source video in the database.
        environment (str): The execution environment ("development" or "production").
    """
    logger = get_run_logger()
    logger.info(f"TASK [Splice]: Starting for source_video_id: {source_video_id}, Environment: {environment}")

    # --- Get S3 Resources using the utility function ---
    s3_client_for_task, s3_bucket_name_for_task = get_s3_resources(environment, logger=logger)
    # Error handling for missing S3 resources is now within get_s3_resources

    conn = None
    temp_dir_obj = None
    source_s3_key = None
    source_title = f"Source_{source_video_id}"
    created_clip_ids = []
    processed_clip_count = 0
    failed_clip_count = 0
    scenes = []
    fps = 0
    frame_size = (0,0)
    total_frames = 0

    # --- Dependency and Configuration Checks ---
    if not s3_client_for_task:
        logger.error("S3 client not initialized. Cannot proceed.")
        raise RuntimeError("S3 client failed to initialize.")
    if not shutil.which(FFMPEG_PATH):
        logger.error(f"Dependency '{FFMPEG_PATH}' not found in PATH.")
        raise FileNotFoundError("ffmpeg is required but not found.")
    # Check OpenCV import success
    try:
        cv2.__version__
        np.__version__
        logger.info(f"Using OpenCV v{cv2.__version__}, NumPy v{np.__version__}")
    except NameError:
         logger.error("OpenCV (cv2) or NumPy (np) not imported correctly. Cannot perform scene detection.")
         raise ImportError("OpenCV or NumPy failed to import.")

    overwrite_existing = False # Define explicitly if needed later, currently splice doesn't overwrite
    task_outcome = "failed" # Default outcome

    try:
        # --- Database Connection and Initial Check ---
        conn = get_db_connection(environment) # New
        if conn is None: raise ConnectionError("Failed to get DB connection.")
        conn.autocommit = False # Manual transaction control

        with conn.cursor() as cur:
            # === Transaction Start (initial check/update) ===
            try:
                # 1. Acquire Lock
                cur.execute("SELECT pg_try_advisory_xact_lock(1, %s)", (source_video_id,))
                lock_acquired = cur.fetchone()[0]
                if not lock_acquired:
                    logger.warning(f"Could not acquire DB lock for source_video_id: {source_video_id}. Skipping.")
                    conn.rollback()
                    return {"status": "skipped_lock", "reason": "Could not acquire lock", "source_video_id": source_video_id}
                logger.info(f"Acquired DB lock for source {source_video_id}.")

                # 2. Fetch data & lock row
                cur.execute("SELECT filepath, ingest_state, title FROM source_videos WHERE id = %s FOR UPDATE", (source_video_id,))
                result = cur.fetchone()
                if not result: raise ValueError(f"Source video ID {source_video_id} not found.")

                source_s3_key, current_state, db_title = result
                if db_title: source_title = db_title # Use DB title if available
                logger.info(f"Fetched source {source_video_id}. Title: '{source_title}', State: '{current_state}', S3 Key: '{source_s3_key}'")

                if not source_s3_key:
                    raise ValueError(f"Source video {source_video_id} missing S3 filepath.")

                # --- UPDATED State Checking Logic ---
                expected_processing_state = 'splicing'
                # Allow processing if state is 'splicing' (set by initiator) or 'splicing_failed' (for retries)
                allow_processing = current_state == expected_processing_state or \
                                   current_state == 'splicing_failed'

                # Explicitly skip if already completed ('spliced') unless overwriting (currently no overwrite logic)
                if current_state == 'spliced' and not overwrite_existing:
                    logger.warning(f"Source video {source_video_id} is already 'spliced'. Skipping.")
                    allow_processing = False
                    task_outcome = "skipped_already_done"

                if not allow_processing:
                    # Log includes the actual state found vs expected
                    logger.warning(f"Skipping splice task for source video {source_video_id}. Current state: '{current_state}' (expected '{expected_processing_state}' or 'splicing_failed').")
                    conn.rollback() # Release lock/transaction

                    # Determine specific skip reason for return value
                    skip_reason = f"State '{current_state}' not runnable"
                    if task_outcome == "skipped_already_done": skip_reason = "Already spliced"

                    return {"status": "skipped_state", "reason": skip_reason, "source_video_id": source_video_id}

                # If we reach here, processing is allowed. The initiator already set the state.
                # Commit transaction to release the row lock before long-running processing.
                conn.commit()
                logger.info(f"Verified state '{current_state}' is runnable for splicing ID {source_video_id}. Proceeding...")
                # The lock acquired by FOR UPDATE is released by commit.

            except (ValueError, psycopg2.DatabaseError) as initial_db_err:
                logger.error(f"DB Error during initial check/update for source {source_video_id}: {initial_db_err}", exc_info=True)
                if conn: conn.rollback()
                raise # Re-raise to be caught by main handler

        # === Main Processing ===
        temp_dir_obj = tempfile.TemporaryDirectory(prefix=f"heaters_splice_{source_video_id}_")
        temp_dir = Path(temp_dir_obj.name)
        logger.info(f"Using temporary directory: {temp_dir}")

        # 3. Download Source Video from S3
        local_source_path = temp_dir / Path(source_s3_key).name
        logger.info(f"Source is S3 key. Downloading s3://{s3_bucket_name_for_task}/{source_s3_key} to {local_source_path}")
        try:
            s3_client_for_task.download_file(s3_bucket_name_for_task, source_s3_key, str(local_source_path))
            logger.info("S3 Download successful.")
        except ClientError as e:
            logger.error(f"Failed to download source video from S3 ({s3_bucket_name_for_task}/{source_s3_key}): {e}", exc_info=True)
            raise RuntimeError(f"S3 download failed for {source_s3_key}") from e

        # 4. Detect Scenes using OpenCV
        logger.info("Starting scene detection...")
        detect_result = detect_scenes(str(local_source_path), SCENE_DETECT_THRESHOLD, SCENE_DETECT_METHOD)

        if detect_result is None or detect_result[0] is None:
             logger.error("Scene detection failed or returned invalid data. Cannot proceed with splicing.")
             # Update source state to failed in final transaction
             scenes = [] # Ensure scenes is empty list
        else:
            scenes, fps, frame_size, total_frames = detect_result
            if not scenes:
                logger.warning("Scene detection finished successfully but found 0 scenes. No clips will be generated.")
            else:
                 logger.info(f"Scene detection complete. Found {len(scenes)} scenes.")

        # 5. Process, Upload, and Record Each Clip based on detected scenes
        sanitized_title_prefix = sanitize_filename(source_title)

        # --- Start *second* transaction for clips and final source update ---
        conn.autocommit = False
        with conn.cursor() as cur:
            # === Transaction Start (clips + final source update) ===
            if not scenes:
                 logger.info("Skipping clip extraction loop as no scenes were detected.")
            else:
                logger.info(f"Starting extraction, upload, and DB insertion for {len(scenes)} detected scenes...")

            for idx, scene_frames in enumerate(scenes):
                try:
                    start_frame, end_frame_exclusive = scene_frames
                    # Calculate accurate times using FPS
                    start_time_seconds = start_frame / fps if fps > 0 else 0
                    # Use end_frame_exclusive for end time calculation
                    end_time_seconds = end_frame_exclusive / fps if fps > 0 else start_time_seconds
                    duration_seconds = max(0, end_time_seconds - start_time_seconds)

                    # Check Minimum Duration
                    if duration_seconds < MIN_CLIP_DURATION_SECONDS:
                        logger.info(f"Skipping scene {idx} (Frames {start_frame}-{end_frame_exclusive-1}): Duration {duration_seconds:.2f}s < minimum {MIN_CLIP_DURATION_SECONDS}s.")
                        continue

                    # Generate identifiers and paths
                    # Use sanitized source title for directory structure
                    clip_identifier = f"{sanitized_title_prefix}_clip_{idx:05d}" # Use 0-based index for consistency
                    clip_filename = f"{clip_identifier}.mp4"
                    local_clip_path = temp_dir / clip_filename # Store temp clips directly in temp_dir
                    s3_prefix = CLIP_S3_PREFIX.strip('/') + '/' # Ensure prefix ends with /
                    # Add sanitized_title_prefix to the S3 key path
                    clip_s3_key = f"{s3_prefix}{sanitized_title_prefix}/{clip_filename}"

                    logger.info(f"Extracting clip {idx}: {clip_identifier} (Frames {start_frame}-{end_frame_exclusive-1}, Time {start_time_seconds:.2f}s-{end_time_seconds:.2f}s)")

                    # Extract clip using ffmpeg with specific start time and duration
                    ffmpeg_extract_cmd = [
                        FFMPEG_PATH, '-y',
                        '-i', str(local_source_path), # Input is the downloaded source
                        '-ss', str(start_time_seconds), # Start time
                        '-t', str(duration_seconds),    # Duration
                        '-map', '0:v:0?', '-map', '0:a:0?', # Map first video/audio streams if present
                        '-c:v', 'libx264', '-preset', FFMPEG_PRESET, '-crf', FFMPEG_CRF, '-pix_fmt', 'yuv420p', # Video encoding
                    ]
                    # Add audio options or -an
                    if FFMPEG_AUDIO_BITRATE and FFMPEG_AUDIO_BITRATE != '0':
                        ffmpeg_extract_cmd.extend(['-c:a', 'aac', '-b:a', FFMPEG_AUDIO_BITRATE])
                    else:
                        ffmpeg_extract_cmd.extend(['-an'])
                    # Output path and faststart
                    ffmpeg_extract_cmd.extend(['-movflags', '+faststart', str(local_clip_path)])

                    # Run ffmpeg command
                    run_ffmpeg_command(ffmpeg_extract_cmd, f"ffmpeg Extract Clip {idx}")

                    # Upload clip to S3
                    logger.debug(f"Uploading {local_clip_path.name} to s3://{s3_bucket_name_for_task}/{clip_s3_key}")
                    with open(local_clip_path, "rb") as f:
                        s3_client_for_task.upload_fileobj(f, s3_bucket_name_for_task, clip_s3_key)
                    logger.debug(f"S3 upload successful for {clip_s3_key}")

                    # Insert clip record into DB
                    cur.execute(
                        """
                        INSERT INTO clips (source_video_id, clip_filepath, clip_identifier,
                                           start_frame, end_frame, start_time_seconds, end_time_seconds,
                                           ingest_state, created_at, updated_at)
                        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, NOW(), NOW())
                        ON CONFLICT (clip_identifier) DO UPDATE SET -- Handle potential reruns
                           clip_filepath = EXCLUDED.clip_filepath,
                           start_frame = EXCLUDED.start_frame,
                           end_frame = EXCLUDED.end_frame,
                           start_time_seconds = EXCLUDED.start_time_seconds,
                           end_time_seconds = EXCLUDED.end_time_seconds,
                           ingest_state = EXCLUDED.ingest_state, -- Reset state on conflict
                           updated_at = NOW()
                        RETURNING id;
                        """,
                        (source_video_id, clip_s3_key, clip_identifier,
                         start_frame, end_frame_exclusive, # Store frame numbers
                         start_time_seconds, end_time_seconds, # Store calculated times
                         'pending_sprite_generation')
                    )
                    new_clip_id = cur.fetchone()[0]
                    created_clip_ids.append(new_clip_id)
                    processed_clip_count += 1
                    logger.info(f"Successfully recorded clip_id: {new_clip_id} (State: pending_sprite_generation)") # Update log

                except (ClientError, psycopg2.DatabaseError, subprocess.CalledProcessError, Exception) as clip_err:
                    failed_clip_count += 1
                    logger.error(f"Failed to process/extract/upload/record clip {idx}: {clip_err}", exc_info=True)
                    # Ensure DB is rolled back if error occurs within loop *before* commit

            # 6. Final Source Video Update (within the same transaction)
            final_source_state = 'spliced'
            final_error_message = None

            if not scenes: # Handle case where scene detection failed or found none
                final_source_state = 'splicing_failed'
                final_error_message = "Scene detection failed or found 0 scenes."
                logger.error(f"Source {source_video_id}: Setting state to failed - {final_error_message}")
            elif failed_clip_count > 0 and processed_clip_count == 0:
                 final_source_state = 'splicing_failed'
                 final_error_message = f"All {failed_clip_count} detected scenes failed processing."
                 logger.error(f"Source {source_video_id}: All {failed_clip_count} clips failed.")
            elif failed_clip_count > 0:
                 final_source_state = 'splicing_partial_failure'
                 final_error_message = f"{failed_clip_count} of {len(scenes)} scenes failed during processing."
                 logger.warning(f"Source {source_video_id}: {final_error_message}")
            elif processed_clip_count > 0:
                  final_source_state = 'spliced'
                  logger.info(f"Source {source_video_id}: Splicing successful, {processed_clip_count} clips created from {len(scenes)} scenes.")
            elif processed_clip_count == 0 and len(scenes) > 0:
                # This case means scenes were detected but all were filtered out (e.g., too short)
                final_source_state = 'spliced' # Technically spliced, just 0 valid clips
                logger.info(f"Source {source_video_id}: Splicing found {len(scenes)} scenes, but 0 clips met criteria.")
            elif processed_clip_count == 0 and failed_clip_count == 0 and len(scenes) == 0:
                 # Handled by the initial 'not scenes' check, but included for clarity
                 final_source_state = 'spliced' # No scenes found is not strictly a failure of splicing
                 logger.info(f"Source {source_video_id}: Splicing finished, 0 scenes detected.")

            logger.info(f"Updating source video {source_video_id} final state to '{final_source_state}'")
            cur.execute(
                """
                UPDATE source_videos
                SET ingest_state = %s,
                    spliced_at = CASE WHEN %s IN ('spliced', 'splicing_partial_failure') THEN NOW() ELSE spliced_at END,
                    last_error = %s,
                    updated_at = NOW()
                WHERE id = %s
                """,
                (final_source_state, final_source_state, final_error_message, source_video_id)
            )

            # Commit clip inserts and final source update together
            conn.commit()
            logger.info(f"TASK [Splice]: Finished for source {source_video_id}. Final State: {final_source_state}. Processed: {processed_clip_count}, Failed: {failed_clip_count}, Detected Scenes: {len(scenes)}")

        # === Final Summary Logging ===
        total_clips = len(created_clip_ids) + failed_clip_count
        logger.info(f"TASK [Splice] for source_video_id {source_video_id} summary:")
        logger.info(f"  Total scenes detected: {len(scenes) if scenes else 'N/A'}")
        logger.info(f"  Source video FPS: {fps:.2f} (if processed)")
        logger.info(f"  Clips to process (after duration filter): {processed_clip_count}")
        logger.info(f"  Successfully created and uploaded clips: {len(created_clip_ids)}")
        logger.info(f"  Failed clip attempts: {failed_clip_count}")
        # Log the s3_bucket_name_for_task used in this run
        logger.info(f"  S3 Bucket Used: {s3_bucket_name_for_task}")

        if failed_clip_count > 0 or not created_clip_ids:
            final_status = "partial_success" if created_clip_ids else "failed_no_clips"
            error_message = final_error_message
            logger.warning(f"TASK [Splice] for source_video_id {source_video_id} finished with outcome: '{final_status}'. Check logs for details.")

        # Return a summary dictionary
        return {
            "status": final_status,
            "source_video_id": source_video_id,
            "scenes_detected": len(scenes) if scenes else 0,
            "clips_processed": processed_clip_count,
            "clips_created_in_db": len(created_clip_ids),
            "clip_ids": created_clip_ids,
            "failed_clips": failed_clip_count,
            "s3_bucket_used": s3_bucket_name_for_task, # Include bucket used
            "error_message": error_message
        }

    except Exception as e:
        task_name = "Splice"
        logger.error(f"TASK FAILED ({task_name}): source_video_id {source_video_id} - {e}", exc_info=True)
        if conn:
            try:
                conn.rollback()
                logger.info("Database transaction rolled back due to task failure.")
                conn.autocommit = True # Switch to autocommit for the error update
                with conn.cursor() as err_cur:
                    err_cur.execute(
                        """
                        UPDATE source_videos
                        SET ingest_state = 'splicing_failed',
                            last_error = %s,
                            updated_at = NOW()
                        WHERE id = %s AND ingest_state = 'splicing'
                        """,
                        (f"{type(e).__name__}: {str(e)[:500]}", source_video_id)
                    )
                logger.info(f"Attempted to set source {source_video_id} state to 'splicing_failed'.")
            except Exception as db_err:
                logger.error(f"Failed to update error state in DB after rollback: {db_err}")
            finally: # Ensure connection is released even if error update fails
                release_db_connection(conn, environment) # New
        raise

    finally:
        if conn and not conn.closed: # Ensure conn is not None and not closed before trying to release
            release_db_connection(conn, environment) # New
            logger.debug(f"DB connection released for source_video_id: {source_video_id}")
        if temp_dir_obj:
            try:
                temp_dir_obj.cleanup()
                logger.info(f"Cleaned up temporary directory: {temp_dir}")
            except Exception as cleanup_err:
                 logger.warning(f"Error cleaning up temporary directory {temp_dir}: {cleanup_err}")