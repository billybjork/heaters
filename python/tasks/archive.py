"""
Refactored Archive Task - "Dumber" Python focused on S3 cleanup only.

This version:
- Receives explicit list of S3 keys to delete from Elixir
- Focuses only on S3 object deletion
- Returns structured data about deletion results instead of managing database state
- No database connections or state management
"""

import argparse
import json
import logging
import os
from typing import List

import boto3
from botocore.exceptions import ClientError, NoCredentialsError

# --- Logging Configuration ---
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

# --- Configuration ---
MAX_DELETE_BATCH_SIZE = 1000  # S3 limit for delete_objects


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


def run_archive(s3_keys_to_delete: List[str], **kwargs) -> dict:
    """
    Deletes a list of S3 objects and returns structured results.
    
    Args:
        s3_keys_to_delete: List of S3 keys to delete
        **kwargs: Additional options
    
    Returns:
        dict: Structured data about deletion results including counts and any errors
    """
    logger.info(f"RUNNING ARCHIVE for {len(s3_keys_to_delete)} S3 objects")
    
    if not s3_keys_to_delete:
        logger.info("No S3 keys provided to delete")
        return {
            "status": "success",
            "deleted_count": 0,
            "error_count": 0,
            "errors": []
        }
    
    # Get S3 resources from environment (provided by Elixir)
    s3_bucket_name = os.getenv("S3_BUCKET_NAME")
    if not s3_bucket_name:
        raise ValueError("S3_BUCKET_NAME environment variable not set")

    try:
        s3_client = boto3.client("s3")
    except NoCredentialsError:
        logger.error("S3 credentials not found")
        raise

    # Process deletions in batches (S3 limit is 1000 objects per request)
    total_deleted = 0
    total_errors = []
    
    try:
        for i in range(0, len(s3_keys_to_delete), MAX_DELETE_BATCH_SIZE):
            batch = s3_keys_to_delete[i:i + MAX_DELETE_BATCH_SIZE]
            logger.info(f"Processing batch {i//MAX_DELETE_BATCH_SIZE + 1}: {len(batch)} objects")
            
            batch_result = delete_s3_objects_batch(s3_client, s3_bucket_name, batch)
            total_deleted += batch_result["deleted"]
            total_errors.extend(batch_result["errors"])
        
        # Return structured data for Elixir to process
        return {
            "status": "success" if not total_errors else "partial_success",
            "deleted_count": total_deleted,
            "error_count": len(total_errors),
            "errors": total_errors,
            "metadata": {
                "total_requested": len(s3_keys_to_delete),
                "batches_processed": (len(s3_keys_to_delete) + MAX_DELETE_BATCH_SIZE - 1) // MAX_DELETE_BATCH_SIZE
            }
        }
        
    except Exception as e:
        logger.error(f"Error during S3 deletion: {e}")
        raise


def main():
    """Main entry point for standalone execution"""
    parser = argparse.ArgumentParser(description="S3 object deletion task")
    parser.add_argument("--s3-keys", required=True, 
                       help="JSON array of S3 keys to delete")
    
    args = parser.parse_args()
    
    # Parse S3 keys from JSON
    try:
        s3_keys_to_delete = json.loads(args.s3_keys)
        if not isinstance(s3_keys_to_delete, list):
            raise ValueError("s3-keys must be a JSON array")
    except json.JSONDecodeError as e:
        print(f"Error parsing s3-keys JSON: {e}")
        exit(1)
    
    try:
        result = run_archive(s3_keys_to_delete)
        print(json.dumps(result, indent=2))
    except Exception as e:
        error_result = {
            "status": "error",
            "error": str(e),
            "error_type": type(e).__name__
        }
        print(json.dumps(error_result, indent=2))
        exit(1)


if __name__ == "__main__":
    main() 