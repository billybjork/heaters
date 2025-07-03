"""
Scene Detection Task - OpenCV-based scene detection for video processing.

This task:
- Downloads source video from S3 
- Performs scene detection using OpenCV histogram comparison
- Caches results to S3 for idempotency
- Returns structured scene data as JSON
- No database connections or state management (follows "dumber Python" pattern)
"""

import json
import logging
import os
import tempfile
from pathlib import Path
from typing import Dict, List, Any, Optional, Tuple

import boto3
import cv2
import numpy as np
from botocore.exceptions import ClientError, NoCredentialsError

# --- Logging Configuration ---
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

# --- OpenCV Histogram Comparison Methods ---
COMPARISON_METHODS = {
    'correl': cv2.HISTCMP_CORREL,
    'chisqr': cv2.HISTCMP_CHISQR, 
    'intersect': cv2.HISTCMP_INTERSECT,
    'bhattacharyya': cv2.HISTCMP_BHATTACHARYYA
}

def run_detect_scenes(
    source_video_path: str,
    source_video_id: int,
    threshold: float = 0.3,
    method: str = "correl", 
    min_duration_seconds: float = 1.0,
    force_redetect: bool = False,
    **kwargs
) -> Dict[str, Any]:
    """
    Detect scene cuts in a video using OpenCV histogram comparison.
    
    Args:
        source_video_path: S3 path to the source video (e.g., 's3://bucket/path/video.mp4')
        source_video_id: ID of the source video (for caching)
        threshold: Similarity threshold for scene detection (0.0-1.0)
        method: Comparison method ('correl', 'chisqr', 'intersect', 'bhattacharyya')
        min_duration_seconds: Minimum scene duration in seconds
        force_redetect: Skip cache and force re-detection
        **kwargs: Additional options
    
    Returns:
        dict: Structured scene detection results
    """
    logger.info(f"RUNNING DETECT_SCENES for source_video_id: {source_video_id}")
    logger.info(f"Video path: {source_video_path}")
    logger.info(f"Params: threshold={threshold}, method={method}, min_duration={min_duration_seconds}")

    # Get S3 resources from environment 
    s3_bucket_name = os.getenv("S3_BUCKET_NAME")
    if not s3_bucket_name:
        error_msg = "S3_BUCKET_NAME environment variable not set"
        logger.error(error_msg)
        return {
            "status": "error",
            "error": error_msg,
            "source_video_id": source_video_id
        }

    try:
        s3_client = boto3.client("s3")
    except NoCredentialsError:
        error_msg = "S3 credentials not found"
        logger.error(error_msg)
        return {
            "status": "error",
            "error": error_msg,
            "source_video_id": source_video_id
        }

    # Check for cached results first (unless force_redetect)
    cache_key = f"scene_detection_results/{source_video_id}.json"
    if not force_redetect:
        cached_result = load_cached_result(s3_client, s3_bucket_name, cache_key)
        if cached_result:
            logger.info(f"Using cached scene detection results for video {source_video_id}")
            return cached_result

    # Validate method
    if method not in COMPARISON_METHODS:
        error_msg = f"Invalid comparison method '{method}'. Must be one of: {list(COMPARISON_METHODS.keys())}"
        logger.error(error_msg)
        return {
            "status": "error",
            "error": error_msg,
            "source_video_id": source_video_id
        }

    # Extract S3 key from the full S3 path
    if source_video_path.startswith('s3://'):
        # Format: s3://bucket/key/path.mp4 -> key/path.mp4
        s3_key = source_video_path.replace(f"s3://{s3_bucket_name}/", "")
    else:
        # Assume it's already just the key
        s3_key = source_video_path

    with tempfile.TemporaryDirectory() as temp_dir:
        temp_dir_path = Path(temp_dir)
        
        try:
            # Step 1: Download video from S3
            local_video_path = download_video_from_s3(
                s3_client, s3_bucket_name, s3_key, temp_dir_path
            )
            
            # Step 2: Perform scene detection
            detection_result = detect_scenes_opencv(
                local_video_path, threshold, method, min_duration_seconds
            )
            
            # Step 3: Cache results to S3
            cache_result_to_s3(s3_client, s3_bucket_name, cache_key, detection_result)
            
            logger.info(f"Scene detection completed: {len(detection_result['scenes'])} scenes found")
            return detection_result

        except Exception as e:
            logger.error(f"Error during scene detection: {e}")
            return {
                "status": "error",
                "error": str(e),
                "source_video_id": source_video_id
            }

