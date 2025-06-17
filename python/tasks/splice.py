"""
Refactored Splice Task - "Dumber" Python focused on video processing only.

This version:
- Receives explicit S3 paths and detection parameters from Elixir
- Focuses only on scene detection and video splitting
- Returns structured data about clips instead of managing database state
- No database connections or state management
"""

import argparse
import json
import logging
import os
import re
import shutil
import subprocess
import tempfile
import threading
from pathlib import Path

import boto3
import cv2
import numpy as np
from botocore.exceptions import ClientError, NoCredentialsError

# --- Logging Configuration ---
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

# --- Task Configuration ---
MIN_CLIP_DURATION_SECONDS = 1.0
FFMPEG_CRF = "23"
FFMPEG_PRESET = "medium"
FFMPEG_AUDIO_BITRATE = "128k"

# Histogram comparison methods
HIST_METHODS_MAP = {
    "CORREL": cv2.HISTCMP_CORREL,
    "CHISQR": cv2.HISTCMP_CHISQR,
    "INTERSECT": cv2.HISTCMP_INTERSECT,
    "BHATTACHARYYA": cv2.HISTCMP_BHATTACHARYYA
}

class S3TransferProgress:
    """Callback for boto3 reporting progress via logger"""
    
    def __init__(self, total_size, filename, logger_instance, throttle_percentage=10):
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
    """Removes potentially problematic characters for filenames and S3 keys."""
    if not name:
        return "untitled"
    name = str(name)
    name = re.sub(r'[^\w\s\-.]', '', name)
    name = re.sub(r'\s+', '_', name).strip('_')
    return name[:150] if name else "sanitized_untitled"

def calculate_histogram(frame, bins=256, ranges=[0, 256]):
    """Calculates and normalizes the BGR histogram for a frame."""
    b, g, r = cv2.split(frame)
    hist_b = cv2.calcHist([b], [0], None, [bins], ranges)
    hist_g = cv2.calcHist([g], [0], None, [bins], ranges)
    hist_r = cv2.calcHist([r], [0], None, [bins], ranges)
    hist = np.concatenate((hist_b, hist_g, hist_r))
    cv2.normalize(hist, hist)
    return hist

def detect_scenes(video_path: str, threshold: float, method_name: str = "CORREL"):
    """Detects scene cuts in a video file using histogram comparison."""
    logger.info(f"Opening video for scene detection: {video_path}")
    
    # Get histogram comparison method
    hist_method = HIST_METHODS_MAP.get(method_name.upper(), cv2.HISTCMP_CORREL)
    
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise IOError(f"Could not open video file: {video_path}")

    fps = cap.get(cv2.CAP_PROP_FPS)
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))

    if not fps or fps <= 0 or not total_frames or total_frames <= 0:
        cap.release()
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

def run_ffmpeg_command(cmd_args, description="FFmpeg command"):
    """Runs an FFmpeg command with proper error handling."""
    cmd = ["ffmpeg"] + cmd_args
    logger.info(f"{description}: {' '.join(cmd)}")
    
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        logger.error(f"FFmpeg command failed: {result.stderr}")
        raise RuntimeError(f"FFmpeg failed: {result.stderr}")
    
    return result

