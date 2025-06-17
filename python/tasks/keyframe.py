"""
Refactored Keyframe Task - "Dumber" Python focused on keyframe extraction only.

This version:
- Receives explicit S3 paths and extraction strategy from Elixir
- Focuses only on keyframe extraction and image processing
- Returns structured data about keyframe artifacts instead of managing database state
- No database connections or state management
"""

import argparse
import json
import logging
import os
import re
import tempfile
import threading
from pathlib import Path

import boto3
import cv2
from botocore.exceptions import ClientError, NoCredentialsError

# --- Logging Configuration ---
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

# --- Task Configuration ---
JPEG_QUALITY = 90

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
    """Removes potentially problematic characters for filenames and S3 keys."""
    if not name:
        return "default_filename"
    name = str(name)
    name = re.sub(r'[^\w\.\-]+', '_', name)
    name = re.sub(r'_+', '_', name).strip('_')
    return name[:150] if name else "default_filename"

def extract_keyframes(
    video_path: str,
    output_dir: Path,
    clip_identifier: str,
    strategy: str = "midpoint"
) -> list:
    """
    Extracts keyframes from a video based on the specified strategy.
    Returns metadata about extracted frames.
    """
    logger.info(f"Opening video for keyframe extraction: {video_path}")
    
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise IOError(f"Error opening video file: {video_path}")

    try:
        total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
        fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
        
        if total_frames <= 0:
            logger.warning(f"Video has no frames: {video_path}")
            return []

        # Determine frame indices to extract based on strategy
        frame_indices_to_extract = []
        
        if strategy == "multi":
            # Extract frames at 25%, 50%, and 75% of the video
            percentages = [0.25, 0.50, 0.75]
            indices = [int(total_frames * p) for p in percentages]
            tags = ["25pct", "50pct", "75pct"]
            frame_indices_to_extract = list(zip(indices, tags))
        elif strategy == "midpoint":
            # Extract single frame at 50% of the video
            frame_indices_to_extract = [(int(total_frames * 0.5), "mid")]
        else:
            raise ValueError(f"Unsupported keyframe strategy: {strategy}")
        
        logger.info(f"Extracting {len(frame_indices_to_extract)} keyframes using strategy '{strategy}'")

        extracted_frames = []
        sanitized_identifier = sanitize_filename(clip_identifier)

        for frame_index, tag in frame_indices_to_extract:
            # Seek to the frame
            cap.set(cv2.CAP_PROP_POS_FRAMES, float(frame_index))
            ret, frame = cap.read()
            
            if ret:
                height, width = frame.shape[:2]
                timestamp_sec = frame_index / fps
                output_filename = f"{sanitized_identifier}_{tag}.jpg"
                output_path = output_dir / output_filename

                logger.debug(f"Saving frame {frame_index} (tag: {tag}) to {output_path}")
                
                # Save frame as JPEG
                success = cv2.imwrite(
                    str(output_path), 
                    frame, 
                    [cv2.IMWRITE_JPEG_QUALITY, JPEG_QUALITY]
                )
                
                if success:
                    extracted_frames.append({
                        'tag': tag,
                        'local_path': str(output_path),
                        's3_filename': output_filename,
                        'frame_index': frame_index,
                        'timestamp_sec': round(timestamp_sec, 3),
                        'width': width,
                        'height': height
                    })
                    logger.debug(f"Successfully saved keyframe: {output_filename}")
                else:
                    logger.error(f"Failed to write frame image to {output_path}")
            else:
                logger.warning(f"Could not read frame at index {frame_index}")

        return extracted_frames

    finally:
        cap.release()

def run_keyframe(
    clip_id: int,
    input_s3_path: str,
    output_s3_prefix: str,
    strategy: str = "midpoint",
    **kwargs
):
    """
    Downloads clip video, extracts keyframes, and uploads to S3.
    Returns structured data about the keyframe artifacts instead of managing database state.
    
    Args:
        clip_id: The ID of the clip (for reference only)
        input_s3_path: S3 path to the clip video file
        output_s3_prefix: S3 prefix where to upload keyframe images
        strategy: Keyframe extraction strategy ('midpoint' or 'multi')
        **kwargs: Additional options
    
    Returns:
        dict: Structured data about the keyframe artifacts including S3 keys and metadata
    """
    logger.info(f"RUNNING KEYFRAME for clip_id: {clip_id}")
    logger.info(f"Input: {input_s3_path}, Output prefix: {output_s3_prefix}, Strategy: {strategy}")
    
    # Get S3 resources from environment (provided by Elixir)
    s3_bucket_name = os.getenv("S3_BUCKET_NAME")
    if not s3_bucket_name:
        raise ValueError("S3_BUCKET_NAME environment variable not set")

    try:
        s3_client = boto3.client("s3")
    except NoCredentialsError:
        logger.error("S3 credentials not found")
        raise

    with tempfile.TemporaryDirectory() as temp_dir:
        temp_dir_path = Path(temp_dir)
        
        try:
            # Step 1: Download clip video from S3
            local_video_path = temp_dir_path / Path(input_s3_path).name
            logger.info(f"Downloading s3://{s3_bucket_name}/{input_s3_path} to {local_video_path}")
            s3_client.download_file(s3_bucket_name, input_s3_path, str(local_video_path))

            # Step 2: Extract keyframes
            clip_identifier = f"clip_{clip_id}"
            extracted_frames = extract_keyframes(
                str(local_video_path),
                temp_dir_path,
                clip_identifier,
                strategy
            )

            if not extracted_frames:
                raise RuntimeError("Keyframe extraction failed to produce any images")

            # Step 3: Upload keyframes to S3 and collect artifact data
            artifacts = []
            for frame_data in extracted_frames:
                s3_key = f"{output_s3_prefix}/{frame_data['s3_filename']}"
                local_path = frame_data['local_path']
                
                # Get file size for progress reporting
                file_size = Path(local_path).stat().st_size
                progress_callback = S3TransferProgress(file_size, frame_data['s3_filename'], logger)
                
                logger.info(f"Uploading {local_path} to s3://{s3_bucket_name}/{s3_key}")
                s3_client.upload_file(
                    local_path, 
                    s3_bucket_name, 
                    s3_key,
                    Callback=progress_callback
                )
                
                # Create artifact data for Elixir to process
                artifacts.append({
                    "artifact_type": "keyframe",
                    "s3_key": s3_key,
                    "metadata": {
                        "tag": frame_data['tag'],
                        "frame_index": frame_data['frame_index'],
                        "timestamp_sec": frame_data['timestamp_sec'],
                        "width": frame_data['width'],
                        "height": frame_data['height'],
                        "strategy": strategy,
                        "file_size": file_size
                    }
                })

            # Return structured data for Elixir to process
            return {
                "status": "success",
                "artifacts": artifacts,
                "metadata": {
                    "strategy": strategy,
                    "keyframes_extracted": len(artifacts),
                    "clip_id": clip_id
                }
            }

        except Exception as e:
            logger.error(f"Error processing keyframes: {e}")
            raise

def main():
    """Main entry point for standalone execution"""
    parser = argparse.ArgumentParser(description="Keyframe extraction task")
    parser.add_argument("--clip-id", type=int, required=True)
    parser.add_argument("--input-s3-path", required=True)
    parser.add_argument("--output-s3-prefix", required=True)
    parser.add_argument("--strategy", default="midpoint", choices=["midpoint", "multi"])
    
    args = parser.parse_args()
    
    try:
        result = run_keyframe(
            args.clip_id,
            args.input_s3_path,
            args.output_s3_prefix,
            args.strategy
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