import torch
from PIL import Image
import os
import re
import numpy as np
from pathlib import Path
import tempfile
import shutil
from datetime import datetime
import logging
import json
import sys

import psycopg2
from psycopg2 import sql
from psycopg2.extras import Json

import boto3
from botocore.exceptions import ClientError, NoCredentialsError

# Model Loading Imports
try:
    from transformers import CLIPProcessor, CLIPModel, AutoImageProcessor, AutoModel
except ImportError:
    print("Warning: transformers library not found. CLIP/some DINOv2 models will not be available.")
    CLIPProcessor, CLIPModel, AutoImageProcessor, AutoModel = None, None, None, None

# --- Local Imports ---
try:
    # Use relative imports for sibling modules within the package
    from .utils.db import get_db_connection
except ImportError:
    # Fallback for when script is run directly
    project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
    if project_root not in sys.path:
        sys.path.insert(0, project_root)
    from py_tasks.utils.db import get_db_connection

# --- Logging Configuration ---
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# --- Constants ---
ARTIFACT_TYPE_KEYFRAME = "keyframe"


# --- Global Model Cache ---
_model_cache = {}
def get_cached_model_and_processor(model_name, device='cpu'):
    """Loads model/processor or retrieves from cache."""
    cache_key = f"{model_name}_{device}"
    if cache_key in _model_cache:
        logger.debug(f"Using cached model/processor for: {cache_key}")
        return _model_cache[cache_key]
    else:
        logger.info(f"Loading and caching model/processor: {model_name} to device: {device}")
        try:
            model, processor, model_type, embedding_dim = _load_model_and_processor_internal(model_name, device)
            _model_cache[cache_key] = (model, processor, model_type, embedding_dim)
            return model, processor, model_type, embedding_dim
        except Exception as load_err:
             logger.error(f"Failed to load model {model_name}: {load_err}", exc_info=True)
             raise

def _load_model_and_processor_internal(model_name, device='cpu'):
    """Internal function to load models."""
    logger.info(f"Attempting to load model: {model_name} to device: {device}")
    model_type_str = None
    embedding_dim = None
    model = None
    processor = None

    if "clip" in model_name.lower():
        if CLIPModel is None: raise ImportError("transformers library required for CLIP models.")
        try:
            model = CLIPModel.from_pretrained(model_name).to(device).eval()
            processor = CLIPProcessor.from_pretrained(model_name)
            if hasattr(model.config, 'projection_dim') and model.config.projection_dim: embedding_dim = model.config.projection_dim
            elif hasattr(model.config, 'hidden_size') and model.config.hidden_size: embedding_dim = model.config.hidden_size
            else: embedding_dim = 512 if "base" in model_name.lower() else 768 # Adjust default based on common sizes
            model_type_str = "clip"
            logger.info(f"Loaded CLIP model: {model_name} (Type: {model_type_str}, Dim: {embedding_dim})")
        except Exception as e:
            if "Cannot copy out of meta tensor" in str(e):
                 raise ValueError(f"Meta tensor error loading CLIP: {model_name}. Check accelerate/config.") from e
            else: raise ValueError(f"Failed to load CLIP model: {model_name}") from e
    elif "dinov2" in model_name.lower():
        if AutoModel is None: raise ImportError("transformers library required for DINOv2 models.")
        try:
            processor = AutoImageProcessor.from_pretrained(model_name)
            model = AutoModel.from_pretrained(model_name).to(device).eval()
            if hasattr(model.config, 'hidden_size') and model.config.hidden_size: embedding_dim = model.config.hidden_size
            else: raise ValueError(f"Cannot determine embedding dimension for DINOv2 model: {model_name}")
            model_type_str = "dino"
            logger.info(f"Loaded DINOv2 model (Transformers): {model_name} (Type: {model_type_str}, Dim: {embedding_dim})")
        except Exception as e:
             if "Cannot copy out of meta tensor" in str(e):
                  raise ValueError(f"Meta tensor error loading DINOv2: {model_name}. Check accelerate/config.") from e
             else: raise ValueError(f"Failed to load DINOv2 model: {model_name}") from e
    else:
        raise ValueError(f"Model name not recognized or supported: {model_name}")

    if model is None or processor is None or model_type_str is None or embedding_dim is None:
         raise RuntimeError(f"Failed to initialize one or more components for model: {model_name}")

    return model, processor, model_type_str, embedding_dim


