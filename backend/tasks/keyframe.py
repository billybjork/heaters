import cv2
import os
import re
import shutil
import tempfile
from pathlib import Path
from datetime import datetime

from prefect import task, get_run_logger
import psycopg2
from psycopg2 import sql
from psycopg2.extras import Json, execute_values
import boto3
from botocore.exceptions import ClientError, NoCredentialsError
import sys

project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))

if project_root not in sys.path:
    sys.path.insert(0, project_root)
try:
    from db.sync_db import get_db_connection, release_db_connection, initialize_db_pool
    from config import get_s3_resources # Import the new S3 utility function
except ImportError as e:
    print(f"Error importing DB utils or config in keyframe.py: {e}")
    def get_db_connection(environment: str, cursor_factory=None): raise NotImplementedError("DB Utils not loaded")
    def release_db_connection(conn, environment: str): pass
    def initialize_db_pool(environment: str): pass
    def get_s3_resources(environment: str, logger=None): raise NotImplementedError("S3 resource getter not loaded")

# --- Configuration ---
KEYFRAMES_S3_PREFIX = os.getenv("KEYFRAMES_S3_PREFIX", "clip_artifacts/keyframes/")
ARTIFACT_TYPE_KEYFRAME = "keyframe" # Constant for artifact type

# --- Environment Configuration ---
# APP_ENV = os.getenv("APP_ENV", "development") # Removed, task uses 'environment' param

# --- S3 Configuration ---
# AWS_REGION = os.getenv("AWS_REGION", "us-west-1") # Removed

# S3_BUCKET_NAME selection logic removed, get_s3_resources handles this
# env_log_msg_suffix logic removed

# --- Initialize S3 Client ---
# s3_client = None # Removed global client initialization
# Logic for initializing s3_client based on APP_ENV removed.
# The task will use get_s3_resources(environment, logger)

