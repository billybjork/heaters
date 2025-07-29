"""
Download Task - Orchestrates video download workflow.

This module orchestrates the complete download process:
- Orchestrates download using download_handler.py (yt-dlp implementation)
- Handles conditional normalization for primary downloads
- Manages S3 upload and metadata extraction
- Returns structured data for Elixir to process

## Architecture:
This is an orchestrator that depends on download_handler.py for core yt-dlp operations.
The download_handler.py contains all the quality-critical yt-dlp configuration and logic.

## Responsibilities:
- Workflow orchestration (download → normalize → upload)
- FFmpeg normalization for primary downloads
- S3 upload and metadata management
- Error handling and state management

## Dependencies:
- download_handler.py: Core yt-dlp implementation and quality requirements
- FFmpegConfig: Normalization arguments from Elixir
- S3: File storage and upload

See download_handler.py for detailed yt-dlp quality requirements and implementation.
"""

import argparse
import json
import logging
import os
import shutil
import subprocess
import tempfile
from datetime import datetime
from pathlib import Path

import boto3
from botocore.exceptions import ClientError, NoCredentialsError

from py.utils.filename_utils import sanitize_filename
# Import shared utility functions 
from .preprocess import validate_ffprobe_available, extract_video_metadata, validate_ffmpeg_available
from .download_handler import (
    download_from_url,
    extract_download_metadata
)
from utils.s3_handler import upload_to_s3


# Custom exception classes for better error handling
class DownloadError(Exception):
    """Raised when yt-dlp download fails"""
    pass


class NormalizationError(Exception):
    """Raised when FFmpeg normalization fails"""
    pass


class QualityReductionError(Exception):
    """Raised when configuration would reduce download quality"""
    pass


# --- Logging Configuration ---
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

# Normalization arguments are now provided by Elixir FFmpegConfig
# This eliminates hardcoded settings and centralizes configuration


def normalize_video(input_path: Path, output_path: Path, normalize_args: list = None) -> bool:
    """
    Lightweight normalization of downloaded video to fix merge issues from primary downloads.
    
    This function applies FFmpeg normalization to fix merge issues that occur when yt-dlp
    downloads separate video/audio streams and merges them internally. The merge operation
    sometimes fails or produces corrupted files, and this normalization ensures the file is 
    valid and playable while preserving the quality benefits of the primary download strategy.
    
    This is intentionally different from preprocessing.py - it's a lightweight fix specifically
    for download issues, not the full transcoding pipeline that creates standardized formats.
    
    Args:
        input_path: Path to the downloaded video file that may have merge issues
        output_path: Path where the normalized video should be saved
        normalize_args: FFmpeg arguments for normalization (from FFmpegConfig, defaults to basic settings)
        
    Returns:
        bool: True if normalization succeeded, False otherwise
        
    Raises:
        NormalizationError: If FFmpeg normalization fails
    """
    try:
        # Use provided normalize_args or fallback to basic settings
        if normalize_args is None:
            normalize_args = ["-map", "0", "-c:v", "libx264", "-preset", "fast", "-crf", "23",
                            "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", 
                            "-movflags", "+faststart", "-f", "mp4"]
        
        cmd = ["ffmpeg", "-i", str(input_path)] + normalize_args + ["-y", str(output_path)]
        
        logger.info(f"Starting normalization for primary download: {input_path.name}")
        logger.info(f"Input file size: {input_path.stat().st_size:,} bytes")
        
        # Use subprocess.Popen for progress tracking similar to other operations
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            universal_newlines=True
        )
        
        # Read stderr for any progress or error information
        stderr_output = []
        while process.poll() is None:
            line = process.stderr.readline()
            if line:
                stderr_output.append(line.strip())
                # Log key progress indicators
                if "time=" in line and "fps=" in line:
                    logger.info(f"Normalization progress: {line.strip()}")
        
        return_code = process.wait()
        
        if return_code != 0:
            logger.error(f"Normalization failed with return code {return_code}")
            logger.error(f"FFmpeg stderr: {' '.join(stderr_output[-5:])}")  # Last 5 lines
            raise NormalizationError(f"FFmpeg normalization failed with return code {return_code}")
        
        if not output_path.exists():
            logger.error(f"Normalized file was not created: {output_path}")
            raise NormalizationError(f"Normalized file was not created: {output_path}")
            
        output_size = output_path.stat().st_size
        logger.info(f"Normalization completed successfully")
        logger.info(f"Output file size: {output_size:,} bytes")
        return True
        
    except NormalizationError:
        # Re-raise NormalizationError as-is
        raise
    except Exception as e:
        logger.error(f"Normalization exception: {e}")
        raise NormalizationError(f"Normalization failed: {e}")


