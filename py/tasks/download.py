"""
Download Task - Simplified Elixir-orchestrated video downloads.

This module executes yt-dlp downloads with complete configuration provided by Elixir.
It focuses purely on execution, with all business logic, configuration, and decision
making handled by the Elixir YtDlpConfig module.

## Architecture:
- Receives complete configuration from Elixir YtDlpConfig
- Executes yt-dlp with 3-tier fallback strategy
- Applies FFmpeg normalization based on Elixir decisions
- Returns structured results for Elixir to process

## Responsibilities:
- yt-dlp execution with progress tracking
- FFmpeg normalization execution
- File handling and S3 upload
- Error reporting (not error decision making)

## Dependencies:
- YtDlpConfig: Complete configuration from Elixir
- FFmpegConfig: Normalization arguments from Elixir
- S3: File storage and upload

All business logic, quality assessment, and configuration is handled by Elixir.
"""

import argparse
import json
import logging
import os
import shutil
import signal
import subprocess
import tempfile
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from typing import Dict, Any, Optional, Tuple

import yt_dlp
from py.utils.filename_utils import sanitize_filename
from py.utils.s3_handler import upload_to_s3

# Custom exception classes for better error handling
class DownloadError(Exception):
    """Raised when yt-dlp download fails"""
    pass

class NormalizationError(Exception):
    """Raised when FFmpeg normalization fails"""
    pass

# Logging configuration
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


@contextmanager
def extraction_timeout(seconds):
    """Context manager for timing out yt-dlp extraction operations"""
    def timeout_handler(signum, frame):
        raise TimeoutError(f"yt-dlp extraction timed out after {seconds} seconds")
    
    old_handler = signal.signal(signal.SIGALRM, timeout_handler)
    signal.alarm(seconds)
    
    try:
        yield
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old_handler)


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


def run_download(
    source_video_id: int,
    input_source: str,
    download_config: dict,
    normalize_args: list = None,
    use_temp_cache: bool = False,
    **kwargs
) -> Dict[str, Any]:
    """
    Execute yt-dlp download with complete configuration from Elixir.
    
    This function executes the download process based on configuration
    provided by Elixir YtDlpConfig. All decision making is handled by Elixir,
    this function focuses purely on execution.
    
    Args:
        source_video_id: The ID of the source video
        input_source: URL or local file path to the video
        download_config: Complete configuration from YtDlpConfig
        normalize_args: FFmpeg arguments for normalization (from FFmpegConfig)
        use_temp_cache: If True, cache the file locally instead of uploading to S3
        **kwargs: Additional options
    
    Returns:
        dict: Structured data about the downloaded video including S3 path and metadata
        
    Raises:
        DownloadError: If yt-dlp download fails with all strategies
        NormalizationError: If FFmpeg normalization fails when required
    """
    logger.info(f"RUNNING DOWNLOAD for source_video_id: {source_video_id}")
    logger.info(f"Input: '{input_source}'")

    # Get S3 resources from environment (provided by Elixir)
    s3_bucket_name = os.getenv("S3_BUCKET_NAME")
    if not s3_bucket_name:
        raise ValueError("S3_BUCKET_NAME environment variable not set")

    is_url = input_source.lower().startswith(("http://", "https://"))
    
    # Validate dependencies
    _validate_ffprobe_available()
    if is_url:
        _validate_ffmpeg_available()

    with tempfile.TemporaryDirectory() as temp_dir:
        temp_dir_path = Path(temp_dir)
        
        try:
            if is_url:
                # Download from URL using configured strategies
                downloaded_path, download_metadata = download_with_fallback_strategy(
                    input_source, temp_dir_path, download_config
                )
                
                # Apply normalization based on Elixir configuration
                final_path = apply_normalization_if_configured(
                    downloaded_path, temp_dir_path, download_metadata, 
                    normalize_args, download_config
                )
                
                # Use download metadata from yt-dlp
                metadata = download_metadata
                
            else:
                # For local files, copy to temp directory
                final_path = temp_dir_path / Path(input_source).name
                shutil.copy2(input_source, final_path)
                metadata = {
                    'normalized': False, 
                    'download_method': 'local_file',
                    'requires_normalization': False
                }

            # Extract final metadata from processed video
            ffprobe_metadata = extract_video_metadata(final_path)
            metadata.update(ffprobe_metadata)
            
            # Validate final video
            _validate_downloaded_file(final_path)
            
            # Generate S3 key for original source video (logic from Elixir config)
            s3_key = generate_s3_key(source_video_id, metadata, final_path.suffix)
            
            # Handle upload vs temp cache based on use_temp_cache flag
            if use_temp_cache:
                local_filepath = handle_temp_cache_storage(final_path, s3_key)
            else:
                upload_to_s3(final_path, s3_key)
                local_filepath = None
            
            # Return structured data for Elixir to process
            result = build_success_result(
                s3_key, metadata, final_path, local_filepath, s3_bucket_name
            )
            
            return result

        except Exception as e:
            logger.error(f"Error processing video: {e}")
            if isinstance(e, (DownloadError, NormalizationError)):
                raise
            raise DownloadError(f"Download processing failed: {e}")