# --- Core Frame Extraction Logic ---
def _extract_and_save_frames_internal(
    local_temp_video_path: str,
    clip_identifier: str,
    title: str,
    local_temp_output_dir: str,
    strategy: str = 'midpoint'
    ) -> list[dict]:
    """
    Extracts frames based on strategy, saves them locally, and returns metadata.

    Returns:
        List of dictionaries, each containing:
        {
            'tag': str, 'local_path': str, 'frame_index': int,
            'timestamp_sec': float, 'width': int, 'height': int
        }
        Returns an empty list if extraction fails or video is invalid.
    """
    logger = get_run_logger()
    extracted_frames_data = []
    cap = None
    total_frames = 0
    try:
        logger.debug(f"Opening temp video file for frame extraction: {local_temp_video_path}")
        cap = cv2.VideoCapture(str(local_temp_video_path))
        if not cap.isOpened():
            if os.path.exists(local_temp_video_path):
                 raise IOError(f"Error opening video file (exists but cannot be opened by OpenCV): {local_temp_video_path}")
            else:
                 raise IOError(f"Error opening video file (does not exist): {local_temp_video_path}")

        total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
        fps = cap.get(cv2.CAP_PROP_FPS)

        if fps is None or fps <= 0:
             logger.warning(f"Invalid FPS ({fps}) for {local_temp_video_path}. Using default 30.0 for timestamp calculations.")
             fps = 30.0

        logger.debug(f"Temp Video properties: Total Frames={total_frames}, FPS={fps:.2f}")

        if total_frames <= 0:
            logger.warning(f"Video file has zero frames or metadata error: {local_temp_video_path}")
            return extracted_frames_data

        frame_indices_to_extract = []
        frame_tags = []
        if strategy == 'multi':
            idx_25 = max(0, min(total_frames - 1, round(total_frames * 0.25)))
            idx_50 = max(0, min(total_frames - 1, round(total_frames * 0.50)))
            idx_75 = max(0, min(total_frames - 1, round(total_frames * 0.75)))
            indices = sorted(list(set([idx_25, idx_50, idx_75])))
            frame_indices_to_extract.extend(indices)
            frame_ids_map = {}
            if idx_25 in indices: frame_ids_map[idx_25] = "25pct"
            if idx_50 in indices: frame_ids_map[idx_50] = "50pct"
            if idx_75 in indices: frame_ids_map[idx_75] = "75pct"
            frame_tags = [frame_ids_map[idx] for idx in indices]
            if len(frame_tags) == 1 and "50pct" not in frame_tags:
                 mid_idx = max(0, min(total_frames - 1, round(total_frames * 0.50)))
                 frame_indices_to_extract = [mid_idx]
                 frame_tags = ["50pct"]
                 logger.debug("Strategy 'multi' resulted in single distinct frame index, defaulting to '50pct' tag.")
        elif strategy == 'midpoint':
            mid_idx = max(0, min(total_frames - 1, round(total_frames * 0.50)))
            frame_indices_to_extract.append(mid_idx)
            frame_tags.append("mid")
        else:
             raise ValueError(f"Unsupported keyframe strategy: {strategy}")

        # Generate sanitized base filename part
        scene_part = None
        match = re.search(r'_(clip|scene)_(\d+)$', clip_identifier)
        if match:
            scene_part = f"{match.group(1)}_{match.group(2)}"
        else:
            parts = clip_identifier.split('_')
            meaningful_part = next((part for part in reversed(parts) if any(char.isdigit() for char in part)), None)
            if meaningful_part:
                 scene_part = meaningful_part
            else:
                 sanitized_clip_id = re.sub(r'[^\w\-]+', '_', clip_identifier).strip('_')
                 scene_part = sanitized_clip_id[-50:]
                 logger.warning(f"Could not parse standard suffix from '{clip_identifier}'. Using: '{scene_part}'")

        # Clean title
        sanitized_title = re.sub(r'[^\w\-\.]+', '_', title).strip('_')
        sanitized_title = re.sub(r'_+', '_', sanitized_title)
        if not sanitized_title: sanitized_title = "untitled"
        sanitized_title = sanitized_title[:100]

        frame_tag_map = dict(zip(frame_indices_to_extract, frame_tags))

        for frame_index in frame_indices_to_extract:
            cap.set(cv2.CAP_PROP_POS_FRAMES, float(frame_index))
            ret, frame = cap.read()
            if not ret:
                logger.warning(f"Initial read failed for frame index {frame_index}, retrying read...")
                ret, frame = cap.read()

            if ret:
                frame_tag = frame_tag_map[frame_index]
                height, width = frame.shape[:2]
                timestamp_sec = frame_index / fps if fps > 0 else 0.0

                output_filename_base = f"{sanitized_title}_{scene_part}_frame_{frame_tag}.jpg"
                output_path_temp_abs = os.path.join(local_temp_output_dir, output_filename_base)

                logger.debug(f"Saving frame {frame_index} (tag: {frame_tag}, time: {timestamp_sec:.2f}s) to TEMP path {output_path_temp_abs}")
                success = cv2.imwrite(output_path_temp_abs, frame, [cv2.IMWRITE_JPEG_QUALITY, 90])

                if not success:
                    logger.error(f"Failed to write frame image to TEMP path {output_path_temp_abs}")
                else:
                    extracted_frames_data.append({
                        'tag': frame_tag,
                        'local_path': output_path_temp_abs,
                        'frame_index': frame_index,
                        'timestamp_sec': round(timestamp_sec, 3),
                        'width': width,
                        'height': height
                    })
            else:
                logger.warning(f"Could not read frame at index {frame_index} (or after retry) from {local_temp_video_path}.")

    except IOError as e:
        logger.error(f"IOError processing video file {local_temp_video_path}: {e}", exc_info=True)
        extracted_frames_data = []
        raise
    except cv2.error as cv_err:
        logger.error(f"OpenCV error processing video file {local_temp_video_path}: {cv_err}", exc_info=True)
        extracted_frames_data = []
        raise RuntimeError(f"OpenCV error during frame extraction for {local_temp_video_path}") from cv_err
    except Exception as e:
        logger.error(f"An unexpected error occurred processing {local_temp_video_path}: {e}", exc_info=True)
        extracted_frames_data = []
        raise
    finally:
        if cap and cap.isOpened():
            cap.release()
            logger.debug(f"Released video capture for {local_temp_video_path}")

    if not extracted_frames_data and total_frames > 0:
        logger.error(f"CRITICAL: No frames were successfully extracted or saved for {local_temp_video_path} despite having {total_frames} frames reported.")
    elif not extracted_frames_data and total_frames <= 0:
         logger.info(f"No frames extracted as video reported {total_frames} frames.")

    return extracted_frames_data


