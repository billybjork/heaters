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


def upload_to_s3(s3_client, bucket_name: str, file_path: Path, s3_key: str):
    """Upload file to S3 with progress reporting and validation"""
    if not file_path.exists():
        raise FileNotFoundError(f"File to upload does not exist: {file_path}")
    
    file_size = file_path.stat().st_size
    if file_size == 0:
        raise ValueError(f"File to upload is empty: {file_path}")
    
    progress_callback = S3TransferProgress(file_size, file_path.name, logger)
    
    try:
        logger.info(f"Starting S3 upload: {file_path.name} ({file_size:,} bytes) to s3://{bucket_name}/{s3_key}")
        s3_client.upload_file(
            str(file_path), 
            bucket_name, 
            s3_key,
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