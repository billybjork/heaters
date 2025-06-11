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
import psycopg2
from psycopg2 import sql
from psycopg2 import extras
import sys
import logging
import json
import argparse

# --- Local Imports ---
try:
    from .utils.db import get_db_connection
    from .utils.process_utils import run_ffmpeg_command
except ImportError:
    project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
    if project_root not in sys.path:
        sys.path.insert(0, project_root)
    from py_tasks.utils.db import get_db_connection
    from py_tasks.utils.process_utils import run_ffmpeg_command

# --- Logging Configuration ---
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# --- Task Configuration ---
CLIP_S3_PREFIX = "clips/"
SCENE_DETECT_THRESHOLD = float(os.getenv("SCENE_DETECT_THRESHOLD", 0.6))
_hist_methods_map = { "CORREL": cv2.HISTCMP_CORREL, "CHISQR": cv2.HISTCMP_CHISQR, "INTERSECT": cv2.HISTCMP_INTERSECT, "BHATTACHARYYA": cv2.HISTCMP_BHATTACHARYYA }
_hist_method_str = os.getenv("SCENE_DETECT_METHOD", "CORREL").upper()
SCENE_DETECT_METHOD = _hist_methods_map.get(_hist_method_str, cv2.HISTCMP_CORREL)
if _hist_method_str not in _hist_methods_map:
    logger.warning(f"Invalid SCENE_DETECT_METHOD '{_hist_method_str}'. Defaulting to CORREL.")

MIN_CLIP_DURATION_SECONDS = float(os.getenv("MIN_CLIP_DURATION_SECONDS", 1.0))
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


# --- OpenCV Scene Detection Functions ---
def calculate_histogram(frame, bins=256, ranges=[0, 256]):
    """Calculates and normalizes the BGR histogram for a frame."""
    b, g, r = cv2.split(frame)
    hist_b = cv2.calcHist([b], [0], None, [bins], ranges)
    hist_g = cv2.calcHist([g], [0], None, [bins], ranges)
    hist_r = cv2.calcHist([r], [0], None, [bins], ranges)
    hist = np.concatenate((hist_b, hist_g, hist_r))
    cv2.normalize(hist, hist)
    return hist

def detect_scenes(video_path: str, threshold: float, hist_method: int):
    """Detects scene cuts in a video file using histogram comparison."""
    logger.info(f"Opening video for scene detection: {video_path}")
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise IOError(f"Could not open video file: {video_path}")

    fps = cap.get(cv2.CAP_PROP_FPS)
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))

    if not fps or fps <= 0 or not total_frames or total_frames <= 0:
        raise ValueError(f"Invalid video properties: FPS={fps}, Frames={total_frames}")

    logger.info(f"Video Info: {width}x{height}, {fps:.2f} FPS, {total_frames} Frames")

    prev_hist = None
    cut_frames = [0]
    frame_number = 0
    
    while True:
        ret, frame = cap.read()
        if not ret:
            break

        current_hist = calculate_histogram(frame)
        if prev_hist is not None:
            score = cv2.compareHist(prev_hist, current_hist, hist_method)
            is_cut = (score < threshold) if hist_method in [cv2.HISTCMP_CORREL, cv2.HISTCMP_INTERSECT] else (score > threshold)
            
            if is_cut and frame_number > cut_frames[-1]:
                cut_frames.append(frame_number)
                logger.debug(f"Scene cut detected at frame {frame_number} (Score: {score:.4f})")

        prev_hist = current_hist
        frame_number += 1
    
    if total_frames > 0 and cut_frames[-1] < total_frames:
        cut_frames.append(total_frames)

    cap.release()
    
    scenes = [(cut_frames[i], cut_frames[i+1]) for i in range(len(cut_frames) - 1) if cut_frames[i] < cut_frames[i+1]]
    logger.info(f"Detected {len(scenes)} potential scenes.")
    return scenes, fps, (width, height), total_frames