# --- Prefect Task ---
@task(name="Extract Clip Keyframes", retries=1, retry_delay_seconds=45)
def extract_keyframes_task(
    clip_id: int,
    strategy: str = 'midpoint',
    overwrite: bool = False,
    environment: str = "development" # Added environment parameter
    ):
    """
    Extracts keyframes, uploads them to S3, and records them in the database.
    Updates clip state and `keyframed_at` timestamp.

    Args:
        clip_id (int): The ID of the clip.
        strategy (str): The keyframe extraction strategy ('midpoint', 'multi').
        overwrite (bool): Whether to overwrite existing keyframes.
        environment (str): The execution environment ("development" or "production").
    """
    logger = get_run_logger()
    logger.info(f"TASK [Keyframe]: Starting for clip_id: {clip_id}, Strategy: '{strategy}', Overwrite: {overwrite}, Env: {environment}")

    # --- Get S3 Resources using the utility function ---
    s3_client_for_task, s3_bucket_name_for_task = get_s3_resources(environment, logger=logger)
    # Error handling for missing S3 resources is now within get_s3_resources

    conn = None
    temp_dir_obj = None
    temp_dir = None
    final_status = "failed_init"
    error_message_for_db = None
    generated_artifact_s3_keys = []
    task_exception = None
    needs_processing = False
    processed_artifact_data_for_db = [] # Holds tuples for execute_values DB insert
    clip_s3_key = None
    clip_identifier = None
    title = None

    # Explicitly initialize DB pool if needed (safer in task context)
    try:
        initialize_db_pool(environment)
    except Exception as pool_err:
        logger.error(f"Failed to initialize DB pool at task start for env '{environment}': {pool_err}")
        raise RuntimeError(f"DB pool initialization failed for env '{environment}'") from pool_err

    try:
        # === Phase 1: Initial DB Check and State Update ===
        conn = get_db_connection(environment, cursor_factory=psycopg2.extras.DictCursor)
        if not conn: raise ConnectionError(f"Failed to get DB connection from pool for env '{environment}'.")
        conn.autocommit = False # Start transaction

        with conn.cursor() as cur:
            # Check for existing keyframes and state
            cur.execute(
                """SELECT c.ingest_state, c.clip_filepath, c.clip_identifier, sv.title, c.keyframed_at
                   FROM clips c JOIN source_videos sv ON c.source_video_id = sv.id
                   WHERE c.id = %s FOR UPDATE""", (clip_id,)
            )
            clip_record = cur.fetchone()
            if not clip_record: raise ValueError(f"Clip {clip_id} not found.")

            current_state = clip_record['ingest_state']
            clip_s3_key = clip_record['clip_filepath'] # S3 key of the video clip
            clip_identifier = clip_record['clip_identifier']
            title = clip_record['title'] # Source video title, or clip specific if available
            keyframed_at_db = clip_record['keyframed_at']

            logger.info(f"Clip {clip_id}: Current state '{current_state}', Keyframed at: {keyframed_at_db}")

            if not clip_s3_key:
                raise ValueError(f"Clip {clip_id} is missing clip_filepath (S3 key for video).")

            # Determine if processing is needed
            # This task is called by process_clip_post_review flow, which should set state to 'processing_post_review'
            expected_entry_state = 'processing_post_review'
            allow_processing = (current_state == expected_entry_state or
                                current_state == 'keyframe_extraction_failed') # Allow re-run on specific failure

            if keyframed_at_db and not overwrite:
                logger.info(f"Clip {clip_id} already keyframed at {keyframed_at_db} and overwrite is False. Skipping.")
                final_status = "skipped_exists"
                needs_processing = False
            elif not allow_processing:
                logger.warning(f"Clip {clip_id} state '{current_state}' is not runnable for keyframing (expected '{expected_entry_state}' or 'keyframe_extraction_failed'). Skipping.")
                final_status = "skipped_state"
                needs_processing = False
            else:
                # State is already 'processing_post_review' (set by caller) or 'keyframe_extraction_failed'
                logger.info(f"Clip {clip_id} is in expected state ('{current_state}') for keyframing. Proceeding.")
                conn.commit() # Commit to release lock if any was held by FOR UPDATE, though not strictly necessary if only reading here.
                needs_processing = True
                final_status = "processing_started" # Tentative status

        if not needs_processing:
            if conn: conn.rollback() # Rollback if we only did checks and no processing needed
            # Ensure expected_entry_state is defined for the return, even if skipping
            expected_entry_state = 'processing_post_review' # Default or ensure it's set before this point
            return {"status": final_status, "clip_id": clip_id, "s3_keys": [], "s3_bucket_used": s3_bucket_name_for_task}

        # === Main Processing (if needs_processing is True) ===
        temp_dir_obj = tempfile.TemporaryDirectory(prefix=f"keyframes_{clip_id}_")
        temp_dir = Path(temp_dir_obj.name)
        logger.info(f"Using temporary directory: {temp_dir}")

        # Download the video clip from S3
        local_temp_video_path = temp_dir / Path(clip_s3_key).name
        logger.info(f"Downloading s3://{s3_bucket_name_for_task}/{clip_s3_key} to {local_temp_video_path}")
        try:
            s3_client_for_task.download_file(s3_bucket_name_for_task, clip_s3_key, str(local_temp_video_path))
        except ClientError as e:
            task_exception = e
            error_message_for_db = f"S3 Download failed: {e.response.get('Error',{}).get('Code','UnknownError')}"
            final_status = "failed_s3_download"
            logger.error(f"{error_message_for_db} for clip {clip_s3_key}", exc_info=True)
            # Jump to finally block for cleanup and DB update
            raise # This will be caught by the outer try-except

        # Extract frames locally
        extracted_frames = _extract_and_save_frames_internal(
            str(local_temp_video_path), clip_identifier, title, str(temp_dir), strategy
        )

        if not extracted_frames:
            logger.warning(f"No frames extracted for clip {clip_id}. This might be due to video issues or strategy outcome.")
            # Decide if this is an error or an acceptable outcome (e.g., very short clip)
            # For now, treat as an error if it was expected to produce frames.
            if strategy != 'none': # Assuming 'none' is a valid strategy that extracts no frames
                task_exception = ValueError("Frame extraction returned no frames.")
                error_message_for_db = "Frame extraction failed or yielded no frames."
                final_status = "failed_extraction"
                logger.error(error_message_for_db)
                raise task_exception # Outer try-except will handle DB update
            else:
                logger.info("Strategy is 'none', so no frames extracted as expected.")
                final_status = "success_no_frames_strategy_none" # Special success state

        # If overwrite is True, delete existing keyframe artifacts from DB and S3
        if overwrite and extracted_frames: # Only delete if we have new frames to upload
            with conn.cursor() as cur:
                cur.execute("SELECT id, s3_key FROM clip_artifacts WHERE clip_id = %s AND artifact_type = %s",
                            (clip_id, ARTIFACT_TYPE_KEYFRAME))
                existing_artifacts = cur.fetchall()
                if existing_artifacts:
                    logger.info(f"Overwrite True: Found {len(existing_artifacts)} existing keyframe artifacts for clip {clip_id} to delete.")
                    s3_keys_to_delete = [{'Key': art['s3_key']} for art in existing_artifacts if art['s3_key']]
                    db_ids_to_delete = [art['id'] for art in existing_artifacts]

                    if s3_keys_to_delete:
                        logger.info(f"Deleting {len(s3_keys_to_delete)} objects from S3 bucket {s3_bucket_name_for_task}...")
                        try:
                            delete_response = s3_client_for_task.delete_objects(
                                Bucket=s3_bucket_name_for_task,
                                Delete={'Objects': s3_keys_to_delete, 'Quiet': True}
                            )
                            if delete_response.get('Errors'):
                                logger.warning(f"Errors during S3 delete_objects: {delete_response['Errors']}")
                            else:
                                logger.info("S3 delete_objects successful for existing keyframes.")
                        except ClientError as s3_del_err:
                            logger.warning(f"ClientError during S3 delete_objects for existing keyframes: {s3_del_err}. Proceeding with DB delete.")

                    if db_ids_to_delete:
                        cur.execute("DELETE FROM clip_artifacts WHERE id = ANY(%s::int[])", (db_ids_to_delete,))
                        logger.info(f"Deleted {cur.rowcount} existing keyframe artifact records from DB.")
                    conn.commit() # Commit deletions

        # Upload new frames to S3 and prepare for DB insert
        for frame_data in extracted_frames:
            frame_filename = Path(frame_data['local_path']).name
            s3_key = f"{KEYFRAMES_S3_PREFIX}{frame_filename}"
            try:
                logger.debug(f"Uploading keyframe {frame_filename} to s3://{s3_bucket_name_for_task}/{s3_key}")
                s3_client_for_task.upload_file(frame_data['local_path'], s3_bucket_name_for_task, s3_key)
                generated_artifact_s3_keys.append(s3_key)
                processed_artifact_data_for_db.append((
                    clip_id, ARTIFACT_TYPE_KEYFRAME,
                    strategy, # This is the input 'strategy' to extract_keyframes_task
                    s3_key,
                    frame_data['tag'], # This is the specific tag like 'mid', '25pct'
                    Json({
                        'width': frame_data['width'],
                        'height': frame_data['height'],
                        'frame_index': frame_data['frame_index'],
                        'timestamp_sec': frame_data['timestamp_sec']
                    })
                ))
            except ClientError as e:
                task_exception = e
                error_message_for_db = f"S3 Upload failed for {frame_filename}: {e.response.get('Error',{}).get('Code','UnknownError')}"
                final_status = "failed_s3_upload"
                logger.error(error_message_for_db, exc_info=True)
                raise # Outer try-except will handle DB update
            except Exception as e_upload:
                task_exception = e_upload
                error_message_for_db = f"Unexpected error uploading {frame_filename}: {str(e_upload)[:200]}"
                final_status = "failed_s3_upload_unexpected"
                logger.error(error_message_for_db, exc_info=True)
                raise

        # Batch insert new artifact records
        if processed_artifact_data_for_db:
            with conn.cursor() as cur:
                insert_query = """
                INSERT INTO clip_artifacts
                (clip_id, artifact_type, strategy, s3_key, tag, metadata)
                VALUES %s RETURNING id;
                """
                try:
                    # execute_values handles mapping tuples to the INSERT query
                    execute_values(cur, insert_query, processed_artifact_data_for_db, page_size=100)
                    # Fetch all returned IDs if needed, though just rowcount is often enough to confirm
                    # inserted_ids = [row[0] for row in cur.fetchall()] # If RETURNING id is used and you need the IDs
                    # if len(inserted_ids) != len(processed_artifact_data_for_db):
                    #    logger.warning(f"Number of inserted artifact IDs ({len(inserted_ids)}) does not match data supplied ({len(processed_artifact_data_for_db)}).")
                    logger.info(f"Successfully inserted {len(processed_artifact_data_for_db)} keyframe artifact records into DB.")

                except psycopg2.Error as db_insert_err:
                    task_exception = db_insert_err
                    error_message_for_db = f"Database error: {str(db_insert_err)[:200]}"
                    final_status = "failed_db_operation"
                    logger.error(f"Database error during keyframe task for clip {clip_id}: {db_insert_err}", exc_info=True)
                    if conn and not conn.closed: conn.rollback()
                finally:
                    if conn and not conn.closed: conn.commit()

                # Update clip state to success
                cur.execute("UPDATE clips SET ingest_state = %s, keyframed_at = NOW(), last_error = NULL WHERE id = %s AND ingest_state = %s",
                            ("keyframed", clip_id, expected_entry_state)) # Conditional update
                if cur.rowcount == 0:
                    logger.error(f"Failed to update clip {clip_id} to 'keyframed'. Current state might not have been '{expected_entry_state}'.")
                    # This is a critical error, implies state changed unexpectedly
                    conn.rollback()
                    final_status = "failed_db_state_mismatch"
                    error_message_for_db = f"DB state mismatch: expected '{expected_entry_state}' for final update."
                    # Raise an error to ensure it's handled by the main try/except/finally
                    raise RuntimeError(error_message_for_db)
                else:
                    conn.commit()
                    final_status = "success"
                    logger.info(f"Clip {clip_id} successfully keyframed. State set to 'keyframed'.")
        elif final_status == "processing_started": # No new artifacts but processing started
            # This case implies no frames were extracted or an issue occurred before artifact creation
            # If final_status is already failed_extraction or success_no_frames_strategy_none, it will be handled by that logic.
            logger.warning(f"No new keyframe artifacts were processed for DB insert for clip {clip_id}, but processing was initiated.")
            # If no error was explicitly raised before, but no artifacts, mark as failed extraction implicitly.
            if not task_exception:
                error_message_for_db = "No frames processed into artifacts despite starting."
                final_status = "failed_extraction_no_artifacts"
                task_exception = ValueError(error_message_for_db) # Create an exception to signify failure
                # No raise here, will be handled by finally block if task_exception is set
            conn.rollback() # Rollback if no DB changes were made for artifacts
        elif final_status == "success_no_frames_strategy_none":
            with conn.cursor() as cur: # Still need to update the clip state
                cur.execute("UPDATE clips SET ingest_state = %s, keyframed_at = NOW(), last_error = NULL WHERE id = %s",
                            ("keyframed", clip_id))
                conn.commit()
            logger.info(f"Clip {clip_id} keyframing skipped by strategy, state set to 'keyframed'.")
        else: # No artifacts and not an explicit success_no_frames case
            conn.rollback() # Rollback if no DB changes were made
            logger.info("No new keyframe artifacts to insert. No DB changes made for artifacts.")


    except (psycopg2.Error, ConnectionError) as db_err:
        task_exception = db_err
        error_message_for_db = f"Database error: {str(db_err)[:200]}"
        final_status = "failed_db_operation"
        logger.error(f"Database error during keyframe task for clip {clip_id}: {db_err}", exc_info=True)
        if conn and not conn.closed: conn.rollback()
    except ValueError as val_err: # Catch specific ValueErrors we raise (e.g. clip not found)
        task_exception = val_err
        error_message_for_db = f"ValueError: {str(val_err)[:200]}"
        final_status = "failed_validation"
        logger.error(f"Validation error for clip {clip_id}: {val_err}", exc_info=True)
        if conn and not conn.closed: conn.rollback()
    except IOError as io_err: # Catch IOErrors from _extract_and_save_frames_internal
        task_exception = io_err
        error_message_for_db = f"IOError during frame extraction: {str(io_err)[:200]}"
        final_status = "failed_io_extraction"
        logger.error(f"IOError for clip {clip_id}: {io_err}", exc_info=True)
        if conn and not conn.closed: conn.rollback()
    except RuntimeError as run_err: # Catch other RuntimeErrors (OpenCV, S3 etc)
        task_exception = run_err
        # error_message_for_db might have been set by a more specific catch block before re-raising
        if not error_message_for_db:
            error_message_for_db = f"Runtime error: {str(run_err)[:200]}"
        if final_status not in ["failed_s3_download", "failed_s3_upload", "failed_s3_upload_unexpected", "failed_extraction"]:
             final_status = "failed_runtime_unknown"
        logger.error(f"Runtime error for clip {clip_id}: {run_err}", exc_info=True)
        if conn and not conn.closed: conn.rollback()
    except Exception as e:
        task_exception = e
        error_message_for_db = f"Unexpected error: {str(e)[:200]}"
        final_status = "failed_unexpected"
        logger.error(f"Unexpected error for clip {clip_id}: {e}", exc_info=True)
        if conn and not conn.closed: conn.rollback()

    finally:
        # Update DB if an error occurred and status hasn't been successfully set
        if task_exception and final_status not in ["success", "skipped_exists", "skipped_state", "success_no_frames_strategy_none"]:
            logger.warning(f"An error occurred ({final_status}). Updating clip {clip_id} state and error message in DB for env '{environment}'.")
            error_conn = None
            # Define expected_entry_state here again for clarity in the finally block scope, 
            # or pass it down if this block were a separate function.
            expected_entry_state_for_error = 'processing_post_review' 
            try:
                error_conn = get_db_connection(environment)
                if not error_conn: raise ConnectionError(f"Failed to get DB connection for error update for env '{environment}'.")
                error_conn.autocommit = True # Simple update
                with error_conn.cursor() as err_cur:
                    # Determine the state to set on failure, typically 'keyframe_extraction_failed'
                    # Ensure we don't overwrite a state that implies later successful processing.
                    failure_db_state = 'keyframe_extraction_failed'
                    err_cur.execute(
                        """UPDATE clips SET ingest_state = %s, last_error = %s, 
                           retry_count = COALESCE(retry_count, 0) + 1
                           WHERE id = %s AND ingest_state = %s""", # Only update if it was in the active processing state
                        (failure_db_state, error_message_for_db, clip_id, expected_entry_state_for_error) 
                    )
                    logger.info(f"Updated clip {clip_id} to '{failure_db_state}' with error: {error_message_for_db}")
            except Exception as db_upd_err:
                logger.error(f"CRITICAL: Failed to update DB state on error for clip {clip_id}: {db_upd_err}", exc_info=True)
            finally:
                if error_conn:
                    release_db_connection(error_conn, environment)

        if temp_dir_obj:
            try:
                logger.debug(f"Cleaning up temporary directory: {temp_dir}")
                temp_dir_obj.cleanup()
            except Exception as cleanup_err:
                logger.warning(f"Error cleaning up temp directory {temp_dir}: {cleanup_err}")
        if conn and not conn.closed:
            release_db_connection(conn, environment)

    logger.info(f"TASK [Keyframe] for clip_id {clip_id} finished. Status: {final_status}, S3 Keys: {len(generated_artifact_s3_keys)}, Bucket: {s3_bucket_name_for_task}")
    return {
        "status": final_status,
        "clip_id": clip_id,
        "s3_keys": generated_artifact_s3_keys,
        "strategy_used": strategy,
        "s3_bucket_used": s3_bucket_name_for_task
    }