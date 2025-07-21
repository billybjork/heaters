"""
Simple Scene Detection Task - Pure OpenCV scene detection.

This "dumb" version:
- Takes a local video file path (no S3 operations)
- Runs OpenCV histogram comparison
- Returns raw scene cuts as simple JSON
- No caching, no downloads, no complex error handling
"""

import json
import logging
from typing import Dict, List, Any

import cv2
import numpy as np

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# OpenCV histogram comparison methods
COMPARISON_METHODS = {
    'correl': cv2.HISTCMP_CORREL,
    'chisqr': cv2.HISTCMP_CHISQR, 
    'intersect': cv2.HISTCMP_INTERSECT,
    'bhattacharyya': cv2.HISTCMP_BHATTACHARYYA
}

def run_detect_scenes(
    proxy_video_path: str,
    source_video_id: int,
    threshold: float = 0.6,
    method: str = "correl", 
    min_duration_seconds: float = 1.0,
    **kwargs
) -> Dict[str, Any]:
    """
    Detect scene cuts in a proxy video file and return cut points for virtual clips.
    
    Args:
        proxy_video_path: S3 path to proxy video file
        source_video_id: Database ID of the source video
        threshold: Scene cut threshold (0.0-1.0)
        method: Comparison method name
        min_duration_seconds: Minimum scene duration
        
    Returns:
        dict: Cut points for virtual clip creation and metadata
    """
    try:
        # For now, assume proxy_video_path is accessible locally or via URL
        # In production, this would download from S3 first
        logger.info(f"Starting scene detection for source_video_id: {source_video_id}")
        logger.info(f"Using proxy video: {proxy_video_path}")
        
        # Open video
        cap = cv2.VideoCapture(proxy_video_path)
        if not cap.isOpened():
            raise ValueError(f"Cannot open proxy video: {proxy_video_path}")
        
        # Get video properties
        fps = cap.get(cv2.CAP_PROP_FPS)
        width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
        
        # Detect scene cuts
        cut_frames = detect_scene_cuts(cap, threshold, method, total_frames)
        
        # Build cut points for virtual clips (not scenes)
        cut_points = build_cut_points_from_cuts(cut_frames, fps, min_duration_seconds)
        
        cap.release()
        
        logger.info(f"Scene detection complete: found {len(cut_points)} valid cut points")
        
        return {
            "status": "success",
            "cut_points": cut_points,
            "metadata": {
                "source_video_id": source_video_id,
                "total_scenes_detected": len(cut_points),
                "video_properties": {
                    "fps": fps,
                    "width": width,
                    "height": height,
                    "total_frames": total_frames,
                    "duration_seconds": total_frames / fps
                },
                "detection_params": {
                    "threshold": threshold,
                    "method": method,
                    "min_duration_seconds": min_duration_seconds
                }
            }
        }
        
    except Exception as e:
        logger.error(f"Scene detection failed for source_video_id {source_video_id}: {e}")
        return {
            "status": "error",
            "error": str(e)
        }

def detect_scene_cuts(cap: cv2.VideoCapture, threshold: float, method: str, total_frames: int) -> List[int]:
    """Detect scene cut frames using histogram comparison."""
    comparison_method = COMPARISON_METHODS[method]
    cut_frames = [0]
    prev_hist = None
    frame_num = 0
    last_logged_percentage = -1
    
    while True:
        ret, frame = cap.read()
        if not ret:
            break
            
        current_hist = calculate_bgr_histogram(frame)
        
        if prev_hist is not None:
            score = cv2.compareHist(prev_hist, current_hist, comparison_method)
            
            if is_scene_cut(score, threshold, method):
                cut_frames.append(frame_num)
        
        prev_hist = current_hist
        frame_num += 1
        
        # Log progress every 5% (following ingest pattern)
        if total_frames > 0:
            current_percentage = int((frame_num / total_frames) * 100)
            if current_percentage >= last_logged_percentage + 5 and current_percentage < 100:
                print(f"Scene detection: {current_percentage}% complete ({frame_num}/{total_frames} frames)")
                last_logged_percentage = current_percentage
    
    # Log completion
    if total_frames > 0:
        print(f"Scene detection: 100% complete ({frame_num}/{total_frames} frames)")
    
    # Add final frame
    if frame_num > 0 and cut_frames[-1] != frame_num:
        cut_frames.append(frame_num)
    
    return cut_frames

def calculate_bgr_histogram(frame: np.ndarray) -> np.ndarray:
    """Calculate normalized BGR histogram."""
    channels = cv2.split(frame)
    hist_b = cv2.calcHist([channels[0]], [0], None, [256], [0, 256])
    hist_g = cv2.calcHist([channels[1]], [0], None, [256], [0, 256])
    hist_r = cv2.calcHist([channels[2]], [0], None, [256], [0, 256])
    
    combined_hist = np.concatenate([hist_b.flatten(), hist_g.flatten(), hist_r.flatten()])
    cv2.normalize(combined_hist, combined_hist)
    return combined_hist

def is_scene_cut(score: float, threshold: float, method: str) -> bool:
    """Determine if score indicates a scene cut."""
    if method in ['correl', 'intersect']:
        return score < threshold
    else:  # chisqr, bhattacharyya
        return score > threshold

def build_cut_points_from_cuts(cut_frames: List[int], fps: float, min_duration: float) -> List[Dict[str, Any]]:
    """Build cut points for virtual clips from cut frames."""
    cut_points = []
    
    for i in range(len(cut_frames) - 1):
        start_frame = cut_frames[i]
        end_frame = cut_frames[i + 1]
        
        start_time = start_frame / fps
        end_time = end_frame / fps
        duration = end_time - start_time
        
        if duration >= min_duration:
            # Format matches what VirtualClips.create_virtual_clips_from_cut_points expects
            cut_points.append({
                "start_frame": start_frame,
                "end_frame": end_frame,
                "start_time_seconds": round(start_time, 3),
                "end_time_seconds": round(end_time, 3)
            })
    
    return cut_points

def build_scenes_from_cuts(cut_frames: List[int], fps: float, min_duration: float) -> List[Dict[str, Any]]:
    """Build scene list from cut frames (legacy function for compatibility)."""
    scenes = []
    
    for i in range(len(cut_frames) - 1):
        start_frame = cut_frames[i]
        end_frame = cut_frames[i + 1]
        
        start_time = start_frame / fps
        end_time = end_frame / fps
        duration = end_time - start_time
        
        if duration >= min_duration:
            scenes.append({
                "start_frame": start_frame,
                "end_frame": end_frame,
                "start_time_seconds": round(start_time, 3),
                "end_time_seconds": round(end_time, 3),
                "duration_seconds": round(duration, 3)
            })
    
    return scenes

def main():
    """CLI entry point for testing."""
    import argparse
    
    parser = argparse.ArgumentParser(description="Simple scene detection")
    parser.add_argument("video_path", help="Local video file path")
    parser.add_argument("--threshold", type=float, default=0.6)
    parser.add_argument("--method", default="correl")
    parser.add_argument("--min-duration", type=float, default=1.0)
    
    args = parser.parse_args()
    
    result = run_detect_scenes(
        args.video_path,
        threshold=args.threshold,
        method=args.method,
        min_duration_seconds=args.min_duration
    )
    
    print(json.dumps(result, indent=2))

if __name__ == "__main__":
    main() 