"""
S3 Upload Task - PyRunner Interface

Task interface for S3 uploads with comprehensive error handling and progress reporting.
Uses utilities from s3_handler.py for the actual upload operations.
"""

import logging
from pathlib import Path
from typing import Dict, Any

logger = logging.getLogger(__name__)


def run_upload_s3(
    local_path: str,
    s3_key: str,
    storage_class: str = "STANDARD",
    **kwargs
) -> Dict[str, Any]:
    """
    Task interface for S3 uploads with comprehensive error handling and progress reporting.
    
    This function provides a standardized interface for background job integration,
    with detailed logging and structured return values for job orchestration.
    
    Args:
        local_path: Path to the local file to upload
        s3_key: S3 key where the file should be stored
        storage_class: S3 storage class (STANDARD, GLACIER, etc.)
        **kwargs: Additional parameters (unused, for compatibility)
    
    Returns:
        Dict with status and upload information:
        - Success: {"status": "success", "s3_key": str, "file_size": int, ...}
        - Error: {"status": "error", "error": str, "local_path": str, "s3_key": str}
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
        
        # Import utilities for actual upload operations
        from utils.s3_handler import get_s3_config, get_transfer_config, upload_to_s3
        
        # Get S3 configuration and create fresh transfer config
        s3_client, bucket_name = get_s3_config()
        transfer_config = get_transfer_config()  # Fresh config for each upload
        
        # Upload with progress reporting and retry logic
        upload_to_s3(s3_client, bucket_name, local_file, s3_key, storage_class, transfer_config)
        
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
    # Test/debug functionality - delegates to consolidated s3_handler
    import sys
    import logging
    
    if len(sys.argv) != 3:
        print("Usage: python upload_s3.py <local_path> <s3_key>")
        sys.exit(1)
    
    local_path = sys.argv[1]
    s3_key = sys.argv[2]
    
    # Set up logging for direct execution
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
    )
    
    result = run_upload_s3(local_path, s3_key)
    print(f"Result: {result}")