def load_cached_result(s3_client, bucket_name: str, cache_key: str) -> Optional[Dict[str, Any]]:
    """Load cached scene detection results from S3."""
    try:
        response = s3_client.get_object(Bucket=bucket_name, Key=cache_key)
        cached_data = json.loads(response['Body'].read().decode('utf-8'))
        logger.info(f"Loaded cached results from {cache_key}")
        return cached_data
    except ClientError as e:
        if e.response['Error']['Code'] == 'NoSuchKey':
            logger.info(f"No cached results found at {cache_key}")
            return None
        else:
            logger.warning(f"Error loading cached results: {e}")
            return None
    except Exception as e:
        logger.warning(f"Error parsing cached results: {e}")
        return None

def cache_result_to_s3(s3_client, bucket_name: str, cache_key: str, result: Dict[str, Any]) -> None:
    """Cache scene detection results to S3."""
    try:
        json_data = json.dumps(result, indent=2)
        s3_client.put_object(
            Bucket=bucket_name,
            Key=cache_key,
            Body=json_data,
            ContentType='application/json'
        )
        logger.info(f"Cached results to {cache_key}")
    except Exception as e:
        logger.warning(f"Failed to cache results to S3: {e}")
        # Don't fail the entire operation for caching issues

def download_video_from_s3(s3_client, bucket_name: str, s3_key: str, temp_dir: Path) -> Path:
    """Download video file from S3 to local temp directory."""
    local_filename = "source_video.mp4"
    local_path = temp_dir / local_filename
    
    logger.info(f"Downloading {s3_key} from S3...")
    
    try:
        s3_client.download_file(bucket_name, s3_key, str(local_path))
        logger.info(f"Successfully downloaded to {local_path}")
        return local_path
    except ClientError as e:
        logger.error(f"Failed to download {s3_key}: {e}")
        raise
    except Exception as e:
        logger.error(f"Error downloading video: {e}")
        raise

def detect_scenes_opencv(
    video_path: Path,
    threshold: float,
    method: str, 
    min_duration_seconds: float
) -> Dict[str, Any]:
    """
    Perform scene detection using OpenCV histogram comparison.
    
    Args:
        video_path: Local path to video file
        threshold: Similarity threshold for scene detection
        method: Comparison method name
        min_duration_seconds: Minimum scene duration
    
    Returns:
        dict: Scene detection results with scenes list and metadata
    """
    logger.info(f"Starting OpenCV scene detection on {video_path}")
    
    # Open video capture
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise ValueError(f"Could not open video file: {video_path}")
    
    try:
        # Extract video properties
        fps = cap.get(cv2.CAP_PROP_FPS)
        width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
        
        if fps <= 0 or total_frames <= 0:
            raise ValueError(f"Invalid video properties: fps={fps}, frames={total_frames}")
        
        duration_seconds = total_frames / fps
        
        video_info = {
            "fps": fps,
            "width": width,
            "height": height, 
            "total_frames": total_frames,
            "duration_seconds": duration_seconds
        }
        
        logger.info(f"Video properties: {width}x{height}, {fps:.2f} FPS, {total_frames} frames, {duration_seconds:.2f}s")
        
        # Detect scene cuts
        scene_cuts = detect_scene_cuts(cap, threshold, method)
        
        # Build scenes from cuts
        scenes = build_scenes_from_cuts(scene_cuts, fps, min_duration_seconds)
        
        logger.info(f"Scene detection complete: {len(scene_cuts)} cuts found, {len(scenes)} scenes after filtering")
        
        return {
            "status": "success",
            "scenes": scenes,
            "video_info": video_info,
            "detection_params": {
                "threshold": threshold,
                "method": method,
                "min_duration_seconds": min_duration_seconds
            }
        }
        
    finally:
        cap.release()

def detect_scene_cuts(cap: cv2.VideoCapture, threshold: float, method: str) -> List[int]:
    """
    Detect scene cut frames using histogram comparison.
    
    Args:
        cap: OpenCV VideoCapture object
        threshold: Similarity threshold
        method: Comparison method name
    
    Returns:
        List[int]: Frame numbers where scene cuts occur
    """
    comparison_method = COMPARISON_METHODS[method]
    cut_frames = [0]  # Always start with frame 0
    prev_hist = None
    frame_num = 0
    
    logger.info(f"Analyzing frames with method '{method}' and threshold {threshold}")
    
    while True:
        ret, frame = cap.read()
        if not ret:
            break
            
        # Calculate BGR histogram for current frame
        current_hist = calculate_bgr_histogram(frame)
        
        if prev_hist is not None:
            # Compare histograms
            score = cv2.compareHist(prev_hist, current_hist, comparison_method)
            
            # Check if this is a scene cut based on the method
            if is_scene_cut(score, threshold, method):
                logger.debug(f"Scene cut detected at frame {frame_num} (score: {score:.4f})")
                cut_frames.append(frame_num)
        
        prev_hist = current_hist
        frame_num += 1
        
        # Log progress periodically
        if frame_num % 1000 == 0:
            logger.info(f"Processed {frame_num} frames...")
    
    # Add final frame if not already present
    if frame_num > 0 and cut_frames[-1] != frame_num:
        cut_frames.append(frame_num)
    
    logger.info(f"Frame analysis complete: {len(cut_frames)} cuts found in {frame_num} frames")
    return cut_frames

