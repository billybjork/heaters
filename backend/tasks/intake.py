import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
from datetime import datetime
from pathlib import Path
import logging

import boto3
from botocore.exceptions import ClientError, NoCredentialsError

from prefect import get_run_logger, task
import yt_dlp

# --- Local Imports ---
try:
    from db.sync_db import get_db_connection, release_db_connection
    from config import get_s3_resources
except ImportError:
    # Standard fallback logic
    project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
    if project_root not in sys.path:
        sys.path.insert(0, project_root)
    try:
        from db.sync_db import get_db_connection, release_db_connection
        from config import get_s3_resources # Import again in fallback
    except ImportError as e:
        print(f"ERROR importing db_utils or config in intake.py: {e}")
        def get_db_connection(environment: str, cursor_factory=None):
            raise NotImplementedError("Dummy get_db_connection")
        def release_db_connection(conn, environment: str):
            raise NotImplementedError("Dummy release_db_connection")
        def get_s3_resources(env, logger=None):
            raise NotImplementedError("Dummy get_s3_resources")


# --- Task Configuration ---
FINAL_SUFFIX = "_qt"
FFMPEG_ARGS = [
    "-map", "0",
    "-c:v:0", "libx264", "-preset", "fast", "-crf", "20", "-pix_fmt", "yuv420p",
    "-c:a:0", "aac", "-b:a", "192k",
    "-c:s", "mov_text",
    "-c:d", "copy",
    "-c:v:1", "copy",  # Attempt to copy 2nd video stream (e.g., thumbnail)
    "-movflags", "+faststart",
]

# --- Helper Function for External Commands ---
def run_external_command(cmd_list, step_name="Command", cwd=None):
    """Runs an external command using subprocess, logs output, and raises errors."""
    logger = get_run_logger()
    cmd_str = ' '.join(cmd_list)
    logger.info(f"Running {step_name}: {cmd_str}")
    try:
        process = subprocess.Popen(
            cmd_list, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding='utf-8', errors='replace', cwd=cwd
        )
        stdout, stderr = process.communicate()

        if process.returncode != 0:
            logger.error(f"Error during '{step_name}': Command failed with exit code {process.returncode}.")
            if stderr: logger.error(f"STDERR (last 1000 chars):\n{stderr[-1000:]}")
            if stdout: logger.error(f"STDOUT (last 1000 chars):\n{stdout[-1000:]}")
            raise subprocess.CalledProcessError(process.returncode, cmd_list, output=stdout, stderr=stderr)
        else:
            pass # Success
        return True

    except FileNotFoundError:
        logger.error(f"Error during '{step_name}': Command not found: '{cmd_list[0]}'. Is it installed and in PATH?")
        raise
    except Exception as e:
        logger.error(f"An unexpected error occurred during '{step_name}': {e}", exc_info=True)
        raise


# --- S3 Upload Progress Callback Class ---
class S3TransferProgress:
    """ Callback for boto3 reporting progress via Prefect logger """
    def __init__(self, total_size, filename, logger, throttle_percentage=5):
        self._filename = filename
        self._total_size = total_size
        self._seen_so_far = 0
        self._lock = threading.Lock()
        self._logger = logger or get_run_logger()
        try:
            self._throttle_percentage = max(1, min(int(throttle_percentage), 100))
        except (ValueError, TypeError):
            self._logger.warning(f"Invalid throttle_percentage '{throttle_percentage}', defaulting to 5.")
            self._throttle_percentage = 5
        self._last_logged_percentage = -1

    def __call__(self, bytes_amount):
        try:
            with self._lock:
                self._seen_so_far += bytes_amount
                current_percentage = 0
                if isinstance(self._total_size, (int, float)) and self._total_size > 0:
                    try:
                        current_percentage = int((self._seen_so_far / self._total_size) * 100)
                    except Exception as calc_err:
                         self._logger.warning(f"S3 Progress ({self._filename}): Error calculating percentage: {calc_err}")
                         current_percentage = 0
                elif self._total_size == 0:
                    current_percentage = 100

                should_log = False
                try:
                    last_logged_int = int(self._last_logged_percentage)
                    throttle_int = int(self._throttle_percentage)
                    should_log = (
                        (current_percentage >= last_logged_int + throttle_int and current_percentage < 100) or
                        (current_percentage == 100 and last_logged_int != 100)
                    )
                except Exception as comp_err:
                    self._logger.warning(f"S3 Progress ({self._filename}): Error during logging comparison: {comp_err}")
                    should_log = False

                if should_log:
                    try:
                        size_mb = float(self._seen_so_far) / (1024 * 1024)
                        total_size_mb = float(self._total_size) / (1024 * 1024) if isinstance(self._total_size, (int, float)) and self._total_size > 0 else 0.0
                        self._logger.info(
                            f"S3 Upload: {self._filename} - {current_percentage}% complete "
                            f"({size_mb:.2f}/{total_size_mb:.2f} MiB)"
                        )
                        self._last_logged_percentage = current_percentage
                    except Exception as log_fmt_err:
                        self._logger.warning(f"S3 Progress ({self._filename}): Error formatting log message: {log_fmt_err}")

                elif self._total_size == 0 and self._seen_so_far == 0 and self._last_logged_percentage == -1:
                    self._logger.info(f"S3 Upload: {self._filename} - 100% complete (0.00/0.00 MiB)")
                    self._last_logged_percentage = 100

        except Exception as callback_err:
            self._logger.error(f"S3 Progress ({self._filename}): Unexpected error in progress callback: {callback_err}", exc_info=True)


