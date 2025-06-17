"""
Refactored Intake Task - "Dumber" Python focused on media processing only.

This version:
- Receives explicit S3 paths and parameters from Elixir
- Focuses only on media processing (download, re-encode, upload)
- Returns structured data instead of managing database state
- No database connections or state management
"""

import argparse
import json
import logging
import os
import shutil
import subprocess
import tempfile
import threading
from datetime import datetime
from pathlib import Path

import boto3
import yt_dlp
from botocore.exceptions import ClientError, NoCredentialsError

# --- Logging Configuration ---
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

# --- Task Configuration ---
FINAL_SUFFIX = "_qt"
FFMPEG_ARGS = [
    "-map", "0", "-c:v:0", "libx264", "-preset", "fast", "-crf", "20",
    "-pix_fmt", "yuv420p", "-c:a:0", "aac", "-b:a", "192k", "-c:s", "mov_text",
    "-c:d", "copy", "-c:v:1", "copy", "-movflags", "+faststart"
]

class S3TransferProgress:
    """Callback for boto3 reporting progress via logger"""
    
    def __init__(self, total_size, filename, logger_instance, throttle_percentage=5):
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

def run_intake(
    source_video_id: int, 
    input_source: str, 
    output_s3_prefix: str,
    re_encode_for_qt: bool = True,
    **kwargs
):
    """
    Intake a source video: downloads/copies, re-encodes, uploads to S3.
    Returns structured data about the processed video instead of managing database state.
    
    Args:
        source_video_id: The ID of the source video (for reference only)
        input_source: URL or local file path to the video
        output_s3_prefix: S3 prefix where to upload the processed video
        re_encode_for_qt: Re-encode for QuickTime compatibility
        **kwargs: Additional options
    
    Returns:
        dict: Structured data about the processed video including S3 path and metadata
    """
    logger.info(f"RUNNING INTAKE for source_video_id: {source_video_id}")
    logger.info(f"Input: '{input_source}', Output prefix: '{output_s3_prefix}'")

    # Get S3 resources from environment (provided by Elixir)
    s3_bucket_name = os.getenv("S3_BUCKET_NAME")
    if not s3_bucket_name:
        raise ValueError("S3_BUCKET_NAME environment variable not set")

    try:
        s3_client = boto3.client("s3")
    except NoCredentialsError:
        logger.error("S3 credentials not found")
        raise

    is_url = input_source.lower().startswith(("http://", "https://"))
    
    # Check dependencies
    if re_encode_for_qt and not shutil.which("ffmpeg"):
        raise FileNotFoundError("ffmpeg not found in PATH")

    with tempfile.TemporaryDirectory() as temp_dir:
        temp_dir_path = Path(temp_dir)
        
        try:
            # Step 1: Download/acquire the video
            if is_url:
                initial_video_path = download_from_url(input_source, temp_dir_path)
            else:
                # For local files, copy to temp directory
                initial_video_path = temp_dir_path / Path(input_source).name
                shutil.copy2(input_source, initial_video_path)

            # Step 2: Extract metadata before re-encoding
            metadata = extract_video_metadata(initial_video_path)
            
            # Step 3: Re-encode if requested
            if re_encode_for_qt:
                final_video_path = re_encode_video(initial_video_path, temp_dir_path)
            else:
                final_video_path = initial_video_path

            # Step 4: Upload to S3
            s3_key = f"{output_s3_prefix}/{final_video_path.name}"
            upload_to_s3(s3_client, s3_bucket_name, final_video_path, s3_key)
            
            # Return structured data for Elixir to process
            return {
                "status": "success",
                "filepath": s3_key,
                "duration_seconds": metadata.get("duration_seconds"),
                "fps": metadata.get("fps"),
                "width": metadata.get("width"),
                "height": metadata.get("height"),
                "metadata": {
                    "original_filename": Path(input_source).name if not is_url else None,
                    "re_encoded": re_encode_for_qt,
                    "processing_timestamp": datetime.utcnow().isoformat()
                }
            }

        except Exception as e:
            logger.error(f"Error processing video: {e}")
            raise

def download_from_url(url: str, temp_dir: Path) -> Path:
    """Download video from URL using yt-dlp"""
    output_template = str(temp_dir / "%(title)s.%(ext)s")
    
    ydl_opts = {
        'outtmpl': output_template,
        'format': 'best[ext=mp4]/best',
        'logger': YtdlpLogger()
    }

    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(url, download=True)
        filename = ydl.prepare_filename(info)
        
    return Path(filename)

def extract_video_metadata(video_path: Path) -> dict:
    """Extract video metadata using ffprobe"""
    try:
        cmd = [
            "ffprobe", "-v", "quiet", "-print_format", "json", "-show_format", "-show_streams",
            str(video_path)
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        data = json.loads(result.stdout)
        
        # Find video stream
        video_stream = next((s for s in data["streams"] if s["codec_type"] == "video"), None)
        
        if not video_stream:
            return {}
            
        return {
            "duration_seconds": float(data["format"].get("duration", 0)),
            "fps": eval(video_stream.get("r_frame_rate", "0/1")),  # Convert fraction to float
            "width": video_stream.get("width"),
            "height": video_stream.get("height")
        }
    except Exception as e:
        logger.warning(f"Failed to extract metadata: {e}")
        return {}

def re_encode_video(input_path: Path, temp_dir: Path) -> Path:
    """Re-encode video for QuickTime compatibility"""
    output_path = temp_dir / f"{input_path.stem}{FINAL_SUFFIX}.mp4"
    
    cmd = ["ffmpeg", "-i", str(input_path)] + FFMPEG_ARGS + [str(output_path)]
    
    logger.info(f"Re-encoding video: {' '.join(cmd)}")
    result = subprocess.run(cmd, capture_output=True, text=True)
    
    if result.returncode != 0:
        raise RuntimeError(f"FFmpeg failed: {result.stderr}")
    
    return output_path

def upload_to_s3(s3_client, bucket_name: str, file_path: Path, s3_key: str):
    """Upload file to S3 with progress reporting"""
    file_size = file_path.stat().st_size
    progress_callback = S3TransferProgress(file_size, file_path.name, logger)
    
    try:
        s3_client.upload_file(
            str(file_path), 
            bucket_name, 
            s3_key,
            Callback=progress_callback
        )
        logger.info(f"Successfully uploaded {file_path.name} to s3://{bucket_name}/{s3_key}")
    except ClientError as e:
        logger.error(f"Failed to upload to S3: {e}")
        raise

class YtdlpLogger:
    """Logger adapter for yt-dlp"""
    def debug(self, msg):
        logger.debug(f"yt-dlp: {msg}")
    
    def info(self, msg):
        logger.info(f"yt-dlp: {msg}")
    
    def warning(self, msg):
        logger.warning(f"yt-dlp: {msg}")
    
    def error(self, msg):
        logger.error(f"yt-dlp: {msg}")

def main():
    """Main entry point for standalone execution"""
    parser = argparse.ArgumentParser(description="Intake video processing task")
    parser.add_argument("--source-video-id", type=int, required=True)
    parser.add_argument("--input-source", required=True)
    parser.add_argument("--output-s3-prefix", required=True)
    parser.add_argument("--re-encode-for-qt", action="store_true", default=True)
    
    args = parser.parse_args()
    
    try:
        result = run_intake(
            args.source_video_id,
            args.input_source,
            args.output_s3_prefix,
            args.re_encode_for_qt
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