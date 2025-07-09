"""
Download Handler Module for Ingest Task

Handles video downloading with yt-dlp including:
- Sophisticated fallback download strategy
- Progress reporting
- Metadata extraction
- Error handling and retries
"""

import logging
import os
import shutil
from pathlib import Path
from typing import Dict, Any, Optional

import yt_dlp

logger = logging.getLogger(__name__)


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


def download_from_url(url: str, temp_dir: Path) -> Path:
    """Download video from URL using yt-dlp with quality-focused strategy and fallback"""
    output_template = str(temp_dir / "%(title)s.%(ext)s")
    
    # Define format preferences with fallback strategy
    format_primary = 'bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b'
    format_fallback = 'bestvideo[ext=mp4][vcodec^=avc1]+bestaudio[ext=m4a]/best[ext=mp4]/best'
    
    base_ydl_opts = {
        'outtmpl': output_template,
        'merge_output_format': 'mp4',  # Ensure merged output is mp4
        'logger': YtdlpLogger(),
        'nocheckcertificate': True,
        'retries': 5,
        'embedmetadata': True,
        'embedthumbnail': True,
        'restrictfilenames': True,
        'ignoreerrors': False,  # Fail on error to trigger fallback
        'socket_timeout': 120,
        'postprocessor_args': {
            'ffmpeg_i': ['-err_detect', 'ignore_err'],
        },
        'fragment_retries': 10,
        'skip_unavailable_fragments': True,
    }

    download_successful = False
    info_dict = None
    video_title = 'Untitled Video'  # Default title
    downloaded_files = []

    def ytdlp_progress_hook(d):
        nonlocal downloaded_files
        if d["status"] == "finished":
            filename = d.get("filename")
            if filename:
                downloaded_files.append(filename)
                logger.info(f"yt-dlp hook: Download finished. File at: {filename}")
        elif d["status"] == "downloading":
            progress_str = d.get("_percent_str", "N/A")
            speed_str = d.get("_speed_str", "N/A")
            eta_str = d.get("_eta_str", "N/A")
            logger.info(f"yt-dlp progress: {progress_str} | Speed: {speed_str} | ETA: {eta_str}")

    # Attempt 1: Primary (Best Quality) Format
    logger.info(f"yt-dlp: Attempt 1 - Using primary format: '{format_primary}'")
    ydl_opts_primary = {**base_ydl_opts, 'format': format_primary, 'progress_hooks': [ytdlp_progress_hook]}

    try:
        with yt_dlp.YoutubeDL(ydl_opts_primary) as ydl:
            logger.info(f"Extracting info (Attempt 1) for {url}...")
            temp_info_dict = ydl.extract_info(url, download=False)
            video_title = temp_info_dict.get('title', video_title)

            logger.info(f"Downloading video (Attempt 1): '{video_title}'...")
            ydl.download([url])

        # Find downloaded files
        final_files = [f for f in downloaded_files if os.path.exists(f)]
        if not final_files:
            for file in os.listdir(temp_dir):
                if file.lower().endswith(('.mp4', '.mkv', '.webm', '.avi')):
                    final_files.append(os.path.join(temp_dir, file))

        if not final_files:
            raise FileNotFoundError("yt-dlp (Attempt 1) finished but no output file found.")

        # Use the largest file (likely the merged result)
        initial_temp_filepath = max(final_files, key=os.path.getsize)

        # Re-extract info for metadata accuracy
        with yt_dlp.YoutubeDL({'logger': YtdlpLogger(), 'quiet': True, 'skip_download': True}) as ydl_info:
            info_dict = ydl_info.extract_info(url, download=False)

        download_successful = True
        logger.info("yt-dlp: Download successful with primary format.")

    except yt_dlp.utils.DownloadError as e_primary:
        logger.warning(f"yt-dlp: Primary download attempt failed: {e_primary}. Trying fallback.")
        # Clean up temp directory before fallback
        _cleanup_temp_directory(temp_dir)
        # Reset tracking variables
        downloaded_files = []

    except Exception as e_generic_primary:
        logger.error(f"yt-dlp: Unexpected error during primary download: {e_generic_primary}")
        logger.warning("Proceeding to fallback attempt despite unexpected error.")
        # Clean up and reset
        _cleanup_temp_directory(temp_dir)
        downloaded_files = []

    # Attempt 2: Fallback (More Compatible) Format
    if not download_successful:
        logger.info(f"yt-dlp: Attempt 2 - Using fallback format: '{format_fallback}'")
        ydl_opts_fallback = {**base_ydl_opts, 'format': format_fallback, 'progress_hooks': [ytdlp_progress_hook]}

        try:
            with yt_dlp.YoutubeDL(ydl_opts_fallback) as ydl:
                logger.info(f"Extracting info (Attempt 2) for {url}...")
                info_dict = ydl.extract_info(url, download=False)
                video_title = info_dict.get('title', video_title)

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

            initial_temp_filepath = max(final_files, key=os.path.getsize)
            download_successful = True
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
            with yt_dlp.YoutubeDL({'logger': YtdlpLogger(), 'quiet': True, 'skip_download': True}) as ydl_final:
                info_dict = ydl_final.extract_info(url, download=False)
        except Exception as final_info_err:
            logger.error(f"Failed to fetch final metadata: {final_info_err}")
            info_dict = {}

    logger.info(f"Using final file: {initial_temp_filepath}")
    
    if not os.path.exists(initial_temp_filepath):
        raise RuntimeError(f"Selected output file does not exist: {initial_temp_filepath}")

    return Path(initial_temp_filepath)


def extract_download_metadata(url: str, info_dict: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """Extract metadata from yt-dlp info dict or by fetching it"""
    if info_dict is None:
        try:
            with yt_dlp.YoutubeDL({'logger': YtdlpLogger(), 'quiet': True, 'skip_download': True}) as ydl:
                info_dict = ydl.extract_info(url, download=False)
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