def run_splice(
    source_video_id: int,
    input_s3_path: str,
    output_s3_prefix: str,
    detection_params: dict,
    **kwargs
):
    """
    Downloads source video, detects scenes, splices into clips, and uploads to S3.
    Returns structured data about the created clips instead of managing database state.
    
    Args:
        source_video_id: The ID of the source video (for reference only)
        input_s3_path: S3 path to the source video file
        output_s3_prefix: S3 prefix where to upload clip files
        detection_params: Scene detection parameters (threshold, method, etc.)
        **kwargs: Additional options
    
    Returns:
        dict: Structured data about the created clips including S3 paths and timing info
    """
    logger.info(f"RUNNING SPLICE for source_video_id: {source_video_id}")
    logger.info(f"Input: {input_s3_path}, Output prefix: {output_s3_prefix}")
    
    # Extract detection parameters
    threshold = detection_params.get("threshold", 0.6)
    method = detection_params.get("method", "CORREL")
    min_duration = detection_params.get("min_duration_seconds", MIN_CLIP_DURATION_SECONDS)
    
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

    with tempfile.TemporaryDirectory() as temp_dir:
        temp_dir_path = Path(temp_dir)
        
        try:
            # Step 1: Download source video from S3
            local_video_path = temp_dir_path / Path(input_s3_path).name
            logger.info(f"Downloading s3://{s3_bucket_name}/{input_s3_path} to {local_video_path}")
            s3_client.download_file(s3_bucket_name, input_s3_path, str(local_video_path))

            # Step 2: Detect scenes
            scenes, fps, (width, height), total_frames = detect_scenes(str(local_video_path), threshold, method)
            
            if not scenes:
                logger.warning("No scenes detected, creating single clip from entire video")
                scenes = [(0, total_frames)]

            # Step 3: Process each scene into a clip
            clips_data = []
            for i, (start_frame, end_frame) in enumerate(scenes):
                start_time = start_frame / fps
                end_time = end_frame / fps
                duration = end_time - start_time

                if duration < min_duration:
                    logger.info(f"Skipping short scene {i+1} ({duration:.2f}s)")
                    continue

                # Generate clip filename and identifier
                clip_identifier = f"{source_video_id}_clip_{i+1:03d}"
                output_filename = f"{clip_identifier}.mp4"
                output_path = temp_dir_path / output_filename

                # Extract clip using FFmpeg
                ffmpeg_args = [
                    "-i", str(local_video_path),
                    "-ss", str(start_time),
                    "-to", str(end_time),
                    "-c:v", "libx264",
                    "-preset", FFMPEG_PRESET,
                    "-crf", FFMPEG_CRF,
                    "-c:a", "aac",
                    "-b:a", FFMPEG_AUDIO_BITRATE,
                    "-y", str(output_path)
                ]
                
                run_ffmpeg_command(ffmpeg_args, f"Extracting clip {i+1}")
                
                # Upload to S3
                s3_key = f"{output_s3_prefix}/{output_filename}"
                file_size = output_path.stat().st_size
                progress_callback = S3TransferProgress(file_size, output_filename, logger)
                
                s3_client.upload_file(
                    str(output_path), 
                    s3_bucket_name, 
                    s3_key,
                    Callback=progress_callback
                )
                logger.info(f"Uploaded clip to s3://{s3_bucket_name}/{s3_key}")

                # Add clip data for Elixir to process
                clips_data.append({
                    "clip_identifier": clip_identifier,
                    "clip_filepath": s3_key,
                    "start_frame": start_frame,
                    "end_frame": end_frame,
                    "start_time_seconds": round(start_time, 3),
                    "end_time_seconds": round(end_time, 3),
                    "metadata": {
                        "duration_seconds": round(duration, 3),
                        "scene_index": i + 1,
                        "fps": fps,
                        "resolution": f"{width}x{height}",
                        "detection_threshold": threshold,
                        "detection_method": method
                    }
                })

            # Return structured data for Elixir to process
            return {
                "status": "success",
                "clips": clips_data,
                "metadata": {
                    "total_scenes_detected": len(scenes),
                    "clips_created": len(clips_data),
                    "detection_params": detection_params,
                    "video_properties": {
                        "fps": fps,
                        "resolution": f"{width}x{height}",
                        "total_frames": total_frames
                    }
                }
            }

        except Exception as e:
            logger.error(f"Error processing video: {e}")
            raise

def main():
    """Main entry point for standalone execution"""
    parser = argparse.ArgumentParser(description="Splice video processing task")
    parser.add_argument("--source-video-id", type=int, required=True)
    parser.add_argument("--input-s3-path", required=True)
    parser.add_argument("--output-s3-prefix", required=True)
    parser.add_argument("--threshold", type=float, default=0.6)
    parser.add_argument("--method", default="CORREL")
    parser.add_argument("--min-duration", type=float, default=1.0)
    
    args = parser.parse_args()
    
    detection_params = {
        "threshold": args.threshold,
        "method": args.method,
        "min_duration_seconds": args.min_duration
    }
    
    try:
        result = run_splice(
            args.source_video_id,
            args.input_s3_path,
            args.output_s3_prefix,
            detection_params
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