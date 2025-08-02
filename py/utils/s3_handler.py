"""
S3 Handler Utilities

Core S3 operations including:
- File upload/download with progress reporting
- Retry logic and error handling  
- Transfer configuration for reliability
- Progress callbacks and configuration helpers

Pure utility functions used by task modules for S3 operations.
"""

import logging
import threading
import time
from pathlib import Path
from typing import Dict, Any

import boto3
from botocore.exceptions import ClientError, UnseekableStreamError

logger = logging.getLogger(__name__)


class S3TransferProgress:
    """Callback for boto3 reporting progress via logger"""
    
    def __init__(self, total_size, filename, logger_instance, throttle_percentage=5):
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


def get_s3_config():
    """Get S3 configuration from environment variables"""
    import os
    
    bucket_name = os.environ.get('S3_BUCKET_NAME')
    if not bucket_name:
        raise ValueError("S3_BUCKET_NAME environment variable not set")
    
    # Configure S3 client
    s3_client = boto3.client('s3')
    
    return s3_client, bucket_name


def get_transfer_config():
    """Create a fresh transfer config for each upload to avoid shared state issues"""
    from boto3.s3.transfer import TransferConfig
    
    return TransferConfig(
        multipart_threshold=100 * 1024 * 1024,  # 100MB - higher threshold for multipart
        max_concurrency=1,  # Disable concurrent uploads to avoid stream conflicts
        multipart_chunksize=16 * 1024 * 1024,  # 16MB chunks
        use_threads=False,  # Disable threading for simplicity
        max_io_queue=1000,  # Increase queue size for better buffering
        io_chunksize=262144  # 256KB chunks for better streaming
    )


def upload_to_s3(s3_client, bucket_name: str, file_path: Path, s3_key: str, storage_class: str = "STANDARD", transfer_config=None):
    """Upload file to S3 with progress reporting, validation, and storage class support"""
    
    # Create immutable copies of critical parameters to prevent corruption during retries
    original_file_path = Path(str(file_path))  # Immutable copy
    original_s3_key = str(s3_key)  # Immutable copy
    
    # Debug logging for file path tracking
    logger.info(f"upload_to_s3 called with file_path: {original_file_path} (type: {type(original_file_path)})")
    logger.info(f"upload_to_s3 called with s3_key: {original_s3_key}")
    
    if not original_file_path.exists():
        raise FileNotFoundError(f"File to upload does not exist: {original_file_path}")
    
    file_size = original_file_path.stat().st_size
    if file_size == 0:
        raise ValueError(f"File to upload is empty: {original_file_path}")
    
        # Build extra args for storage class
    extra_args = {}
    if storage_class != "STANDARD":
        extra_args['StorageClass'] = storage_class
    
    # Retry configuration
    max_retries = 3
    base_delay = 2  # seconds
    
    for attempt in range(max_retries):
        try:
            # Debug: Track file path in each attempt
            attempt_num = attempt + 1
            if attempt_num == 1:
                logger.info(f"Starting S3 upload: file_path = {original_file_path}")
            else:
                logger.info(f"Retry attempt {attempt_num}: file_path = {original_file_path}")
            
            # Verify file still exists before each attempt
            if not original_file_path.exists():
                raise FileNotFoundError(f"File to upload no longer exists: {original_file_path}")
                
            logger.info(f"Starting S3 upload (attempt {attempt_num}/{max_retries}): {original_file_path.name} ({file_size:,} bytes) to s3://{bucket_name}/{original_s3_key} (storage class: {storage_class})")
            
            # Create fresh progress callback for each attempt to avoid stream issues
            progress_callback = S3TransferProgress(file_size, original_file_path.name, logger)
            
            # Use upload_file with fresh file handle each time
            upload_kwargs = {
                'Filename': str(original_file_path),
                'Bucket': bucket_name,
                'Key': original_s3_key,
                'ExtraArgs': extra_args,
                'Callback': progress_callback
            }
            
            if transfer_config:
                upload_kwargs['Config'] = transfer_config
            
            s3_client.upload_file(**upload_kwargs)
            
            logger.info(f"Successfully uploaded {original_file_path.name} to s3://{bucket_name}/{original_s3_key}")
            
            # Verify the upload by checking if the object exists
            try:
                s3_client.head_object(Bucket=bucket_name, Key=original_s3_key)
                logger.info(f"S3 upload verification successful for {original_s3_key}")
            except ClientError as verify_error:
                logger.warning(f"S3 upload verification failed for {original_s3_key}: {verify_error}")
                # Don't raise here - upload might still be successful
            
            # Success - break out of retry loop
            return
            
        except UnseekableStreamError as stream_error:
            logger.warning(f"Unseekable stream error on attempt {attempt + 1}: {stream_error}")
            if attempt < max_retries - 1:
                delay = base_delay * (2 ** attempt)  # Exponential backoff
                logger.info(f"Retrying upload after {delay} seconds...")
                time.sleep(delay)
                continue
            else:
                logger.error(f"Upload failed after {max_retries} attempts due to stream errors")
                raise
                
        except ClientError as e:
            error_code = e.response.get('Error', {}).get('Code', 'Unknown')
            logger.error(f"Failed to upload to S3 on attempt {attempt + 1} (error code: {error_code}): {e}")
            if attempt < max_retries - 1:
                delay = base_delay * (2 ** attempt)
                logger.info(f"Retrying upload after {delay} seconds...")
                time.sleep(delay)
                continue
            else:
                raise
                
        except Exception as e:
            logger.error(f"Unexpected error during S3 upload on attempt {attempt + 1}: {e}")
            if attempt < max_retries - 1:
                delay = base_delay * (2 ** attempt)
                logger.info(f"Retrying upload after {delay} seconds...")
                time.sleep(delay)
                continue
            else:
                raise


def download_from_s3(s3_client, bucket_name: str, s3_key: str, local_path: Path):
    """Download file from S3 to local path with progress reporting"""
    clean_key = str(s3_key).lstrip('/')
    
    try:
        # Get object size for progress reporting
        response = s3_client.head_object(Bucket=bucket_name, Key=clean_key)
        file_size = response['ContentLength']
        
        logger.info(f"Starting S3 download: s3://{bucket_name}/{clean_key} ({file_size:,} bytes) to {local_path}")
        
        # Create progress callback
        progress_callback = S3TransferProgress(file_size, local_path.name, logger)
        
        s3_client.download_file(
            bucket_name, 
            clean_key, 
            str(local_path),
            Callback=progress_callback
        )
        
        logger.info(f"Successfully downloaded {clean_key} to {local_path}")
        
        # Verify download
        if not local_path.exists():
            raise FileNotFoundError(f"Downloaded file not found at {local_path}")
            
        downloaded_size = local_path.stat().st_size
        if downloaded_size != file_size:
            logger.warning(f"Size mismatch: expected {file_size}, got {downloaded_size}")
        else:
            logger.info(f"Download verification successful for {local_path}")
            
    except ClientError as e:
        error_code = e.response.get('Error', {}).get('Code', 'Unknown')
        logger.error(f"Failed to download from S3 (error code: {error_code}): {e}")
        raise
    except Exception as e:
        logger.error(f"Unexpected error during S3 download: {e}")
        raise


