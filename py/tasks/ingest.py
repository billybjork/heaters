"""
Refactored Ingest Task - "Dumber" Python focused on media processing only.

This version:
- Receives explicit S3 paths and parameters from Elixir
- Focuses only on media processing (download, re-encode, upload)
- Returns structured data instead of managing database state
- No database connections or state management
- Now split into focused modules for better maintainability
"""

import argparse
import json
import logging
import os
import shutil
import tempfile
from datetime import datetime
from pathlib import Path

import boto3
from botocore.exceptions import ClientError, NoCredentialsError

from py.utils.filename_utils import sanitize_filename
from .media_processing import (
    validate_ffmpeg_available,
    validate_ffprobe_available,
    extract_video_metadata,
    re_encode_video
)
from .download_handler import (
    download_from_url,
    extract_download_metadata
)
from .s3_handler import upload_to_s3

# --- Logging Configuration ---
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


def run_ingest(
    source_video_id: int, 
    input_source: str, 
    output_s3_prefix: str = None,
    re_encode_for_qt: bool = True,
    **kwargs
):
    """
    Ingest a source video: downloads/copies, re-encodes, uploads to S3.
    Returns structured data about the processed video instead of managing database state.
    
    Args:
        source_video_id: The ID of the source video (for reference only)
        input_source: URL or local file path to the video
        output_s3_prefix: S3 prefix where to upload the processed video (deprecated, constructs own path)
        re_encode_for_qt: Re-encode for QuickTime compatibility
        **kwargs: Additional options
    
    Returns:
        dict: Structured data about the processed video including S3 path and metadata
    """
    logger.info(f"RUNNING INGEST for source_video_id: {source_video_id}")
    logger.info(f"Input: '{input_source}'")

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
    
    # Check dependencies - more robust validation
    if re_encode_for_qt:
        validate_ffmpeg_available()
    
    # Always validate ffprobe since we use it for metadata
    validate_ffprobe_available()

    with tempfile.TemporaryDirectory() as temp_dir:
        temp_dir_path = Path(temp_dir)
        
        try:
            # Step 1: Download/acquire the video
            if is_url:
                initial_video_path = download_from_url(input_source, temp_dir_path)
                # Extract metadata from yt-dlp info
                metadata = extract_download_metadata(input_source)
            else:
                # For local files, copy to temp directory
                initial_video_path = temp_dir_path / Path(input_source).name
                shutil.copy2(input_source, initial_video_path)
                metadata = {}

            # Step 2: Extract metadata before re-encoding
            ffprobe_metadata = extract_video_metadata(initial_video_path)
            metadata.update(ffprobe_metadata)
            
            # Step 3: Re-encode if requested
            if re_encode_for_qt:
                final_video_path = re_encode_video(initial_video_path, temp_dir_path)
            else:
                final_video_path = initial_video_path

            # Step 4: Validate final video before upload
            if not final_video_path.exists():
                raise RuntimeError(f"Final video file not found: {final_video_path}")
            
            final_file_size = final_video_path.stat().st_size
            if final_file_size == 0:
                raise RuntimeError(f"Final video file is empty: {final_video_path}")
            
            # Step 5: Upload to S3
            # Use the video title for S3 key instead of numeric prefix
            video_title = metadata.get("title", f"video_{source_video_id}")
            
            # Sanitize title for filesystem/S3 compatibility
            sanitized_title = sanitize_filename(video_title)
            
            # Generate S3 key for source video with timestamp to avoid conflicts
            timestamp = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
            s3_key = f"source_videos/{sanitized_title}_{timestamp}.mp4"
            upload_to_s3(s3_client, s3_bucket_name, final_video_path, s3_key)
            
            # Step 6: Return structured data for Elixir to process
            result = {
                "status": "success",
                "filepath": s3_key,
                "duration_seconds": metadata.get("duration_seconds"),
                "fps": metadata.get("fps"),
                "width": metadata.get("width"),
                "height": metadata.get("height"),
                "file_size_bytes": final_file_size,
                "metadata": {
                    "title": metadata.get("title"),
                    "original_url": metadata.get("original_url"),
                    "uploader": metadata.get("uploader"),
                    "upload_date": metadata.get("upload_date"),
                    "extractor": metadata.get("extractor"),
                    "original_filename": Path(input_source).name if not is_url else None,
                    "re_encoded": re_encode_for_qt,
                    "processing_timestamp": datetime.utcnow().isoformat(),
                    "s3_key": s3_key,
                    "s3_bucket": s3_bucket_name
                }
            }
            
            # Validate required fields before returning
            required_fields = ["filepath", "duration_seconds", "fps", "width", "height"]
            missing_fields = [field for field in required_fields if result.get(field) is None]
            if missing_fields:
                logger.warning(f"Missing required fields in result: {missing_fields}")
            
            return result

        except Exception as e:
            logger.error(f"Error processing video: {e}")
            raise


def main():
    """Main entry point for standalone execution"""
    parser = argparse.ArgumentParser(description="Ingest video processing task")
    parser.add_argument("--source-video-id", type=int, required=True)
    parser.add_argument("--input-source", required=True)
    parser.add_argument("--output-s3-prefix", required=False)
    parser.add_argument("--re-encode-for-qt", action="store_true", default=True)
    
    args = parser.parse_args()
    
    try:
        result = run_ingest(
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