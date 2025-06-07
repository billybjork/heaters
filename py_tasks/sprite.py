import os
import sys
import re
import subprocess
import tempfile
from pathlib import Path
import shutil
import json
import math
import logging
import argparse

import psycopg2
from psycopg2 import sql, extras
import boto3
from botocore.exceptions import ClientError, NoCredentialsError

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

def sanitize_filename(name):
    """Sanitizes a string to be a valid filename."""
    if not name: return "default_filename"
    name = str(name)
    name = re.sub(r'[^\w\.\-]+', '_', name)
    name = re.sub(r'_+', '_', name).strip('_')
    return name[:150]

# --- Constants ---
SPRITE_SHEET_S3_PREFIX = os.getenv("SPRITE_SHEET_S3_PREFIX", "clip_artifacts/sprite_sheets/")
SPRITE_TILE_WIDTH = int(os.getenv("SPRITE_TILE_WIDTH", 480))
SPRITE_TILE_HEIGHT = int(os.getenv("SPRITE_TILE_HEIGHT", -1)) # -1 preserves aspect ratio
SPRITE_FPS = int(os.getenv("SPRITE_FPS", 1)) # Generate 1 frame per second of video
SPRITE_COLS = int(os.getenv("SPRITE_COLS", 5))
ARTIFACT_TYPE_SPRITE_SHEET = "sprite_sheet"


