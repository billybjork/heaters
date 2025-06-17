"""
Refactored Split Task - "Dumber" Python focused on video splitting only.

This version:
- Receives explicit S3 paths and split parameters from Elixir
- Focuses only on video splitting using FFmpeg
- Returns structured data about the split clips instead of managing database state
- No database connections or state management
"""

import argparse
import json
import logging
import math
import os
import re
import shutil
import subprocess
import tempfile
import threading
from pathlib import Path

import boto3
from botocore.exceptions import ClientError, NoCredentialsError

# --- Logging Configuration ---
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

# --- Task Configuration ---
MIN_CLIP_DURATION_SECONDS = 0.5

class S3TransferProgress:
    """Callback for boto3 reporting progress via logger"""
    
    def __init__(self, total_size, filename, logger_instance, throttle_percentage=25):
        self._filename = filename
        self._total_size = total_size
        self._seen_so_far = 0
        self._lock = threading.Lock()
        self._logger = logger_instance
        self._throttle_percentage = max(1, min(int(throttle_percentage), 100))
        self._last_logged_percentage = -1

    def __call__(self, bytes_amount):
        try:
            with self._lock:
                self._seen_so_far += bytes_amount
                current_percentage = 0
                if self._total_size > 0:
                    current_percentage = int((self._seen_so_far / self._total_size) * 100)
                
                should_log = (
                    current_percentage >= self._last_logged_percentage + self._throttle_percentage
                    and current_percentage < 100
                ) or (current_percentage == 100 and self._last_logged_percentage != 100)

                if should_log:
                    size_mb = self._seen_so_far / (1024 * 1024)
                    total_size_mb = self._total_size / (1024 * 1024)
                    self._logger.info(
                        f"S3 Upload: {self._filename} - {current_percentage}% complete "
                        f"({size_mb:.2f}/{total_size_mb:.2f} MiB)"
                    )
                    self._last_logged_percentage = current_percentage
        except Exception as e:
            self._logger.error(f"S3 Progress error: {e}")

def sanitize_filename(name):
    """Sanitizes a string to be a valid filename."""
    if not name:
        return "default_filename"
    name = str(name)
    name = re.sub(r'[^\w\.\-]+', '_', name)
    name = re.sub(r'_+', '_', name).strip('_')
    return name[:150]

def run_ffmpeg_command(cmd_args, description="FFmpeg command"):
    """Runs an FFmpeg command with proper error handling."""
    cmd = ["ffmpeg"] + cmd_args
    logger.info(f"{description}: {' '.join(cmd)}")
    
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        logger.error(f"FFmpeg command failed: {result.stderr}")
        raise RuntimeError(f"FFmpeg failed: {result.stderr}")
    
    return result

def run_ffprobe_command(cmd_args, description="FFprobe command"):
    """Runs an FFprobe command with proper error handling."""
    cmd = ["ffprobe"] + cmd_args
    logger.info(f"{description}: {' '.join(cmd)}")
    
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        logger.error(f"FFprobe command failed: {result.stderr}")
        raise RuntimeError(f"FFprobe failed: {result.stderr}")
    
    return result.stdout, result.stderr

def get_video_fps(video_path: str) -> float:
    """Gets the FPS of a video file using ffprobe."""
    ffprobe_cmd = [
        "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=r_frame_rate", 
        "-of", "default=noprint_wrappers=1:nokey=1",
        str(video_path)
    ]
    
    stdout, _ = run_ffprobe_command(ffprobe_cmd, "FFprobe for FPS")
    
    try:
        num, den = map(int, stdout.strip().split('/'))
        fps = num / den if den > 0 else 30.0
        logger.info(f"Detected video FPS: {fps:.3f}")
        return fps
    except (ValueError, ZeroDivisionError) as e:
        logger.warning(f"Could not parse FPS from '{stdout}', defaulting to 30.0: {e}")
        return 30.0