def download_with_fallback_strategy(
    url: str, temp_dir: Path, download_config: dict
) -> Tuple[Path, Dict[str, Any]]:
    """
    Execute yt-dlp download with 3-tier fallback strategy from Elixir config.
    
    Args:
        url: Video URL to download
        temp_dir: Temporary directory for downloads
        download_config: Complete configuration from YtDlpConfig
        
    Returns:
        tuple: (Path to downloaded file, metadata dict with download info)
        
    Raises:
        DownloadError: If all download strategies fail
    """
    _validate_ffmpeg_for_merge()
    
    format_strategies = download_config["format_strategies"]
    base_options = download_config["base_options"]
    timeout_config = download_config["timeout_config"]
    
    output_template = str(temp_dir / "%(title)s.%(ext)s")
    
    # Build base yt-dlp options from Elixir config
    base_ydl_opts = {
        'outtmpl': output_template,
        'logger': YtdlpLogger(),
        **base_options,
        'socket_timeout': timeout_config['socket_timeout']
    }

    downloaded_files = []
    info_dict = None
    
    def ytdlp_progress_hook(d):
        nonlocal downloaded_files
        status = d.get("status", "unknown")
        filename = d.get("filename", "unknown")
        
        if status == "finished":
            downloaded_files.append(filename)
            logger.info(f"yt-dlp hook: Download finished. File at: {filename}")
        elif status == "downloading":
            progress_str = d.get("_percent_str", "N/A")
            speed_str = d.get("_speed_str", "N/A")
            eta_str = d.get("_eta_str", "N/A")
            logger.info(f"yt-dlp progress: {progress_str} | Speed: {speed_str} | ETA: {eta_str}")
        elif status == "processing":
            logger.info(f"yt-dlp hook: Post-processing {filename} (likely merging audio/video)")
        elif status == "error":
            logger.error(f"yt-dlp hook: Error with {filename}")

    # Try each strategy in order
    for strategy_name, strategy_config in format_strategies.items():
        format_str = strategy_config["format"]
        logger.info(f"yt-dlp: Attempting {strategy_name} - format: '{format_str}'")
        logger.info(f"yt-dlp: {strategy_config['description']}")
        
        ydl_opts = {
            **base_ydl_opts, 
            'format': format_str, 
            'progress_hooks': [ytdlp_progress_hook]
        }
        
        try:
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                # Extract info with timeout
                logger.info(f"Extracting info ({strategy_name}) for {url}...")
                try:
                    with extraction_timeout(timeout_config['extraction_timeout']):
                        temp_info_dict = ydl.extract_info(url, download=False)
                        video_title = temp_info_dict.get('title', 'Untitled Video')
                        logger.info(f"yt-dlp: Extracted info - title: '{video_title}'")
                        
                        # Log available formats for debugging
                        formats = temp_info_dict.get('formats', [])
                        if formats:
                            logger.info(f"yt-dlp: Found {len(formats)} available formats")
                        
                        info_dict = temp_info_dict
                        
                except TimeoutError as timeout_err:
                    logger.error(f"{strategy_name} extraction timed out: {timeout_err}")
                    raise yt_dlp.utils.DownloadError(f"Extraction timeout: {timeout_err}")

                # Download with timeout
                logger.info(f"Downloading video ({strategy_name}): '{video_title}'...")
                ydl.download([url])

            # Find and validate downloaded files
            final_files = [f for f in downloaded_files if os.path.exists(f)]
            if not final_files:
                for file in os.listdir(temp_dir):
                    if file.lower().endswith(('.mp4', '.mkv', '.webm', '.avi')):
                        final_files.append(os.path.join(temp_dir, file))

            if not final_files:
                raise FileNotFoundError(f"yt-dlp ({strategy_name}) finished but no output file found.")

            # Use the largest file (likely the merged result)
            downloaded_path = max(final_files, key=lambda f: os.path.getsize(f) if os.path.exists(f) else 0)
            
            # Validate file
            file_size = os.path.getsize(downloaded_path)
            if file_size == 0:
                raise RuntimeError(f"Downloaded file is empty: {downloaded_path}")
            
            logger.info(f"Selected file: {downloaded_path} ({file_size} bytes)")
            logger.info(f"yt-dlp: Download successful with {strategy_name} format.")

            # Build metadata including strategy info
            result_metadata = info_dict or {}
            result_metadata.update({
                'download_method': strategy_name,
                'requires_normalization': strategy_config.get('requires_normalization', False),
                'strategy_description': strategy_config['description']
            })
            
            return Path(downloaded_path), result_metadata

        except yt_dlp.utils.DownloadError as e:
            logger.warning(f"yt-dlp: {strategy_name} download failed: {e}")
            _cleanup_temp_directory(temp_dir)
            downloaded_files = []
            continue
            
        except Exception as e:
            logger.error(f"yt-dlp: Unexpected error during {strategy_name} download: {e}")
            _cleanup_temp_directory(temp_dir)
            downloaded_files = []
            continue

    # If we get here, all strategies failed
    raise DownloadError("yt-dlp download failed with all strategies")


