import os
import subprocess
import tempfile
from pathlib import Path
import shutil
import json
import re
import sys
import logging
import argparse

import psycopg2
from psycopg2 import sql, extras
import boto3
from botocore.exceptions import ClientError, NoCredentialsError

# --- Local Imports ---
try:
    from python.utils.db import get_db_connection
    from python.utils.process_utils import run_ffmpeg_command
except ImportError:
    project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
    if project_root not in sys.path:
        sys.path.insert(0, project_root)
    from python.utils.db import get_db_connection
    from python.utils.process_utils import run_ffmpeg_command

# --- Logging Configuration ---
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)


# --- Constants ---
CLIP_S3_PREFIX = "clips/"
ARTIFACT_TYPE_SPRITE_SHEET = "sprite_sheet"

def sanitize_filename(name):
    """Sanitizes a string to be a valid filename."""
    if not name: return "default_filename"
    name = str(name)
    name = re.sub(r'[^\w\.\-]+', '_', name)
    name = re.sub(r'_+', '_', name).strip('_')
    return name[:150]

def _delete_s3_artifacts(s3_client, bucket_name, artifact_keys):
    """Deletes a list of artifacts from S3."""
    if not artifact_keys:
        return
    logger.info(f"Deleting {len(artifact_keys)} associated S3 artifacts.")
    keys_to_delete = [{'Key': key} for key in artifact_keys]
    try:
        response = s3_client.delete_objects(
            Bucket=bucket_name,
            Delete={'Objects': keys_to_delete, 'Quiet': True}
        )
        if 'Errors' in response and response['Errors']:
            for error in response['Errors']:
                logger.error(f"Failed to delete S3 object {error['Key']}: {error['Message']}")
    except ClientError as e:
        logger.error(f"An S3 error occurred during artifact deletion: {e}", exc_info=True)


