import argparse
import json
import logging
import os
import shutil
import subprocess
import sys
import tempfile
import threading
from datetime import datetime
from pathlib import Path

import boto3
import psycopg2
import yt_dlp
from botocore.exceptions import ClientError, NoCredentialsError

# --- Local Imports ---
try:
    # Use relative imports for sibling modules within the package
    from .utils.db import get_db_connection
    from .utils.process_utils import run_ffmpeg_command
except ImportError:
    # Fallback for when script is run directly
    project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    if project_root not in sys.path:
        sys.path.insert(0, project_root)
    from py_tasks.utils.db import get_db_connection
    from py_tasks.utils.process_utils import run_ffmpeg_command


# --- Logging Configuration ---
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


# --- Task Configuration ---
FINAL_SUFFIX = "_qt"
FFMPEG_ARGS = [
    "-map",
    "0",
    "-c:v:0",
    "libx264",
    "-preset",
    "fast",
    "-crf",
    "20",
    "-pix_fmt",
    "yuv420p",
    "-c:a:0",
    "aac",
    "-b:a",
    "192k",
    "-c:s",
    "mov_text",
    "-c:d",
    "copy",
    "-c:v:1",
    "copy",  # Attempt to copy 2nd video stream (e.g., thumbnail)
    "-movflags",
    "+faststart",
]


# --- S3 Upload Progress Callback Class ---
class S3TransferProgress:
    """Callback for boto3 reporting progress via a standard logger"""

    def __init__(self, total_size, filename, logger_instance, throttle_percentage=5):
        self._filename = filename
        self._total_size = total_size
        self._seen_so_far = 0
        self._lock = threading.Lock()
        self._logger = logger_instance
        try:
            self._throttle_percentage = max(1, min(int(throttle_percentage), 100))
        except (ValueError, TypeError):
            self._logger.warning(
                f"Invalid throttle_percentage '{throttle_percentage}', defaulting to 5."
            )
            self._throttle_percentage = 5
        self._last_logged_percentage = -1

    def __call__(self, bytes_amount):
        try:
            with self._lock:
                self._seen_so_far += bytes_amount
                current_percentage = 0
                if isinstance(self._total_size, (int, float)) and self._total_size > 0:
                    try:
                        current_percentage = int(
                            (self._seen_so_far / self._total_size) * 100
                        )
                    except Exception as calc_err:
                        self._logger.warning(
                            f"S3 Progress ({self._filename}): Error calculating percentage: {calc_err}"
                        )
                        current_percentage = 0
                elif self._total_size == 0:
                    current_percentage = 100

                should_log = False
                try:
                    last_logged_int = int(self._last_logged_percentage)
                    throttle_int = int(self._throttle_percentage)
                    should_log = (
                        current_percentage >= last_logged_int + throttle_int
                        and current_percentage < 100
                    ) or (current_percentage == 100 and last_logged_int != 100)
                except Exception as comp_err:
                    self._logger.warning(
                        f"S3 Progress ({self._filename}): Error during logging comparison: {comp_err}"
                    )
                    should_log = False

                if should_log:
                    try:
                        size_mb = float(self._seen_so_far) / (1024 * 1024)
                        total_size_mb = (
                            float(self._total_size) / (1024 * 1024)
                            if isinstance(self._total_size, (int, float))
                            and self._total_size > 0
                            else 0.0
                        )
                        self._logger.info(
                            f"S3 Upload: {self._filename} - {current_percentage}% complete "
                            f"({size_mb:.2f}/{total_size_mb:.2f} MiB)"
                        )
                        self._last_logged_percentage = current_percentage
                    except Exception as log_fmt_err:
                        self._logger.warning(
                            f"S3 Progress ({self._filename}): Error formatting log message: {log_fmt_err}"
                        )

                elif (
                    self._total_size == 0
                    and self._seen_so_far == 0
                    and self._last_logged_percentage == -1
                ):
                    self._logger.info(
                        f"S3 Upload: {self._filename} - 100% complete (0.00/0.00 MiB)"
                    )
                    self._last_logged_percentage = 100

        except Exception as callback_err:
            self._logger.error(
                f"S3 Progress ({self._filename}): Unexpected error in progress callback: {callback_err}",
                exc_info=True,
            )


