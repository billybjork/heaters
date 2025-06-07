import os
import shutil
import subprocess
import tempfile
from pathlib import Path
import re
import sys
import json
import logging
import argparse

import psycopg2
from psycopg2 import sql, extras
import boto3
from botocore.exceptions import NoCredentialsError, ClientError

# --- Local Imports ---
try:
    from .utils.db import get_db_connection
    from .utils.process_utils import run_ffmpeg_command, run_ffprobe_command
except ImportError:
    project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
    if project_root not in sys.path:
        sys.path.insert(0, project_root)
    from py_tasks.utils.db import get_db_connection
    from py_tasks.utils.process_utils import run_ffmpeg_command, run_ffprobe_command

# --- Logging Configuration ---
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# --- Task Configuration ---
CLIP_S3_PREFIX = "clips/"
MIN_CLIP_DURATION_SECONDS = float(os.getenv("MIN_CLIP_DURATION_SECONDS_SPLIT", 0.5))
ARTIFACT_TYPE_SPRITE_SHEET = "sprite_sheet"
ARTIFACT_TYPE_KEYFRAME = "keyframe"

def sanitize_filename(name):
    """Sanitizes a string to be a valid filename."""
    if not name: return "default_filename"
    name = str(name)
    name = re.sub(r'[^\w\.\-]+', '_', name)
    name = re.sub(r'_+', '_', name).strip('_')
    return name[:150]

def _delete_s3_artifacts(s3_client, bucket_name, artifact_keys):
    """Deletes a list of artifacts from S3."""
    if not artifact_keys:
        return
    logger.info(f"Deleting {len(artifact_keys)} associated S3 artifacts.")
    keys_to_delete = [{'Key': key} for key in artifact_keys]
    try:
        response = s3_client.delete_objects(
            Bucket=bucket_name,
            Delete={'Objects': keys_to_delete, 'Quiet': True}
        )
        if 'Errors' in response and response['Errors']:
            for error in response['Errors']:
                logger.error(f"Failed to delete S3 object {error['Key']}: {error['Message']}")
    except ClientError as e:
        logger.error(f"An S3 error occurred during artifact deletion: {e}", exc_info=True)

