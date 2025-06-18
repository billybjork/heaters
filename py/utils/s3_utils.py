"""
S3 utilities for Python tasks.

This module provides common S3 operations for use by media processing tasks
like merge.py and split.py that need to clean up source files after successful processing.
"""

import logging
from typing import List

import boto3
from botocore.exceptions import ClientError, NoCredentialsError

logger = logging.getLogger(__name__)

# S3 limit for delete_objects operation
MAX_DELETE_BATCH_SIZE = 1000


def delete_s3_objects(s3_client, bucket_name: str, s3_keys: List[str]) -> dict:
    """
    Deletes a list of S3 objects and returns structured results.
    
    Args:
        s3_client: Boto3 S3 client instance
        bucket_name: S3 bucket name
        s3_keys: List of S3 keys to delete
    
    Returns:
        dict: Results with deleted count and any errors
    """
    if not s3_keys:
        logger.info("No S3 keys provided to delete")
        return {
            "deleted_count": 0,
            "error_count": 0,
            "errors": []
        }
    
    logger.info(f"Deleting {len(s3_keys)} S3 objects from bucket: {bucket_name}")
    
    # Process deletions in batches (S3 limit is 1000 objects per request)
    total_deleted = 0
    total_errors = []
    
    try:
        for i in range(0, len(s3_keys), MAX_DELETE_BATCH_SIZE):
            batch = s3_keys[i:i + MAX_DELETE_BATCH_SIZE]
            logger.info(f"Processing batch {i//MAX_DELETE_BATCH_SIZE + 1}: {len(batch)} objects")
            
            batch_result = delete_s3_objects_batch(s3_client, bucket_name, batch)
            total_deleted += batch_result["deleted"]
            total_errors.extend(batch_result["errors"])
        
        return {
            "deleted_count": total_deleted,
            "error_count": len(total_errors),
            "errors": total_errors
        }
        
    except Exception as e:
        logger.error(f"Error during S3 deletion: {e}")
        raise


def delete_s3_objects_batch(s3_client, bucket_name: str, s3_keys: List[str]) -> dict:
    """
    Deletes a batch of S3 objects (up to 1000 at a time).
    Returns results with success/error details.
    """
    if not s3_keys:
        return {"deleted": 0, "errors": []}
    
    # Prepare objects for deletion
    objects_to_delete = [{"Key": key} for key in s3_keys]
    
    logger.info(f"Deleting {len(objects_to_delete)} S3 objects from bucket: {bucket_name}")
    
    try:
        response = s3_client.delete_objects(
            Bucket=bucket_name,
            Delete={"Objects": objects_to_delete, "Quiet": True}
        )
        
        # Check for errors in the response
        errors = response.get("Errors", [])
        deleted_count = len(objects_to_delete) - len(errors)
        
        if errors:
            logger.warning(f"S3 deletion had {len(errors)} errors")
            for error in errors:
                logger.error(f"Failed to delete {error['Key']}: {error['Code']} - {error['Message']}")
        else:
            logger.info(f"Successfully deleted {deleted_count} S3 objects")
        
        return {
            "deleted": deleted_count,
            "errors": errors
        }
        
    except ClientError as e:
        logger.error(f"S3 ClientError during deletion: {e}")
        raise


def get_s3_client():
    """
    Creates and returns a configured S3 client.
    Raises appropriate errors if credentials are not available.
    """
    try:
        return boto3.client("s3")
    except NoCredentialsError:
        logger.error("S3 credentials not found")
        raise 