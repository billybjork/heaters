"""
Preprocess Task for Video Pipeline

Handles creation of transcoded outputs from original source videos:
1. Master - lossless MKV + FFV1 for archival storage
2. Proxy - all-I-frame H.264 MP4 for efficient seeking and export
3. Keyframe offsets - byte positions for efficient seeking

This is the main transcoding step that creates all necessary video formats
from the original video files stored by the download task.
"""

import json
import logging
import shutil
import subprocess
from pathlib import Path
from typing import Dict, Any, List, Tuple
import tempfile
import os

logger = logging.getLogger(__name__)

# FFmpeg arguments are now provided by Elixir FFmpegConfig
# This eliminates hardcoded settings and centralizes configuration


def run_preprocess(source_video_path: str, source_video_id: int, video_title: str, 
                  master_args: list, proxy_args: list, use_temp_cache: bool = False,
                  skip_master: bool = False, reuse_as_proxy: bool = False, **kwargs) -> Dict[str, Any]:
    """
    Create master and proxy from original source video.
    
    This is the main transcoding step that processes original videos 
    (stored by ingest task) into the required output formats.
    
    Args:
        source_video_path: S3 path to original source video (from download task)
        source_video_id: Database ID of the source video
        video_title: Title for generating output filenames
        master_args: FFmpeg arguments for master encoding (from FFmpegConfig)
        proxy_args: FFmpeg arguments for proxy encoding (from FFmpegConfig)
        use_temp_cache: If True, cache files locally instead of uploading to S3 immediately
        skip_master: If True, skip master file generation for cost optimization
        reuse_as_proxy: If True, try to reuse source as proxy if compatible
        
    Returns:
        {
            "status": "success",
            "master_path": "masters/video_123_master.mkv",
            "proxy_path": "review_proxies/video_123_proxy.mp4", 
            "keyframe_offsets": [0, 150, 300, ...],
            "metadata": {
                "duration_seconds": 1800.0,
                "fps": 29.97,
                "width": 1920,
                "height": 1080
            }
        }
    """
    
    try:
        logger.info(f"Starting preprocess for video {source_video_id}: {video_title}")
        
        # Validate FFmpeg availability
        validate_ffmpeg_available()
        
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_dir_path = Path(temp_dir)
            
            # Get source video (from cache or S3)
            if Path(source_video_path).exists():
                # Source is already a local file (from temp cache)
                logger.info(f"Using cached source video: {source_video_path}")
                local_source_path = Path(source_video_path)
            else:
                # Source is S3 path - download it
                logger.info(f"Downloading source video from S3: {source_video_path}")
                local_source_path = temp_dir_path / "source.mp4"
                download_from_s3(source_video_path, local_source_path)
            
            # Extract metadata from source
            metadata = extract_video_metadata(local_source_path)
            logger.info(f"Source video metadata: {metadata}")
            
            # Generate output paths
            sanitized_title = sanitize_filename(video_title)
            master_s3_key = f"masters/{sanitized_title}_{source_video_id}_master.mkv"
            proxy_s3_key = f"proxies/{sanitized_title}_{source_video_id}_proxy.mp4"
            
            # Handle proxy creation/reuse
            if reuse_as_proxy:
                logger.info("Attempting to reuse source file as proxy")
                # Copy source file as proxy (smart reuse optimization)
                proxy_local = temp_dir_path / "proxy.mp4"
                shutil.copy2(local_source_path, proxy_local)
                # Still extract keyframes from the proxy
                keyframe_offsets = extract_keyframe_offsets(proxy_local)
            else:
                # Create proxy (all I-frame)
                proxy_local = temp_dir_path / "proxy.mp4"
                keyframe_offsets = create_proxy(local_source_path, proxy_local, metadata, proxy_args)
            
            # Handle master creation
            master_local = None
            if not skip_master:
                master_local = temp_dir_path / "master.mkv"
                create_master(local_source_path, master_local, metadata, master_args)
            
            # Handle upload vs temp cache
            if use_temp_cache:
                # Create cache directory
                cache_dir = Path(tempfile.gettempdir()) / "heaters_preprocess_cache"
                cache_dir.mkdir(exist_ok=True)
                
                # Cache proxy file
                proxy_cache_filename = proxy_s3_key.replace("/", "_").replace("\\", "_")
                proxy_cached_path = cache_dir / proxy_cache_filename
                shutil.copy2(proxy_local, proxy_cached_path)
                logger.info(f"Cached proxy to: {proxy_cached_path}")
                
                # Cache master file if generated
                master_cached_path = None
                if master_local and master_local.exists():
                    master_cache_filename = master_s3_key.replace("/", "_").replace("\\", "_")
                    master_cached_path = cache_dir / master_cache_filename
                    shutil.copy2(master_local, master_cached_path)
                    logger.info(f"Cached master to: {master_cached_path}")
                
                # Return with local paths
                result = {
                    "status": "success",
                    "proxy_path": proxy_s3_key,  # Future S3 path
                    "proxy_local_path": str(proxy_cached_path),  # Current local path
                    "keyframe_offsets": keyframe_offsets,
                    "metadata": metadata
                }
                
                if master_cached_path:
                    result["master_path"] = master_s3_key  # Future S3 path
                    result["master_local_path"] = str(master_cached_path)  # Current local path
                    
                return result
                
            else:
                # Traditional approach: upload to S3 immediately
                upload_to_s3(proxy_local, proxy_s3_key, storage_class="STANDARD")
                
                if master_local and master_local.exists():
                    upload_to_s3(master_local, master_s3_key, storage_class="GLACIER")
                
                # Return success result
                result = {
                    "status": "success",
                    "proxy_path": proxy_s3_key,
                    "keyframe_offsets": keyframe_offsets,
                    "metadata": metadata
                }
                
                if master_local and master_local.exists():
                    result["master_path"] = master_s3_key
                    
                return result
            
    except Exception as e:
        logger.error(f"Preprocess failed for video {source_video_id}: {e}")
        return {
            "status": "error",
            "error": str(e),
            "metadata": {"source_video_id": source_video_id}
        }


