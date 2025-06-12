import cv2
import os
import re
import argparse
import shutil
import tempfile
from pathlib import Path
from datetime import datetime
import logging
import json
import sys

import psycopg2
from psycopg2 import sql
from psycopg2.extras import Json, execute_values
import boto3
from botocore.exceptions import ClientError, NoCredentialsError

# --- Local Imports ---
try:
    from python.utils.db import get_db_connection
except ImportError:
    project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
    if project_root not in sys.path:
        sys.path.insert(0, project_root)
    from python.utils.db import get_db_connection

# --- Logging Configuration ---
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)


# --- Configuration ---
KEYFRAMES_S3_PREFIX = os.getenv("KEYFRAMES_S3_PREFIX", "clip_artifacts/keyframes/")
ARTIFACT_TYPE_KEYFRAME = "keyframe"

def sanitize_filename(name):
    """Removes potentially problematic characters for filenames and S3 keys."""
    name = str(name)
    name = re.sub(r'[^\w\.\-]+', '_', name)
    name = re.sub(r'_+', '_', name).strip('_')
    return name[:150] if name else "default_filename"

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
    """
    extracted_frames_data = []
    cap = None
    try:
        logger.debug(f"Opening video for frame extraction: {local_temp_video_path}")
        cap = cv2.VideoCapture(str(local_temp_video_path))
        if not cap.isOpened():
            raise IOError(f"Error opening video file: {local_temp_video_path}")

        total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
        fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
        if total_frames <= 0:
            logger.warning(f"Video has no frames: {local_temp_video_path}")
            return []

        frame_indices_to_extract = []
        if strategy == 'multi':
            indices = sorted(list({int(total_frames * p) for p in [0.25, 0.50, 0.75]}))
            frame_indices_to_extract = [(idx, f"{int(p*100)}pct") for idx, p in zip(indices, [0.25, 0.50, 0.75])]
        elif strategy == 'midpoint':
            frame_indices_to_extract.append((int(total_frames * 0.5), "mid"))
        else:
            raise ValueError(f"Unsupported keyframe strategy: {strategy}")
        
        sanitized_title = sanitize_filename(title)

        for frame_index, tag in frame_indices_to_extract:
            cap.set(cv2.CAP_PROP_POS_FRAMES, float(frame_index))
            ret, frame = cap.read()
            if ret:
                height, width = frame.shape[:2]
                timestamp_sec = frame_index / fps
                output_filename = f"{sanitized_title}_{tag}.jpg"
                output_path = os.path.join(local_temp_output_dir, output_filename)

                logger.debug(f"Saving frame {frame_index} (tag: {tag}) to {output_path}")
                if cv2.imwrite(output_path, frame, [cv2.IMWRITE_JPEG_QUALITY, 90]):
                    extracted_frames_data.append({
                        'tag': tag,
                        'local_path': output_path,
                        's3_filename': output_filename,
                        'frame_index': frame_index,
                        'timestamp_sec': round(timestamp_sec, 3),
                        'width': width,
                        'height': height
                    })
                else:
                    logger.error(f"Failed to write frame image to {output_path}")
            else:
                logger.warning(f"Could not read frame at index {frame_index}.")

    except Exception as e:
        logger.error(f"Error during frame extraction for {local_temp_video_path}: {e}", exc_info=True)
        raise
    finally:
        if cap:
            cap.release()

    return extracted_frames_data


# --- Stateless Task Function ---
def run_keyframe(
    clip_id: int,
    strategy: str,
    environment: str,
    **kwargs
    ):
    """
    Extracts keyframes, uploads them to S3, and records them in the database.
    """
    overwrite = kwargs.get('overwrite', False)
    logger.info(f"RUNNING KEYFRAME for clip_id: {clip_id}, Strategy: '{strategy}', Overwrite: {overwrite}, Env: {environment}")

    # --- Get S3 Resources from Environment ---
    s3_bucket_name = os.getenv("S3_BUCKET_NAME")
    if not s3_bucket_name:
        raise ValueError("S3_BUCKET_NAME environment variable not set.")
    
    try:
        s3_client = boto3.client("s3")
    except NoCredentialsError:
        logger.error("S3 credentials not found. Configure AWS_ACCESS_KEY_ID, etc.")
        raise

    temp_dir_obj = None
    error_message = None
    generated_artifact_s3_keys = []

    try:
        # --- DB Check and State Update ---
        with get_db_connection() as conn, conn.cursor(cursor_factory=psycopg2.extras.DictCursor) as cur:
            conn.autocommit = False
            cur.execute("SELECT pg_advisory_xact_lock(3, %s)", (clip_id,))
            logger.info(f"Acquired DB lock for clip_id: {clip_id}")
            
            cur.execute(
                """
                SELECT c.ingest_state, c.clip_filepath, c.clip_identifier, sv.title
                FROM clips c JOIN source_videos sv ON c.source_video_id = sv.id
                WHERE c.id = %s
                """, (clip_id,)
            )
            clip_rec = cur.fetchone()
            if not clip_rec: raise ValueError(f"Clip ID {clip_id} not found.")

            # Idempotency checks
            eligible_states = ['spliced', 'keyframing_failed']
            if clip_rec['ingest_state'] not in eligible_states and not (overwrite and clip_rec['ingest_state'] == 'keyframed'):
                return {"status": "skipped_state", "clip_id": clip_id, "reason": f"State '{clip_rec['ingest_state']}' not eligible."}
            
            if overwrite:
                cur.execute("DELETE FROM clip_artifacts WHERE clip_id = %s AND artifact_type = %s AND strategy = %s", (clip_id, ARTIFACT_TYPE_KEYFRAME, strategy))
                logger.info(f"Overwrite enabled: Deleted {cur.rowcount} existing keyframe artifacts for strategy '{strategy}'.")

            cur.execute("UPDATE clips SET ingest_state = 'keyframing', updated_at = NOW() WHERE id = %s", (clip_id,))
            conn.commit()
            logger.info(f"Set clip {clip_id} state to 'keyframing'")

        # --- Download and Process ---
        temp_dir_obj = tempfile.TemporaryDirectory(prefix="keyframe_")
        temp_dir = temp_dir_obj.name
        
        clip_s3_key = clip_rec['clip_filepath']
        local_video_path = os.path.join(temp_dir, os.path.basename(clip_s3_key))
        logger.info(f"Downloading clip s3://{s3_bucket_name}/{clip_s3_key} to {local_video_path}")
        s3_client.download_file(s3_bucket_name, clip_s3_key, local_video_path)
        
        extracted_frames = _extract_and_save_frames_internal(
            local_video_path,
            clip_rec['clip_identifier'],
            clip_rec['title'],
            temp_dir,
            strategy
        )

        if not extracted_frames:
            raise RuntimeError("Frame extraction failed to produce any images.")

        # --- Upload and Record Artifacts ---
        db_artifact_records = []
        for frame_data in extracted_frames:
            s3_key = f"{KEYFRAMES_S3_PREFIX}{clip_id}/{frame_data['s3_filename']}"
            logger.info(f"Uploading {frame_data['local_path']} to s3://{s3_bucket_name}/{s3_key}")
            s3_client.upload_file(frame_data['local_path'], s3_bucket_name, s3_key)
            generated_artifact_s3_keys.append(s3_key)
            
            metadata = {
                'frame_index': frame_data['frame_index'],
                'timestamp_sec': frame_data['timestamp_sec'],
                'width': frame_data['width'],
                'height': frame_data['height']
            }
            db_artifact_records.append((
                clip_id, ARTIFACT_TYPE_KEYFRAME, s3_key, strategy,
                frame_data['tag'], Json(metadata)
            ))
        
        with get_db_connection() as conn, conn.cursor() as cur:
            execute_values(cur,
                """
                INSERT INTO clip_artifacts
                (clip_id, artifact_type, s3_key, strategy, tag, metadata)
                VALUES %s
                """, db_artifact_records
            )
            logger.info(f"Inserted {len(db_artifact_records)} keyframe artifacts into DB.")
            
            cur.execute("UPDATE clips SET ingest_state = 'keyframed', keyframed_at = NOW() WHERE id = %s", (clip_id,))
            conn.commit()
            logger.info(f"Set clip {clip_id} state to 'keyframed'")

        logger.info(f"SUCCESS: Keyframe extraction finished for clip_id: {clip_id}")
        return {
            "status": "success",
            "clip_id": clip_id,
            "strategy": strategy,
            "generated_artifacts": len(generated_artifact_s3_keys),
            "artifact_keys": generated_artifact_s3_keys
        }

    except Exception as e:
        logger.error(f"FATAL: Keyframe extraction failed for clip_id {clip_id}: {e}", exc_info=True)
        error_message = str(e)
        try:
            with get_db_connection() as conn, conn.cursor() as cur:
                logger.error(f"Attempting to mark clip {clip_id} as 'keyframing_failed'")
                cur.execute(
                    "UPDATE clips SET ingest_state = 'keyframing_failed', last_error = %s, updated_at = NOW() WHERE id = %s",
                    (error_message, clip_id)
                )
                conn.commit()
        except Exception as db_fail_err:
            logger.error(f"CRITICAL: Failed to update DB state to 'keyframing_failed' for {clip_id}: {db_fail_err}", exc_info=True)
        
        raise

    finally:
        if temp_dir_obj:
            try:
                temp_dir_obj.cleanup()
                logger.info("Cleaned up temporary directory.")
            except Exception as cleanup_err:
                logger.warning(f"Failed to clean up temporary directory: {cleanup_err}")

# --- Direct invocation for testing ---
if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Run keyframe extraction for a single clip.")
    parser.add_argument("--clip-id", required=True, type=int, help="The clip_id from the database.")
    parser.add_argument("--strategy", default='midpoint', choices=['midpoint', 'multi'], help="The keyframe extraction strategy.")
    parser.add_argument("--env", default="development", help="The environment.")
    parser.add_argument("--overwrite", action="store_true", help="Overwrite existing keyframes for this strategy.")
    
    args = parser.parse_args()

    try:
        result = run_keyframe(
            clip_id=args.clip_id,
            strategy=args.strategy,
            environment=args.env,
            overwrite=args.overwrite
        )
        print("Keyframe extraction finished successfully.")
        print(json.dumps(result, indent=2))
        sys.exit(0)
    except Exception as e:
        print(f"Keyframe extraction failed: {e}", file=sys.stderr)
        sys.exit(1)