"""
S3 Handler Module for Ingest Task

Handles S3 operations including:
- File upload with progress reporting
- Upload verification
- Error handling
"""

import logging
import threading
from pathlib import Path

import boto3
from botocore.exceptions import ClientError

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
    
    s3_client = boto3.client('s3')
    return s3_client, bucket_name


def upload_to_s3(s3_client, bucket_name: str, file_path: Path, s3_key: str, storage_class: str = "STANDARD"):
    """Upload file to S3 with progress reporting, validation, and storage class support"""
    if not file_path.exists():
        raise FileNotFoundError(f"File to upload does not exist: {file_path}")
    
    file_size = file_path.stat().st_size
    if file_size == 0:
        raise ValueError(f"File to upload is empty: {file_path}")
    
    progress_callback = S3TransferProgress(file_size, file_path.name, logger)
    
    try:
        logger.info(f"Starting S3 upload: {file_path.name} ({file_size:,} bytes) to s3://{bucket_name}/{s3_key} (storage class: {storage_class})")
        
        # Build extra args for storage class
        extra_args = {}
        if storage_class != "STANDARD":
            extra_args['StorageClass'] = storage_class
        
        s3_client.upload_file(
            str(file_path), 
            bucket_name, 
            s3_key,
            ExtraArgs=extra_args,
            Callback=progress_callback
        )
        logger.info(f"Successfully uploaded {file_path.name} to s3://{bucket_name}/{s3_key}")
        
        # Verify the upload by checking if the object exists
        try:
            s3_client.head_object(Bucket=bucket_name, Key=s3_key)
            logger.info(f"S3 upload verification successful for {s3_key}")
        except ClientError as verify_error:
            logger.warning(f"S3 upload verification failed for {s3_key}: {verify_error}")
            # Don't raise here - upload might still be successful
            
    except ClientError as e:
        error_code = e.response.get('Error', {}).get('Code', 'Unknown')
        logger.error(f"Failed to upload to S3 (error code: {error_code}): {e}")
        raise
    except Exception as e:
        logger.error(f"Unexpected error during S3 upload: {e}")
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