def calculate_bgr_histogram(frame: np.ndarray) -> np.ndarray:
    """Calculate concatenated BGR histogram for a frame."""
    try:
        # Split into B, G, R channels
        channels = cv2.split(frame)
        
        # Calculate histogram for each channel (256 bins, range 0-256)
        hist_b = cv2.calcHist([channels[0]], [0], None, [256], [0, 256])
        hist_g = cv2.calcHist([channels[1]], [0], None, [256], [0, 256])
        hist_r = cv2.calcHist([channels[2]], [0], None, [256], [0, 256])
        
        # Concatenate histograms
        combined_hist = np.concatenate([hist_b.flatten(), hist_g.flatten(), hist_r.flatten()])
        
        # Normalize the histogram
        cv2.normalize(combined_hist, combined_hist)
        
        return combined_hist
        
    except Exception as e:
        logger.error(f"Error calculating histogram: {e}")
        # Return zeros as fallback
        return np.zeros(768, dtype=np.float32)

def is_scene_cut(score: float, threshold: float, method: str) -> bool:
    """Determine if a histogram comparison score indicates a scene cut."""
    if method == 'correl':
        # Lower correlation = more different
        return score < threshold
    elif method == 'intersect':
        # Lower intersection = more different  
        return score < threshold
    elif method == 'chisqr':
        # Higher chi-square = more different
        return score > threshold
    elif method == 'bhattacharyya':
        # Higher distance = more different
        return score > threshold
    else:
        # Default to correlation-like behavior
        return score < threshold

def build_scenes_from_cuts(cut_frames: List[int], fps: float, min_duration: float) -> List[Dict[str, Any]]:
    """
    Build scene list from cut frame numbers.
    
    Args:
        cut_frames: List of frame numbers where cuts occur
        fps: Video frame rate
        min_duration: Minimum scene duration in seconds
    
    Returns:
        List[Dict]: Scene objects with timing information
    """
    if len(cut_frames) < 2:
        logger.warning(f"Not enough cut frames to build scenes: {cut_frames}")
        return []
    
    scenes = []
    
    for i in range(len(cut_frames) - 1):
        start_frame = cut_frames[i]
        end_frame = cut_frames[i + 1]
        
        start_time_seconds = start_frame / fps
        end_time_seconds = end_frame / fps
        duration_seconds = end_time_seconds - start_time_seconds
        
        # Filter out scenes that are too short
        if duration_seconds >= min_duration:
            scene = {
                "start_frame": start_frame,
                "end_frame": end_frame, 
                "start_time_seconds": round(start_time_seconds, 3),
                "end_time_seconds": round(end_time_seconds, 3),
                "duration_seconds": round(duration_seconds, 3)
            }
            scenes.append(scene)
        else:
            logger.debug(f"Filtering out short scene: {duration_seconds:.3f}s < {min_duration}s")
    
    logger.info(f"Built {len(scenes)} scenes from {len(cut_frames)} cuts (filtered by min_duration)")
    return scenes

def main():
    """Entry point for testing the scene detection task directly."""
    import argparse
    
    parser = argparse.ArgumentParser(description="Test scene detection task")
    parser.add_argument("--source-video-path", required=True, help="S3 path to source video")
    parser.add_argument("--source-video-id", type=int, required=True, help="Source video ID")
    parser.add_argument("--threshold", type=float, default=0.3, help="Detection threshold")
    parser.add_argument("--method", default="correl", help="Comparison method")
    parser.add_argument("--min-duration", type=float, default=1.0, help="Minimum scene duration")
    parser.add_argument("--force-redetect", action="store_true", help="Skip cache")
    
    args = parser.parse_args()
    
    result = run_detect_scenes(
        source_video_path=args.source_video_path,
        source_video_id=args.source_video_id,
        threshold=args.threshold,
        method=args.method,
        min_duration_seconds=args.min_duration,
        force_redetect=args.force_redetect
    )
    
    print(json.dumps(result, indent=2))

if __name__ == "__main__":
    main() 