# --- Prefect Task ---
@task(name="Intake Source Video", retries=1, retry_delay_seconds=30)
def intake_task(source_video_id: int,
                input_source: str,
                re_encode_for_qt: bool = True,
                overwrite_existing: bool = False,
                environment: str = "development"
                ):
    """
    Intakes a source video: downloads/copies, re-encodes, uploads to S3, updates DB.
    
    Args:
        source_video_id: The ID of the source video in the database
        input_source: URL or local file path to the video
        re_encode_for_qt: Whether to re-encode for QuickTime compatibility
        overwrite_existing: Whether to overwrite existing files
        environment: The environment to use ("development" or "production")
    """
    logger = get_run_logger()
    logger.info(f"TASK [Intake]: Starting for source_video_id: {source_video_id}, Input: '{input_source}', Environment: {environment}")

    # --- Get S3 Resources using the utility function ---
    s3_client_for_task, s3_bucket_name_for_task = get_s3_resources(environment, logger=logger)
    # Error handling for missing S3 resources is now within get_s3_resources

    conn = None
    initial_temp_filepath = None
    s3_object_key = None
    final_filename_for_db = None
    metadata = {}
    temp_dir_obj = None
    task_outcome = "failed" # Default outcome
    error_message = None # Store error message for DB update if needed

    is_url = input_source.lower().startswith(('http://', 'https://'))
    if re_encode_for_qt or not is_url: # Check ffmpeg only if needed
        if not shutil.which("ffmpeg"):
            error_message = "Dependency 'ffmpeg' not found in PATH."
            logger.error(error_message)
            raise FileNotFoundError(error_message)
    if not is_url: # Check ffprobe only for local files
        if not shutil.which("ffprobe"):
            logger.warning("Dependency 'ffprobe' not found in PATH. Metadata from local files will be limited.")
    logger.info("Checked dependencies (S3 client OK, ffmpeg/ffprobe if needed).")

    try:
        # --- Database Connection and Lock Setup ---
        conn = get_db_connection(environment)
        if conn is None:
             # Raise specific error if connection fails initially
             error_message = "Failed to get database connection from pool."
             logger.error(error_message)
             raise ConnectionError(error_message)
        conn.autocommit = False # Manual transaction control

        # --- Acquire Lock and Check State ---
        with conn.cursor() as cur:
            try:
                cur.execute("SELECT pg_try_advisory_xact_lock(1, %s)", (source_video_id,))
                lock_acquired = cur.fetchone()[0]
                if not lock_acquired:
                    logger.warning(f"Could not acquire DB lock for source_video_id: {source_video_id}. Another process may be working on it. Skipping.")
                    conn.rollback()
                    return {"status": "skipped_lock", "reason": "Could not acquire lock", "source_video_id": source_video_id}
                logger.info(f"Acquired DB lock for source_video_id: {source_video_id}")
            except Exception as lock_err:
                logger.error(f"Error checking/acquiring DB lock for source_video_id {source_video_id}: {lock_err}", exc_info=True)
                raise RuntimeError("DB Lock acquisition check failed") from lock_err

            cur.execute("SELECT ingest_state, filepath FROM source_videos WHERE id = %s FOR UPDATE", (source_video_id,))
            result = cur.fetchone()
            if not result:
                raise ValueError(f"Source video with ID {source_video_id} not found in database.")
            current_state, existing_filepath = result
            logger.info(f"Current DB state for {source_video_id}: '{current_state}'")

            expected_processing_state = 'downloading' if is_url else 'processing_local'
            initial_state_before_potential_transition = current_state # Save for state transition logic

            # Determine if processing is allowed based on current state and flags
            if is_url:
                allow_processing = current_state in ('new', 'downloading', 'download_failed') or \
                                   (current_state == 'downloaded' and overwrite_existing)
            else: # local file
                allow_processing = current_state in ('processing_local', 'download_failed') or \
                                   (current_state in ('new', None) and overwrite_existing) or \
                                   (current_state == 'downloaded' and overwrite_existing)

            # Specific check for 'downloaded' state when not overwriting (takes precedence)
            if initial_state_before_potential_transition == 'downloaded' and not overwrite_existing:
                logger.info(f"Source video {source_video_id} is already 'downloaded' and overwrite=False. Skipping.")
                allow_processing = False # Override previous decision
                task_outcome = "skipped_already_done"

            if not allow_processing:
                # Build a more accurate reason message for skipping
                expected_conditions_msg_parts = []
                if is_url:
                    expected_conditions_msg_parts.extend(["'new'", "'downloading'", "'download_failed'"])
                    if overwrite_existing: expected_conditions_msg_parts.append("'downloaded' (with Overwrite=True)")
                else: # local file
                    if overwrite_existing: expected_conditions_msg_parts.append("'new'/'None' (with Overwrite=True)")
                    expected_conditions_msg_parts.append("'processing_local'")
                    # Consider if 'download_failed' is truly expected for local files or if it implies a prior URL attempt
                    expected_conditions_msg_parts.append("'download_failed'")
                    if overwrite_existing: expected_conditions_msg_parts.append("'downloaded' (with Overwrite=True)")
                
                # Remove duplicates and join for a clean message
                reason_detail = f"expected one of {', '.join(sorted(list(set(expected_conditions_msg_parts))))}"
                
                final_reason_str = f"State '{current_state}' not runnable ({reason_detail} for Overwrite={overwrite_existing})"
                if task_outcome == "skipped_already_done": # This reason is more specific
                    final_reason_str = "Already downloaded and overwrite=False"

                logger.warning(f"Skipping intake task for source video {source_video_id}. Reason: {final_reason_str}.")
                conn.rollback() # Release lock/transaction

                return {"status": "skipped_already_done" if task_outcome == "skipped_already_done" else "skipped_state",
                        "reason": final_reason_str, "s3_key": existing_filepath, "source_video_id": source_video_id}

            # If processing is allowed, and current_state needs to be updated to expected_processing_state
            # This transition is necessary if starting from 'new', 'download_failed',
            # or 'downloaded' (if overwriting), and current_state is not already expected_processing_state.
            needs_transition_to_active_state = \
                initial_state_before_potential_transition != expected_processing_state and \
                (initial_state_before_potential_transition in ('new', None, 'download_failed', 'processing_failed') or
                 (initial_state_before_potential_transition == 'downloaded' and overwrite_existing))

            if needs_transition_to_active_state:
                logger.info(f"Transitioning state for {source_video_id} from '{initial_state_before_potential_transition}' to '{expected_processing_state}' before I/O (Overwrite={overwrite_existing}).")
                cur.execute(
                    "UPDATE source_videos SET ingest_state = %s, last_error = NULL WHERE id = %s AND ingest_state = %s",
                    (expected_processing_state, source_video_id, initial_state_before_potential_transition)
                )
                if cur.rowcount == 0:
                    # This implies the state changed between SELECT FOR UPDATE and this UPDATE.
                    # Should be rare due to row lock, but a critical check.
                    logger.error(f"CRITICAL: Failed to transition state from '{initial_state_before_potential_transition}' to '{expected_processing_state}' for ID {source_video_id}. State may have changed concurrently. Aborting.")
                    conn.rollback()
                    raise RuntimeError(f"DB state transition failed for {source_video_id} due to concurrent modification or unexpected state.")
            
            # If processing allowed, commit to release row lock before long I/O
            conn.commit()
            logger.info(f"Verified state. Proceeding with intake processing for ID {source_video_id} (DB state should now be '{expected_processing_state}' for final concurrency check)...")
            # Advisory lock is also released by commit.

        # === Core Processing in Temporary Directory ===
        temp_dir_obj = tempfile.TemporaryDirectory(prefix=f"heaters_intake_{source_video_id}_")
        temp_dir = Path(temp_dir_obj.name)
        logger.info(f"Using temporary directory: {temp_dir}")

        base_filename_no_ext = f"source_{source_video_id}_video" # Safer default

        if is_url:
            # --- Handle URL Download ---
            logger.info("Input is URL. Processing with yt-dlp...")
            output_template = str(temp_dir.joinpath('%(title).100B [%(id)s].%(ext)s'))

            class YtdlpLogger: # Ensure this class is defined here or accessible
                def debug(self, msg): logger.debug(f"yt-dlp debug: {msg}") if not msg.startswith('[debug] ') else None
                def warning(self, msg): logger.warning(f"yt-dlp warning: {msg}")
                def error(self, msg): logger.error(f"yt-dlp error: {msg}")
                def info(self, msg): logger.info(f"yt-dlp: {msg}")

            def ytdlp_progress_hook(d): # Ensure this function is defined here or accessible
                if d['status'] == 'downloading':
                    progress_info = f"{d.get('_percent_str', 'N/A%')} ({d.get('_downloaded_bytes_str', '?')}/{d.get('_total_bytes_str', '?')}) Speed:{d.get('_speed_str', '?')} ETA:{d.get('_eta_str', '?')}"
                    logger.debug(f"yt-dlp: Downloading... {progress_info}")
                elif d['status'] == 'finished':
                    logger.info(f"yt-dlp: Finished downloading {d.get('filename')} Total size: {d.get('total_bytes_str') or d.get('downloaded_bytes_str')}")
                elif d['status'] == 'error':
                    logger.error(f"yt-dlp: Error during download for {d.get('filename')}")

            # Define format preferences
            format_primary = 'bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b'
            format_fallback = 'bestvideo[ext=mp4][vcodec^=avc1]+bestaudio[ext=m4a]/best[ext=mp4]/best'

            base_ydl_opts = {
                'outtmpl': output_template,
                'merge_output_format': 'mp4',
                'embedmetadata': True,
                'embedthumbnail': True,
                'restrictfilenames': True,
                'ignoreerrors': False,  # Fail on error to trigger fallback
                'logger': YtdlpLogger(),
                'progress_hooks': [ytdlp_progress_hook],
                'noprogress': False,
                'socket_timeout': 120,
                'postprocessor_args': { # Kept as user provided, may need review if problematic
                    'ffmpeg_i': ['-err_detect', 'ignore_err'],
                },
                'fragment_retries': 10,
                'skip_unavailable_fragments': True,
                # 'retries': 3, # yt-dlp's own retries for the whole download attempt
            }

            download_successful = False
            info_dict = None
            video_title = f'Untitled Video {source_video_id}' # Default
            # initial_temp_filepath will be set after a successful download

            # Attempt 1: Primary (Best Quality) Format
            current_attempt_format_str = format_primary
            logger.info(f"yt-dlp: Attempt 1 - Using primary format: '{current_attempt_format_str}'")
            ydl_opts_attempt1 = {**base_ydl_opts, 'format': current_attempt_format_str}

            try:
                with yt_dlp.YoutubeDL(ydl_opts_attempt1) as ydl:
                    logger.info(f"Extracting info (Attempt 1) for {input_source}...")
                    temp_info_dict = ydl.extract_info(input_source, download=False)
                    video_title = temp_info_dict.get('title', video_title)

                    logger.info(f"Downloading video (Attempt 1): '{video_title}'...")
                    ydl.download([input_source])

                downloaded_files = list(temp_dir.glob('*.mp4'))
                if not downloaded_files:
                    raise FileNotFoundError("yt-dlp (Attempt 1) finished but no MP4 output file found.")
                initial_temp_filepath = downloaded_files[0]

                # Re-populate info_dict from the successful download to ensure accuracy for metadata (as per user plan)
                with yt_dlp.YoutubeDL({'logger': YtdlpLogger(), 'quiet': True, 'skip_download': True, 'extract_flat': 'in_playlist'}) as ydl_info_check:
                     info_dict = ydl_info_check.extract_info(input_source, download=False)

                download_successful = True
                logger.info("yt-dlp: Download successful with primary format.")

            except yt_dlp.utils.DownloadError as e_primary:
                logger.warning(f"yt-dlp: Primary download attempt (format: '{format_primary}') failed: {e_primary}. Trying fallback.")
                logger.debug(f"Cleaning up temp_dir '{temp_dir}' before fallback attempt...")
                for item in temp_dir.iterdir():
                    try:
                        if item.is_file(): item.unlink(); logger.debug(f"Removed temp file: {item}")
                        elif item.is_dir(): shutil.rmtree(item); logger.debug(f"Removed temp dir: {item}")
                    except OSError as oe:
                        logger.warning(f"Could not remove temp item {item} during cleanup: {oe}")

            except Exception as e_generic_primary:
                logger.error(f"yt-dlp: Unexpected error during primary download (format: '{format_primary}'): {e_generic_primary}", exc_info=True)
                logger.warning("Proceeding to fallback attempt despite unexpected error in primary.")
                logger.debug(f"Cleaning up temp_dir '{temp_dir}' before fallback attempt...")
                for item in temp_dir.iterdir():
                    try:
                        if item.is_file(): item.unlink(); logger.debug(f"Removed temp file: {item}")
                        elif item.is_dir(): shutil.rmtree(item); logger.debug(f"Removed temp dir: {item}")
                    except OSError as oe:
                        logger.warning(f"Could not remove temp item {item} during cleanup: {oe}")

            # Attempt 2: Fallback (More Compatible) Format
            if not download_successful:
                current_attempt_format_str = format_fallback
                logger.info(f"yt-dlp: Attempt 2 - Using fallback format: '{current_attempt_format_str}'")
                ydl_opts_attempt2 = {**base_ydl_opts, 'format': current_attempt_format_str}

                try:
                    with yt_dlp.YoutubeDL(ydl_opts_attempt2) as ydl:
                        logger.info(f"Extracting info (Attempt 2) for {input_source}...")
                        # Ensure we have a fresh info_dict for this attempt
                        info_dict = ydl.extract_info(input_source, download=False)
                        video_title = info_dict.get('title', video_title)

                        logger.info(f"Downloading video (Attempt 2): '{video_title}'...")
                        ydl.download([input_source])

                    downloaded_files = list(temp_dir.glob('*.mp4'))
                    if not downloaded_files:
                        raise FileNotFoundError("yt-dlp (Attempt 2 - Fallback) finished but no MP4 output file found.")
                    initial_temp_filepath = downloaded_files[0]
                    # info_dict is already set from extract_info above for this successful attempt
                    download_successful = True
                    logger.info("yt-dlp: Download successful with fallback format.")

                except yt_dlp.utils.DownloadError as e_fallback:
                    logger.error(f"yt-dlp: Fallback download attempt (format: '{format_fallback}') also failed: {e_fallback}", exc_info=True)
                    error_message = f"yt-dlp download failed with all strategies. Last error (fallback): {str(e_fallback)[:200]}"
                    raise
                except Exception as e_generic_fallback:
                    logger.error(f"yt-dlp: Unexpected error during fallback download (format: '{format_fallback}'): {e_generic_fallback}", exc_info=True)
                    error_message = f"yt-dlp unexpected error with fallback. Last error: {str(e_generic_fallback)[:200]}"
                    raise

            if not download_successful:
                final_error_msg = "yt-dlp processing failed after all attempts for unknown reasons (e.g. file not found after download claim)."
                logger.error(final_error_msg)
                if not error_message: error_message = final_error_msg
                raise FileNotFoundError(final_error_msg) # Or a more specific yt-dlp custom error

            logger.info(f"Download complete. Initial temp file: {initial_temp_filepath}")

            if not info_dict: # Should be populated if download_successful
                logger.error("CRITICAL: info_dict is not populated after successful download claim. Metadata might be incomplete. Attempting one last fetch.")
                try:
                    with yt_dlp.YoutubeDL({'logger': YtdlpLogger(), 'quiet': True, 'skip_download': True, 'extract_flat': 'in_playlist'}) as ydl_final_info:
                         info_dict = ydl_final_info.extract_info(input_source, download=False)
                except Exception as final_info_err:
                    logger.error(f"Failed to fetch info_dict as a last resort: {final_info_err}")
                    # Proceed with a minimal info_dict if necessary, or handle error
                    info_dict = {} # Ensure info_dict is at least an empty dict

            metadata['title'] = info_dict.get('title', video_title) # Use the most up-to-date title
            metadata['duration'] = info_dict.get('duration')
            metadata['width'] = info_dict.get('width')
            metadata['height'] = info_dict.get('height')
            metadata['fps'] = info_dict.get('fps')
            metadata['original_url'] = info_dict.get('webpage_url', input_source)
            metadata['extractor'] = info_dict.get('extractor_key')
            metadata['upload_date'] = info_dict.get('upload_date') # Format YYYYMMDD

            # Prepare base filename from title/id using the final info_dict
            # The 'outtmpl' for prepare_filename should not include the directory part
            # prepare_filename expects an info_dict that yt-dlp would have obtained.
            try:
                with yt_dlp.YoutubeDL({'logger': YtdlpLogger(), 'quiet': True, 'skip_download': True, 'extract_flat': 'in_playlist'}) as ydl_prep:
                    # Use a simple outtmpl for stem extraction, not the full path one.
                    # Use the info_dict from the successful download.
                    safe_stem = Path(ydl_prep.prepare_filename(info_dict, outtmpl='%(title).100B [%(id)s]')).stem
                base_filename_no_ext = safe_stem
            except Exception as prep_fn_err:
                logger.warning(f"Failed to prepare filename from info_dict using yt-dlp: {prep_fn_err}. Falling back to generic name.")
                # Fallback base_filename_no_ext is already set at the top of `if is_url`

        else:
            # --- Handle Local File Path ---
            logger.info(f"Input is a local path: {input_source}")
            input_path = Path(input_source).resolve()
            if not input_path.is_file():
                raise FileNotFoundError(f"Local file path does not exist: {input_path}")

            initial_temp_filepath = temp_dir / input_path.name
            logger.info(f"Copying local file '{input_path}' to '{initial_temp_filepath}'")
            shutil.copy2(input_path, initial_temp_filepath) # copy2 preserves metadata
            logger.info(f"Copied local file to temp location.")

            base_filename_no_ext = input_path.stem
            metadata['title'] = base_filename_no_ext # Default title
            metadata['original_url'] = f"localfile://{input_path}"

            ffprobe_path = shutil.which("ffprobe")
            if ffprobe_path:
                try:
                    logger.info(f"Attempting ffprobe metadata extraction for {initial_temp_filepath}")
                    ffprobe_cmd = [ffprobe_path, "-v", "error", "-show_format", "-show_streams", "-of", "json", str(initial_temp_filepath)]
                    process = subprocess.run(ffprobe_cmd, check=True, capture_output=True, text=True, encoding='utf-8', errors='replace')
                    probe_data = json.loads(process.stdout)
                    video_stream = next((s for s in probe_data.get('streams', []) if s.get('codec_type') == 'video'), None)
                    if video_stream:
                        metadata['width'] = video_stream.get('width')
                        metadata['height'] = video_stream.get('height')
                        fr = video_stream.get('avg_frame_rate', '0/1')
                        if '/' in fr:
                            try:
                                num, den = map(int, fr.split('/'))
                                if den > 0: metadata['fps'] = num / den
                            except ValueError: logger.warning(f"Could not parse frame rate: {fr}")
                        if not metadata.get('duration'):
                             metadata['duration'] = float(video_stream.get('duration', 0))
                    if 'format' in probe_data:
                        format_duration = probe_data['format'].get('duration')
                        if format_duration: metadata['duration'] = float(format_duration)
                        creation_time_str = probe_data['format'].get('tags', {}).get('creation_time')
                        if creation_time_str:
                             metadata['creation_time_iso'] = creation_time_str # Store ISO time if available
                    logger.info(f"Metadata extracted via ffprobe: {metadata}")
                except Exception as probe_err:
                    logger.warning(f"Could not extract metadata using ffprobe: {probe_err}", exc_info=False)
            else:
                logger.warning("ffprobe not found, skipping local file metadata extraction.")

        # --- Determine Final Filename and S3 Object Key ---
        final_ext = ".mp4"
        safe_base_filename_no_ext = "".join(c if c.isalnum() or c in ['-', '_'] else '_' for c in base_filename_no_ext)
        safe_base_filename_no_ext = safe_base_filename_no_ext[:150] # Limit length
        final_filename_no_suffix = f"{safe_base_filename_no_ext}{final_ext}"
        final_filename_with_suffix = f"{safe_base_filename_no_ext}{FINAL_SUFFIX}{final_ext}"
        perform_re_encode = re_encode_for_qt
        final_filename_for_db = final_filename_with_suffix if perform_re_encode else final_filename_no_suffix
        s3_object_key = f"source_videos/{final_filename_for_db}"
        logger.info(f"Target S3 object key: s3://{s3_bucket_name_for_task}/{s3_object_key}")

        # --- Re-encode into consistent format ---
        file_to_upload = initial_temp_filepath
        if perform_re_encode:
            logger.info(f"Starting ffmpeg re-encoding...")
            encoded_temp_path = temp_dir / final_filename_for_db
            ffmpeg_cmd = ["ffmpeg", "-y", "-i", str(initial_temp_filepath)] + FFMPEG_ARGS + [str(encoded_temp_path)]
            try:
                run_external_command(ffmpeg_cmd, "ffmpeg Re-encoding")
                logger.info(f"Re-encoding successful: {encoded_temp_path.name}")
                file_to_upload = encoded_temp_path
            except Exception as encode_err:
                logger.error(f"ffmpeg re-encoding failed: {encode_err}")
                error_message = f"FFmpeg re-encoding failed: {encode_err}"
                raise RuntimeError("FFmpeg re-encoding failed") from encode_err
        else:
            target_temp_path = temp_dir / final_filename_for_db
            if initial_temp_filepath != target_temp_path:
                logger.info(f"Skipping re-encoding. Renaming '{initial_temp_filepath.name}' to '{target_temp_path.name}'.")
                shutil.move(str(initial_temp_filepath), str(target_temp_path))
                file_to_upload = target_temp_path
            else:
                 logger.info(f"Skipping re-encoding. File already has target name: {file_to_upload.name}")


        # --- Upload Processed File to S3 ---
        logger.info(f"Preparing to upload '{file_to_upload.name}' to S3: {s3_object_key}")
        try:
            file_size = os.path.getsize(file_to_upload)
            logger.info(f"File size: {file_size / (1024*1024):.2f} MiB")
            # Adjust throttle based on size
            throttle = 10 if file_size < 100 * 1024 * 1024 else 5
            # Pass AWS_REGION to S3TransferProgress if it initializes its own client, 
            # or modify S3TransferProgress to accept an s3_client instance.
            # For now, assuming S3TransferProgress might be used by other tasks that don't have this new pattern yet.
            # Ideally, S3TransferProgress would also use the passed s3_client_for_task if possible.
            aws_region_for_progress = os.getenv("AWS_REGION", "us-west-1") # Keep this for S3TransferProgress if it needs it
            progress_callback = S3TransferProgress(file_size, file_to_upload.name, logger, throttle_percentage=throttle)

            logger.info(f"Starting S3 upload to s3://{s3_bucket_name_for_task}/{s3_object_key}...")
            with open(file_to_upload, "rb") as f:
                s3_client_for_task.upload_fileobj(f, s3_bucket_name_for_task, s3_object_key, Callback=progress_callback)
            logger.info(f"✅ S3 Upload completed successfully for '{file_to_upload.name}'.") # Added confirmation

        except ClientError as s3_err:
            logger.error(f"Failed to upload to S3: {s3_err}", exc_info=True)
            error_message = f"S3 upload failed: {s3_err}"
            raise RuntimeError("S3 upload failed") from s3_err
        except Exception as upload_err:
            logger.error(f"Unexpected error during S3 upload: {upload_err}", exc_info=True)
            error_message = f"S3 upload failed: {upload_err}"
            raise RuntimeError("S3 upload failed") from upload_err

        # --- Final Database Update ---
        conn_final = None
        try:
            logger.info("Attempting final database update...")
            conn_final = get_db_connection(environment)
            if conn_final is None: raise ConnectionError("Failed to get DB connection for final update.")
            conn_final.autocommit = False
            with conn_final.cursor() as cur_final:
                # Re-acquire lock for the final update transaction
                cur_final.execute("SELECT pg_try_advisory_xact_lock(1, %s)", (source_video_id,))
                lock_acquired = cur_final.fetchone()[0]
                if not lock_acquired:
                    # This is unlikely if the first lock worked, but possible
                    raise RuntimeError("Failed to re-acquire lock for final DB update.")
                logger.info(f"Re-acquired lock for final update.")

                logger.info("Parsing metadata and preparing final DB update...")
                # Metadata parsing logic
                db_title = metadata.get('title'); db_duration = metadata.get('duration'); db_width = metadata.get('width')
                db_height = metadata.get('height'); db_fps = metadata.get('fps'); db_original_url = metadata.get('original_url')
                db_upload_date_str = metadata.get('upload_date')
                db_published_date = None
                if db_upload_date_str and isinstance(db_upload_date_str, str) and len(db_upload_date_str) == 8:
                    try: db_published_date = datetime.strptime(db_upload_date_str, '%Y%m%d').date()
                    except ValueError: logger.warning(f"Could not parse upload_date '{db_upload_date_str}'.")
                elif db_upload_date_str: logger.warning(f"Non-standard upload_date format '{db_upload_date_str}'.")
                db_duration = float(db_duration) if db_duration is not None else None
                db_width = int(db_width) if db_width is not None else None
                db_height = int(db_height) if db_height is not None else None
                db_fps = float(db_fps) if db_fps is not None else None

                logger.info(f"Executing final UPDATE statement for ID {source_video_id}...")
                cur_final.execute(
                    """
                    UPDATE source_videos
                    SET ingest_state = 'downloaded', filepath = %s, title = COALESCE(%s, title),
                        duration_seconds = %s, width = %s, height = %s, fps = %s,
                        original_url = COALESCE(%s, original_url), published_date = %s,
                        downloaded_at = NOW(), last_error = NULL
                    WHERE id = %s AND ingest_state = %s -- Concurrency check using the state we started with (which should now be expected_processing_state)
                    RETURNING id;
                    """,
                    (s3_object_key, db_title, db_duration, db_width, db_height, db_fps,
                     db_original_url, db_published_date, source_video_id, expected_processing_state) # Check against expected_processing_state
                )
                updated_id_result = cur_final.fetchone() # Fetch the result
                if updated_id_result is None:
                     # The UPDATE statement did not find a row matching (id = %s AND ingest_state = %s)
                     # This could be because the state was changed by another process, or the ID doesn't exist (less likely here).
                     cur_final.execute("SELECT ingest_state FROM source_videos WHERE id = %s", (source_video_id,))
                     current_state_on_fail_check = cur_final.fetchone()
                     actual_current_state = current_state_on_fail_check[0] if current_state_on_fail_check else "NOT_FOUND"

                     if actual_current_state == 'downloaded':
                         # If it's already 'downloaded', another concurrent run likely completed this step.
                         # This is not an error for the current task run; the desired state is achieved.
                         logger.warning(
                             f"Final DB update for ID {source_video_id}: Concurrency check showed state was already 'downloaded' "
                             f"(expected to transition from '{expected_processing_state}'). Assuming success due to concurrent completion."
                         )
                         conn_final.commit() # Commit the transaction (which did nothing in this UPDATE but releases lock)
                         logger.info(f"✅ Final DB state confirmed as 'downloaded' for ID {source_video_id} (likely by concurrent run). Update by this task run skipped.")
                         task_outcome = "success" # Mark as success
                     else:
                         # If it's some other state, then it's a genuine problem.
                         fail_msg = (
                             f"Final DB update failed for ID {source_video_id}. "
                             f"Concurrency check failed: Expected to update from state '{expected_processing_state}', but current state is '{actual_current_state}'. "
                             f"Upload to S3 ({s3_object_key}) likely succeeded, but DB state is inconsistent."
                         )
                         logger.error(fail_msg)
                         conn_final.rollback() # Rollback the failed update attempt
                         error_message = f"DB final update state mismatch: expected to update from {expected_processing_state}, but found {actual_current_state}"
                         raise RuntimeError(fail_msg) # Raise a specific error
                else:
                    # The UPDATE was successful and returned the ID.
                    conn_final.commit()
                    logger.info(f"✅ Final DB update committed successfully. State set to 'downloaded'.")
                    task_outcome = "success"

        except Exception as final_db_err:
             logger.error(f"Error during final database update: {final_db_err}", exc_info=True)
             if conn_final: conn_final.rollback()
             # Ensure error_message is set if not already
             if not error_message: error_message = f"Final DB update failed: {final_db_err}"
             raise # Re-raise the caught exception
        finally:
             if conn_final:
                 release_db_connection(conn_final, environment)

        # === Successful Completion ===
        logger.info(f"TASK [Intake]: Successfully processed source_video_id: {source_video_id}. Final S3 key: {s3_object_key}")
        final_return_value = {"status": task_outcome, "s3_key": s3_object_key, "metadata": metadata, "s3_bucket_used": s3_bucket_name_for_task}
        logger.info(f"--- Returning value for ID {source_video_id}: {final_return_value} ---") # Log before return
        return final_return_value

    # === Main Exception Handling ===
    except Exception as e:
        # Attempt to update DB to failed state
        task_name = "Intake"
        # Check if it's an error we already caught and formatted
        if not error_message:
             error_message = f"{type(e).__name__}: {str(e)[:450]}" # Format current exception if needed
        logger.error(f"TASK FAILED ({task_name}): source_video_id {source_video_id} - {error_message}", exc_info=True)
        task_outcome = "failed"

        # Rollback initial transaction if still active
        if conn and not conn.closed and not conn.autocommit:
            try: conn.rollback(); logger.info("Initial DB transaction rolled back on error.")
            except Exception as rb_err: logger.error(f"Error during initial rollback: {rb_err}")

        # Attempt to update DB state to failed using a NEW connection
        error_conn = None
        try:
            logger.info(f"Attempting to update DB state to 'download_failed' for {source_video_id}...")
            error_conn = get_db_connection(environment)
            if error_conn is None: raise ConnectionError("Failed to get DB connection for error update.")
            error_conn.autocommit = True # Use autocommit for simple error update
            with error_conn.cursor() as err_cur:
                err_cur.execute(
                    """
                    UPDATE source_videos
                    SET ingest_state = 'download_failed', last_error = %s,
                        retry_count = COALESCE(retry_count, 0) + 1
                    WHERE id = %s AND ingest_state != 'downloaded'; -- Avoid overwriting success
                    """,
                    (error_message, source_video_id)
                )
            logger.info(f"Updated DB state to 'download_failed' for source_video_id: {source_video_id}")
        except Exception as db_err_update:
            logger.error(f"CRITICAL: Failed to update error state in DB for {source_video_id}: {db_err_update}")
        finally:
            if error_conn:
                release_db_connection(error_conn, environment)

        # Re-raise the original exception for Prefect
        raise e

    finally:
        # --- Final Logging and Cleanup ---
        # Log final outcome with appropriate level
        log_level = logging.INFO if task_outcome == "success" else logging.ERROR
        logger.log(log_level, f"TASK [Intake] finished for ID {source_video_id}. Outcome: {task_outcome}.")

        # Release initial connection if acquired
        if conn:
             release_db_connection(conn, environment)
             logger.debug(f"Released initial DB connection for source_video_id: {source_video_id}")

        # Cleanup temporary directory
        if temp_dir_obj:
            try:
                temp_dir_obj.cleanup()
                logger.info(f"Cleaned up temporary directory: {temp_dir}")
            except Exception as cleanup_err:
                 logger.warning(f"Error cleaning up temporary directory {temp_dir}: {cleanup_err}")

        # Optional: Explicitly return dict on failure for inspection (Prefect mainly uses exception)
        # if task_outcome != "success":
        #     return {"status": task_outcome, "s3_key": s3_object_key, "error": error_message, "source_video_id": source_video_id}