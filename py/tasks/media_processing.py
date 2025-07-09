"""
Media Processing Module for Ingest Task

Handles FFmpeg operations including:
- Video metadata extraction
- Video transcoding with progress reporting
- FFmpeg/FFprobe validation
"""

import json
import logging
import subprocess
from pathlib import Path
from typing import Dict, Any

logger = logging.getLogger(__name__)

# FFmpeg configuration
FINAL_SUFFIX = "_qt"
FFMPEG_ARGS = [
    "-map", "0", "-c:v:0", "libx264", "-preset", "fast", "-crf", "20",
    "-pix_fmt", "yuv420p", "-c:a:0", "aac", "-b:a", "192k", "-c:s", "mov_text",
    "-c:d", "copy", "-c:v:1", "copy", "-movflags", "+faststart", "-y"  # Add -y flag for overwrite
]


def validate_ffmpeg_available() -> bool:
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
        return True
    except (subprocess.TimeoutExpired, FileNotFoundError, subprocess.SubprocessError) as e:
        raise RuntimeError(f"FFmpeg validation failed: {e}")


def validate_ffprobe_available() -> bool:
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
        return True
    except (subprocess.TimeoutExpired, FileNotFoundError, subprocess.SubprocessError) as e:
        raise RuntimeError(f"FFprobe validation failed: {e}")


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


def extract_video_metadata(video_path: Path) -> Dict[str, Any]:
    """Extract video metadata using ffprobe"""
    try:
        cmd = [
            "ffprobe", "-v", "quiet", "-print_format", "json", "-show_format", "-show_streams",
            str(video_path)
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        data = json.loads(result.stdout)
        
        # Find video stream
        video_stream = next((s for s in data["streams"] if s["codec_type"] == "video"), None)
        
        if not video_stream:
            return {}
        
        # Parse frame rate safely (replacing eval usage)
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


def re_encode_video(input_path: Path, temp_dir: Path) -> Path:
    """Re-encode video for QuickTime compatibility with progress reporting"""
    output_path = temp_dir / f"{input_path.stem}{FINAL_SUFFIX}.mp4"
    
    # Get video duration for progress calculation
    duration = get_video_duration(input_path)
    
    cmd = ["ffmpeg", "-i", str(input_path)] + FFMPEG_ARGS + [str(output_path)]
    
    logger.info(f"Re-encoding video: {' '.join(cmd)}")
    logger.info(f"Video duration: {duration:.2f} seconds")
    
    # Run FFmpeg with progress monitoring
    success = run_ffmpeg_with_progress(cmd, duration, "Transcode")
    
    if not success:
        raise RuntimeError("FFmpeg transcode failed")
    
    if not output_path.exists():
        raise RuntimeError(f"Output file was not created: {output_path}")
    
    return output_path


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
        
        progress_parser = FFmpegProgressParser(duration, operation_name, logger)
        
        # Read stderr for progress updates
        while process.poll() is None:
            line = process.stderr.readline()
            if line:
                progress_parser.parse_line(line.strip())
        
        # Read any remaining output
        remaining_stderr = process.stderr.read()
        if remaining_stderr:
            for line in remaining_stderr.strip().split('\n'):
                if line:
                    progress_parser.parse_line(line.strip())
        
        return_code = process.wait()
        
        if return_code == 0:
            logger.info(f"{operation_name}: Completed successfully")
            return True
        else:
            # Read stdout for error details
            stdout_output = process.stdout.read() if process.stdout else ""
            logger.error(f"{operation_name}: FFmpeg failed with return code {return_code}")
            if stdout_output:
                logger.error(f"{operation_name}: FFmpeg stdout: {stdout_output}")
            return False
            
    except Exception as e:
        logger.error(f"{operation_name}: Exception running FFmpeg: {e}")
        return False


class FFmpegProgressParser:
    """Parser for FFmpeg progress output"""
    
    def __init__(self, duration: float, operation_name: str, logger_instance, throttle_percentage: int = 5):
        self.duration = duration
        self.operation_name = operation_name
        self.logger = logger_instance
        self.throttle_percentage = max(1, min(int(throttle_percentage), 100))
        self.last_logged_percentage = -1
        self.current_time = 0.0
        
    def parse_line(self, line: str):
        """Parse a single line of FFmpeg progress output"""
        try:
            # FFmpeg progress format: "key=value"
            if "=" in line:
                key, value = line.split("=", 1)
                key = key.strip()
                value = value.strip()
                
                if key == "out_time_ms":
                    # Convert microseconds to seconds
                    try:
                        time_ms = int(value)
                        self.current_time = time_ms / 1000000.0
                        self._report_progress()
                    except ValueError:
                        pass
                elif key == "out_time":
                    # Time format: HH:MM:SS.mmm
                    try:
                        self.current_time = self._parse_time_string(value)
                        self._report_progress()
                    except ValueError:
                        pass
                        
        except Exception as e:
            # Don't let progress parsing errors break the encoding
            pass
    
    def _parse_time_string(self, time_str: str) -> float:
        """Parse time string in format HH:MM:SS.mmm to seconds"""
        parts = time_str.split(":")
        if len(parts) == 3:
            hours = float(parts[0])
            minutes = float(parts[1])
            seconds = float(parts[2])
            return hours * 3600 + minutes * 60 + seconds
        return 0.0
    
    def _report_progress(self):
        """Report progress if threshold is met"""
        if self.duration <= 0:
            return
            
        current_percentage = int((self.current_time / self.duration) * 100)
        current_percentage = min(current_percentage, 100)  # Cap at 100%
        
        should_log = (
            current_percentage >= self.last_logged_percentage + self.throttle_percentage
            and current_percentage < 100
        ) or (current_percentage == 100 and self.last_logged_percentage != 100)
        
        if should_log:
            self.logger.info(
                f"{self.operation_name}: {current_percentage}% complete "
                f"({self.current_time:.1f}/{self.duration:.1f}s)"
            )
            self.last_logged_percentage = current_percentage