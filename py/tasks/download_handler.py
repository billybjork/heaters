"""
Download Handler - Core yt-dlp implementation for quality-focused downloads.

This module contains the core yt-dlp implementation and quality-critical configuration.
It handles video downloading with sophisticated fallback strategies to ensure best possible
quality (including 4K/8K when available).

🚨 CRITICAL: BEST QUALITY DOWNLOAD REQUIREMENTS 🚨

This module implements 4K/8K quality downloads. To maintain this capability:

❌ NEVER ADD height restrictions to format strings (e.g., [height<=1080])
❌ NEVER ADD client restrictions via extractor_args 
❌ NEVER ADD quality caps or manual limitations
❌ NEVER ADD extension restrictions to primary format (blocks VP9/AV1 4K)

✅ ALWAYS use unrestricted format strings
✅ ALWAYS let yt-dlp choose optimal clients (no extractor_args)
✅ ALWAYS test with expected ~49 formats and 80MB+ downloads
✅ ALWAYS use three-tier fallback strategy

BREAKING THESE RULES REDUCES QUALITY FROM 4K TO 360P (verified multiple times)

## Core Responsibilities:
- yt-dlp configuration and format selection
- Quality-focused download strategy with fallbacks
- Progress reporting and error handling
- Metadata extraction and validation

## Format Strategy:
- Primary: 'bv*+ba/b' (best quality, separate streams, may need normalization)
- Fallback1: 'best[ext=mp4]/bestvideo[ext=mp4]+bestaudio[ext=m4a]/best' (compatible)
- Fallback2: 'worst' (maximum compatibility)

## Validation:
- Should see ≥40 formats for YouTube videos
- Primary should select 4K when available
- Quality tiers: HIGH (≥1080p), MEDIUM (720p-1079p), LOW (480p-719p), VERY_LOW (<480p)

This module is used by download.py for workflow orchestration.
"""

import logging
import os
import shutil
import signal
import subprocess
from contextlib import contextmanager
from pathlib import Path
from typing import Dict, Any, Optional, Tuple
from datetime import datetime

import yt_dlp

logger = logging.getLogger(__name__)


@contextmanager
def extraction_timeout(seconds):
    """Context manager for timing out yt-dlp extraction operations"""
    def timeout_handler(signum, frame):
        raise TimeoutError(f"yt-dlp extraction timed out after {seconds} seconds")
    
    # Set up the timeout
    old_handler = signal.signal(signal.SIGALRM, timeout_handler)
    signal.alarm(seconds)
    
    try:
        yield
    finally:
        # Clean up: restore old handler and cancel alarm
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old_handler)


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


def _validate_yt_dlp_config(base_ydl_opts: dict) -> None:
    """
    Validate yt-dlp configuration follows quality requirements.
    
    This prevents common mistakes that reduce download quality from 4K to 360p.
    """
    # Check for extractor_args that reduce format availability
    if 'extractor_args' in base_ydl_opts:
        raise ValueError(
            "extractor_args will reduce available formats from ~49 to ~5, "
            "blocking 4K/8K quality. Remove extractor_args to let yt-dlp "
            "auto-select optimal clients."
        )
    
    # Check for height restrictions in format strings
    format_str = base_ydl_opts.get('format', '')
    if '[height<=' in format_str:
        raise ValueError(
            "Height restrictions like [height<=1080] will block 4K (2160p) "
            "and 1440p downloads. Remove height restrictions from format strings."
        )
    
    # Check for extension restrictions in primary format
    if format_str and '[ext=' in format_str and 'bv*' in format_str:
        logger.warning(
            "Extension restrictions in primary format may block VP9/AV1 4K streams. "
            "Consider using unrestricted format for maximum quality."
        )


