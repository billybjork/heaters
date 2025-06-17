"""
Refactored Merge Task - "Dumber" Python focused on video concatenation only.

This version:
- Receives explicit S3 paths to the two clips to merge from Elixir
- Focuses only on video concatenation using FFmpeg
- Returns structured data about the merged clip instead of managing database state
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
from botocore.exceptions import ClientError, NoCredentialsError

# --- Logging Configuration ---
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

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

def merge_videos(
    target_video_path: str,
    source_video_path: str,
    output_path: Path,
    output_identifier: str
) -> dict:
    """
    Merges two video files using FFmpeg concat filter.
    Returns metadata about the merged video.
    """
    # Create concat list file for FFmpeg
    concat_list_path = output_path.parent / "concat_list.txt"
    
    with open(concat_list_path, "w", encoding='utf-8') as f:
        f.write(f"file '{Path(target_video_path).resolve().as_posix()}'\n")
        f.write(f"file '{Path(source_video_path).resolve().as_posix()}'\n")
    
    # Generate output filename
    output_filename = f"{output_identifier}.mp4"
    final_output_path = output_path / output_filename
    
    # Run FFmpeg concat
    ffmpeg_cmd = [
        "-f", "concat", "-safe", "0", "-i", str(concat_list_path),
        "-c", "copy",  # Stream copy for faster processing
        "-y", str(final_output_path)
    ]
    
    run_ffmpeg_command(ffmpeg_cmd, "Merging videos")
    
    if not final_output_path.exists():
        raise RuntimeError("Video merge failed - output file not created")
    
    # Get file size
    file_size = final_output_path.stat().st_size
    
    logger.info(f"Successfully merged videos: {output_filename} ({file_size} bytes)")
    
    return {
        "local_path": str(final_output_path),
        "filename": output_filename,
        "file_size": file_size
    }

def run_merge(
    target_clip_id: int,
    source_clip_id: int,
    target_s3_path: str,
    source_s3_path: str,
    output_s3_prefix: str,
    merge_metadata: dict,
    **kwargs
):
    """
    Downloads two clip videos, merges them, and uploads the result to S3.
    Returns structured data about the merged clip instead of managing database state.
    
    Args:
        target_clip_id: The ID of the target clip (for reference only)
        source_clip_id: The ID of the source clip (for reference only)
        target_s3_path: S3 path to the target clip video file
        source_s3_path: S3 path to the source clip video file
        output_s3_prefix: S3 prefix where to upload merged video
        merge_metadata: Metadata about the merge (frames, times, identifier)
        **kwargs: Additional options
    
    Returns:
        dict: Structured data about the merged clip including S3 path and metadata
    """
    logger.info(f"RUNNING MERGE: Target clip {target_clip_id} + Source clip {source_clip_id}")
    logger.info(f"Target: {target_s3_path}, Source: {source_s3_path}")
    logger.info(f"Output prefix: {output_s3_prefix}")
    
    if target_clip_id == source_clip_id:
        raise ValueError("Cannot merge a clip with itself")
    
    # Extract merge metadata
    new_identifier = merge_metadata.get("new_identifier", f"merged_{target_clip_id}_{source_clip_id}")
    
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
            # Step 1: Download both clip videos from S3
            target_local_path = temp_dir_path / f"target_{Path(target_s3_path).name}"
            source_local_path = temp_dir_path / f"source_{Path(source_s3_path).name}"
            
            logger.info(f"Downloading target clip: s3://{s3_bucket_name}/{target_s3_path}")
            s3_client.download_file(s3_bucket_name, target_s3_path, str(target_local_path))
            
            logger.info(f"Downloading source clip: s3://{s3_bucket_name}/{source_s3_path}")
            s3_client.download_file(s3_bucket_name, source_s3_path, str(source_local_path))

            # Step 2: Merge the videos
            merge_result = merge_videos(
                str(target_local_path),
                str(source_local_path),
                temp_dir_path,
                new_identifier
            )

            # Step 3: Upload merged video to S3
            s3_key = f"{output_s3_prefix}/{merge_result['filename']}"
            local_path = merge_result['local_path']
            file_size = merge_result['file_size']
            
            progress_callback = S3TransferProgress(file_size, merge_result['filename'], logger)
            
            logger.info(f"Uploading merged video: s3://{s3_bucket_name}/{s3_key}")
            s3_client.upload_file(
                local_path,
                s3_bucket_name,
                s3_key,
                Callback=progress_callback
            )

            # Return structured data for Elixir to process
            return {
                "status": "success",
                "merged_clip": {
                    "s3_key": s3_key,
                    "file_size": file_size,
                    "filename": merge_result['filename']
                },
                "metadata": {
                    "target_clip_id": target_clip_id,
                    "source_clip_id": source_clip_id,
                    "new_identifier": new_identifier,
                    **merge_metadata
                }
            }

        except Exception as e:
            logger.error(f"Error processing merge: {e}")
            raise

def main():
    """Main entry point for standalone execution"""
    parser = argparse.ArgumentParser(description="Video merge task")
    parser.add_argument("--target-clip-id", type=int, required=True)
    parser.add_argument("--source-clip-id", type=int, required=True)
    parser.add_argument("--target-s3-path", required=True)
    parser.add_argument("--source-s3-path", required=True)
    parser.add_argument("--output-s3-prefix", required=True)
    parser.add_argument("--new-identifier", required=True)
    
    args = parser.parse_args()
    
    merge_metadata = {
        "new_identifier": args.new_identifier
    }
    
    try:
        result = run_merge(
            args.target_clip_id,
            args.source_clip_id,
            args.target_s3_path,
            args.source_s3_path,
            args.output_s3_prefix,
            merge_metadata
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