# --- Stateless Task Function ---
def run_embed(
    clip_id: int,
    model_name: str,
    generation_strategy: str,
    environment: str, # For context
    **kwargs
    ):
    """
    Generates embeddings for a clip based on specified keyframe artifacts.

    Args:
        clip_id (int): The ID of the clip.
        model_name (str): The name of the embedding model to use.
        generation_strategy (str): Strategy for selecting/aggregating keyframes.
        environment (str): The execution environment.
        **kwargs:
            overwrite (bool): Whether to overwrite existing embeddings.
    """
    overwrite = kwargs.get('overwrite', False)
    device = kwargs.get('device', 'cpu') # Allow overriding device for testing
    
    logger.info(f"RUNNING EMBED for clip_id: {clip_id}, Model: '{model_name}', Strategy: '{generation_strategy}', Overwrite: {overwrite}, Env: {environment}")

    # --- Get S3 Resources from Environment ---
    s3_bucket_name = os.getenv("S3_BUCKET_NAME")
    if not s3_bucket_name:
        raise ValueError("S3_BUCKET_NAME environment variable not set.")
    
    try:
        s3_client = boto3.client("s3") # Credentials from env vars
    except NoCredentialsError:
        logger.error("S3 credentials not found. Configure AWS_ACCESS_KEY_ID, etc.")
        raise
    
    temp_dir_obj = None
    embedding_id = None
    error_message = None

    try:
        # --- Strategy Parsing ---
        match = re.match(r"keyframe_([a-zA-Z0-9]+)(?:_(avg))?$", generation_strategy)
        if not match: raise ValueError(f"Invalid generation_strategy format: '{generation_strategy}'.")
        keyframe_strategy_name = match.group(1)
        aggregation_method = match.group(2)
        logger.info(f"Parsed strategy: keyframe_type='{keyframe_strategy_name}', aggregation='{aggregation_method}'")

        # --- DB State Check and Prerequisite Validation ---
        with get_db_connection() as conn, conn.cursor() as cur:
            conn.autocommit = False
            # Acquire lock
            cur.execute("SELECT pg_advisory_xact_lock(2, %s)", (clip_id,))
            logger.info(f"Acquired DB lock for clip_id: {clip_id}")

            # Check clip state and existing embedding
            cur.execute(
                """
                SELECT c.ingest_state,
                       EXISTS (SELECT 1 FROM embeddings e WHERE e.clip_id = c.id AND e.model_name = %s AND e.generation_strategy = %s)
                FROM clips c WHERE c.id = %s;
                """, (model_name, generation_strategy, clip_id)
            )
            result = cur.fetchone()
            if not result: raise ValueError(f"Clip ID {clip_id} not found.")
            current_state, embedding_exists = result
            logger.info(f"Clip {clip_id}: State='{current_state}', EmbeddingExists={embedding_exists}")

            # Idempotency checks
            allow_processing = current_state in ('keyframed', 'embedding_failed') or (overwrite and current_state == 'embedded')
            if not allow_processing:
                return {"status": "skipped_state", "clip_id": clip_id, "reason": f"State '{current_state}' not eligible."}
            if embedding_exists and not overwrite:
                return {"status": "skipped_exists", "clip_id": clip_id, "reason": "Embedding exists and overwrite=False."}

            # Check for keyframe artifacts
            cur.execute(
                "SELECT s3_key FROM clip_artifacts WHERE clip_id = %s AND artifact_type = %s AND strategy = %s",
                (clip_id, ARTIFACT_TYPE_KEYFRAME, keyframe_strategy_name)
            )
            keyframe_records = cur.fetchall()
            if not keyframe_records:
                raise ValueError(f"Prerequisite keyframes missing for clip {clip_id}, strategy '{keyframe_strategy_name}'.")
            
            keyframe_s3_keys = [rec[0] for rec in keyframe_records]
            logger.info(f"Found {len(keyframe_s3_keys)} keyframes to process.")
            
            # Set state to 'embedding'
            cur.execute("UPDATE clips SET ingest_state = 'embedding', updated_at = NOW() WHERE id = %s", (clip_id,))
            conn.commit()
            logger.info(f"Set clip {clip_id} state to 'embedding'")

        # --- Download Keyframes ---
        temp_dir_obj = tempfile.TemporaryDirectory(prefix="embed_")
        temp_dir = temp_dir_obj.name
        local_image_paths = []
        for s3_key in keyframe_s3_keys:
            local_path = os.path.join(temp_dir, os.path.basename(s3_key))
            logger.debug(f"Downloading s3://{s3_bucket_name}/{s3_key} to {local_path}")
            s3_client.download_file(s3_bucket_name, s3_key, local_path)
            local_image_paths.append(local_path)

        # --- Model Loading and Embedding Generation ---
        model, processor, model_type, embedding_dim = get_cached_model_and_processor(model_name, device=device)
        
        images = [Image.open(p).convert("RGB") for p in local_image_paths]
        logger.info(f"Loaded {len(images)} images for embedding.")
        
        embeddings_list = []
        with torch.no_grad():
            if model_type == "clip":
                inputs = processor(text=None, images=images, return_tensors="pt", padding=True)
                inputs = {k: v.to(device) for k, v in inputs.items()}
                image_features = model.get_image_features(**inputs)
                embeddings_list = image_features.cpu().numpy()
            elif model_type == "dino":
                inputs = processor(images=images, return_tensors="pt").to(device)
                outputs = model(**inputs)
                # DINOv2 piscina head is recommended for image retrieval tasks
                image_features = outputs.last_hidden_state
                embeddings_list = image_features[:, 0].cpu().numpy() # CLS token

        if not aggregation_method and len(embeddings_list) > 1:
            raise ValueError(f"Multiple keyframes found but no aggregation method (e.g., '_avg') specified in strategy '{generation_strategy}'.")
        
        final_embedding = None
        if aggregation_method == "avg":
            logger.info(f"Aggregating {len(embeddings_list)} embeddings using 'avg' method.")
            final_embedding = np.mean(embeddings_list, axis=0)
        else:
            final_embedding = embeddings_list[0]
            
        final_embedding = final_embedding.flatten().tolist()
        logger.info(f"Generated final embedding with dimension {len(final_embedding)}")

        # --- Store Embedding in DB ---
        with get_db_connection() as conn, conn.cursor() as cur:
            # Upsert the embedding
            cur.execute(
                """
                INSERT INTO embeddings (clip_id, model_name, generation_strategy, embedding_dim, embedding)
                VALUES (%s, %s, %s, %s, %s)
                ON CONFLICT (clip_id, model_name, generation_strategy)
                DO UPDATE SET
                    embedding = EXCLUDED.embedding,
                    embedding_dim = EXCLUDED.embedding_dim,
                    updated_at = NOW()
                RETURNING id;
                """,
                (clip_id, model_name, generation_strategy, embedding_dim, Json(final_embedding))
            )
            embedding_id = cur.fetchone()[0]
            logger.info(f"Stored embedding in DB with ID: {embedding_id}")

            # Update clip state to 'embedded'
            cur.execute("UPDATE clips SET ingest_state = 'embedded', updated_at = NOW() WHERE id = %s", (clip_id,))
            conn.commit()
            logger.info(f"Set clip {clip_id} state to 'embedded'")

        logger.info(f"SUCCESS: Embedding generation finished for clip_id: {clip_id}")
        return {
            "status": "success",
            "clip_id": clip_id,
            "embedding_id": embedding_id,
            "model_name": model_name,
            "strategy": generation_strategy
        }

    except Exception as e:
        logger.error(f"FATAL: Embedding generation failed for clip_id {clip_id}: {e}", exc_info=True)
        error_message = str(e)
        try:
            with get_db_connection() as conn, conn.cursor() as cur:
                logger.error(f"Attempting to mark clip {clip_id} as 'embedding_failed'")
                cur.execute(
                    """
                    UPDATE clips SET ingest_state = 'embedding_failed', error_message = %s, updated_at = NOW() WHERE id = %s
                    """,
                    (error_message, clip_id)
                )
                conn.commit()
        except Exception as db_fail_err:
            logger.error(f"CRITICAL: Failed to update DB state to 'embedding_failed' for {clip_id}: {db_fail_err}", exc_info=True)
        
        raise
        
    finally:
        if temp_dir_obj:
            try:
                temp_dir_obj.cleanup()
                logger.info(f"Cleaned up temporary directory.")
            except Exception as cleanup_err:
                logger.warning(f"Failed to clean up temporary directory: {cleanup_err}")

# --- Direct invocation for testing ---
if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description="Run embedding generation for a single clip.")
    parser.add_argument("--clip-id", required=True, type=int, help="The clip_id from the database.")
    parser.add_argument("--model", required=True, help="The name of the model to use (e.g., 'openai/clip-vit-base-patch32').")
    parser.add_argument("--strategy", required=True, help="The generation strategy (e.g., 'uniform_avg').")
    parser.add_argument("--env", default="development", help="The environment.")
    parser.add_argument("--overwrite", action="store_true", help="Overwrite existing embeddings.")
    parser.add_argument("--device", default="cpu", help="Device to use for model inference (e.g., 'cpu', 'cuda').")
    
    args = parser.parse_args()

    try:
        result = run_embed(
            clip_id=args.clip_id,
            model_name=args.model,
            generation_strategy=args.strategy,
            environment=args.env,
            overwrite=args.overwrite,
            device=args.device
        )
        print("Embedding generation finished successfully.")
        print(json.dumps(result, indent=2))
        sys.exit(0)
    except Exception as e:
        print(f"Embedding generation failed: {e}", file=sys.stderr)
        sys.exit(1)