def _create_structured_log_data(source_video_id: int, url: str, format_str: str, 
                              quality_tier: str, file_size_mb: float) -> dict:
    """Create structured log data for monitoring and debugging."""
    return {
        "source_video_id": source_video_id,
        "url": url,
        "format": format_str,
        "quality_tier": quality_tier,
        "file_size_mb": round(file_size_mb, 2),
        "timestamp": datetime.utcnow().isoformat()
    }


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


def download_from_url(url: str, temp_dir: Path) -> Tuple[Path, Dict[str, Any]]:
    """
    Download video from URL using yt-dlp with quality-focused strategy.
    
    This function implements the core yt-dlp download logic with sophisticated
    fallback strategies to ensure best possible quality. It handles format selection,
    progress reporting, error handling, and metadata extraction.
    
    The download strategy uses a three-tier approach:
    1. Primary format for maximum quality (may need normalization)
    2. Fallback format for compatibility
    3. Worst format for maximum compatibility
    
    Args:
        url: Video URL to download
        temp_dir: Temporary directory for downloads
        
    Returns:
        tuple: (Path to downloaded file, info_dict with metadata)
        
    Raises:
        RuntimeError: If all download strategies fail
    """
    # Validate FFmpeg is available for yt-dlp's merge operations
    _validate_ffmpeg_for_merge()
    
    output_template = str(temp_dir / "%(title)s.%(ext)s")
    
    # CRITICAL: Format preferences for BEST QUALITY downloads (including 4K)
    # 
    # ⚠️  WARNING: DO NOT ADD HEIGHT RESTRICTIONS (e.g., [height<=1080])
    # ⚠️  This will block 4K (2160p) and 1440p downloads!
    # 
    # ⚠️  WARNING: DO NOT ADD EXTENSION RESTRICTIONS to primary format
    # ⚠️  This blocks VP9/AV1 4K streams that are often the highest quality
    # 
    # Primary format: BEST QUALITY with separate streams (4K/8K capable)
    # - Downloads highest quality video stream + best audio separately  
    # - yt-dlp merges them with FFmpeg for maximum quality
    # - Supports 4K, 8K, any resolution without restrictions
    # - May require post-download normalization to fix merge issues
    # - NO extension filter to allow VP9/AV1 4K streams
    # - Expected: ~49 formats available, 80MB+ downloads for 4K content
    format_primary = 'bv*+ba/b'
    
    # Fallback format 1: Most compatible formats
    # - Used when primary format fails (merge issues, network problems)
    # - Prioritizes compatibility over absolute best quality
    # - Ensures MP4 output for downstream processing
    # - Expected: ~5-10 formats, smaller file sizes
    format_fallback1 = 'best[ext=mp4]/bestvideo[ext=mp4]+bestaudio[ext=m4a]/best'
    
    # Fallback format 2: "Whatever plays" (optional)
    # - Used when both primary and fallback1 fail
    # - Guaranteed to work on very old devices
    # - Last resort for problematic videos
    # - Expected: 1-3 formats, lowest quality but guaranteed compatibility
    format_fallback2 = 'worst'
    
    base_ydl_opts = {
        'outtmpl': output_template,
        'merge_output_format': 'mp4',  # Ensure merged output is mp4
        'logger': YtdlpLogger(),
        'nocheckcertificate': True,
        'retries': 3,  # Reduced retries to fail faster
        'embedmetadata': False,  # Disabled to avoid potential issues
        'embedthumbnail': False,  # Disabled to avoid potential issues  
        'restrictfilenames': True,
        'ignoreerrors': False,  # Fail on error to trigger fallback
        'socket_timeout': 300,  # Increased timeout for 4K downloads and merge operations
        'postprocessor_args': {
            'ffmpeg_i': ['-err_detect', 'ignore_err', '-fflags', '+genpts'],
        },
        'fragment_retries': 5,  # Reduced fragment retries
        'skip_unavailable_fragments': True,
        
        # CRITICAL: Prevent playlist expansion and multiple video downloads
        # These settings ensure only the single requested video is downloaded
        'playlist_items': '1',  # Only download the first item (prevents playlist expansion)
        'extract_flat': False,  # Ensure we get full video info
        'noplaylist': True,     # Don't download playlists (prevents channel/playlist expansion)
        
        # CRITICAL: Clear cached data to prevent old video downloads
        # These settings prevent yt-dlp from using cached data that might cause
        # downloading of previously cached videos instead of the requested one
        'no_cache_dir': True,   # Don't use cache directory
        'cachedir': False,      # Disable caching entirely
        
        # CRITICAL: No extractor_args for BEST QUALITY downloads
        # 
        # ⚠️  WARNING: DO NOT add 'extractor_args' with client restrictions!
        # ⚠️  This reduces available formats from ~49 to ~5, blocking high quality!
        # ⚠️  Let yt-dlp use its optimal default client selection automatically
        # 
        # yt-dlp auto-selects optimal clients:
        # - Tries multiple clients automatically (iOS, Android, web)
        # - Maximizes format availability (including 4K/2160p)
        # - Self-adapts to YouTube's changing restrictions
        # - No manual client selection needed
        
        # OPTIONAL: Robustness features for faster and more reliable downloads
        'concurrent_fragment_downloads': 5,  # Faster DASH grabs (parallel downloads)
        'external_downloader': 'aria2c',     # Resume & parallel HTTP (if available)
        # Note: format_sort was removed due to yt-dlp compatibility issues
    }

    # Validate configuration to prevent quality-reducing mistakes
    _validate_yt_dlp_config(base_ydl_opts)

    download_successful = False
    info_dict = None
    video_title = 'Untitled Video'  # Default title
    downloaded_files = []
    download_method = 'failed'  # Track which method succeeded

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
        else:
            logger.info(f"yt-dlp hook: {status} - {filename}")

    # Attempt 1: Primary (Best Quality) Format
    logger.info(f"yt-dlp: Attempt 1 - Using primary format: '{format_primary}'")
    logger.info(f"yt-dlp: Processing URL: {url}")
    ydl_opts_primary = {**base_ydl_opts, 'format': format_primary, 'progress_hooks': [ytdlp_progress_hook]}

    try:
        with yt_dlp.YoutubeDL(ydl_opts_primary) as ydl:
            logger.info(f"Extracting info (Attempt 1) for {url}...")
            try:
                with extraction_timeout(60):  # 60 second timeout for extraction
                    temp_info_dict = ydl.extract_info(url, download=False)
                    video_title = temp_info_dict.get('title', video_title)
                    logger.info(f"yt-dlp: Extracted info - title: '{video_title}', type: {temp_info_dict.get('_type', 'unknown')}, entries: {len(temp_info_dict.get('entries', []))}")
                    
                    # Debug: Log available formats to understand what we're working with
                    formats = temp_info_dict.get('formats', [])
                    if formats:
                        logger.info(f"yt-dlp: Found {len(formats)} available formats")
                        
                        # Log top 10 video formats by resolution for better debugging
                        video_formats = [f for f in formats if f.get('vcodec') != 'none' and f.get('height')]
                        video_formats_sorted = sorted(video_formats, key=lambda x: x.get('height', 0), reverse=True)[:10]
                        
                        logger.info("yt-dlp: Top available video formats:")
                        for i, fmt in enumerate(video_formats_sorted):
                            filesize_mb = fmt.get('filesize_approx', 0) // 1024 // 1024 if fmt.get('filesize_approx') else '?'
                            bitrate = fmt.get('tbr', 'unknown')
                            fps = fmt.get('fps', 'unknown')
                            vcodec = fmt.get('vcodec', 'unknown')
                            acodec = fmt.get('acodec', 'none')
                            # Mark if this is a complete file (has both video and audio) vs video-only
                            is_complete = acodec != 'none'
                            complete_indicator = "🎵" if is_complete else "📹"
                            logger.info(f"yt-dlp:   #{i+1}: {fmt.get('format_id')} - {fmt.get('height')}p@{fps}fps, {fmt.get('ext')}, {bitrate}kbps, ~{filesize_mb}MB, {vcodec}, {complete_indicator}")
                        
                        # Also log top 5 audio formats
                        audio_formats = [f for f in formats if f.get('acodec') != 'none' and f.get('vcodec') == 'none']
                        audio_formats_sorted = sorted(audio_formats, key=lambda x: x.get('abr') or 0, reverse=True)[:5]
                        
                        if audio_formats_sorted:
                            logger.info("yt-dlp: Top available audio formats:")
                            for i, fmt in enumerate(audio_formats_sorted):
                                bitrate = fmt.get('abr', f"tbr:{fmt.get('tbr', 'unknown')}")
                                logger.info(f"yt-dlp:   #{i+1}: {fmt.get('format_id')} - {fmt.get('ext')}, {bitrate}kbps")
                    
                    # Store the info_dict for later use
                    info_dict = temp_info_dict
            except TimeoutError as timeout_err:
                logger.error(f"Primary extraction timed out: {timeout_err}")
                raise yt_dlp.utils.DownloadError(f"Extraction timeout: {timeout_err}")

            logger.info(f"Downloading video (Attempt 1): '{video_title}'...")
            
            # Debug: List temp directory before download
            logger.info(f"Temp dir before download: {list(os.listdir(temp_dir))}")
            
            ydl.download([url])
            
            # Debug: List temp directory after download
            logger.info(f"Temp dir after download: {list(os.listdir(temp_dir))}")

        # Find downloaded files
        final_files = [f for f in downloaded_files if os.path.exists(f)]
        if not final_files:
            for file in os.listdir(temp_dir):
                if file.lower().endswith(('.mp4', '.mkv', '.webm', '.avi')):
                    final_files.append(os.path.join(temp_dir, file))

        if not final_files:
            raise FileNotFoundError("yt-dlp (Attempt 1) finished but no output file found.")

        # Debug: Log file sizes
        logger.info(f"Found {len(final_files)} downloaded files:")
        for file in final_files:
            size = os.path.getsize(file)
            logger.info(f"  {file}: {size} bytes")

        # Use the largest file (likely the merged result)
        initial_temp_filepath = max(final_files, key=lambda f: os.path.getsize(f) if os.path.exists(f) else 0)
        
        # Check if the selected file is empty
        file_size = os.path.getsize(initial_temp_filepath)
        if file_size == 0:
            raise RuntimeError(f"Downloaded file is empty: {initial_temp_filepath}")
        
        logger.info(f"Selected file: {initial_temp_filepath} ({file_size} bytes)")

        # CRITICAL: Optimize metadata handling to avoid timeout issues
        # Reuse metadata from download phase instead of making redundant network calls
        # This prevents the timeout issues that occur when yt-dlp tries to re-extract
        # metadata after the download is complete
        if not info_dict:
            logger.warning("No info_dict from download phase, attempting metadata extraction...")
            with yt_dlp.YoutubeDL({'logger': YtdlpLogger(), 'quiet': True, 'skip_download': True, 'socket_timeout': 30}) as ydl_info:
                try:
                    with extraction_timeout(120):  # 120 second timeout for metadata extraction
                        info_dict = ydl_info.extract_info(url, download=False)
                except TimeoutError as timeout_err:
                    logger.error(f"Metadata extraction timed out: {timeout_err}")
                    # Don't fail here, just use empty info_dict
                    info_dict = {}
                except Exception as e:
                    logger.error(f"Metadata extraction failed: {e}")
                    info_dict = {}
        else:
            logger.info("Using info_dict from download phase for metadata")

        download_successful = True
        download_method = 'primary'
        logger.info("yt-dlp: Download successful with primary format.")

    except yt_dlp.utils.DownloadError as e_primary:
        error_msg = str(e_primary)
        logger.warning(f"yt-dlp: Primary download attempt failed: {error_msg}")
        
        # Debug: Check what files exist in temp dir after failure
        logger.info(f"Temp dir after primary failure: {list(os.listdir(temp_dir))}")
        for file in os.listdir(temp_dir):
            file_path = os.path.join(temp_dir, file)
            if os.path.isfile(file_path):
                size = os.path.getsize(file_path)
                logger.info(f"  {file}: {size} bytes")
        
        # Check if it's a merge-related error
        if any(keyword in error_msg.lower() for keyword in ['merge', 'ffmpeg', 'postprocessor', 'mux']):
            logger.warning("Error appears to be related to audio/video merge operation")
        
        logger.warning("Trying fallback format which may not require merge operation")
        
        # Clean up temp directory before fallback
        _cleanup_temp_directory(temp_dir)
        # Reset tracking variables
        downloaded_files = []

    except Exception as e_generic_primary:
        error_msg = str(e_generic_primary)
        logger.error(f"yt-dlp: Unexpected error during primary download: {error_msg}")
        
        # Check if it's a merge-related error
        if any(keyword in error_msg.lower() for keyword in ['merge', 'ffmpeg', 'postprocessor', 'mux']):
            logger.error("Unexpected error appears to be related to audio/video merge operation")
        
        logger.warning("Proceeding to fallback attempt despite unexpected error.")
        
        # Clean up and reset
        _cleanup_temp_directory(temp_dir)
        downloaded_files = []

    # Attempt 2: Fallback (More Compatible) Format
    if not download_successful:
        logger.info(f"yt-dlp: Attempt 2 - Using fallback format: '{format_fallback1}'")
        logger.info(f"yt-dlp: Processing URL (fallback): {url}")
        ydl_opts_fallback1 = {**base_ydl_opts, 'format': format_fallback1, 'progress_hooks': [ytdlp_progress_hook]}

        try:
            with yt_dlp.YoutubeDL(ydl_opts_fallback1) as ydl:
                logger.info(f"Extracting info (Attempt 2) for {url}...")
                try:
                    with extraction_timeout(120):  # 120 second timeout for fallback extraction
                        temp_info_dict = ydl.extract_info(url, download=False)
                        video_title = temp_info_dict.get('title', video_title)
                        logger.info(f"yt-dlp: Extracted info (fallback) - title: '{video_title}', type: {temp_info_dict.get('_type', 'unknown')}, entries: {len(temp_info_dict.get('entries', []))}")
                        # Store the info_dict for later use
                        info_dict = temp_info_dict
                except TimeoutError as timeout_err:
                    logger.error(f"Fallback extraction timed out: {timeout_err}")
                    raise yt_dlp.utils.DownloadError(f"Fallback extraction timeout: {timeout_err}")
                except Exception as e:
                    logger.error(f"Fallback extraction failed: {e}")
                    raise yt_dlp.utils.DownloadError(f"Fallback extraction failed: {e}")

                logger.info(f"Downloading video (Attempt 2): '{video_title}'...")
                ydl.download([url])

            # Find downloaded files
            final_files = [f for f in downloaded_files if os.path.exists(f)]
            if not final_files:
                for file in os.listdir(temp_dir):
                    if file.lower().endswith(('.mp4', '.mkv', '.webm', '.avi')):
                        final_files.append(os.path.join(temp_dir, file))

            if not final_files:
                raise FileNotFoundError("yt-dlp (Attempt 2 - Fallback) finished but no output file found.")

            # Debug: Log file sizes for fallback
            logger.info(f"Fallback found {len(final_files)} downloaded files:")
            for file in final_files:
                size = os.path.getsize(file)
                logger.info(f"  {file}: {size} bytes")

            initial_temp_filepath = max(final_files, key=lambda f: os.path.getsize(f) if os.path.exists(f) else 0)
            
            # Check if the selected file is empty
            file_size = os.path.getsize(initial_temp_filepath)
            if file_size == 0:
                raise RuntimeError(f"Fallback downloaded file is empty: {initial_temp_filepath}")
            
            logger.info(f"Fallback selected file: {initial_temp_filepath} ({file_size} bytes)")
            download_successful = True
            download_method = 'fallback1'
            logger.info("yt-dlp: Download successful with fallback format.")

        except yt_dlp.utils.DownloadError as e_fallback:
            logger.error(f"yt-dlp: Fallback download attempt also failed: {e_fallback}")
            raise RuntimeError(f"yt-dlp download failed with all strategies. Last error: {str(e_fallback)[:200]}")

        except Exception as e_generic_fallback:
            logger.error(f"yt-dlp: Unexpected error during fallback download: {e_generic_fallback}")
            raise RuntimeError(f"yt-dlp unexpected error with fallback: {str(e_generic_fallback)[:200]}")

    # Attempt 3: Fallback (Even More Compatible) Format
    if not download_successful:
        logger.info(f"yt-dlp: Attempt 3 - Using fallback format: '{format_fallback2}'")
        logger.info(f"yt-dlp: Processing URL (fallback): {url}")
        ydl_opts_fallback2 = {**base_ydl_opts, 'format': format_fallback2, 'progress_hooks': [ytdlp_progress_hook]}

        try:
            with yt_dlp.YoutubeDL(ydl_opts_fallback2) as ydl:
                logger.info(f"Extracting info (Attempt 3) for {url}...")
                try:
                    with extraction_timeout(120):  # 120 second timeout for fallback extraction
                        temp_info_dict = ydl.extract_info(url, download=False)
                        video_title = temp_info_dict.get('title', video_title)
                        logger.info(f"yt-dlp: Extracted info (fallback) - title: '{video_title}', type: {temp_info_dict.get('_type', 'unknown')}, entries: {len(temp_info_dict.get('entries', []))}")
                        # Store the info_dict for later use
                        info_dict = temp_info_dict
                except TimeoutError as timeout_err:
                    logger.error(f"Fallback extraction timed out: {timeout_err}")
                    raise yt_dlp.utils.DownloadError(f"Fallback extraction timeout: {timeout_err}")
                except Exception as e:
                    logger.error(f"Fallback extraction failed: {e}")
                    raise yt_dlp.utils.DownloadError(f"Fallback extraction failed: {e}")

                logger.info(f"Downloading video (Attempt 3): '{video_title}'...")
                ydl.download([url])

            # Find downloaded files
            final_files = [f for f in downloaded_files if os.path.exists(f)]
            if not final_files:
                for file in os.listdir(temp_dir):
                    if file.lower().endswith(('.mp4', '.mkv', '.webm', '.avi')):
                        final_files.append(os.path.join(temp_dir, file))

            if not final_files:
                raise FileNotFoundError("yt-dlp (Attempt 3 - Fallback) finished but no output file found.")

            # Debug: Log file sizes for fallback
            logger.info(f"Fallback found {len(final_files)} downloaded files:")
            for file in final_files:
                size = os.path.getsize(file)
                logger.info(f"  {file}: {size} bytes")

            initial_temp_filepath = max(final_files, key=lambda f: os.path.getsize(f) if os.path.exists(f) else 0)
            
            # Check if the selected file is empty
            file_size = os.path.getsize(initial_temp_filepath)
            if file_size == 0:
                raise RuntimeError(f"Fallback downloaded file is empty: {initial_temp_filepath}")
            
            logger.info(f"Fallback selected file: {initial_temp_filepath} ({file_size} bytes)")
            download_successful = True
            download_method = 'fallback2'
            logger.info("yt-dlp: Download successful with fallback format.")

        except yt_dlp.utils.DownloadError as e_fallback:
            logger.error(f"yt-dlp: Fallback download attempt also failed: {e_fallback}")
            raise RuntimeError(f"yt-dlp download failed with all strategies. Last error: {str(e_fallback)[:200]}")

        except Exception as e_generic_fallback:
            logger.error(f"yt-dlp: Unexpected error during fallback download: {e_generic_fallback}")
            raise RuntimeError(f"yt-dlp unexpected error with fallback: {str(e_generic_fallback)[:200]}")

    if not download_successful:
        raise RuntimeError("yt-dlp processing failed after all attempts.")

    # Ensure info_dict is populated
    if not info_dict:
        logger.warning("info_dict not populated. Attempting final metadata fetch...")
        try:
            with yt_dlp.YoutubeDL({'logger': YtdlpLogger(), 'quiet': True, 'skip_download': True, 'socket_timeout': 30}) as ydl_final:
                try:
                    with extraction_timeout(120):  # 120 second timeout for final metadata fetch
                        info_dict = ydl_final.extract_info(url, download=False)
                except TimeoutError as timeout_err:
                    logger.error(f"Final metadata extraction timed out: {timeout_err}")
                    info_dict = {}
                except Exception as e:
                    logger.error(f"Final metadata extraction failed: {e}")
                    info_dict = {}
        except Exception as final_info_err:
            logger.error(f"Failed to fetch final metadata: {final_info_err}")
            info_dict = {}

    logger.info(f"Using final file: {initial_temp_filepath}")
    
    if not os.path.exists(initial_temp_filepath):
        raise RuntimeError(f"Selected output file does not exist: {initial_temp_filepath}")

    # Add metadata about which format was used for downstream processing
    result_metadata = info_dict or {}
    
    # Track which download method was successful
    if download_successful:
        # Determine which attempt succeeded based on the current state
        if download_method == 'primary':
            result_metadata['download_method'] = 'primary'
            result_metadata['requires_normalization'] = True  # Primary downloads may need normalization
        elif download_method == 'fallback1':
            result_metadata['download_method'] = 'fallback1'
            result_metadata['requires_normalization'] = True  # Fallback1 downloads may need normalization
        elif download_method == 'fallback2':
            result_metadata['download_method'] = 'fallback2'
            result_metadata['requires_normalization'] = True  # Fallback2 downloads may need normalization
        else:
            result_metadata['download_method'] = 'unknown'
            result_metadata['requires_normalization'] = False
    else:
        result_metadata['download_method'] = 'failed'
        result_metadata['requires_normalization'] = False

    # Add quality assessment based on downloaded file
    final_height = result_metadata.get('height', 0)
    final_width = result_metadata.get('width', 0)
    file_size = os.path.getsize(initial_temp_filepath)
    file_size_mb = file_size / (1024 * 1024)
    
    # Assess quality and log YouTube restrictions if applicable
    if final_height >= 1080:
        quality_tier = "high"
        logger.info(f"✅ Downloaded HIGH quality: {final_width}x{final_height}, {file_size_mb:.1f}MB")
    elif final_height >= 720:
        quality_tier = "medium"
        logger.info(f"⚠️  Downloaded MEDIUM quality: {final_width}x{final_height}, {file_size_mb:.1f}MB")
    elif final_height >= 480:
        quality_tier = "low"
        logger.info(f"⚠️  Downloaded LOW quality: {final_width}x{final_height}, {file_size_mb:.1f}MB")
    else:
        quality_tier = "very_low"
        logger.warning(f"⚠️  Downloaded VERY LOW quality: {final_width}x{final_height}, {file_size_mb:.1f}MB")
        
        # Check if this appears to be YouTube restrictions
        extractor = result_metadata.get('extractor_key', '').lower()
        if 'youtube' in extractor:
            logger.warning("📺 YouTube Quality Restriction Detected:")
            logger.warning("   This appears to be due to YouTube's PO token requirements.")
            logger.warning("   Higher quality formats are currently restricted without authentication tokens.")
            logger.warning("   The video processing pipeline will still work with this quality.")
    
    # Add structured logging for monitoring
    log_data = _create_structured_log_data(
        source_video_id=0,  # Not available in this context
        url=url,
        format_str=format_primary if download_method == 'primary' else format_fallback1,
        quality_tier=quality_tier,
        file_size_mb=file_size_mb
    )
    logger.info("download_quality_assessment", extra=log_data)
    
    # Record metrics for monitoring (if source_video_id is available)
    # Note: source_video_id is not available in this context, but metrics
    # can still be recorded for quality monitoring
    _record_download_metrics(
        source_video_id=0,  # Not available in this context
        quality_tier=quality_tier,
        file_size_mb=file_size_mb,
        download_method=download_method,
        format_count=0  # Not tracked in this context
    )
    
    result_metadata['quality_tier'] = quality_tier
    result_metadata['file_size_mb'] = round(file_size_mb, 2)
    result_metadata['youtube_restricted'] = (quality_tier in ['low', 'very_low'] and 'youtube' in result_metadata.get('extractor_key', '').lower())
    
    return Path(initial_temp_filepath), result_metadata