def run_split(clip_id: int, split_at_frame: int, environment: str, **kwargs):
    """
    Splits a single clip into two at a specific frame.
    """
    logger.info(f"RUNNING SPLIT for clip_id: {clip_id}, split_at_frame: {split_at_frame}, Env: {environment}")

    s3_bucket_name = os.getenv("S3_BUCKET_NAME")
    if not s3_bucket_name:
        raise ValueError("S3_BUCKET_NAME environment variable not set.")

    try:
        s3_client = boto3.client("s3")
    except NoCredentialsError:
        logger.error("S3 credentials not found.")
        raise

    temp_dir_obj = None
    new_clip_ids = []
    error_message = None

    try:
        with get_db_connection(cursor_factory=extras.DictCursor) as conn:
            # Phase 1: Lock, validate, and set state
            with conn.cursor() as cur:
                conn.autocommit = False # Use transactions
                cur.execute("SELECT pg_advisory_xact_lock(2, %s)", (clip_id,))
                logger.info(f"Acquired DB lock for clip_id: {clip_id}")

                cur.execute(
                    """
                    SELECT
                        c.clip_filepath, c.clip_identifier, c.start_time_seconds, c.end_time_seconds,
                        c.source_video_id, c.ingest_state, c.start_frame, c.end_frame,
                        sv.filepath AS source_video_filepath,
                        sv.title AS source_title,
                        sv.fps AS source_video_fps
                    FROM clips c
                    JOIN source_videos sv ON c.source_video_id = sv.id
                    WHERE c.id = %s FOR UPDATE OF c;
                    """,
                    (clip_id,)
                )
                original_clip_data = cur.fetchone()
                if not original_clip_data:
                    raise ValueError(f"Original clip {clip_id} not found.")

                current_state = original_clip_data['ingest_state']
                if current_state not in ['keyframed', 'embedded', 'split_failed', 'spliced']: # Valid previous states
                    return {"status": "skipped_state", "clip_id": clip_id, "reason": f"Clip state '{current_state}' not eligible for splitting."}
                
                if not original_clip_data['source_video_filepath']:
                    raise ValueError(f"Source video filepath missing for clip {clip_id}.")

                # Frame validation
                clip_start_frame = original_clip_data['start_frame']
                clip_end_frame = original_clip_data['end_frame']
                if not (clip_start_frame < split_at_frame < clip_end_frame):
                    raise ValueError(f"Split frame {split_at_frame} is outside the clip's frame range ({clip_start_frame}-{clip_end_frame}).")

                cur.execute("UPDATE clips SET ingest_state = 'splitting', last_error = NULL WHERE id = %s", (clip_id,))
                conn.commit()
                logger.info(f"Set clip {clip_id} state to 'splitting'")

            # Phase 2: Main processing (downloads, ffmpeg, uploads)
            temp_dir_obj = tempfile.TemporaryDirectory(prefix=f"split_{clip_id}_")
            temp_dir = Path(temp_dir_obj.name)
            
            source_s3_key = original_clip_data['source_video_filepath']
            local_source_path = temp_dir / Path(source_s3_key).name
            logger.info(f"Downloading source video s3://{s3_bucket_name}/{source_s3_key} to {local_source_path}")
            s3_client.download_file(s3_bucket_name, source_s3_key, str(local_source_path))

            # Determine FPS - prefer source video FPS, but ffprobe original clip if needed.
            clip_fps = original_clip_data.get('source_video_fps')
            if not clip_fps or clip_fps <= 0:
                logger.warning("Source video FPS not available, probing original clip.")
                original_clip_s3_path = original_clip_data['clip_filepath']
                local_clip_path = temp_dir / Path(original_clip_s3_path).name
                s3_client.download_file(s3_bucket_name, original_clip_s3_path, str(local_clip_path))
                
                ffprobe_cmd = [
                    "ffprobe", "-v", "error", "-select_streams", "v:0",
                    "-show_entries", "stream=r_frame_rate", "-of", "default=noprint_wrappers=1:nokey=1",
                    str(local_clip_path)
                ]
                stdout, _ = run_ffprobe_command(ffprobe_cmd, "FFprobe for FPS")
                num, den = map(int, stdout.strip().split('/'))
                clip_fps = num / den if den > 0 else 30.0
            
            logger.info(f"Using FPS: {clip_fps:.3f}")

            # Calculate times
            original_start_time = original_clip_data['start_time_seconds']
            # The split *frame* is relative to the SOURCE video, so we can calculate time directly.
            split_time_abs = split_at_frame / clip_fps

            ffmpeg_base_opts = [
                "-map", "0:v:0?", "-map", "0:a:0?",
                "-c:v", "libx264", "-preset", "medium", "-crf", "23",
                "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k",
                "-movflags", "+faststart", "-y"
            ]
            
            source_video_id = original_clip_data['source_video_id']
            sanitized_source_title = sanitize_filename(original_clip_data['source_title'])

            # --- Clip A ---
            start_a_time = original_start_time
            end_a_time = split_time_abs
            duration_a = end_a_time - start_a_time

            if duration_a >= MIN_CLIP_DURATION_SECONDS:
                start_f_a = original_clip_data['start_frame']
                end_f_a = split_at_frame - 1
                id_a = f"{sanitized_source_title}_{start_f_a}_{end_f_a}"
                fn_a = f"{id_a}.mp4"
                output_path_a = temp_dir / fn_a
                
                cmd_a = ["ffmpeg", "-i", str(local_source_path), "-ss", str(start_a_time), "-to", str(end_a_time)] + ffmpeg_base_opts + [str(output_path_a)]
                run_ffmpeg_command(cmd_a, "Splitting Clip A")
                
                s3_key_a = f"{CLIP_S3_PREFIX}{fn_a}"
                s3_client.upload_file(str(output_path_a), s3_bucket_name, s3_key_a)
                logger.info(f"Uploaded Clip A to s3://{s3_bucket_name}/{s3_key_a}")
                
                with conn.cursor() as cur:
                    cur.execute(
                        """
                        INSERT INTO clips (source_video_id, clip_identifier, clip_filepath, start_time_seconds, end_time_seconds, duration_seconds, start_frame, end_frame, ingest_state)
                        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, 'spliced') RETURNING id;
                        """,
                        (source_video_id, id_a, s3_key_a, start_a_time, end_a_time, duration_a, start_f_a, end_f_a)
                    )
                    new_clip_ids.append(cur.fetchone()[0])

            # --- Clip B ---
            start_b_time = split_time_abs
            end_b_time = original_clip_data['end_time_seconds']
            duration_b = end_b_time - start_b_time

            if duration_b >= MIN_CLIP_DURATION_SECONDS:
                start_f_b = split_at_frame
                end_f_b = original_clip_data['end_frame']
                id_b = f"{sanitized_source_title}_{start_f_b}_{end_f_b}"
                fn_b = f"{id_b}.mp4"
                output_path_b = temp_dir / fn_b

                cmd_b = ["ffmpeg", "-i", str(local_source_path), "-ss", str(start_b_time), "-to", str(end_b_time)] + ffmpeg_base_opts + [str(output_path_b)]
                run_ffmpeg_command(cmd_b, "Splitting Clip B")
                
                s3_key_b = f"{CLIP_S3_PREFIX}{fn_b}"
                s3_client.upload_file(str(output_path_b), s3_bucket_name, s3_key_b)
                logger.info(f"Uploaded Clip B to s3://{s3_bucket_name}/{s3_key_b}")
                
                with conn.cursor() as cur:
                    cur.execute(
                        """
                        INSERT INTO clips (source_video_id, clip_identifier, clip_filepath, start_time_seconds, end_time_seconds, duration_seconds, start_frame, end_frame, ingest_state)
                        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, 'spliced') RETURNING id;
                        """,
                        (source_video_id, id_b, s3_key_b, start_b_time, end_b_time, duration_b, start_f_b, end_f_b)
                    )
                    new_clip_ids.append(cur.fetchone()[0])
            
            # Phase 3: Finalize, archive old clip, and clean up artifacts
            with conn.cursor() as cur:
                # Get artifacts to delete
                cur.execute(
                    "SELECT s3_key FROM clip_artifacts WHERE clip_id = %s",
                    (clip_id,)
                )
                artifacts_to_delete = [row[0] for row in cur.fetchall()]
                
                # Delete artifact records from DB
                cur.execute("DELETE FROM clip_artifacts WHERE clip_id = %s", (clip_id,))
                logger.info(f"Deleted {len(artifacts_to_delete)} artifact records from DB for original clip {clip_id}")

                # Archive original clip
                cur.execute("UPDATE clips SET ingest_state = 'split_complete', updated_at = NOW() WHERE id = %s", (clip_id,))
                logger.info(f"Set original clip {clip_id} state to 'split_complete'")
                conn.commit()

            # Now delete from S3
            _delete_s3_artifacts(s3_client, s3_bucket_name, artifacts_to_delete)
            # Also delete the original clip video file from S3
            _delete_s3_artifacts(s3_client, s3_bucket_name, [original_clip_data['clip_filepath']])

        return {
            "status": "success",
            "original_clip_id": clip_id,
            "created_clip_ids": new_clip_ids
        }

    except Exception as e:
        logger.error(f"FATAL: Splitting failed for clip_id {clip_id}: {e}", exc_info=True)
        error_message = str(e)
        try:
            with get_db_connection() as conn:
                cur = conn.cursor()
                cur.execute(
                    "UPDATE clips SET ingest_state = 'split_failed', error_message = %s, updated_at = NOW() WHERE id = %s",
                    (error_message, clip_id)
                )
                conn.commit()
                cur.close()
        except Exception as db_err:
            logger.error(f"CRITICAL: Failed to update DB state to 'split_failed' for {clip_id}: {db_err}")
        raise
    finally:
        if temp_dir_obj:
            temp_dir_obj.cleanup()
            logger.info("Cleaned up temporary directory.")

# --- Direct invocation for testing ---
if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Split a clip at a specific frame.")
    parser.add_argument("--clip-id", required=True, type=int, help="The ID of the clip to split.")
    parser.add_argument("--split-at-frame", required=True, type=int, help="The frame number (relative to the source video) to split at.")
    parser.add_argument("--env", default="development", help="The environment.")
    
    args = parser.parse_args()

    try:
        result = run_split(
            clip_id=args.clip_id,
            split_at_frame=args.split_at_frame,
            environment=args.env
        )
        print("Splitting finished successfully.")
        print(json.dumps(result, indent=2))
        sys.exit(0)
    except Exception as e:
        print(f"Splitting failed: {e}", file=sys.stderr)
        sys.exit(1)