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
DEFAULT_MODEL_NAME = os.getenv("DEFAULT_MODEL_NAME", "openai/clip-vit-base-patch32")
DEFAULT_GENERATION_STRATEGY = os.getenv("DEFAULT_GENERATION_STRATEGY", "keyframe_midpoint")
NUM_RESULTS = int(os.getenv("NUM_RESULTS", 10))

# Database URLs
DEV_DATABASE_URL = os.getenv("DEV_DATABASE_URL")
PROD_DATABASE_URL = os.getenv("PROD_DATABASE_URL")

# S3 Specific Environment Variables (will be used by get_s3_resources)
S3_DEV_BUCKET_NAME = os.getenv("S3_DEV_BUCKET_NAME")
S3_PROD_BUCKET_NAME = os.getenv("S3_PROD_BUCKET_NAME")
AWS_REGION = os.getenv("AWS_REGION", "us-west-1") # Default if not set

# CloudFront Domains (New)
CLOUDFRONT_DEV_DOMAIN = os.getenv("CLOUDFRONT_DEV_DOMAIN")
CLOUDFRONT_PROD_DOMAIN = os.getenv("CLOUDFRONT_PROD_DOMAIN")


# --- Input Validation (for critical startup configs) ---

if not DEV_DATABASE_URL:
    config_logger.warning("DEV_DATABASE_URL is not set. 'development' database operations will fail if not overridden or if it's the default.")
if not PROD_DATABASE_URL:
    config_logger.warning("PROD_DATABASE_URL is not set. 'production' database operations will fail.")

if not CLOUDFRONT_DEV_DOMAIN:
    config_logger.warning("CLOUDFRONT_DEV_DOMAIN is not set. 'development' CloudFront URLs may be incorrect.")
if not CLOUDFRONT_PROD_DOMAIN:
    config_logger.warning("CLOUDFRONT_PROD_DOMAIN is not set. 'production' CloudFront URLs may be incorrect.")

# Basic check for S3 bucket names at load time (get_s3_resources will do more specific checks)
if not S3_DEV_BUCKET_NAME:
    config_logger.warning("S3_DEV_BUCKET_NAME is not set. 'development' S3 operations will fail if not overridden.")
if not S3_PROD_BUCKET_NAME:
    config_logger.warning("S3_PROD_BUCKET_NAME is not set. 'production' S3 operations will fail if not overridden.")
if not AWS_REGION:
    config_logger.warning("AWS_REGION is not set explicitly, defaulting to 'us-west-1'. This might not be intended for production.")


# --- Utility Function for Database URL ---
def get_database_url(environment: str, logger: logging.Logger = None) -> str:
    """
    Provides the database connection URL based on the specified environment.

    Args:
        environment (str): The execution environment, e.g., "development" or "production".
        logger (logging.Logger, optional): Logger to use. Defaults to config_logger.

    Returns:
        str: The database connection URL.

    Raises:
        ValueError: If the required database URL for the environment is missing.
    """
    log = logger if logger else config_logger
    db_url = None

    if environment == "production":
        db_url = PROD_DATABASE_URL
        log.info(f"Using PRODUCTION Database URL (is set: {bool(db_url)})")
    elif environment == "development":
        db_url = DEV_DATABASE_URL
        log.info(f"Using DEVELOPMENT Database URL (is set: {bool(db_url)})")
    else:
        log.warning(f"Unknown environment '{environment}' specified for database URL. Defaulting to DEVELOPMENT.")
        db_url = DEV_DATABASE_URL # Default to dev for unknown environments
        log.info(f"Using DEVELOPMENT Database URL for unknown env '{environment}' (is set: {bool(db_url)})")

    if not db_url:
        err_msg = f"Database URL not configured for environment '{environment}'. Check DEV_DATABASE_URL/PROD_DATABASE_URL."
        log.error(err_msg)
        raise ValueError(err_msg)
    
    return db_url

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

# --- Utility Function for CloudFront Domain ---
def get_cloudfront_domain(environment: str, logger: logging.Logger = None) -> str:
    """
    Provides the CloudFront domain based on the specified environment.

    Args:
        environment (str): The execution environment, e.g., "development" or "production".
        logger (logging.Logger, optional): Logger to use. Defaults to config_logger.

    Returns:
        str: The CloudFront domain.

    Raises:
        ValueError: If the CloudFront domain for the environment is missing.
    """
    log = logger if logger else config_logger
    cloudfront_domain_val = None

    if environment == "production":
        cloudfront_domain_val = CLOUDFRONT_PROD_DOMAIN
        log.info(f"Using PRODUCTION CloudFront Domain: {cloudfront_domain_val} (is set: {bool(cloudfront_domain_val)})")
    elif environment == "development":
        cloudfront_domain_val = CLOUDFRONT_DEV_DOMAIN
        log.info(f"Using DEVELOPMENT CloudFront Domain: {cloudfront_domain_val} (is set: {bool(cloudfront_domain_val)})")
    else:
        log.warning(f"Unknown environment '{environment}' specified for CloudFront domain. Defaulting to DEVELOPMENT.")
        cloudfront_domain_val = CLOUDFRONT_DEV_DOMAIN # Default to dev for unknown environments
        log.info(f"Using DEVELOPMENT CloudFront Domain for unknown env '{environment}': {cloudfront_domain_val} (is set: {bool(cloudfront_domain_val)})")

    if not cloudfront_domain_val:
        err_msg = f"CloudFront domain not configured for environment '{environment}'. Check CLOUDFRONT_DEV_DOMAIN/CLOUDFRONT_PROD_DOMAIN."
        log.error(err_msg)
        raise ValueError(err_msg)
    
    return cloudfront_domain_val


# --- Log Loaded Configuration ---
config_logger.info("--- Backend Configuration Loaded ---")
config_logger.info(f"DEV_DATABASE_URL (first 15 chars): {DEV_DATABASE_URL[:15] if DEV_DATABASE_URL else 'Not Set'}...")
config_logger.info(f"PROD_DATABASE_URL (first 15 chars): {PROD_DATABASE_URL[:15] if PROD_DATABASE_URL else 'Not Set'}...")
config_logger.info(f"S3_DEV_BUCKET_NAME: {S3_DEV_BUCKET_NAME}")
config_logger.info(f"S3_PROD_BUCKET_NAME: {S3_PROD_BUCKET_NAME}")
config_logger.info(f"AWS_REGION: {AWS_REGION}")
config_logger.info(f"CLOUDFRONT_DEV_DOMAIN: {CLOUDFRONT_DEV_DOMAIN}")
config_logger.info(f"CLOUDFRONT_PROD_DOMAIN: {CLOUDFRONT_PROD_DOMAIN}")
config_logger.info(f"Default Model: {DEFAULT_MODEL_NAME}")
config_logger.info(f"Default Strategy: {DEFAULT_GENERATION_STRATEGY}")
config_logger.info(f"Number of Results: {NUM_RESULTS}")
config_logger.info("----------------------------------")