def split_video(
    source_video_path: str,
    output_dir: Path,
    split_params: dict,
    source_video_id: int
) -> list:
    """
    Splits a video file at the specified frame.
    Returns metadata about the created clips.
    """
    # Extract split parameters
    split_at_frame = split_params["split_at_frame"]
    original_start_time = split_params["original_start_time"]
    original_end_time = split_params["original_end_time"]
    original_start_frame = split_params["original_start_frame"]
    original_end_frame = split_params["original_end_frame"]
    source_title = split_params.get("source_title", f"source_{source_video_id}")
    fps = split_params.get("fps")
    
    # Get FPS if not provided
    if not fps or fps <= 0:
        fps = get_video_fps(source_video_path)
    
    logger.info(f"Splitting video at frame {split_at_frame} (FPS: {fps:.3f})")
    
    # Validate split frame is within clip bounds
    if not (original_start_frame < split_at_frame < original_end_frame):
        raise ValueError(f"Split frame {split_at_frame} is outside clip range ({original_start_frame}-{original_end_frame})")
    
    # Calculate split time
    split_time_abs = split_at_frame / fps
    
    # FFmpeg base options for encoding
    ffmpeg_base_opts = [
        "-map", "0:v:0?", "-map", "0:a:0?",
        "-c:v", "libx264", "-preset", "medium", "-crf", "23",
        "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k",
        "-movflags", "+faststart", "-y"
    ]
    
    sanitized_source_title = sanitize_filename(source_title)
    created_clips = []
    
    # --- Clip A (before split) ---
    start_a_time = original_start_time
    end_a_time = split_time_abs
    duration_a = end_a_time - start_a_time
    
    if duration_a >= MIN_CLIP_DURATION_SECONDS:
        start_f_a = original_start_frame
        end_f_a = split_at_frame - 1
        id_a = f"{sanitized_source_title}_{start_f_a}_{end_f_a}"
        fn_a = f"{id_a}.mp4"
        output_path_a = output_dir / fn_a
        
        cmd_a = [
            "-i", str(source_video_path),
            "-ss", str(start_a_time),
            "-to", str(end_a_time)
        ] + ffmpeg_base_opts + [str(output_path_a)]
        
        run_ffmpeg_command(cmd_a, "Creating clip A (before split)")
        
        if output_path_a.exists():
            file_size_a = output_path_a.stat().st_size
            created_clips.append({
                "clip_identifier": id_a,
                "filename": fn_a,
                "local_path": str(output_path_a),
                "start_time_seconds": start_a_time,
                "end_time_seconds": end_a_time,
                "start_frame": start_f_a,
                "end_frame": end_f_a,
                "duration_seconds": duration_a,
                "file_size": file_size_a
            })
            logger.info(f"Created clip A: {fn_a} ({duration_a:.2f}s)")
    else:
        logger.info(f"Skipping clip A - too short ({duration_a:.2f}s)")
    
    # --- Clip B (after split) ---
    start_b_time = split_time_abs
    end_b_time = original_end_time
    duration_b = end_b_time - start_b_time
    
    if duration_b >= MIN_CLIP_DURATION_SECONDS:
        start_f_b = split_at_frame
        end_f_b = original_end_frame
        id_b = f"{sanitized_source_title}_{start_f_b}_{end_f_b}"
        fn_b = f"{id_b}.mp4"
        output_path_b = output_dir / fn_b
        
        cmd_b = [
            "-i", str(source_video_path),
            "-ss", str(start_b_time),
            "-to", str(end_b_time)
        ] + ffmpeg_base_opts + [str(output_path_b)]
        
        run_ffmpeg_command(cmd_b, "Creating clip B (after split)")
        
        if output_path_b.exists():
            file_size_b = output_path_b.stat().st_size
            created_clips.append({
                "clip_identifier": id_b,
                "filename": fn_b,
                "local_path": str(output_path_b),
                "start_time_seconds": start_b_time,
                "end_time_seconds": end_b_time,
                "start_frame": start_f_b,
                "end_frame": end_f_b,
                "duration_seconds": duration_b,
                "file_size": file_size_b
            })
            logger.info(f"Created clip B: {fn_b} ({duration_b:.2f}s)")
    else:
        logger.info(f"Skipping clip B - too short ({duration_b:.2f}s)")
    
    if not created_clips:
        raise ValueError("Split operation did not create any valid clips")
    
    return created_clips

