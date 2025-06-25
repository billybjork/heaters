#!/usr/bin/env python3
"""
Mock Python runner for testing.

This script simulates the behavior of py/runner.py for testing purposes
without requiring actual video processing dependencies.
"""

import sys
import json
import argparse


def mock_keyframe_task(args):
    """Mock keyframe extraction task."""
    return {
        "status": "success",
        "task": "keyframe",
        "artifacts": [
            {
                "artifact_type": "keyframe",
                "s3_key": "test/keyframes/mock_25pct.jpg",
                "metadata": {
                    "tag": "25pct",
                    "frame_index": 250,
                    "timestamp_sec": 8.33,
                    "width": 1920,
                    "height": 1080
                }
            },
            {
                "artifact_type": "keyframe", 
                "s3_key": "test/keyframes/mock_50pct.jpg",
                "metadata": {
                    "tag": "50pct",
                    "frame_index": 500,
                    "timestamp_sec": 16.67,
                    "width": 1920,
                    "height": 1080
                }
            }
        ]
    }


def mock_sprite_task(args):
    """Mock sprite generation task."""
    return {
        "status": "success",
        "task": "sprite",
        "artifacts": [
            {
                "artifact_type": "sprite",
                "s3_key": "test/sprites/mock_sprite.jpg",
                "metadata": {
                    "width": 1920,
                    "height": 1080,
                    "thumbnail_count": 25
                }
            }
        ]
    }


def mock_embed_task(args):
    """Mock embedding generation task."""
    return {
        "status": "success", 
        "task": "embed",
        "embeddings": [
            {
                "keyframe_s3_key": "test/keyframes/mock_25pct.jpg",
                "embedding": [0.1, 0.2, 0.3, 0.4, 0.5] * 100  # Mock 500-dim embedding
            },
            {
                "keyframe_s3_key": "test/keyframes/mock_50pct.jpg", 
                "embedding": [0.6, 0.7, 0.8, 0.9, 1.0] * 100  # Mock 500-dim embedding
            }
        ]
    }


def mock_unknown_task(args):
    """Mock handler for unknown tasks."""
    return {
        "status": "error",
        "error": f"Unknown task: {args.get('task', 'unknown')}"
    }


TASK_HANDLERS = {
    "keyframe": mock_keyframe_task,
    "sprite": mock_sprite_task, 
    "embed": mock_embed_task
}


def main():
    parser = argparse.ArgumentParser(description="Mock Python task runner for testing")
    parser.add_argument("task_name", help="Name of the task to run")
    parser.add_argument("--args-file", required=True, help="JSON file containing task arguments")
    
    args = parser.parse_args()
    
    # Load arguments from file
    try:
        with open(args.args_file, 'r') as f:
            task_args = json.load(f)
    except Exception as e:
        print(f"Error loading args file: {e}", file=sys.stderr)
        sys.exit(1)
    
    # Print progress messages (PyRunner expects these)
    print(f"Mock runner: Starting task '{args.task_name}'")
    print(f"Mock runner: Task arguments: {json.dumps(task_args)}")
    
    # Get the task handler
    handler = TASK_HANDLERS.get(args.task_name, mock_unknown_task)
    
    # Execute the task
    try:
        result = handler(task_args)
        print(f"Mock runner: Task completed successfully")
        
        # Output final JSON result (PyRunner looks for this)
        print(f"FINAL_JSON:{json.dumps(result)}")
        
    except Exception as e:
        print(f"Mock runner: Task failed with error: {e}", file=sys.stderr)
        error_result = {
            "status": "error",
            "error": str(e)
        }
        print(f"FINAL_JSON:{json.dumps(error_result)}")
        sys.exit(1)


if __name__ == "__main__":
    main() 