def apply_normalization_if_configured(
    input_path: Path, temp_dir: Path, metadata: dict, 
    normalize_args: list, download_config: dict
) -> Path:
    """
    Apply FFmpeg normalization based on Elixir configuration decisions.
    
    Args:
        input_path: Path to downloaded video
        temp_dir: Temporary directory for normalization
        metadata: Download metadata from yt-dlp
        normalize_args: FFmpeg arguments from FFmpegConfig
        download_config: Configuration from YtDlpConfig
        
    Returns:
        Path: Either normalized file or original file
    """
    requires_normalization = metadata.get('requires_normalization', False)
    force_normalization = download_config.get('base_options', {}).get('force_normalization', False)
    
    if requires_normalization or force_normalization:
        logger.info(f"Applying normalization based on Elixir configuration")
        normalized_path = temp_dir / f"normalized_{input_path.name}"
        
        try:
            if normalize_video(input_path, normalized_path, normalize_args):
                logger.info("Normalization completed successfully")
                return normalized_path
            else:
                logger.warning("Normalization failed, proceeding with original download")
                return input_path
        except NormalizationError as e:
            logger.warning(f"Normalization failed: {e}, proceeding with original download")
            return input_path
    else:
        logger.info("No normalization required based on Elixir configuration")
        return input_path