# --- Stateless Task Function ---
def run_intake(
    source_video_id: int, input_source: str, environment: str, **kwargs
):
    """
    Intakes a source video: downloads/copies, re-encodes, uploads to S3, updates DB.
    This is a stateless function orchestrated by an external runner.
    
    Args:
        source_video_id: The ID of the source video in the database.
        input_source: URL or local file path to the video.
        environment: The runtime environment (e.g., "development", "production").
        **kwargs:
            re_encode_for_qt (bool): Re-encode for QuickTime compatibility. Defaults to True.
            overwrite_existing (bool): Overwrite existing files on S3. Defaults to False.
    """
    re_encode_for_qt = kwargs.get("re_encode_for_qt", True)
    overwrite_existing = kwargs.get("overwrite_existing", False)

    logger.info(
        f"RUNNING INTAKE for source_video_id: {source_video_id}, Input: '{input_source}', Env: {environment}"
    )

    # --- Get S3 Resources from Environment ---
    s3_bucket_name = os.getenv("S3_BUCKET_NAME")
    if not s3_bucket_name:
        raise ValueError("S3_BUCKET_NAME environment variable not set.")

    try:
        s3_client = boto3.client("s3")  # Credentials from env vars
    except NoCredentialsError:
        logger.error("S3 credentials not found. Configure AWS_ACCESS_KEY_ID, etc.")
        raise

    initial_temp_filepath = None
    s3_object_key = None
    final_filename_for_db = None
    metadata = {}
    temp_dir_obj = None
    error_message = None  # Store error message for DB update if needed

    is_url = input_source.lower().startswith(("http://", "https://"))
    # Check for ffmpeg dependency if re-encoding is needed or it's a local file op
    if re_encode_for_qt or not is_url:
        if not shutil.which("ffmpeg"):
            error_message = "Dependency 'ffmpeg' not found in PATH."
            logger.error(error_message)
            raise FileNotFoundError(error_message)
    if not is_url:
        if not shutil.which("ffprobe"):
            logger.warning(
                "Dependency 'ffprobe' not found in PATH. Metadata from local files will be limited."
            )
    logger.info("Checked dependencies (S3 client OK, ffmpeg/ffprobe if needed).")

    try:
        # --- Database Connection and State Check ---
        with get_db_connection() as conn:
            with conn.cursor() as cur:
                # Acquire a transactional lock on the source video record
                try:
                    cur.execute(
                        "SELECT pg_try_advisory_xact_lock(1, %s)", (source_video_id,)
                    )
                    if not cur.fetchone()[0]:
                        logger.warning(
                            f"Could not acquire DB lock for source_video_id: {source_video_id}. Another process may be running. Skipping."
                        )
                        # This is not an error, but a deliberate skip.
                        return {"status": "skipped_lock", "source_video_id": source_video_id}
                    logger.info(f"Acquired DB lock for source_video_id: {source_video_id}")
                except Exception as lock_err:
                    logger.error(
                        f"Error acquiring DB lock for {source_video_id}: {lock_err}",
                        exc_info=True,
                    )
                    raise RuntimeError("DB Lock acquisition failed") from lock_err

                cur.execute(
                    "SELECT ingest_state, filepath FROM source_videos WHERE id = %s FOR UPDATE",
                    (source_video_id,),
                )
                result = cur.fetchone()
                if not result:
                    raise ValueError(
                        f"Source video with ID {source_video_id} not found."
                    )
                current_state, existing_filepath = result
                logger.info(f"Current DB state for {source_video_id}: '{current_state}'")

                # Idempotency check: decide if we should proceed
                if is_url:
                    allow_processing = current_state in (
                        "new",
                        "downloading",
                        "download_failed",
                    )
                else:  # local file
                    allow_processing = current_state in (
                        "new",
                        "processing_local",
                        "download_failed",
                    )

                if current_state == "downloaded" and not overwrite_existing:
                    logger.info(
                        f"Source video {source_video_id} is already 'downloaded' and overwrite=False. Skipping."
                    )
                    return {
                        "status": "skipped_exists",
                        "source_video_id": source_video_id,
                        "s3_key": existing_filepath,
                    }

                if not allow_processing and not overwrite_existing:
                    logger.warning(
                        f"Skipping {source_video_id}: current state is '{current_state}' and overwrite is False."
                    )
                    return {
                        "status": "skipped_state",
                        "source_video_id": source_video_id,
                    }

                # --- Mark as Processing ---
                initial_state_for_update = (
                    "downloading" if is_url else "processing_local"
                )
                cur.execute(
                    "UPDATE source_videos SET ingest_state = %s, updated_at = NOW() WHERE id = %s",
                    (initial_state_for_update, source_video_id),
                )
                logger.info(
                    f"Updated DB state for {source_video_id} to '{initial_state_for_update}'"
                )
                conn.commit()

        # --- Main Processing Block (outside initial DB transaction) ---
        temp_dir_obj = tempfile.TemporaryDirectory(prefix="intake_")
        temp_dir = temp_dir_obj.name
        logger.info(f"Created temporary directory: {temp_dir}")

        # --- Stage 1: Download or Copy File ---
        if is_url:
            # --- YouTube-DLp Download Logic ---
            logger.info(f"Input is a URL, using yt-dlp to download: {input_source}")

            # Nested logger for yt-dlp hooks
            class YtdlpLogger:
                def debug(self, msg):
                    if msg.startswith("[debug] "):
                        pass
                    else:
                        logger.debug(msg)

                def info(self, msg):
                    logger.info(msg)

                def warning(self, msg):
                    logger.warning(msg)

                def error(self, msg):
                    logger.error(msg)

            download_finished = False

            def ytdlp_progress_hook(d):
                nonlocal download_finished
                if d["status"] == "finished":
                    nonlocal initial_temp_filepath
                    initial_temp_filepath = d.get("filename")
                    download_finished = True
                    logger.info(
                        f"yt-dlp hook: Download finished. File at: {initial_temp_filepath}"
                    )
                elif d["status"] == "downloading":
                    progress_str = d.get("_percent_str", "N/A")
                    speed_str = d.get("_speed_str", "N/A")
                    eta_str = d.get("_eta_str", "N/A")
                    logger.info(
                        f"yt-dlp progress: {progress_str} | Speed: {speed_str} | ETA: {eta_str}"
                    )

            output_template = os.path.join(temp_dir, "%(title)s.%(ext)s")
            ydl_opts = {
                "format": "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best",
                "outtmpl": output_template,
                "logger": YtdlpLogger(),
                "progress_hooks": [ytdlp_progress_hook],
                "nocheckcertificate": True,
                "retries": 5,
            }
            try:
                with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                    info_dict = ydl.extract_info(input_source, download=False)
                    metadata.update(
                        {
                            "title": info_dict.get("title"),
                            "original_url": info_dict.get("webpage_url"),
                            "uploader": info_dict.get("uploader"),
                            "duration": info_dict.get("duration"),
                            "upload_date": info_dict.get("upload_date"),
                            "extractor": info_dict.get("extractor_key"),
                            "width": info_dict.get("width"),
                            "height": info_dict.get("height"),
                            "fps": info_dict.get("fps"),
                        }
                    )
                    ydl.download([input_source])

                if (
                    not download_finished
                    or not initial_temp_filepath
                    or not os.path.exists(initial_temp_filepath)
                ):
                    raise RuntimeError(
                        "yt-dlp finished but the output file is missing."
                    )
            except Exception as ydl_err:
                error_message = f"yt-dlp download failed: {str(ydl_err)}"
                logger.error(error_message, exc_info=True)
                raise  # Re-raise to be caught by the main try/except block

            final_filename_for_db = f"source_videos/{source_video_id}/{Path(initial_temp_filepath).name}"

        else:  # It's a local file path
            logger.info(f"Input is a local file, copying to temp dir: {input_source}")
            if not os.path.exists(input_source):
                raise FileNotFoundError(f"Local input file not found: {input_source}")

            temp_destination = os.path.join(temp_dir, os.path.basename(input_source))
            shutil.copy2(input_source, temp_destination)
            initial_temp_filepath = temp_destination
            logger.info(f"Copied local file to {initial_temp_filepath}")
            final_filename_for_db = f"source_videos/{source_video_id}/{os.path.basename(input_source)}"

        # --- Stage 2: Re-encode (if requested) ---
        file_to_upload = initial_temp_filepath
        if re_encode_for_qt:
            logger.info(
                f"Re-encoding '{Path(initial_temp_filepath).name}' for QuickTime compatibility."
            )
            output_filename = f"{Path(initial_temp_filepath).stem}{FINAL_SUFFIX}.mp4"
            output_filepath = os.path.join(temp_dir, output_filename)

            ffmpeg_cmd = ["-i", initial_temp_filepath, *FFMPEG_ARGS, output_filepath]
            run_ffmpeg_command(ffmpeg_cmd, "re-encoding", cwd=temp_dir)

            file_to_upload = output_filepath
            final_filename_for_db = (
                f"source_videos/{source_video_id}/{output_filename}"
            )
            logger.info(
                f"Re-encoding complete. New file to upload: {output_filepath}"
            )
        else:
            logger.info("Skipping re-encoding as requested.")

        # --- Stage 3: Upload to S3 ---
        s3_object_key = (
            final_filename_for_db  # Use the final calculated name for the S3 key
        )
        logger.info(
            f"Uploading '{Path(file_to_upload).name}' to S3 bucket '{s3_bucket_name}' with key '{s3_object_key}'"
        )

        try:
            file_size = os.path.getsize(file_to_upload)
            progress_callback = S3TransferProgress(
                file_size, os.path.basename(file_to_upload), logger
            )
            s3_client.upload_file(
                file_to_upload, s3_bucket_name, s3_object_key, Callback=progress_callback
            )
            logger.info("Successfully uploaded to S3.")
        except ClientError as e:
            error_message = f"S3 upload failed: {e.response['Error']['Message']}"
            logger.error(error_message, exc_info=True)
            raise RuntimeError(error_message) from e
        except Exception as e:
            error_message = f"An unexpected error occurred during S3 upload: {e}"
            logger.error(error_message, exc_info=True)
            raise RuntimeError(error_message) from e

        # --- Final DB Update on Success ---
        with get_db_connection() as conn:
            with conn.cursor() as cur:
                logger.info(
                    f"Updating DB for {source_video_id}: state='downloaded', filepath='{s3_object_key}'"
                )

                db_metadata = {
                    "title": metadata.get("title"),
                    "original_url": metadata.get("original_url"),
                    "uploader": metadata.get("uploader"),
                    "duration": metadata.get("duration"),
                    "upload_date": metadata.get("upload_date"),
                    "extractor": metadata.get("extractor"),
                    "width": metadata.get("width"),
                    "height": metadata.get("height"),
                    "fps": metadata.get("fps"),
                }

                cur.execute(
                    """
                    UPDATE source_videos
                    SET ingest_state = 'downloaded',
                        filepath = %s,
                        title = COALESCE(%s, title),
                        metadata = metadata || %s,
                        duration_seconds = %s,
                        width = %s,
                        height = %s,
                        fps = %s,
                        downloaded_at = NOW(),
                        updated_at = NOW()
                    WHERE id = %s
                    """,
                    (
                        s3_object_key,
                        db_metadata.get("title"),
                        json.dumps(db_metadata),
                        db_metadata.get("duration"),
                        db_metadata.get("width"),
                        db_metadata.get("height"),
                        db_metadata.get("fps"),
                        source_video_id,
                    ),
                )
                conn.commit()

        logger.info(f"SUCCESS: Intake task finished for source_video_id: {source_video_id}")
        return {
            "status": "success",
            "source_video_id": source_video_id,
            "s3_key": s3_object_key,
        }

    except Exception as e:
        logger.error(
            f"FATAL: Intake failed for source_video_id {source_video_id}: {e}",
            exc_info=True,
        )
        error_message = str(e)
        # --- Final DB Update on Failure ---
        try:
            with get_db_connection() as conn:
                with conn.cursor() as cur:
                    logger.error(
                        f"Attempting to mark source_video_id {source_video_id} as 'ingestion_failed'"
                    )
                    cur.execute(
                        """
                        UPDATE source_videos 
                        SET ingest_state = 'ingestion_failed', 
                            last_error = %s,
                            retry_count = retry_count + 1
                        WHERE id = %s
                        """,
                        (error_message, source_video_id),
                    )
                    conn.commit()
        except Exception as db_fail_err:
            logger.error(
                f"CRITICAL: Failed to update DB state to 'ingestion_failed' for {source_video_id}: {db_fail_err}",
                exc_info=True,
            )

        # Re-raise the original exception to signal failure to the runner
        raise

    finally:
        # --- Cleanup ---
        if temp_dir_obj:
            try:
                temp_dir_obj.cleanup()
                logger.info("Cleaned up temporary directory.")
            except Exception as cleanup_err:
                logger.warning(
                    f"Failed to clean up temporary directory {temp_dir_obj.name}: {cleanup_err}"
                )


