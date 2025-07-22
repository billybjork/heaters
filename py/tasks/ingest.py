"""
Ingest Task - Download Only Workflow

This version focuses on downloading and storing original videos:
- Downloads videos from URLs or copies local files  
- Stores original files in S3 without transcoding
- Extracts basic metadata using FFprobe
- No transcoding - that happens later in preprocessing.py
- Returns structured data for Elixir to process
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
from .preprocessing import validate_ffprobe_available, extract_video_metadata, validate_ffmpeg_available
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

# Lightweight normalization for downloaded videos (different from preprocessing)
NORMALIZE_ARGS = [
    "-map", "0", "-c:v", "libx264", "-preset", "fast", "-crf", "23",
    "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", 
    "-movflags", "+faststart", "-f", "mp4"
]


def normalize_video(input_path: Path, output_path: Path) -> bool:
    """
    Lightweight normalization of downloaded video to fix merge issues from primary downloads.
    
    CRITICAL: This step is essential for maintaining best quality downloads. Primary downloads
    use separate video/audio streams that yt-dlp merges internally, but this merge operation
    sometimes fails or produces corrupted files. This normalization ensures the file is 
    valid and playable while preserving the quality benefits of the primary download strategy.
    
    This is intentionally different from preprocessing.py - it's a lightweight fix specifically
    for download issues, not the full transcoding pipeline that creates standardized formats.
    
    Args:
        input_path: Path to the downloaded video file that may have merge issues
        output_path: Path where the normalized video should be saved
        
    Returns:
        bool: True if normalization succeeded, False otherwise
    """
    try:
        cmd = ["ffmpeg", "-i", str(input_path)] + NORMALIZE_ARGS + ["-y", str(output_path)]
        
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
            return False
        
        if not output_path.exists():
            logger.error(f"Normalized file was not created: {output_path}")
            return False
            
        output_size = output_path.stat().st_size
        logger.info(f"Normalization completed successfully")
        logger.info(f"Output file size: {output_size:,} bytes")
        return True
        
    except Exception as e:
        logger.error(f"Normalization exception: {e}")
        return False


def run_ingest(
    source_video_id: int, 
    input_source: str, 
    **kwargs
):
    """
    Ingest a source video: downloads original and stores in S3 without transcoding.
    Transcoding happens later in preprocessing.py to avoid redundant operations.
    
    Args:
        source_video_id: The ID of the source video (for reference only)
        input_source: URL or local file path to the video
        **kwargs: Additional options
    
    Returns:
        dict: Structured data about the original video including S3 path and metadata
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
                downloaded_path, download_info_dict = download_from_url(input_source, temp_dir_path)
                # Use the info_dict from the download process to avoid extra yt-dlp calls
                metadata = extract_download_metadata(input_source, download_info_dict)
                
                # Step 1.5: Conditional normalization for primary downloads
                # 
                # CRITICAL ARCHITECTURE NOTE: This conditional normalization is essential for 
                # maintaining our best-quality-first download strategy. Here's why:
                #
                # PRIMARY DOWNLOADS (requires_normalization=True):
                # - Use format: 'bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b'
                # - Download separate video/audio streams for maximum quality
                # - yt-dlp merges them internally using FFmpeg
                # - This merge sometimes fails or produces corrupted files
                # - Normalization fixes these merge issues while preserving quality benefits
                #
                # FALLBACK DOWNLOADS (requires_normalization=False):
                # - Use format: 'bestvideo[ext=mp4][vcodec^=avc1]+bestaudio[ext=m4a]/best[ext=mp4]/best'
                # - Download pre-merged files or more compatible formats
                # - No merge operation needed, so no normalization required
                #
                # This approach ensures we get the best possible quality when available,
                # with graceful fallback to more compatible formats when needed.
                #
                requires_normalization = download_info_dict.get('requires_normalization', False)
                download_method = download_info_dict.get('download_method', 'unknown')
                
                if requires_normalization:
                    logger.info(f"Primary download method detected - applying normalization for merge issue prevention")
                    normalized_path = temp_dir_path / f"normalized_{downloaded_path.name}"
                    
                    if normalize_video(downloaded_path, normalized_path):
                        original_video_path = normalized_path
                        metadata['normalized'] = True
                        logger.info("Primary download normalization completed successfully")
                    else:
                        logger.warning("Normalization failed, proceeding with original download")
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
            raise


def main():
    """Main entry point for standalone execution"""
    parser = argparse.ArgumentParser(description="Ingest video download task")
    parser.add_argument("--source-video-id", type=int, required=True)
    parser.add_argument("--input-source", required=True)
    
    args = parser.parse_args()
    
    try:
        result = run_ingest(
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