def normalize_video(input_path: Path, output_path: Path, normalize_args: list = None) -> bool:
    """
    Apply FFmpeg normalization to fix merge issues from primary downloads.
    
    Args:
        input_path: Path to the downloaded video file
        output_path: Path where the normalized video should be saved
        normalize_args: FFmpeg arguments for normalization (from FFmpegConfig)
        
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
        
        # Extract video duration for progress calculation
        duration = extract_video_duration(input_path)
        
        cmd = ["ffmpeg", "-i", str(input_path)] + normalize_args + ["-y", str(output_path)]
        
        logger.info(f"Starting normalization: {input_path.name}")
        logger.info(f"Input file size: {input_path.stat().st_size:,} bytes")
        logger.info(f"Video duration: {duration:.2f} seconds")
        
        # Run FFmpeg with progress reporting
        success = run_ffmpeg_with_progress(cmd, duration, "Normalization")
        
        if not success:
            raise NormalizationError("FFmpeg normalization failed")
        
        if not output_path.exists():
            raise NormalizationError(f"Normalized file was not created: {output_path}")
            
        output_size = output_path.stat().st_size
        logger.info(f"Normalization completed successfully")
        logger.info(f"Output file size: {output_size:,} bytes")
        return True
        
    except NormalizationError:
        raise
    except Exception as e:
        logger.error(f"Normalization exception: {e}")
        raise NormalizationError(f"Normalization failed: {e}")


def extract_video_duration(video_path: Path) -> float:
    """Extract video duration using ffprobe"""
    try:
        cmd = [
            "ffprobe", "-v", "quiet", "-print_format", "json", 
            "-show_format", str(video_path)
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        data = json.loads(result.stdout)
        return float(data["format"].get("duration", 0))
    except Exception as e:
        logger.warning(f"Failed to extract video duration: {e}")
        return 0.0


def run_ffmpeg_with_progress(cmd: list, duration: float, operation_name: str) -> bool:
    """Run FFmpeg command with real-time progress reporting"""
    try:
        # Add progress reporting to stderr
        cmd_with_progress = cmd + ["-progress", "pipe:2"]
        
        process = subprocess.Popen(
            cmd_with_progress,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            universal_newlines=True
        )
        
        # Read stderr for progress updates
        while process.poll() is None:
            line = process.stderr.readline()
            if line and duration > 0:
                if "out_time=" in line:
                    try:
                        time_str = line.split("out_time=")[1].split()[0]
                        current_seconds = parse_time_string(time_str)
                        progress = min(100, int((current_seconds / duration) * 100))
                        if progress > 0 and progress % 10 == 0:  # Log every 10%
                            logger.info(f"{operation_name}: {progress}% complete")
                    except:
                        pass
        
        return_code = process.wait()
        
        if return_code == 0:
            logger.info(f"{operation_name}: Completed successfully")
            return True
        else:
            logger.error(f"{operation_name}: FFmpeg failed with return code {return_code}")
            return False
            
    except Exception as e:
        logger.error(f"{operation_name}: Exception running FFmpeg: {e}")
        return False


def parse_time_string(time_str: str) -> float:
    """Parse time string in format HH:MM:SS.mmm to seconds"""
    try:
        parts = time_str.split(":")
        if len(parts) == 3:
            hours = float(parts[0])
            minutes = float(parts[1])
            seconds = float(parts[2])
            return hours * 3600 + minutes * 60 + seconds
        return 0.0
    except:
        return 0.0


def extract_video_metadata(video_path: Path) -> dict:
    """Extract video metadata using ffprobe"""
    try:
        cmd = [
            "ffprobe", "-v", "quiet", "-print_format", "json", 
            "-show_format", "-show_streams", str(video_path)
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        data = json.loads(result.stdout)
        
        # Find video stream
        video_stream = next((s for s in data["streams"] if s["codec_type"] == "video"), None)
        
        if not video_stream:
            return {}
        
        # Parse frame rate safely
        fps = _parse_frame_rate(video_stream.get("r_frame_rate", "0/1"))
            
        return {
            "duration_seconds": float(data["format"].get("duration", 0)),
            "fps": fps,
            "width": video_stream.get("width"),
            "height": video_stream.get("height")
        }
    except Exception as e:
        logger.warning(f"Failed to extract metadata: {e}")
        return {}


def generate_s3_key(source_video_id: int, metadata: dict, file_extension: str) -> str:
    """Generate S3 key for video storage"""
    video_title = metadata.get("title", f"video_{source_video_id}")
    sanitized_title = sanitize_filename(video_title)
    timestamp = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
    ext = file_extension or '.mp4'
    return f"originals/{sanitized_title}_{timestamp}{ext}"


def handle_temp_cache_storage(final_path: Path, s3_key: str) -> str:
    """Handle temp cache storage for pipeline chaining"""
    persist_dir = Path(tempfile.gettempdir()) / "heaters_persistent"
    persist_dir.mkdir(exist_ok=True)
    
    persist_filename = s3_key.replace("/", "_").replace("\\", "_")
    persistent_path = persist_dir / persist_filename
    
    shutil.copy2(final_path, persistent_path)
    logger.info(f"Created persistent file for Elixir caching: {persistent_path}")
    
    return str(persistent_path)


def build_success_result(s3_key: str, metadata: dict, final_path: Path, 
                        local_filepath: Optional[str], s3_bucket_name: str) -> dict:
    """Build success result dict for Elixir"""
    file_size = final_path.stat().st_size
    
    result = {
        "status": "success",
        "filepath": s3_key,
        "duration_seconds": metadata.get("duration_seconds"),
        "fps": metadata.get("fps"),
        "width": metadata.get("width"),
        "height": metadata.get("height"),
        "file_size_bytes": file_size,
        "metadata": {
            "title": metadata.get("title"),
            "original_url": metadata.get("original_url"),
            "uploader": metadata.get("uploader"),
            "upload_date": metadata.get("upload_date"),
            "extractor": metadata.get("extractor"),
            "transcoded": metadata.get('normalized', False),
            "download_method": metadata.get('download_method', 'unknown'),
            "processing_timestamp": datetime.utcnow().isoformat(),
            "s3_key": s3_key,
            "s3_bucket": s3_bucket_name
        }
    }
    
    if local_filepath:
        result["local_filepath"] = local_filepath
    
    return result


# Utility functions
def _validate_ffmpeg_for_merge():
    """Validate that FFmpeg is available for yt-dlp's internal merge operations"""
    try:
        result = subprocess.run(
            ["ffmpeg", "-version"], 
            capture_output=True, 
            text=True, 
            timeout=10
        )
        if result.returncode != 0:
            raise RuntimeError(f"FFmpeg validation failed with return code {result.returncode}")
        logger.info("FFmpeg validation successful for yt-dlp merge operations")
    except (subprocess.TimeoutExpired, FileNotFoundError, subprocess.SubprocessError) as e:
        raise RuntimeError(f"FFmpeg not available for yt-dlp merge operations: {e}")


