import argparse
import json
import logging
import sys

from sqlalchemy.orm import sessionmaker
from utils.db import get_db_engine
from utils.s3 import get_s3_client
from utils.schemas import Clip, ClipArtifact

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")


def archive_clip(clip_id: int):
    """
    Archives a clip by deleting its associated S3 artifacts and updating its status.
    """
    logging.info(f"Starting archive process for clip_id: {clip_id}")
    engine = get_db_engine()
    Session = sessionmaker(bind=engine)
    session = Session()
    s3_client = get_s3_client()

    try:
        clip = session.query(Clip).filter(Clip.id == clip_id).first()
        if not clip:
            logging.error(f"No clip found with id: {clip_id}")
            return {"status": "error", "message": f"Clip not found: {clip_id}"}

        artifacts = session.query(ClipArtifact).filter(ClipArtifact.clip_id == clip_id).all()
        if not artifacts:
            logging.warning(f"No artifacts found for clip_id: {clip_id}. Marking as archived.")
        else:
            logging.info(f"Found {len(artifacts)} artifacts to delete for clip {clip_id}.")
            for artifact in artifacts:
                if artifact.s3_key:
                    try:
                        logging.info(f"Deleting S3 object: {artifact.s3_bucket}/{artifact.s3_key}")
                        s3_client.delete_object(Bucket=artifact.s3_bucket, Key=artifact.s3_key)
                        logging.info(f"Successfully deleted S3 object: {artifact.s3_key}")
                    except Exception as e:
                        logging.error(f"Failed to delete S3 object {artifact.s3_key}: {e}")
                        # Decide if we should continue or fail the whole process
                        # For now, we'll log the error and continue.

        # After attempting to delete all artifacts, update the clip's state.
        clip.ingest_state = "archived"
        clip.last_error = None # Clear previous errors
        session.commit()
        logging.info(f"Successfully archived clip {clip_id} and updated its state.")

        return {"status": "success", "result": {"clip_id": clip_id, "final_state": "archived"}}

    except Exception as e:
        session.rollback()
        logging.error(f"An error occurred during the archive process for clip {clip_id}: {e}")
        # Optionally update the clip state to an error status
        clip = session.query(Clip).filter(Clip.id == clip_id).first()
        if clip:
            clip.ingest_state = "archive_failed"
            clip.last_error = str(e)
            session.commit()
        return {"status": "error", "message": str(e)}
    finally:
        session.close()


def main():
    parser = argparse.ArgumentParser(description="Archive a clip and its S3 artifacts.")
    parser.add_argument("--clip-id", type=int, required=True, help="The ID of the clip to archive.")
    args = parser.parse_args()

    result = archive_clip(args.clip_id)
    # The final line of output should be the JSON result for the Elixir runner
    print(json.dumps(result))


if __name__ == "__main__":
    main() 