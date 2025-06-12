import os
import boto3
import logging
from botocore.exceptions import ClientError, NoCredentialsError
import sys

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

# --- Local Imports ---
try:
    from python.utils.db import get_db_connection
except ImportError:
    project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
    if project_root not in sys.path:
        sys.path.insert(0, project_root)
    from python.utils.db import get_db_connection

def run_archive(s3_keys_to_delete: list, **kwargs):
    """
    A stateless utility that deletes a provided list of objects from S3.
    This task does not connect to the database.
    """
    if not s3_keys_to_delete:
        logger.info("No S3 keys provided to delete. Exiting successfully.")
        return {"status": "success", "deleted_count": 0}

    logger.info(f"Attempting to delete {len(s3_keys_to_delete)} S3 objects.")

    s3_bucket_name = os.getenv("S3_BUCKET_NAME")
    if not s3_bucket_name:
        raise ValueError("S3_BUCKET_NAME environment variable not set.")

    try:
        s3_client = boto3.client("s3")
    except NoCredentialsError:
        logger.error("S3 credentials not found. Configure AWS environment variables.")
        raise

    try:
        # S3 expects a list of dicts with 'Key'
        objects_to_delete = [{"Key": key} for key in s3_keys_to_delete]

        # delete_objects can handle up to 1000 keys at a time.
        # For simplicity, we assume fewer than 1000 artifacts per clip.
        # For a more robust solution, this would be chunked into batches of 1000.
        response = s3_client.delete_objects(
            Bucket=s3_bucket_name,
            Delete={"Objects": objects_to_delete, "Quiet": True},
        )

        if response.get("Errors"):
            error_details = response["Errors"]
            logger.error(f"S3 deletion had errors: {error_details}")
            # Even with partial errors, we might want to proceed, but for Oban,
            # it's better to fail the job so it can be inspected.
            raise RuntimeError(f"S3 deletion failed for some keys: {error_details}")

        logger.info(f"Successfully deleted {len(objects_to_delete)} S3 objects.")

        return {
            "status": "success",
            "deleted_count": len(objects_to_delete),
        }

    except ClientError as e:
        logger.error(f"A fatal S3 ClientError occurred during deletion: {e}", exc_info=True)
        # Re-raise to ensure the Oban job is marked as failed
        raise