def run_split(
    clip_id: int,
    source_video_s3_path: str,
    output_s3_prefix: str,
    split_params: dict,
    **kwargs
):
    """
    Downloads source video, splits it at specified frame, and uploads clips to S3.
    Returns structured data about the split clips instead of managing database state.
    
    Args:
        clip_id: The ID of the original clip (for reference only)
        source_video_s3_path: S3 path to the source video file
        output_s3_prefix: S3 prefix where to upload split clips
        split_params: Split parameters including frame, times, and metadata
        **kwargs: Additional options
    
    Returns:
        dict: Structured data about the split clips including S3 paths and metadata
    """
    logger.info(f"RUNNING SPLIT for clip_id: {clip_id}")
    logger.info(f"Source video: {source_video_s3_path}")
    logger.info(f"Split at frame: {split_params.get('split_at_frame')}")
    logger.info(f"Output prefix: {output_s3_prefix}")
    
    # Get S3 resources from environment (provided by Elixir)
    s3_bucket_name = os.getenv("S3_BUCKET_NAME")
    if not s3_bucket_name:
        raise ValueError("S3_BUCKET_NAME environment variable not set")

    try:
        s3_client = boto3.client("s3")
    except NoCredentialsError:
        logger.error("S3 credentials not found")
        raise

    # Check dependencies
    if not shutil.which("ffmpeg"):
        raise FileNotFoundError("ffmpeg not found in PATH")
    if not shutil.which("ffprobe"):
        raise FileNotFoundError("ffprobe not found in PATH")

    with tempfile.TemporaryDirectory() as temp_dir:
        temp_dir_path = Path(temp_dir)
        
        try:
            # Step 1: Download source video from S3
            local_video_path = temp_dir_path / Path(source_video_s3_path).name
            logger.info(f"Downloading source video: s3://{s3_bucket_name}/{source_video_s3_path}")
            s3_client.download_file(s3_bucket_name, source_video_s3_path, str(local_video_path))

            # Step 2: Split the video
            source_video_id = split_params.get("source_video_id", clip_id)
            created_clips = split_video(
                str(local_video_path),
                temp_dir_path,
                split_params,
                source_video_id
            )

            # Step 3: Upload split clips to S3
            uploaded_clips = []
            for clip_data in created_clips:
                s3_key = f"{output_s3_prefix}/{clip_data['filename']}"
                local_path = clip_data['local_path']
                file_size = clip_data['file_size']
                
                progress_callback = S3TransferProgress(file_size, clip_data['filename'], logger)
                
                logger.info(f"Uploading {clip_data['filename']}: s3://{s3_bucket_name}/{s3_key}")
                s3_client.upload_file(
                    local_path,
                    s3_bucket_name,
                    s3_key,
                    Callback=progress_callback
                )
                
                # Add S3 info to clip data
                uploaded_clip = {
                    **clip_data,
                    "s3_key": s3_key
                }
                uploaded_clips.append(uploaded_clip)

            # Return structured data for Elixir to process
            return {
                "status": "success",
                "original_clip_id": clip_id,
                "created_clips": uploaded_clips,
                "metadata": {
                    "split_at_frame": split_params["split_at_frame"],
                    "clips_created": len(uploaded_clips),
                    "total_duration": sum(clip["duration_seconds"] for clip in uploaded_clips)
                }
            }

        except Exception as e:
            logger.error(f"Error processing split: {e}")
            raise

def main():
    """Main entry point for standalone execution"""
    parser = argparse.ArgumentParser(description="Video split task")
    parser.add_argument("--clip-id", type=int, required=True)
    parser.add_argument("--source-video-s3-path", required=True)
    parser.add_argument("--output-s3-prefix", required=True)
    parser.add_argument("--split-at-frame", type=int, required=True)
    parser.add_argument("--original-start-time", type=float, required=True)
    parser.add_argument("--original-end-time", type=float, required=True)
    parser.add_argument("--original-start-frame", type=int, required=True)
    parser.add_argument("--original-end-frame", type=int, required=True)
    parser.add_argument("--source-title", default="")
    parser.add_argument("--fps", type=float, default=0)
    
    args = parser.parse_args()
    
    split_params = {
        "split_at_frame": args.split_at_frame,
        "original_start_time": args.original_start_time,
        "original_end_time": args.original_end_time,
        "original_start_frame": args.original_start_frame,
        "original_end_frame": args.original_end_frame,
        "source_title": args.source_title,
        "fps": args.fps,
        "source_video_id": args.clip_id
    }
    
    try:
        result = run_split(
            args.clip_id,
            args.source_video_s3_path,
            args.output_s3_prefix,
            split_params
        )
        print(json.dumps(result, indent=2))
    except Exception as e:
        error_result = {
            "status": "error",
            "error": str(e),
            "error_type": type(e).__name__
        }
        print(json.dumps(error_result, indent=2))
        exit(1)

if __name__ == "__main__":
    main() 