def run_merge(clip_id_target: int, clip_id_source: int, environment: str, **kwargs):
    """
    Merges the source clip into the target clip.
    """
    logger.info(f"RUNNING MERGE: Source Clip {clip_id_source} into Target Clip {clip_id_target}")

    s3_bucket_name = os.getenv("S3_BUCKET_NAME")
    if not s3_bucket_name:
        raise ValueError("S3_BUCKET_NAME environment variable not set.")

    try:
        s3_client = boto3.client("s3")
    except NoCredentialsError:
        logger.error("S3 credentials not found.")
        raise
    
    if clip_id_target == clip_id_source:
        raise ValueError("Cannot merge a clip with itself.")

    temp_dir_obj = None
    merged_clip_s3_key = None
    
    try:
        with get_db_connection(cursor_factory=extras.DictCursor) as conn:
            # Phase 1: Lock, validate, and set state
            with conn.cursor() as cur:
                conn.autocommit = False
                cur.execute("SELECT pg_advisory_xact_lock(2, %s)", (clip_id_target,))
                cur.execute("SELECT pg_advisory_xact_lock(2, %s)", (clip_id_source,))
                logger.info(f"Acquired DB locks for clips {clip_id_target} and {clip_id_source}")

                cur.execute(
                    """
                    SELECT c.id, c.clip_filepath, c.clip_identifier, c.start_frame, c.end_frame,
                           c.start_time_seconds, c.end_time_seconds, c.source_video_id,
                           c.ingest_state, sv.title AS source_title
                    FROM clips c
                    JOIN source_videos sv ON c.source_video_id = sv.id
                    WHERE c.id = ANY(%s::int[]) FOR UPDATE;
                    """, ([clip_id_target, clip_id_source],)
                )
                results = cur.fetchall()
                if len(results) != 2:
                    raise ValueError(f"Could not find/lock both clips {clip_id_target}, {clip_id_source}.")

                clip_target_data = next((r for r in results if r['id'] == clip_id_target), None)
                clip_source_data = next((r for r in results if r['id'] == clip_id_source), None)

                if not clip_target_data or not clip_source_data:
                    raise ValueError("Mismatch fetching clip data.")
                
                if clip_target_data['source_video_id'] != clip_source_data['source_video_id']:
                    raise ValueError("Clips do not belong to the same source video.")
                
                if not clip_target_data['clip_filepath'] or not clip_source_data['clip_filepath']:
                    raise ValueError("One or both clips are missing filepaths.")

                cur.execute("UPDATE clips SET ingest_state = 'merging_target', last_error = NULL WHERE id = %s", (clip_id_target,))
                cur.execute("UPDATE clips SET ingest_state = 'merging_source', last_error = NULL WHERE id = %s", (clip_id_source,))
                conn.commit()
                logger.info(f"Set states to 'merging_target' for {clip_id_target} and 'merging_source' for {clip_id_source}")

            # Phase 2: Download, Merge, Upload
            temp_dir_obj = tempfile.TemporaryDirectory(prefix=f"merge_{clip_id_target}_{clip_id_source}_")
            temp_dir = Path(temp_dir_obj.name)

            local_clip_target_path = temp_dir / Path(clip_target_data['clip_filepath']).name
            local_clip_source_path = temp_dir / Path(clip_source_data['clip_filepath']).name
            concat_list_path = temp_dir / "concat_list.txt"

            logger.info(f"Downloading clips to {temp_dir}...")
            s3_client.download_file(s3_bucket_name, clip_target_data['clip_filepath'], str(local_clip_target_path))
            s3_client.download_file(s3_bucket_name, clip_source_data['clip_filepath'], str(local_clip_source_path))

            with open(concat_list_path, "w", encoding='utf-8') as f:
                f.write(f"file '{local_clip_target_path.resolve().as_posix()}'\n")
                f.write(f"file '{local_clip_source_path.resolve().as_posix()}'\n")

            new_start_frame = clip_target_data['start_frame']
            new_end_frame = clip_source_data['end_frame']
            sanitized_title = sanitize_filename(clip_target_data['source_title'])
            new_identifier = f"{sanitized_title}_{new_start_frame}_{new_end_frame}"
            output_filename = f"{new_identifier}.mp4"
            output_path = temp_dir / output_filename
            
            ffmpeg_cmd = [
                "-f", "concat", "-safe", "0", "-i", str(concat_list_path),
                "-c", "copy", str(output_path)
            ]
            run_ffmpeg_command(ffmpeg_cmd, "Merging clips")

            merged_clip_s3_key = f"{CLIP_S3_PREFIX}{output_filename}"
            s3_client.upload_file(str(output_path), s3_bucket_name, merged_clip_s3_key)
            logger.info(f"Uploaded merged clip to s3://{s3_bucket_name}/{merged_clip_s3_key}")

            # Phase 3: Finalize DB state and cleanup artifacts
            with conn.cursor() as cur:
                # Update target clip
                new_duration = clip_target_data['end_time_seconds'] - clip_target_data['start_time_seconds'] + \
                               (clip_source_data['end_time_seconds'] - clip_source_data['start_time_seconds'])

                cur.execute(
                    """
                    UPDATE clips
                    SET clip_identifier = %s, clip_filepath = %s, end_time_seconds = %s,
                        end_frame = %s, ingest_state = 'spliced',
                        updated_at = NOW()
                    WHERE id = %s;
                    """,
                    (
                        new_identifier, merged_clip_s3_key, clip_source_data['end_time_seconds'],
                        new_end_frame, clip_id_target
                    )
                )
                logger.info(f"Updated target clip {clip_id_target} with merged data.")

                # Archive source clip
                cur.execute("UPDATE clips SET ingest_state = 'merged_archived', updated_at = NOW() WHERE id = %s", (clip_id_source,))
                logger.info(f"Archived source clip {clip_id_source}")

                # Get artifacts to delete for BOTH clips (target's old artifacts, source's all artifacts)
                cur.execute("SELECT s3_key FROM clip_artifacts WHERE clip_id = ANY(%s::int[])", ([clip_id_target, clip_id_source],))
                artifacts_to_delete = [row[0] for row in cur.fetchall()]
                
                # Delete artifact records from DB
                cur.execute("DELETE FROM clip_artifacts WHERE clip_id = ANY(%s::int[])", ([clip_id_target, clip_id_source],))
                logger.info(f"Deleted artifact records from DB for clips {clip_id_target}, {clip_id_source}")
                
                conn.commit()
            
            # Now delete from S3
            s3_artifacts_to_delete = artifacts_to_delete + [clip_target_data['clip_filepath'], clip_source_data['clip_filepath']]
            _delete_s3_artifacts(s3_client, s3_bucket_name, s3_artifacts_to_delete)

        return {
            "status": "success",
            "merged_clip_id": clip_id_target,
            "archived_clip_id": clip_id_source,
            "new_s3_key": merged_clip_s3_key
        }

    except Exception as e:
        logger.error(f"FATAL: Merging failed for target {clip_id_target} and source {clip_id_source}: {e}", exc_info=True)
        error_message = str(e)
        try:
            with get_db_connection() as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        "UPDATE clips SET ingest_state = 'merge_failed', last_error = %s, updated_at = NOW() WHERE id = ANY(%s::int[])",
                        (error_message, [clip_id_target, clip_id_source])
                    )
                    conn.commit()
        except Exception as db_err:
            logger.error(f"CRITICAL: Failed to update DB state to 'merge_failed' for clips {clip_id_target}, {clip_id_source}: {db_err}")
        raise
    finally:
        if temp_dir_obj:
            temp_dir_obj.cleanup()
            logger.info("Cleaned up temporary directory.")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Merge two clips together.")
    parser.add_argument("--target-clip-id", required=True, type=int, help="The ID of the target clip (the earlier one).")
    parser.add_argument("--source-clip-id", required=True, type=int, help="The ID of the source clip (the later one to be merged in).")
    parser.add_argument("--env", default="development", help="The environment.")
    
    args = parser.parse_args()

    try:
        result = run_merge(
            clip_id_target=args.target_clip_id,
            clip_id_source=args.source_clip_id,
            environment=args.env
        )
        print("Merging finished successfully.")
        print(json.dumps(result, indent=2))
        sys.exit(0)
    except Exception as e:
        print(f"Merging failed: {e}", file=sys.stderr)
        sys.exit(1)