def run_sprite_sheet(clip_id: int, overwrite: bool, environment: str, **kwargs):
    """
    Generates a sprite sheet for a given clip, uploads it to S3,
    and records it as an artifact in the database.
    """
    logger.info(f"RUNNING SPRITE SHEET for clip_id: {clip_id}, Overwrite: {overwrite}, Env: {environment}")

    s3_bucket_name = os.getenv("S3_BUCKET_NAME")
    if not s3_bucket_name:
        raise ValueError("S3_BUCKET_NAME environment variable not set.")

    try:
        s3_client = boto3.client("s3")
    except NoCredentialsError:
        logger.error("S3 credentials not found.")
        raise
    
    temp_dir_obj = None
    error_message = None

    try:
        with get_db_connection(cursor_factory=extras.DictCursor) as conn:
            # --- Phase 1: DB Check, Lock, and State Update ---
            with conn.cursor() as cur:
                conn.autocommit = False
                cur.execute("SELECT pg_advisory_xact_lock(3, %s)", (clip_id,))
                logger.info(f"Acquired DB lock for clip {clip_id}")

                cur.execute(
                    """
                    SELECT
                        c.clip_filepath, c.clip_identifier, c.ingest_state,
                        sv.title AS source_title
                    FROM clips c
                    JOIN source_videos sv ON c.source_video_id = sv.id
                    WHERE c.id = %s FOR UPDATE;
                    """, (clip_id,)
                )
                clip_data = cur.fetchone()

                if not clip_data:
                    raise ValueError(f"Clip {clip_id} not found.")
                
                if not clip_data['clip_filepath']:
                    raise ValueError(f"Clip {clip_id} is missing a filepath.")

                current_state = clip_data['ingest_state']
                logger.info(f"Clip {clip_id} current state: '{current_state}'")

                # Idempotency and state check
                eligible_states = ['spliced', 'keyframed', 'embedded', 'sprite_failed']
                if current_state not in eligible_states and not (overwrite and current_state == 'complete'):
                    return {"status": "skipped_state", "clip_id": clip_id, "reason": f"State '{current_state}' not eligible."}

                if overwrite:
                    cur.execute("DELETE FROM clip_artifacts WHERE clip_id = %s AND artifact_type = %s", (clip_id, ARTIFACT_TYPE_SPRITE_SHEET))
                    logger.info(f"Overwrite enabled: Deleted {cur.rowcount} existing sprite sheet artifacts for clip {clip_id}.")

                cur.execute("UPDATE clips SET ingest_state = 'generating_sprite', updated_at = NOW() WHERE id = %s", (clip_id,))
                conn.commit()
                logger.info(f"Set clip {clip_id} state to 'generating_sprite'")

            # --- Phase 2: Processing ---
            temp_dir_obj = tempfile.TemporaryDirectory(prefix=f"sprite_{clip_id}_")
            temp_dir = Path(temp_dir_obj.name)
            
            clip_s3_key = clip_data['clip_filepath']
            local_clip_path = temp_dir / Path(clip_s3_key).name
            logger.info(f"Downloading clip s3://{s3_bucket_name}/{clip_s3_key} to {local_clip_path}")
            s3_client.download_file(s3_bucket_name, clip_s3_key, str(local_clip_path))

            # Probe for duration
            ffprobe_cmd = ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", str(local_clip_path)]
            stdout, _ = run_ffprobe_command(ffprobe_cmd, "FFprobe for duration")
            duration = float(stdout.strip())

            total_frames = math.ceil(duration * SPRITE_FPS)
            rows = math.ceil(total_frames / SPRITE_COLS)

            # Generate sprite sheet
            base_filename = sanitize_filename(f"{clip_data['source_title']}_{clip_data['clip_identifier']}_sprite")
            output_filename = f"{base_filename}.jpg"
            output_path = temp_dir / output_filename
            
            vf_option = f"fps={SPRITE_FPS},scale={SPRITE_TILE_WIDTH}:{SPRITE_TILE_HEIGHT},tile={SPRITE_COLS}x{rows}"
            ffmpeg_cmd = ["ffmpeg", "-i", str(local_clip_path), "-vf", vf_option, "-an", "-vsync", "vfr", str(output_path)]
            run_ffmpeg_command(ffmpeg_cmd, "Generate sprite sheet")
            
            if not output_path.exists() or output_path.stat().st_size == 0:
                raise RuntimeError("ffmpeg failed to generate a non-empty sprite sheet.")
            
            logger.info(f"Generated sprite sheet: {output_path}")

            # --- Phase 3: Upload and DB Record ---
            sprite_s3_key = f"{SPRITE_SHEET_S3_PREFIX}{clip_id}/{output_filename}"
            s3_client.upload_file(str(output_path), s3_bucket_name, sprite_s3_key)
            logger.info(f"Uploaded sprite sheet to s3://{s3_bucket_name}/{sprite_s3_key}")

            with conn.cursor() as cur:
                metadata = {
                    "tile_width": SPRITE_TILE_WIDTH,
                    "tile_height": SPRITE_TILE_HEIGHT,
                    "sprite_fps": SPRITE_FPS,
                    "columns": SPRITE_COLS,
                    "rows": rows,
                    "total_frames": total_frames,
                    "video_duration": duration
                }
                cur.execute(
                    """
                    INSERT INTO clip_artifacts (clip_id, artifact_type, s3_key, strategy, metadata)
                    VALUES (%s, %s, %s, %s, %s)
                    ON CONFLICT (clip_id, artifact_type, strategy) DO UPDATE SET
                        s3_key = EXCLUDED.s3_key,
                        metadata = EXCLUDED.metadata,
                        updated_at = NOW()
                    RETURNING id;
                    """,
                    (clip_id, ARTIFACT_TYPE_SPRITE_SHEET, sprite_s3_key, "default", json.dumps(metadata))
                )
                artifact_id = cur.fetchone()[0]
                logger.info(f"Created clip artifact record with ID: {artifact_id}")

                cur.execute("UPDATE clips SET ingest_state = 'complete', updated_at = NOW() WHERE id = %s", (clip_id,))
                conn.commit()
                logger.info(f"Set clip {clip_id} state to 'complete'")

        return {
            "status": "success",
            "clip_id": clip_id,
            "artifact_id": artifact_id,
            "s3_key": sprite_s3_key
        }

    except Exception as e:
        logger.error(f"FATAL: Sprite sheet generation failed for clip_id {clip_id}: {e}", exc_info=True)
        error_message = str(e)
        try:
            with get_db_connection() as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        "UPDATE clips SET ingest_state = 'sprite_failed', error_message = %s, updated_at = NOW() WHERE id = %s",
                        (error_message, clip_id)
                    )
                    conn.commit()
        except Exception as db_err:
            logger.error(f"CRITICAL: Failed to update DB state to 'sprite_failed' for {clip_id}: {db_err}")
        
        raise
    
    finally:
        if temp_dir_obj:
            temp_dir_obj.cleanup()
            logger.info("Cleaned up temporary directory.")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Generate a sprite sheet for a single clip.")
    parser.add_argument("--clip-id", required=True, type=int, help="The clip_id from the database.")
    parser.add_argument("--env", default="development", help="The environment.")
    parser.add_argument("--overwrite", action="store_true", help="Overwrite existing sprite sheet for this clip.")
    
    args = parser.parse_args()

    try:
        result = run_sprite_sheet(
            clip_id=args.clip_id,
            overwrite=args.overwrite,
            environment=args.env
        )
        print("Sprite sheet generation finished successfully.")
        print(json.dumps(result, indent=2))
        sys.exit(0)
    except Exception as e:
        print(f"Sprite sheet generation failed: {e}", file=sys.stderr)
        sys.exit(1)