# --- Main Splice Task ---
def run_splice(source_video_id: int, environment: str, **kwargs):
    """
    Downloads source video, detects scenes, splices, uploads clips, and creates records.
    """
    logger.info(f"RUNNING SPLICE for source_video_id: {source_video_id}, Env: {environment}")

    s3_bucket_name = os.getenv("S3_BUCKET_NAME")
    if not s3_bucket_name:
        raise ValueError("S3_BUCKET_NAME environment variable not set.")
    
    try:
        s3_client = boto3.client("s3")
    except NoCredentialsError:
        logger.error("S3 credentials not found.")
        raise

    temp_dir_obj = None
    created_clip_ids = []

    try:
        with get_db_connection() as conn, conn.cursor(cursor_factory=psycopg2.extras.DictCursor) as cur:
            cur.execute("SELECT pg_advisory_xact_lock(4, %s)", (source_video_id,))
            logger.info(f"Acquired DB lock for source_video_id: {source_video_id}")

            cur.execute(
                "SELECT filepath, title, ingest_state FROM source_videos WHERE id = %s",
                (source_video_id,)
            )
            source_rec = cur.fetchone()
            if not source_rec or not source_rec['filepath']:
                raise ValueError(f"Source video {source_video_id} not found or has no filepath.")

            if source_rec['ingest_state'] not in ['downloaded', 'splicing_failed']:
                return {"status": "skipped_state", "source_video_id": source_video_id, "reason": f"State '{source_rec['ingest_state']}' not eligible."}

            cur.execute("UPDATE source_videos SET ingest_state = 'splicing' WHERE id = %s", (source_video_id,))
            conn.commit()
            logger.info(f"Set source_video {source_video_id} state to 'splicing'")

        temp_dir_obj = tempfile.TemporaryDirectory(prefix="splice_")
        temp_dir = temp_dir_obj.name
        
        source_s3_key = source_rec['filepath']
        local_video_path = os.path.join(temp_dir, os.path.basename(source_s3_key))
        logger.info(f"Downloading s3://{s3_bucket_name}/{source_s3_key} to {local_video_path}")
        s3_client.download_file(s3_bucket_name, source_s3_key, local_video_path)

        scenes, fps, _, _ = detect_scenes(local_video_path, SCENE_DETECT_THRESHOLD, SCENE_DETECT_METHOD)

        for i, (start_frame, end_frame) in enumerate(scenes):
            start_time = start_frame / fps
            end_time = end_frame / fps
            duration = end_time - start_time

            if duration < MIN_CLIP_DURATION_SECONDS:
                logger.info(f"Skipping short scene {i+1} ({duration:.2f}s).")
                continue

            clip_identifier = f"source_{source_video_id}_scene_{i+1}"
            safe_title = sanitize_filename(f"{source_rec['title']}_scene_{i+1}")
            output_filename = f"{safe_title}.mp4"
            output_path = os.path.join(temp_dir, output_filename)

            ffmpeg_cmd = [
                "ffmpeg", "-i", local_video_path,
                "-ss", str(start_time), "-to", str(end_time),
                "-c:v", "libx264", "-preset", FFMPEG_PRESET, "-crf", FFMPEG_CRF,
                "-c:a", "aac", "-b:a", FFMPEG_AUDIO_BITRATE,
                "-y", output_path
            ]
            run_ffmpeg_command(ffmpeg_cmd, f"Splicing scene {i+1}")
            
            clip_s3_key = f"{CLIP_S3_PREFIX}{output_filename}"
            s3_client.upload_file(output_path, s3_bucket_name, clip_s3_key)
            logger.info(f"Uploaded clip to s3://{s3_bucket_name}/{clip_s3_key}")
            
            with get_db_connection() as conn, conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO clips (source_video_id, clip_identifier, clip_filepath, start_time_seconds, end_time_seconds, duration_seconds)
                    VALUES (%s, %s, %s, %s, %s, %s) RETURNING id
                    """,
                    (source_video_id, clip_identifier, clip_s3_key, start_time, end_time, duration)
                )
                new_clip_id = cur.fetchone()[0]
                created_clip_ids.append(new_clip_id)
                conn.commit()
                logger.info(f"Created clip record with ID: {new_clip_id}")

        with get_db_connection() as conn, conn.cursor() as cur:
            cur.execute("UPDATE source_videos SET ingest_state = 'spliced' WHERE id = %s", (source_video_id,))
            conn.commit()
            logger.info(f"Set source_video {source_video_id} state to 'spliced'")

        return {
            "status": "success",
            "source_video_id": source_video_id,
            "created_clips": len(created_clip_ids),
            "clip_ids": created_clip_ids
        }

    except Exception as e:
        logger.error(f"FATAL: Splicing failed for source_video_id {source_video_id}: {e}", exc_info=True)
        try:
            with get_db_connection() as conn, conn.cursor() as cur:
                cur.execute(
                    "UPDATE source_videos SET ingest_state = 'splicing_failed', last_error = %s WHERE id = %s",
                    (str(e), source_video_id)
                )
                conn.commit()
        except Exception as db_err:
            logger.error(f"CRITICAL: Failed to update DB state to 'splicing_failed' for {source_video_id}: {db_err}")
        raise

    finally:
        if temp_dir_obj:
            temp_dir_obj.cleanup()
            logger.info("Cleaned up temporary directory.")


# --- Direct invocation for testing ---
if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Run video splicing for a source video.")
    parser.add_argument("--source-id", required=True, type=int, help="The source_video_id from the database.")
    parser.add_argument("--env", default="development", help="The environment.")
    
    args = parser.parse_args()

    try:
        result = run_splice(
            source_video_id=args.source_id,
            environment=args.env
        )
        print("Splicing finished successfully.")
        print(json.dumps(result, indent=2))
        sys.exit(0)
    except Exception as e:
        print(f"Splicing failed: {e}", file=sys.stderr)
        sys.exit(1)