"""
S3 Upload Task with Progress Reporting

Handles S3 uploads with detailed progress logging, suitable for large files
where upload progress visibility is important.

This task provides:
- Percentage-based progress reporting (every 5%)
- File size and speed tracking
- Storage class support
- Upload verification
- Error handling with detailed logging
"""

import logging
import os
from pathlib import Path
from typing import Dict, Any

logger = logging.getLogger(__name__)


def run_s3_upload(
    local_path: str,
    s3_key: str,
    storage_class: str = "STANDARD",
    **kwargs
) -> Dict[str, Any]:
    """
    Upload a file to S3 with progress reporting.
    
    Args:
        local_path: Path to the local file to upload
        s3_key: S3 key where the file should be stored
        storage_class: S3 storage class (STANDARD, GLACIER, etc.)
        **kwargs: Additional parameters (unused, for compatibility)
    
    Returns:
        Dict with status and upload information
    """
    try:
        logger.info(f"S3Upload: Starting upload task for {local_path}")
        
        # Validate inputs
        local_file = Path(local_path)
        if not local_file.exists():
            error_msg = f"Local file does not exist: {local_path}"
            logger.error(f"S3Upload: {error_msg}")
            return {"status": "error", "error": error_msg}
        
        if not s3_key or not s3_key.strip():
            error_msg = "S3 key cannot be empty"
            logger.error(f"S3Upload: {error_msg}")
            return {"status": "error", "error": error_msg}
        
        # Get file size for progress reporting
        file_size = local_file.stat().st_size
        if file_size == 0:
            error_msg = f"File is empty: {local_path}"
            logger.error(f"S3Upload: {error_msg}")
            return {"status": "error", "error": error_msg}
        
        logger.info(f"S3Upload: File size: {file_size:,} bytes ({file_size / (1024*1024):.2f} MiB)")
        logger.info(f"S3Upload: Storage class: {storage_class}")
        logger.info(f"S3Upload: Destination: s3://bucket/{s3_key}")
        
        # Import and use the existing S3 handler with progress reporting
        from utils.s3_handler import get_s3_config, upload_to_s3
        
        # Get S3 configuration
        s3_client, bucket_name = get_s3_config()
        
        # Upload with progress reporting (built into s3_handler)
        upload_to_s3(s3_client, bucket_name, local_file, s3_key, storage_class)
        
        logger.info(f"S3Upload: Upload completed successfully")
        
        return {
            "status": "success",
            "s3_key": s3_key,
            "file_size": file_size,
            "storage_class": storage_class,
            "local_path": str(local_file)
        }
        
    except Exception as e:
        error_msg = f"S3 upload failed: {str(e)}"
        logger.error(f"S3Upload: {error_msg}")
        logger.exception("S3Upload: Full exception details:")
        
        return {
            "status": "error",
            "error": error_msg,
            "local_path": local_path,
            "s3_key": s3_key
        }


if __name__ == "__main__":
    # Test/debug functionality
    import sys
    
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