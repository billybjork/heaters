import os
import logging
from dotenv import load_dotenv
import boto3 # Added for S3 client
from botocore.exceptions import NoCredentialsError, ClientError # Added for S3 exceptions

dotenv_path = os.path.join(os.path.dirname(__file__), '.env')
# Ensure .env is loaded before other configurations that might depend on it.
# Use a print statement here as logger might not be configured yet.
print(f"Config.py: Attempting to load .env from: {dotenv_path}")
if os.path.exists(dotenv_path):
    load_dotenv(dotenv_path=dotenv_path)
    print(f"Config.py: Successfully loaded .env from {dotenv_path}")
else:
    print(f"Config.py: .env file not found at {dotenv_path}. Relying on environment variables set externally.")


# --- Logging Setup ---
# Use a generic logger name for config.py, or a project-specific one if preferred
config_logger = logging.getLogger("backend_config")
if not config_logger.hasHandlers():
    handler = logging.StreamHandler()
    formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - [%(module)s:%(lineno)d] - %(message)s')
    handler.setFormatter(formatter)
    config_logger.addHandler(handler)
config_logger.setLevel(logging.INFO)


# --- Configuration Values ---
DATABASE_URL = os.getenv("DATABASE_URL")
DEFAULT_MODEL_NAME = os.getenv("DEFAULT_MODEL_NAME", "openai/clip-vit-base-patch32")
DEFAULT_GENERATION_STRATEGY = os.getenv("DEFAULT_GENERATION_STRATEGY", "keyframe_midpoint")
NUM_RESULTS = int(os.getenv("NUM_RESULTS", 10))

# S3 Specific Environment Variables (will be used by get_s3_resources)
S3_DEV_BUCKET_NAME = os.getenv("S3_DEV_BUCKET_NAME")
S3_PROD_BUCKET_NAME = os.getenv("S3_PROD_BUCKET_NAME")
AWS_REGION = os.getenv("AWS_REGION", "us-west-1") # Default if not set

# CloudFront - kept for compatibility, ensure it's set if used elsewhere
CLOUDFRONT_DOMAIN = os.getenv("CLOUDFRONT_DOMAIN")


# --- Input Validation (for critical startup configs) ---
if not DATABASE_URL:
    config_logger.critical("FATAL: DATABASE_URL not found. Application core functionality will fail.")
    raise ValueError("DATABASE_URL not found in environment variables.")

# CLOUDFRONT_DOMAIN validation can remain if it's critical for other parts of app startup
if not CLOUDFRONT_DOMAIN:
    config_logger.critical("FATAL: CLOUDFRONT_DOMAIN not found. Relevant functionalities will fail.")
    raise ValueError("CLOUDFRONT_DOMAIN not found in environment variables.")

# Basic check for S3 bucket names at load time (get_s3_resources will do more specific checks)
if not S3_DEV_BUCKET_NAME:
    config_logger.warning("S3_DEV_BUCKET_NAME is not set. 'development' S3 operations will fail if not overridden.")
if not S3_PROD_BUCKET_NAME:
    config_logger.warning("S3_PROD_BUCKET_NAME is not set. 'production' S3 operations will fail if not overridden.")
if not AWS_REGION:
    config_logger.warning("AWS_REGION is not set explicitly, defaulting to 'us-west-1'. This might not be intended for production.")


# --- Utility Function for S3 Resources ---
def get_s3_resources(environment: str, logger: logging.Logger = None):
    """
    Provides an S3 client and bucket name based on the specified environment.

    Args:
        environment (str): The execution environment, e.g., "development" or "production".
        logger (logging.Logger, optional): Logger to use. Defaults to config_logger.

    Returns:
        tuple: (boto3.S3.Client, str) S3 client and S3 bucket name.

    Raises:
        ValueError: If required S3 configuration (bucket name, region) is missing for the environment.
        RuntimeError: If the S3 client fails to initialize (e.g., credentials issue).
    """
    log = logger if logger else config_logger # Use provided logger or fallback
    log.info(f"get_s3_resources called for environment: '{environment}'")

    s3_bucket_name = None
    effective_aws_region = os.getenv("AWS_REGION", "us-west-1") # Re-fetch for safety, respect override

    if environment == "production":
        s3_bucket_name = os.getenv("S3_PROD_BUCKET_NAME")
        log.info(f"Using PRODUCTION S3 Bucket: '{s3_bucket_name}' from S3_PROD_BUCKET_NAME")
    elif environment == "development":
        s3_bucket_name = os.getenv("S3_DEV_BUCKET_NAME")
        log.info(f"Using DEVELOPMENT S3 Bucket: '{s3_bucket_name}' from S3_DEV_BUCKET_NAME")
    else:
        err_msg = f"Invalid environment '{environment}' specified for S3 resource configuration. Must be 'development' or 'production'."
        log.error(err_msg)
        raise ValueError(err_msg)

    if not s3_bucket_name:
        err_msg = f"S3 bucket name not configured for environment '{environment}'. Ensure S3_PROD_BUCKET_NAME or S3_DEV_BUCKET_NAME is set."
        log.error(err_msg)
        raise ValueError(err_msg)

    if not effective_aws_region:
        err_msg = "AWS_REGION is not configured. Cannot initialize S3 client."
        log.error(err_msg)
        raise ValueError(err_msg)

    try:
        s3_client = boto3.client("s3", region_name=effective_aws_region)
        log.info(f"S3 client initialized successfully for region: {effective_aws_region}")
        return s3_client, s3_bucket_name
    except NoCredentialsError as e:
        err_msg = f"AWS credentials not found. Cannot initialize S3 client for region '{effective_aws_region}'. Error: {e}"
        log.error(err_msg)
        raise RuntimeError(err_msg) from e
    except ClientError as e:
        err_msg = f"AWS ClientError while initializing S3 client for region '{effective_aws_region}'. Error: {e}"
        log.error(err_msg)
        raise RuntimeError(err_msg) from e
    except Exception as e:
        err_msg = f"Unexpected error initializing S3 client for region '{effective_aws_region}'. Error: {e}"
        log.error(err_msg, exc_info=True) # Include stack trace for unexpected errors
        raise RuntimeError(err_msg) from e


# --- Log Loaded Configuration ---
config_logger.info("--- Backend Configuration Loaded ---")
config_logger.info(f"DATABASE_URL (first 15 chars): {DATABASE_URL[:15]}...")
config_logger.info(f"S3_DEV_BUCKET_NAME: {S3_DEV_BUCKET_NAME}")
config_logger.info(f"S3_PROD_BUCKET_NAME: {S3_PROD_BUCKET_NAME}")
config_logger.info(f"AWS_REGION: {AWS_REGION}")
config_logger.info(f"CLOUDFRONT_DOMAIN: {CLOUDFRONT_DOMAIN}")
config_logger.info(f"Default Model: {DEFAULT_MODEL_NAME}")
config_logger.info(f"Default Strategy: {DEFAULT_GENERATION_STRATEGY}")
config_logger.info(f"Number of Results: {NUM_RESULTS}")
config_logger.info("----------------------------------")