"""
Refactored Sprite Task - "Dumber" Python focused on sprite sheet generation only.

This version:
- Receives explicit S3 paths and sprite parameters from Elixir
- Focuses only on sprite sheet generation using FFmpeg
- Returns structured data about sprite artifacts instead of managing database state
- No database connections or state management
"""

import argparse
import json
import logging
import math
import os
import re
import shutil
import subprocess
import tempfile
import threading
from datetime import datetime
from pathlib import Path

import boto3
from botocore.exceptions import ClientError, NoCredentialsError
from utils import sanitize_filename
from utils.process_utils import run_ffmpeg_command, run_ffprobe_command

# --- Logging Configuration ---
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

# --- Task Configuration ---
SPRITE_TILE_WIDTH = 480
SPRITE_TILE_HEIGHT = -1  # -1 preserves aspect ratio
SPRITE_FPS = 24
SPRITE_COLS = 5
JPEG_QUALITY = 3  # FFmpeg qscale:v value (lower = better quality)

class S3TransferProgress:
    """Callback for boto3 reporting progress via logger"""
    
    def __init__(self, total_size, filename, logger_instance, throttle_percentage=25):
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





def get_video_metadata(video_path: str) -> dict:
    """Extracts detailed video metadata using ffprobe."""
    logger.info(f"Probing video metadata: {video_path}")
    
    ffprobe_cmd = [
        "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=duration,r_frame_rate,nb_frames",
        "-count_frames", "-of", "json", str(video_path)
    ]
    
    stdout, _ = run_ffprobe_command(ffprobe_cmd, "FFprobe for video metadata")
    
    try:
        probe_data_list = json.loads(stdout).get('streams', [])
        if not probe_data_list:
            raise ValueError(f"ffprobe found no video streams in {video_path}")
        
        probe_data = probe_data_list[0]
        logger.debug(f"ffprobe result: {probe_data}")

        # Extract duration
        duration_str = probe_data.get('duration')
        if duration_str:
            duration = float(duration_str)
        else:
            raise ValueError("Could not determine video duration")

        # Extract frame rate
        fps_str = probe_data.get('r_frame_rate', '0/1')
        if '/' in fps_str:
            num_str, den_str = fps_str.split('/')
            num, den = int(num_str), int(den_str)
            if den > 0:
                fps = num / den
            else:
                raise ValueError("Invalid frame rate denominator")
        else:
            fps = float(fps_str)

        # Extract total frames
        nb_frames_str = probe_data.get('nb_frames')
        if nb_frames_str:
            total_frames = int(nb_frames_str)
            logger.info(f"Using ffprobe nb_frames: {total_frames}")
        else:
            # Calculate from duration and fps
            total_frames = math.ceil(duration * fps)
            logger.info(f"Calculated total frames from duration*fps: {total_frames}")

        if duration <= 0 or fps <= 0 or total_frames <= 0:
            raise ValueError(f"Invalid video metadata: duration={duration:.3f}s, fps={fps:.3f}, frames={total_frames}")
        
        return {
            "duration": duration,
            "fps": fps,
            "total_frames": total_frames
        }

    except (json.JSONDecodeError, KeyError, ValueError, TypeError) as e:
        logger.error(f"Failed to parse video metadata: {e}")
        raise ValueError(f"Video metadata parsing failed: {e}")

def generate_sprite_sheet(
    video_path: str,
    output_path: Path,
    clip_identifier: str,
    sprite_params: dict
) -> dict:
    """
    Generates a sprite sheet from a video file.
    Returns metadata about the generated sprite sheet.
    """
    # Get sprite parameters
    tile_width = sprite_params.get("tile_width", SPRITE_TILE_WIDTH)
    tile_height = sprite_params.get("tile_height", SPRITE_TILE_HEIGHT)
    sprite_fps = sprite_params.get("fps", SPRITE_FPS)
    cols = sprite_params.get("cols", SPRITE_COLS)
    
    # Get video metadata
    metadata = get_video_metadata(str(video_path))
    duration = metadata["duration"]
    video_fps = metadata["fps"]
    
    # Calculate sprite parameters using video's native FPS
    effective_sprite_fps = min(video_fps, sprite_fps)  # Don't exceed video's native FPS
    num_sprite_frames = math.ceil(duration * effective_sprite_fps)
    
    if num_sprite_frames <= 0:
        raise ValueError(f"Video too short for sprite generation: {duration:.3f}s")
    
    # Generate output filename
    base_filename = sanitize_filename(f"{clip_identifier}_sprite")
    timestamp = datetime.now().strftime("%Y%m%d%H%M%S")
    output_filename = f"{base_filename}_{effective_sprite_fps}fps_w{tile_width}_c{cols}_{timestamp}.jpg"
    final_output_path = output_path / output_filename
    
    # Calculate grid dimensions
    num_rows = max(1, math.ceil(num_sprite_frames / cols))
    
    # Build FFmpeg video filter
    vf_option = f"fps={effective_sprite_fps},scale={tile_width}:{tile_height}:flags=neighbor,tile={cols}x{num_rows}"
    
    # Generate sprite sheet using FFmpeg
    ffmpeg_cmd = [
        "-y", "-i", str(video_path),
        "-vf", vf_option,
        "-an",  # No audio
        "-qscale:v", str(JPEG_QUALITY),
        str(final_output_path)
    ]
    
    run_ffmpeg_command(["ffmpeg"] + ffmpeg_cmd, f"Generating sprite sheet")
    
    if not final_output_path.exists():
        raise RuntimeError("Sprite sheet generation failed - output file not created")
    
    # Get file size
    file_size = final_output_path.stat().st_size
    
    logger.info(f"Successfully generated sprite sheet: {output_filename} ({file_size} bytes)")
    
    return {
        "local_path": str(final_output_path),
        "filename": output_filename,
        "file_size": file_size,
        "sprite_metadata": {
            "effective_fps": effective_sprite_fps,
            "num_frames": num_sprite_frames,
            "cols": cols,
            "rows": num_rows,
            "tile_width": tile_width,
            "tile_height": tile_height,
            "video_duration": duration,
            "video_fps": video_fps
        }
    }

