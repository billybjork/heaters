"""
Export Clips Task for Video Pipeline

Handles final export of virtual clips to physical clips using the gold master.
Creates MP4 files optimized for streaming/delivery using FFmpeg.

This is the final stage of the virtual clip pipeline.
"""

import json
import logging
import subprocess
from pathlib import Path
from typing import Dict, Any, List
import tempfile
import os

logger = logging.getLogger(__name__)

# Final clip encoding settings (optimized for streaming/delivery)
FINAL_CLIP_ARGS = [
    "-c:v", "libx264",   # H.264 video codec
    "-preset", "fast",   # Encoding speed vs compression balance
    "-crf", "23",        # Quality setting (18-28 range, 23 is good default)
    "-pix_fmt", "yuv420p", # Pixel format for compatibility
    "-c:a", "aac",       # Audio codec
    "-b:a", "128k",      # Audio bitrate (lower than proxy since these are clips)
    "-movflags", "+faststart", # Web optimization
    "-avoid_negative_ts", "make_zero", # Avoid timestamp issues
    "-f", "mp4"          # MP4 container
]


def run_export_clips(gold_master_path: str, clips_data: list, source_video_id: int, video_title: str, **kwargs) -> Dict[str, Any]:
    """
    Export final clips from gold master using approved virtual cut points
    
    Args:
        gold_master_path: S3 path to lossless gold master file
        clips_data: List of clip data with cut points
        source_video_id: Database ID of the source video
        video_title: Title for generating output filenames
        
    Returns:
        {
            "status": "success", 
            "exported_clips": [
                {"clip_id": 123, "output_path": "final_clips/clip_001.mp4", "duration": 5.2},
                ...
            ],
            "metadata": {...}
        }
    """
    
    try:
        logger.info(f"Starting export for {len(clips_data)} clips from source_video_id: {source_video_id}")
        
        # Validate FFmpeg availability
        validate_ffmpeg_available()
        
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_dir_path = Path(temp_dir)
            
            # Download gold master
            local_gold_master = temp_dir_path / "gold_master.mkv"
            download_from_s3(gold_master_path, local_gold_master)
            
            # Extract video metadata from gold master
            metadata = extract_video_metadata(local_gold_master)
            logger.info(f"Gold master metadata: {metadata}")
            
            # Export all clips
            exported_clips = []
            for clip_data in clips_data:
                try:
                    exported_clip = export_single_clip(
                        local_gold_master, 
                        clip_data, 
                        temp_dir_path, 
                        video_title, 
                        metadata
                    )
                    exported_clips.append(exported_clip)
                except Exception as e:
                    logger.error(f"Failed to export clip {clip_data['clip_id']}: {e}")
                    return {
                        "status": "error",
                        "error": f"Failed to export clip {clip_data['clip_id']}: {str(e)}"
                    }
            
            logger.info(f"Successfully exported {len(exported_clips)} clips")
            
            return {
                "status": "success",
                "exported_clips": exported_clips,
                "metadata": {
                    "source_video_id": source_video_id,
                    "total_clips_exported": len(exported_clips),
                    "gold_master_metadata": metadata,
                    "export_settings": {
                        "video_codec": "libx264",
                        "audio_codec": "aac",
                        "crf": 23
                    }
                }
            }
            
    except Exception as e:
        logger.error(f"Export failed for source_video_id {source_video_id}: {e}")
        return {
            "status": "error",
            "error": str(e)
        }


def export_single_clip(gold_master_path: Path, clip_data: dict, temp_dir: Path, video_title: str, metadata: dict) -> Dict[str, Any]:
    """Export a single clip from the gold master using cut points"""
    
    clip_id = clip_data["clip_id"]
    clip_identifier = clip_data["clip_identifier"] 
    cut_points = clip_data["cut_points"]
    
    logger.info(f"Exporting clip {clip_id} ({clip_identifier})")
    
    # Extract timing information from cut points
    start_time = cut_points["start_time_seconds"]
    end_time = cut_points["end_time_seconds"]
    duration = end_time - start_time
    
    # Generate output paths
    sanitized_title = sanitize_filename(video_title)
    local_output = temp_dir / f"{clip_identifier}.mp4"
    s3_output_key = f"final_clips/{sanitized_title}_{clip_identifier}.mp4"
    
    # Build FFmpeg command
    cmd = [
        "ffmpeg", "-i", str(gold_master_path),
        "-ss", str(start_time),           # Start time
        "-t", str(duration),              # Duration (not end time)
        "-map", "0",                      # Map all streams
    ] + FINAL_CLIP_ARGS + ["-y", str(local_output)]
    
    logger.debug(f"FFmpeg command: {' '.join(cmd)}")
    
    # Execute FFmpeg
    success = run_ffmpeg_with_progress(cmd, duration, f"Export clip {clip_id}")
    
    if not success:
        raise RuntimeError(f"FFmpeg export failed for clip {clip_id}")
    
    if not local_output.exists():
        raise RuntimeError(f"Output file was not created for clip {clip_id}: {local_output}")
    
    file_size = local_output.stat().st_size
    logger.info(f"Clip {clip_id} exported successfully: {file_size} bytes")
    
    # Upload to S3
    upload_to_s3(local_output, s3_output_key, storage_class="STANDARD")
    
    # Get actual duration from exported file
    actual_duration = get_video_duration(local_output)
    
    return {
        "clip_id": clip_id,
        "output_path": s3_output_key,
        "duration": actual_duration,
        "file_size_bytes": file_size,
        "cut_points_used": cut_points
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
            "height": video_stream.get("height"),
            "codec": video_stream.get("codec_name")
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


def get_video_duration(video_path: Path) -> float:
    """Get video duration in seconds using ffprobe"""
    try:
        cmd = [
            "ffprobe", "-v", "quiet", "-print_format", "json", "-show_format",
            str(video_path)
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        data = json.loads(result.stdout)
        return float(data["format"].get("duration", 0))
    except Exception as e:
        logger.warning(f"Failed to get video duration: {e}")
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
                        if progress > 0 and progress % 25 == 0:  # Log every 25% for clips
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
    from .s3_handler import get_s3_config, download_from_s3 as s3_download
    
    s3_client, bucket_name = get_s3_config()
    s3_download(s3_client, bucket_name, s3_path, local_path)


def upload_to_s3(local_path: Path, s3_key: str, storage_class: str = "STANDARD") -> None:
    """Upload local file to S3 using centralized S3 handler"""
    from .s3_handler import get_s3_config, upload_to_s3 as s3_upload
    
    s3_client, bucket_name = get_s3_config()
    s3_upload(s3_client, bucket_name, local_path, s3_key, storage_class) 