def _validate_ffmpeg_available():
    """Validate that FFmpeg is available and working"""
    try:
        result = subprocess.run(
            ["ffmpeg", "-version"], 
            capture_output=True, 
            text=True, 
            timeout=10
        )
        if result.returncode != 0:
            raise RuntimeError(f"FFmpeg returned error code {result.returncode}")
    except (subprocess.TimeoutExpired, FileNotFoundError, subprocess.SubprocessError) as e:
        raise RuntimeError(f"FFmpeg validation failed: {e}")


def _validate_ffprobe_available():
    """Validate that FFprobe is available and working"""
    try:
        result = subprocess.run(
            ["ffprobe", "-version"], 
            capture_output=True, 
            text=True, 
            timeout=10
        )
        if result.returncode != 0:
            raise RuntimeError(f"FFprobe returned error code {result.returncode}")
    except (subprocess.TimeoutExpired, FileNotFoundError, subprocess.SubprocessError) as e:
        raise RuntimeError(f"FFprobe validation failed: {e}")


def _validate_downloaded_file(file_path: Path):
    """Validate downloaded file exists and is not empty"""
    if not file_path.exists():
        raise RuntimeError(f"Downloaded file not found: {file_path}")
    
    file_size = file_path.stat().st_size
    if file_size == 0:
        raise RuntimeError(f"Downloaded file is empty: {file_path}")


def _parse_frame_rate(fps_str: str) -> float:
    """Safely parse frame rate from string format like '30/1' or '30.0'"""
    try:
        if "/" in fps_str:
            numerator, denominator = fps_str.split("/", 1)
            num = float(numerator)
            den = float(denominator)
            if den == 0:
                return 0.0
            return num / den
        else:
            return float(fps_str)
    except (ValueError, ZeroDivisionError):
        return 0.0


def _cleanup_temp_directory(temp_dir: Path):
    """Clean up temp directory contents"""
    for item in os.listdir(temp_dir):
        item_path = os.path.join(temp_dir, item)
        try:
            if os.path.isfile(item_path):
                os.unlink(item_path)
            elif os.path.isdir(item_path):
                shutil.rmtree(item_path)
        except OSError as oe:
            logger.warning(f"Could not remove temp item {item_path}: {oe}")


def main():
    """Main entry point for standalone execution"""
    parser = argparse.ArgumentParser(description="Download video task (refactored)")
    parser.add_argument("--source-video-id", type=int, required=True)
    parser.add_argument("--input-source", required=True)
    
    args = parser.parse_args()
    
    try:
        # For standalone execution, use default config
        # In production, this comes from Elixir
        default_config = {
            "format_strategies": {
                "primary": {
                    "format": "bv*+ba/b",
                    "description": "Best quality with separate streams",
                    "requires_normalization": True
                },
                "fallback1": {
                    "format": "best[ext=mp4]/bestvideo[ext=mp4]+bestaudio[ext=m4a]/best",
                    "description": "Compatible MP4 format",
                    "requires_normalization": False
                }
            },
            "base_options": {
                "merge_output_format": "mp4",
                "restrictfilenames": True,
                "ignoreerrors": False,
                "retries": 3
            },
            "timeout_config": {
                "extraction_timeout": 60,
                "socket_timeout": 300
            }
        }
        
        result = run_download(
            args.source_video_id,
            args.input_source,
            default_config
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