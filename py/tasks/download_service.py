"""
Download Service - High-level interface for video downloads.

This service wraps the existing download functionality to provide a cleaner interface
while preserving all existing logic and functionality.
"""

import logging
from pathlib import Path
from typing import Dict, Any, Optional

from .download_handler import download_from_url, extract_download_metadata
from .download import normalize_video, DownloadError, NormalizationError

logger = logging.getLogger(__name__)


class DownloadService:
    """
    High-level service for video downloads with quality-focused strategy.
    
    This service provides a clean interface to the download functionality
    while preserving all existing logic and quality requirements.
    """
    
    def __init__(self, ffmpeg_config: Optional[Dict[str, Any]] = None):
        """
        Initialize the download service.
        
        Args:
            ffmpeg_config: Optional FFmpeg configuration for normalization
        """
        self.ffmpeg_config = ffmpeg_config or {}
    
    def download_video(self, url: str, temp_dir: Path, 
                      source_video_id: Optional[int] = None) -> Dict[str, Any]:
        """
        Download a video with quality-focused strategy.
        
        This method orchestrates the download process using the existing
        download_handler.py implementation, preserving all quality requirements.
        
        Args:
            url: Video URL to download
            temp_dir: Temporary directory for downloads
            source_video_id: Optional source video ID for logging
            
        Returns:
            Dict containing download result with metadata
            
        Raises:
            DownloadError: If yt-dlp download fails
            NormalizationError: If FFmpeg normalization fails
        """
        try:
            # Use existing download_handler implementation
            downloaded_path, download_info_dict = download_from_url(url, temp_dir)
            
            # Extract metadata using existing function
            metadata = extract_download_metadata(url, download_info_dict)
            
            # Add source_video_id to metadata if provided
            if source_video_id:
                metadata['source_video_id'] = source_video_id
            
            # Handle normalization if needed (using existing logic)
            requires_normalization = download_info_dict.get('requires_normalization', False)
            download_method = download_info_dict.get('download_method', 'unknown')
            
            if requires_normalization:
                logger.info(f"Primary download method detected - applying normalization")
                normalized_path = temp_dir / f"normalized_{downloaded_path.name}"
                
                try:
                    normalize_args = self.ffmpeg_config.get('normalize_args')
                    if normalize_video(downloaded_path, normalized_path, normalize_args):
                        final_path = normalized_path
                        metadata['normalized'] = True
                        logger.info("Primary download normalization completed successfully")
                    else:
                        logger.warning("Normalization failed, proceeding with original download")
                        final_path = downloaded_path
                        metadata['normalized'] = False
                except NormalizationError as e:
                    logger.warning(f"Normalization failed: {e}, proceeding with original download")
                    final_path = downloaded_path
                    metadata['normalized'] = False
            else:
                logger.info(f"Fallback download method detected - no normalization needed")
                final_path = downloaded_path
                metadata['normalized'] = False
            
            metadata['download_method'] = download_method
            metadata['final_path'] = str(final_path)
            
            return {
                'status': 'success',
                'metadata': metadata,
                'file_path': str(final_path)
            }
            
        except Exception as e:
            logger.error(f"Download service failed: {e}")
            if isinstance(e, (DownloadError, NormalizationError)):
                raise
            raise DownloadError(f"Download service failed: {e}")
    
    def get_download_info(self, url: str) -> Dict[str, Any]:
        """
        Get download information without downloading.
        
        This method provides information about available formats and quality
        without performing the actual download.
        
        Args:
            url: Video URL to analyze
            
        Returns:
            Dict containing format information
        """
        try:
            # This would require a separate method in download_handler.py
            # For now, we'll use the existing extract_download_metadata
            metadata = extract_download_metadata(url)
            return {
                'status': 'info_only',
                'metadata': metadata
            }
        except Exception as e:
            logger.error(f"Failed to get download info: {e}")
            raise DownloadError(f"Failed to get download info: {e}")


# Convenience function for backward compatibility
def create_download_service(ffmpeg_config: Optional[Dict[str, Any]] = None) -> DownloadService:
    """
    Create a download service instance.
    
    Args:
        ffmpeg_config: Optional FFmpeg configuration
        
    Returns:
        DownloadService instance
    """
    return DownloadService(ffmpeg_config) 