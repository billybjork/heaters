"""
S3 Upload Task - PyRunner Interface

Thin wrapper around consolidated s3_handler.py for PyRunner compatibility.
All actual functionality has been moved to utils/s3_handler.py for better organization.
"""

from typing import Dict, Any


def run_s3_upload(
    local_path: str,
    s3_key: str,
    storage_class: str = "STANDARD",
    **kwargs
) -> Dict[str, Any]:
    """
    Upload a file to S3 with progress reporting.
    
    This is a PyRunner-compatible wrapper around the consolidated S3 handler.
    
    Args:
        local_path: Path to the local file to upload
        s3_key: S3 key where the file should be stored
        storage_class: S3 storage class (STANDARD, GLACIER, etc.)
        **kwargs: Additional parameters (unused, for compatibility)
    
    Returns:
        Dict with status and upload information
    """
    # Import and delegate to the consolidated S3 handler
    from utils.s3_handler import run_s3_upload_task
    
    return run_s3_upload_task(local_path, s3_key, storage_class, **kwargs)


if __name__ == "__main__":
    # Test/debug functionality - delegates to consolidated s3_handler
    import sys
    import logging
    
    if len(sys.argv) != 3:
        print("Usage: python s3_upload.py <local_path> <s3_key>")
        sys.exit(1)
    
    local_path = sys.argv[1]
    s3_key = sys.argv[2]
    
    # Set up logging for direct execution
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
    )
    
    result = run_s3_upload(local_path, s3_key)
    print(f"Result: {result}")