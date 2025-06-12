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
from datetime import datetime

import psycopg2
from psycopg2 import sql, extras
import boto3
from botocore.exceptions import ClientError, NoCredentialsError

# --- Local Imports ---
try:
    from python.utils.db import get_db_connection
    from python.utils.process_utils import run_ffmpeg_command, run_ffprobe_command
except ImportError:
    project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
    if project_root not in sys.path:
        sys.path.insert(0, project_root)
    from python.utils.db import get_db_connection
    from python.utils.process_utils import run_ffmpeg_command, run_ffprobe_command

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
SPRITE_FPS = int(os.getenv("SPRITE_FPS", 24)) # Use video's native FPS for sprite generation
SPRITE_COLS = int(os.getenv("SPRITE_COLS", 5))
ARTIFACT_TYPE_SPRITE_SHEET = "sprite_sheet"


def run_sprite(clip_id: int, overwrite: bool, environment: str, **kwargs):
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
                if current_state not in eligible_states and not (overwrite and current_state == 'pending_review'):
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

            # Probe for detailed video metadata
            logger.info(f"Probing downloaded clip: {local_clip_path}")
            ffprobe_cmd = [
                "-v", "error", "-select_streams", "v:0",
                "-show_entries", "stream=duration,r_frame_rate,nb_frames",
                "-count_frames", "-of", "json", str(local_clip_path)
            ]
            stdout, _ = run_ffprobe_command(ffprobe_cmd, "FFprobe for detailed metadata")
            
            try:
                probe_data_list = json.loads(stdout).get('streams', [])
                if not probe_data_list:
                    raise ValueError(f"ffprobe found no video streams in {local_clip_path}")
                probe_data = probe_data_list[0]
                logger.debug(f"ffprobe result for clip {clip_id}: {probe_data}")

                # Extract duration
                duration_str = probe_data.get('duration')
                if duration_str:
                    duration = float(duration_str)
                else:
                    raise ValueError("Could not determine video duration")

                # Extract frame rate
                fps_str = probe_data.get('r_frame_rate', '0/1')
                if '/' in fps_str:
                    num_str, den_str = fps_str.split('/')
                    num, den = int(num_str), int(den_str)
                    if den > 0:
                        fps = num / den
                    else:
                        raise ValueError("Invalid frame rate denominator")
                else:
                    fps = float(fps_str)

                # Extract total frames
                nb_frames_str = probe_data.get('nb_frames')
                if nb_frames_str:
                    total_frames_in_clip = int(nb_frames_str)
                    logger.info(f"Using ffprobe nb_frames: {total_frames_in_clip}")
                else:
                    # Calculate from duration and fps
                    total_frames_in_clip = math.ceil(duration * fps)
                    logger.info(f"Calculated total frames from duration*fps: {total_frames_in_clip}")

                if duration <= 0 or fps <= 0 or total_frames_in_clip <= 0:
                    raise ValueError(f"Invalid video metadata: duration={duration:.3f}s, fps={fps:.3f}, frames={total_frames_in_clip}")
                
                logger.info(f"Clip {clip_id} metadata: Duration={duration:.3f}s, FPS={fps:.3f}, Total Frames={total_frames_in_clip}")

            except (json.JSONDecodeError, KeyError, ValueError, TypeError) as e:
                logger.error(f"Failed to parse video metadata: {e}")
                raise ValueError(f"Video metadata parsing failed: {e}")

            # Calculate sprite parameters using video's native FPS
            effective_sprite_fps = min(fps, SPRITE_FPS)  # Don't exceed video's native FPS
            num_sprite_frames = math.ceil(duration * effective_sprite_fps)
            
            if num_sprite_frames <= 0:
                logger.warning(f"Clip {clip_id} too short for sprite generation: {duration:.3f}s")
                # Still update to pending_review but without sprite
                with conn.cursor() as cur:
                    cur.execute("UPDATE clips SET ingest_state = 'pending_review', updated_at = NOW() WHERE id = %s", (clip_id,))
                    conn.commit()
                return {"status": "success_no_sprite", "clip_id": clip_id, "reason": "Video too short"}

            # Generate sprite sheet
            source_title = clip_data.get('source_title', f'source_{clip_id}')
            base_filename = sanitize_filename(f"{source_title}_{clip_data['clip_identifier']}_sprite")
            timestamp = datetime.now().strftime("%Y%m%d%H%M%S")
            output_filename = f"{base_filename}_{effective_sprite_fps}fps_w{SPRITE_TILE_WIDTH}_c{SPRITE_COLS}_{timestamp}.jpg"
            output_path = temp_dir / output_filename
            
            num_rows = max(1, math.ceil(num_sprite_frames / SPRITE_COLS))
            vf_option = f"fps={effective_sprite_fps},scale={SPRITE_TILE_WIDTH}:{SPRITE_TILE_HEIGHT}:flags=neighbor,tile={SPRITE_COLS}x{num_rows}"
            
            ffmpeg_cmd = [
                "-y", "-i", str(local_clip_path),
                "-vf", vf_option, "-an", "-qscale:v", "3",
                "-vframes", str(num_sprite_frames),
                str(output_path)
            ]
            
            logger.info(f"Generating {SPRITE_COLS}x{num_rows} sprite sheet ({num_sprite_frames} frames) for clip {clip_id}...")
            run_ffmpeg_command(ffmpeg_cmd, "Generate sprite sheet")
            
            if not output_path.exists() or output_path.stat().st_size == 0:
                raise RuntimeError("ffmpeg failed to generate a non-empty sprite sheet.")
            
            logger.info(f"Generated sprite sheet: {output_path}")

            # Probe the generated sprite to get actual tile height
            calculated_tile_height = None
            try:
                sprite_probe_cmd = [
                    "-v", "error", "-select_streams", "v:0",
                    "-show_entries", "stream=width,height", "-of", "json", str(output_path)
                ]
                sprite_stdout, _ = run_ffprobe_command(sprite_probe_cmd, "Probe sprite dimensions")
                sprite_dims_list = json.loads(sprite_stdout).get('streams', [])
                
                if sprite_dims_list:
                    sprite_dims = sprite_dims_list[0]
                    total_sprite_height = int(sprite_dims.get('height', 0))
                    if total_sprite_height > 0 and num_rows > 0:
                        calculated_tile_height = math.floor(total_sprite_height / num_rows)
                        logger.info(f"Calculated sprite tile height: {calculated_tile_height}")
                    else:
                        logger.warning("Could not calculate valid tile height from sprite probe")
                else:
                    logger.warning("No video streams found in generated sprite")
            except Exception as sprite_probe_err:
                logger.warning(f"Could not probe sprite dimensions: {sprite_probe_err}")

            # --- Phase 3: Upload and DB Record ---
            sprite_s3_key = f"{SPRITE_SHEET_S3_PREFIX}{clip_id}/{output_filename}"
            s3_client.upload_file(str(output_path), s3_bucket_name, sprite_s3_key)
            logger.info(f"Uploaded sprite sheet to s3://{s3_bucket_name}/{sprite_s3_key}")

            with conn.cursor() as cur:
                metadata = {
                    "tile_width": SPRITE_TILE_WIDTH,
                    "tile_height_calculated": calculated_tile_height,
                    "cols": SPRITE_COLS,
                    "rows": num_rows,
                    "total_sprite_frames": num_sprite_frames,
                    "clip_fps_source": round(fps, 3),
                    "clip_total_frames_source": total_frames_in_clip,
                    "sprite_fps_used": effective_sprite_fps,
                    "video_duration": duration
                }
                cur.execute(
                    """
                    INSERT INTO clip_artifacts (clip_id, artifact_type, s3_key, strategy, tag, metadata)
                    VALUES (%s, %s, %s, %s, %s, %s)
                    ON CONFLICT (clip_id, artifact_type, strategy, tag) DO UPDATE SET
                        s3_key = EXCLUDED.s3_key,
                        metadata = EXCLUDED.metadata,
                        updated_at = NOW()
                    RETURNING id;
                    """,
                    (clip_id, ARTIFACT_TYPE_SPRITE_SHEET, sprite_s3_key, "default", None, json.dumps(metadata))
                )
                artifact_id = cur.fetchone()[0]
                logger.info(f"Created clip artifact record with ID: {artifact_id}")

                cur.execute("UPDATE clips SET ingest_state = 'pending_review', updated_at = NOW() WHERE id = %s", (clip_id,))
                conn.commit()
                logger.info(f"Set clip {clip_id} state to 'pending_review'")

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
                        "UPDATE clips SET ingest_state = 'sprite_failed', last_error = %s, updated_at = NOW() WHERE id = %s",
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
        result = run_sprite(
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