# --- Direct invocation for testing ---
if __name__ == "__main__":
    # This block allows for direct testing of the intake script.
    # Example:
    # export DATABASE_URL="..."
    # export S3_BUCKET_NAME="..."
    # python -m py_tasks.intake --source-id 123 --url "https://www.youtube.com/watch?v=..."

    parser = argparse.ArgumentParser(
        description="Run the intake process for a single video."
    )
    parser.add_argument(
        "--source-id", required=True, type=int, help="The source_video_id from the database."
    )
    parser.add_argument("--url", required=True, help="The URL of the video to intake.")
    parser.add_argument("--env", default="development", help="The environment.")
    parser.add_argument(
        "--no-re-encode", action="store_true", help="Skip re-encoding step."
    )
    parser.add_argument(
        "--overwrite", action="store_true", help="Overwrite existing S3 files."
    )

    args = parser.parse_args()

    try:
        result = run_intake(
            source_video_id=args.source_id,
            input_source=args.url,
            environment=args.env,
            re_encode_for_qt=not args.no_re_encode,
            overwrite_existing=args.overwrite,
        )
        print("Intake finished successfully.")
        print(json.dumps(result, indent=2))
        sys.exit(0)
    except Exception as e:
        print(f"Intake failed: {e}", file=sys.stderr)
        sys.exit(1)