def run_download(
    source_video_id: int, 
    input_source: str, 
    normalize_args: list = None,
    **kwargs
):
    """
    Orchestrate the complete download workflow.
    
    This function orchestrates the download process by:
    1. Using download_handler.py for yt-dlp operations
    2. Applying conditional normalization for primary downloads
    3. Uploading to S3 and extracting metadata
    4. Returning structured data for Elixir processing
    
    The core yt-dlp implementation and quality requirements are handled by download_handler.py.
    This function focuses on workflow orchestration and integration with the broader pipeline.
    
    Args:
        source_video_id: The ID of the source video (for reference only)
        input_source: URL or local file path to the video
        normalize_args: FFmpeg arguments for normalization (from Elixir FFmpegConfig)
        **kwargs: Additional options
    
    Returns:
        dict: Structured data about the original video including S3 path and metadata
        
    Raises:
        DownloadError: If yt-dlp download fails
        NormalizationError: If FFmpeg normalization fails
    """
    logger.info(f"RUNNING DOWNLOAD for source_video_id: {source_video_id}")
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
    
    # Validate dependencies
    validate_ffprobe_available()
    if is_url:
        # We might need FFmpeg for normalization of primary downloads
        validate_ffmpeg_available()

    with tempfile.TemporaryDirectory() as temp_dir:
        temp_dir_path = Path(temp_dir)
        
        try:
            # Step 1: Download/acquire the original video
            if is_url:
                try:
                    downloaded_path, download_info_dict = download_from_url(input_source, temp_dir_path)
                except Exception as e:
                    logger.error(f"yt-dlp download failed: {e}")
                    raise DownloadError(f"yt-dlp download failed: {e}")
                
                # Use the info_dict from the download process to avoid extra yt-dlp calls
                metadata = extract_download_metadata(input_source, download_info_dict)
                
                # Step 1.5: Conditional normalization for primary downloads
                # 
                # This step applies FFmpeg normalization to fix merge issues that occur
                # when yt-dlp downloads separate video/audio streams. The merge operation
                # sometimes fails or produces corrupted files, and normalization ensures
                # the file is valid and playable while preserving quality benefits.
                #
                # Primary downloads (requires_normalization=True):
                # - Use separate video/audio streams for maximum quality
                # - May have merge issues that need normalization
                # - Expected: 4K quality, 80MB+ files, may need normalization
                #
                # Fallback downloads (requires_normalization=False):
                # - Use pre-merged files for compatibility
                # - No merge operation needed, so no normalization required
                # - Expected: Lower quality, smaller files, guaranteed compatibility
                #
                # This approach ensures we get the best possible quality when available,
                # with graceful fallback to more compatible formats when needed.
                #
                requires_normalization = download_info_dict.get('requires_normalization', False)
                download_method = download_info_dict.get('download_method', 'unknown')
                
                if requires_normalization:
                    logger.info(f"Primary download method detected - applying normalization for merge issue prevention")
                    normalized_path = temp_dir_path / f"normalized_{downloaded_path.name}"
                    
                    try:
                        if normalize_video(downloaded_path, normalized_path, normalize_args):
                            original_video_path = normalized_path
                            metadata['normalized'] = True
                            logger.info("Primary download normalization completed successfully")
                        else:
                            logger.warning("Normalization failed, proceeding with original download")
                            original_video_path = downloaded_path
                            metadata['normalized'] = False
                    except NormalizationError as e:
                        logger.warning(f"Normalization failed: {e}, proceeding with original download")
                        original_video_path = downloaded_path
                        metadata['normalized'] = False
                else:
                    logger.info(f"Fallback download method detected - no normalization needed")
                    original_video_path = downloaded_path
                    metadata['normalized'] = False
                    
                metadata['download_method'] = download_method
                
            else:
                # For local files, copy to temp directory
                original_video_path = temp_dir_path / Path(input_source).name
                shutil.copy2(input_source, original_video_path)
                metadata = {'normalized': False, 'download_method': 'local_file'}

            # Step 2: Extract metadata from final video
            ffprobe_metadata = extract_video_metadata(original_video_path)
            metadata.update(ffprobe_metadata)
            
            # Step 3: Validate original video before upload
            if not original_video_path.exists():
                raise RuntimeError(f"Original video file not found: {original_video_path}")
            
            original_file_size = original_video_path.stat().st_size
            if original_file_size == 0:
                raise RuntimeError(f"Original video file is empty: {original_video_path}")
            
            # Step 4: Upload original to S3 (no transcoding)
            # Use the video title for S3 key instead of numeric prefix
            video_title = metadata.get("title", f"video_{source_video_id}")
            
            # Sanitize title for filesystem/S3 compatibility
            sanitized_title = sanitize_filename(video_title)
            
            # Generate S3 key for original source video with timestamp to avoid conflicts
            timestamp = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
            original_ext = original_video_path.suffix or '.mp4'
            s3_key = f"source_videos_original/{sanitized_title}_{timestamp}{original_ext}"
            upload_to_s3(s3_client, s3_bucket_name, original_video_path, s3_key)
            
            # Step 5: Return structured data for Elixir to process
            result = {
                "status": "success",
                "filepath": s3_key,
                "duration_seconds": metadata.get("duration_seconds"),
                "fps": metadata.get("fps"),
                "width": metadata.get("width"),
                "height": metadata.get("height"),
                "file_size_bytes": original_file_size,
                "metadata": {
                    "title": metadata.get("title"),
                    "original_url": metadata.get("original_url"),
                    "uploader": metadata.get("uploader"),
                    "upload_date": metadata.get("upload_date"),
                    "extractor": metadata.get("extractor"),
                    "original_filename": Path(input_source).name if not is_url else None,
                    "transcoded": metadata.get('normalized', False),  # True if normalization was applied
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
            # Preserve original error type if it's one of our custom exceptions
            if isinstance(e, (DownloadError, NormalizationError, QualityReductionError)):
                raise
            # Wrap generic exceptions to provide context
            raise DownloadError(f"Download processing failed: {e}")


def main():
    """Main entry point for standalone execution"""
    parser = argparse.ArgumentParser(description="Download video task")
    parser.add_argument("--source-video-id", type=int, required=True)
    parser.add_argument("--input-source", required=True)
    
    args = parser.parse_args()
    
    try:
        result = run_download(
            args.source_video_id,
            args.input_source
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