def validate_ffmpeg_available() -> None:
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


def validate_ffprobe_available() -> None:
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


def extract_video_metadata(video_path: Path) -> Dict[str, Any]:
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
        fps = parse_frame_rate(video_stream.get("r_frame_rate", "0/1"))
            
        return {
            "duration_seconds": float(data["format"].get("duration", 0)),
            "fps": fps,
            "width": video_stream.get("width"),
            "height": video_stream.get("height")
        }
    except Exception as e:
        logger.warning(f"Failed to extract metadata: {e}")
        return {}


def parse_frame_rate(fps_str: str) -> float:
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


def create_master(source_path: Path, output_path: Path, metadata: Dict[str, Any], master_args: list) -> None:
    """Create lossless master for archival storage"""
    logger.info(f"Creating master: {output_path}")
    
    cmd = ["ffmpeg", "-i", str(source_path)] + master_args + ["-y", str(output_path)]
    
    duration = metadata.get("duration_seconds", 0)
    success = run_ffmpeg_with_progress(cmd, duration, "Master Creation")
    
    if not success:
        raise RuntimeError("Failed to create master")
    
    if not output_path.exists():
        raise RuntimeError(f"Master file was not created: {output_path}")
    
    logger.info(f"Master created successfully: {output_path.stat().st_size} bytes")


def create_proxy(source_path: Path, output_path: Path, metadata: Dict[str, Any], proxy_args: list) -> List[int]:
    """Create all-I-frame proxy and extract keyframe offsets"""
    logger.info(f"Creating proxy: {output_path}")
    
    cmd = ["ffmpeg", "-i", str(source_path)] + proxy_args + ["-y", str(output_path)]
    
    duration = metadata.get("duration_seconds", 0)
    success = run_ffmpeg_with_progress(cmd, duration, "Proxy Creation")
    
    if not success:
        raise RuntimeError("Failed to create proxy")
    
    if not output_path.exists():
        raise RuntimeError(f"Proxy file was not created: {output_path}")
    
    logger.info(f"Proxy created successfully: {output_path.stat().st_size} bytes")
    
    # Extract keyframe offsets for efficient seeking
    keyframe_offsets = extract_keyframe_offsets(output_path)
    logger.info(f"Extracted {len(keyframe_offsets)} keyframe offsets")
    
    return keyframe_offsets


def extract_keyframe_offsets(video_path: Path) -> List[int]:
    """Extract byte offsets of keyframes for efficient seeking"""
    try:
        cmd = [
            "ffprobe", "-v", "quiet", "-select_streams", "v:0",
            "-show_entries", "frame=key_frame,pkt_pos",
            "-print_format", "json", str(video_path)
        ]
        
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        data = json.loads(result.stdout)
        
        offsets = []
        for frame in data.get("frames", []):
            if frame.get("key_frame") == 1:  # key_frame is 1 for keyframes, 0 for non-keyframes
                pos = frame.get("pkt_pos")
                if pos and pos != "N/A":
                    try:
                        offsets.append(int(pos))
                    except (ValueError, TypeError):
                        # Skip invalid positions
                        continue
        
        logger.info(f"Successfully extracted {len(offsets)} keyframe offsets from {video_path}")
        return sorted(offsets)
        
    except subprocess.CalledProcessError as e:
        logger.warning(f"ffprobe failed to extract keyframe offsets: {e}")
        return []
    except json.JSONDecodeError as e:
        logger.warning(f"Failed to parse ffprobe JSON output: {e}")
        return []
    except Exception as e:
        logger.warning(f"Failed to extract keyframe offsets: {e}")
        return []


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


def sanitize_filename(filename: str) -> str:
    """Sanitize filename for safe storage"""
    # Replace problematic characters with underscores
    import re
    sanitized = re.sub(r'[^a-zA-Z0-9_\-\.]', '_', filename)
    # Remove multiple consecutive underscores
    sanitized = re.sub(r'_+', '_', sanitized)
    # Trim underscores from ends
    return sanitized.strip('_')[:100]  # Limit length


def download_from_s3(s3_path: str, local_path: Path) -> None:
    """Download file from S3 to local path using centralized S3 handler"""
    from utils.s3_handler import get_s3_config, download_from_s3 as s3_download
    
    s3_client, bucket_name = get_s3_config()
    s3_download(s3_client, bucket_name, s3_path, local_path)


def upload_to_s3(local_path: Path, s3_key: str, storage_class: str = "STANDARD") -> None:
    """Upload local file to S3 using centralized S3 handler with optimized transfer settings"""
    from utils.s3_handler import get_s3_config, get_transfer_config, upload_to_s3 as s3_upload
    
    s3_client, bucket_name = get_s3_config()
    transfer_config = get_transfer_config()  # Fresh config for each upload
    s3_upload(s3_client, bucket_name, local_path, s3_key, storage_class, transfer_config) 