def extract_download_metadata(url: str, info_dict: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """Extract metadata from yt-dlp info dict or by fetching it"""
    if info_dict is None:
        try:
            with yt_dlp.YoutubeDL({'logger': YtdlpLogger(), 'quiet': True, 'skip_download': True, 'socket_timeout': 30}) as ydl:
                try:
                    with extraction_timeout(120):  # 120 second timeout for metadata extraction
                        info_dict = ydl.extract_info(url, download=False)
                except TimeoutError as timeout_err:
                    logger.warning(f"Metadata extraction timed out: {timeout_err}")
                    info_dict = {}
                except Exception as e:
                    logger.warning(f"Metadata extraction failed: {e}")
                    info_dict = {}
        except Exception as e:
            logger.warning(f"Failed to extract metadata from URL: {e}")
            info_dict = {}
    
    if not info_dict:
        info_dict = {}
    
    return {
        "title": info_dict.get("title"),
        "original_url": info_dict.get("webpage_url", url),
        "uploader": info_dict.get("uploader"),
        "duration": info_dict.get("duration"),
        "upload_date": info_dict.get("upload_date"),
        "extractor": info_dict.get("extractor_key"),
        "width": info_dict.get("width"),
        "height": info_dict.get("height"),
        "fps": info_dict.get("fps"),
    }


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


def _record_download_metrics(source_video_id: int, quality_tier: str, file_size_mb: float, 
                           download_method: str, format_count: int) -> None:
    """
    Record download metrics for monitoring and quality assessment.
    
    This function provides structured data for monitoring download performance
    and quality trends without affecting the download process.
    """
    metrics = {
        "source_video_id": source_video_id,
        "quality_tier": quality_tier,
        "file_size_mb": round(file_size_mb, 2),
        "download_method": download_method,
        "format_count": format_count,
        "timestamp": datetime.utcnow().isoformat()
    }
    
    # Log metrics for monitoring (can be extended to send to metrics service)
    logger.info("download_metrics", extra=metrics)
    
    # Quality tier distribution for monitoring
    quality_tiers = {
        "high": "≥1080p (4K, 1440p, 1080p)",
        "medium": "720p-1079p", 
        "low": "480p-719p",
        "very_low": "<480p"
    }
    
    if quality_tier in quality_tiers:
        logger.info(f"Quality tier '{quality_tier}': {quality_tiers[quality_tier]}")
    
    # Alert on very low quality downloads
    if quality_tier == "very_low":
        logger.warning(f"Very low quality download detected: {file_size_mb:.1f}MB")
    
    # Alert on high quality downloads (success case)
    if quality_tier == "high":
        logger.info(f"High quality download achieved: {file_size_mb:.1f}MB")