def run_sprite(
    clip_id: int,
    input_s3_path: str,
    output_s3_prefix: str,
    overwrite: bool = False,
    **kwargs
):
    """
    Downloads clip video, generates sprite sheet, and uploads to S3.
    Returns structured data about the sprite artifact instead of managing database state.
    
    Args:
        clip_id: The ID of the clip (for reference only)
        input_s3_path: S3 path to the clip video file
        output_s3_prefix: S3 prefix where to upload sprite sheet
        overwrite: Whether to overwrite existing sprites (for compatibility)
        **kwargs: Additional sprite parameters
    
    Returns:
        dict: Structured data about the sprite artifact including S3 key and metadata
    """
    logger.info(f"RUNNING SPRITE for clip_id: {clip_id}")
    logger.info(f"Input: {input_s3_path}, Output prefix: {output_s3_prefix}, Overwrite: {overwrite}")
    
    # Extract sprite parameters from kwargs
    sprite_params = {
        "tile_width": kwargs.get("tile_width", SPRITE_TILE_WIDTH),
        "tile_height": kwargs.get("tile_height", SPRITE_TILE_HEIGHT),
        "fps": kwargs.get("sprite_fps", SPRITE_FPS),
        "cols": kwargs.get("cols", SPRITE_COLS)
    }
    
    # Get S3 resources from environment (provided by Elixir)
    s3_bucket_name = os.getenv("S3_BUCKET_NAME")
    if not s3_bucket_name:
        raise ValueError("S3_BUCKET_NAME environment variable not set")

    try:
        s3_client = boto3.client("s3")
    except NoCredentialsError:
        logger.error("S3 credentials not found")
        raise

    # Check dependencies
    if not shutil.which("ffmpeg"):
        raise FileNotFoundError("ffmpeg not found in PATH")
    if not shutil.which("ffprobe"):
        raise FileNotFoundError("ffprobe not found in PATH")

    with tempfile.TemporaryDirectory() as temp_dir:
        temp_dir_path = Path(temp_dir)
        
        try:
            # Step 1: Download clip video from S3
            local_video_path = temp_dir_path / Path(input_s3_path).name
            logger.info(f"Downloading s3://{s3_bucket_name}/{input_s3_path} to {local_video_path}")
            s3_client.download_file(s3_bucket_name, input_s3_path, str(local_video_path))

            # Step 2: Generate sprite sheet
            clip_identifier = f"clip_{clip_id}"
            sprite_result = generate_sprite_sheet(
                str(local_video_path),
                temp_dir_path,
                clip_identifier,
                sprite_params
            )

            # Step 3: Upload sprite sheet to S3
            s3_key = f"{output_s3_prefix}/{sprite_result['filename']}"
            local_path = sprite_result['local_path']
            file_size = sprite_result['file_size']
            
            progress_callback = S3TransferProgress(file_size, sprite_result['filename'], logger)
            
            logger.info(f"Uploading {local_path} to s3://{s3_bucket_name}/{s3_key}")
            s3_client.upload_file(
                local_path,
                s3_bucket_name,
                s3_key,
                Callback=progress_callback
            )

            # Return structured data for Elixir to process
            return {
                "status": "success",
                "artifacts": [{
                    "artifact_type": "sprite_sheet",
                    "s3_key": s3_key,
                    "metadata": {
                        "file_size": file_size,
                        "filename": sprite_result['filename'],
                        **sprite_result['sprite_metadata']
                    }
                }],
                "metadata": {
                    "clip_id": clip_id,
                    "sprite_generated": True
                }
            }

        except Exception as e:
            logger.error(f"Error processing sprite: {e}")
            raise

def main():
    """Main entry point for standalone execution"""
    parser = argparse.ArgumentParser(description="Sprite sheet generation task")
    parser.add_argument("--clip-id", type=int, required=True)
    parser.add_argument("--input-s3-path", required=True)
    parser.add_argument("--output-s3-prefix", required=True)
    parser.add_argument("--overwrite", action="store_true", default=False)
    parser.add_argument("--tile-width", type=int, default=SPRITE_TILE_WIDTH)
    parser.add_argument("--sprite-fps", type=int, default=SPRITE_FPS)
    parser.add_argument("--cols", type=int, default=SPRITE_COLS)
    
    args = parser.parse_args()
    
    try:
        result = run_sprite(
            args.clip_id,
            args.input_s3_path,
            args.output_s3_prefix,
            args.overwrite,
            tile_width=args.tile_width,
            sprite_fps=args.sprite_fps,
            cols=args.cols
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