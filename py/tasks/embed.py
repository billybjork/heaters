"""
Refactored Embed Task - "Dumber" Python focused on embedding generation only.

This version:
- Receives explicit S3 paths to keyframe images from Elixir
- Focuses only on embedding generation using ML models (CLIP, DINOv2)
- Returns structured data about embeddings instead of managing database state
- No database connections or state management
"""

import argparse
import json
import logging
import os
import re
import tempfile
import threading
from pathlib import Path

import boto3
import numpy as np
import torch
from PIL import Image
from botocore.exceptions import ClientError, NoCredentialsError

# Model Loading Imports
try:
    from transformers import CLIPProcessor, CLIPModel, AutoImageProcessor, AutoModel
except ImportError:
    CLIPProcessor, CLIPModel, AutoImageProcessor, AutoModel = None, None, None, None

# --- Logging Configuration ---
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

class S3TransferProgress:
    """Callback for boto3 reporting progress via logger"""
    
    def __init__(self, total_size, filename, logger_instance, throttle_percentage=50):
        self._filename = filename
        self._total_size = total_size
        self._seen_so_far = 0
        self._lock = threading.Lock()
        self._logger = logger_instance
        self._throttle_percentage = max(1, min(int(throttle_percentage), 100))
        self._last_logged_percentage = -1

    def __call__(self, bytes_amount):
        try:
            with self._lock:
                self._seen_so_far += bytes_amount
                current_percentage = 0
                if self._total_size > 0:
                    current_percentage = int((self._seen_so_far / self._total_size) * 100)
                
                should_log = (
                    current_percentage >= self._last_logged_percentage + self._throttle_percentage
                    and current_percentage < 100
                ) or (current_percentage == 100 and self._last_logged_percentage != 100)

                if should_log:
                    size_mb = self._seen_so_far / (1024 * 1024)
                    total_size_mb = self._total_size / (1024 * 1024)
                    self._logger.info(
                        f"S3 Download: {self._filename} - {current_percentage}% complete "
                        f"({size_mb:.2f}/{total_size_mb:.2f} MiB)"
                    )
                    self._last_logged_percentage = current_percentage
        except Exception as e:
            self._logger.error(f"S3 Progress error: {e}")

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
        if CLIPModel is None:
            raise ImportError("transformers library required for CLIP models")
        try:
            model = CLIPModel.from_pretrained(model_name).to(device).eval()
            processor = CLIPProcessor.from_pretrained(model_name)
            if hasattr(model.config, 'projection_dim') and model.config.projection_dim:
                embedding_dim = model.config.projection_dim
            elif hasattr(model.config, 'hidden_size') and model.config.hidden_size:
                embedding_dim = model.config.hidden_size
            else:
                embedding_dim = 512 if "base" in model_name.lower() else 768
            model_type_str = "clip"
            logger.info(f"Loaded CLIP model: {model_name} (Type: {model_type_str}, Dim: {embedding_dim})")
        except Exception as e:
            if "Cannot copy out of meta tensor" in str(e):
                raise ValueError(f"Meta tensor error loading CLIP: {model_name}. Check accelerate/config.") from e
            else:
                raise ValueError(f"Failed to load CLIP model: {model_name}") from e
    
    elif "dinov2" in model_name.lower():
        if AutoModel is None:
            raise ImportError("transformers library required for DINOv2 models")
        try:
            processor = AutoImageProcessor.from_pretrained(model_name)
            model = AutoModel.from_pretrained(model_name).to(device).eval()
            if hasattr(model.config, 'hidden_size') and model.config.hidden_size:
                embedding_dim = model.config.hidden_size
            else:
                raise ValueError(f"Cannot determine embedding dimension for DINOv2 model: {model_name}")
            model_type_str = "dino"
            logger.info(f"Loaded DINOv2 model: {model_name} (Type: {model_type_str}, Dim: {embedding_dim})")
        except Exception as e:
            if "Cannot copy out of meta tensor" in str(e):
                raise ValueError(f"Meta tensor error loading DINOv2: {model_name}. Check accelerate/config.") from e
            else:
                raise ValueError(f"Failed to load DINOv2 model: {model_name}") from e
    else:
        raise ValueError(f"Model name not recognized or supported: {model_name}")

    if model is None or processor is None or model_type_str is None or embedding_dim is None:
        raise RuntimeError(f"Failed to initialize one or more components for model: {model_name}")

    return model, processor, model_type_str, embedding_dim

def generate_image_embedding(image_path: str, model, processor, model_type: str, device='cpu') -> np.ndarray:
    """Generates embedding for a single image."""
    try:
        image = Image.open(image_path).convert('RGB')
        logger.debug(f"Processing image: {image_path} (Size: {image.size})")
        
        with torch.no_grad():
            if model_type == "clip":
                inputs = processor(images=image, return_tensors="pt").to(device)
                outputs = model.get_image_features(**inputs)
                embedding = outputs.cpu().numpy().flatten()
            elif model_type == "dino":
                inputs = processor(images=image, return_tensors="pt").to(device)
                outputs = model(**inputs)
                # For DINOv2, typically use the [CLS] token (first token)
                embedding = outputs.last_hidden_state[:, 0].cpu().numpy().flatten()
            else:
                raise ValueError(f"Unsupported model type: {model_type}")
        
        logger.debug(f"Generated embedding shape: {embedding.shape}")
        return embedding
        
    except Exception as e:
        logger.error(f"Error processing image {image_path}: {e}")
        raise

def aggregate_embeddings(embeddings: list, aggregation_method: str = None) -> np.ndarray:
    """Aggregates multiple embeddings using the specified method."""
    if len(embeddings) == 1:
        return embeddings[0]
    
    embeddings_array = np.stack(embeddings)
    
    if aggregation_method == "avg":
        result = np.mean(embeddings_array, axis=0)
        logger.info(f"Averaged {len(embeddings)} embeddings")
    else:
        # Default: return the first embedding if no aggregation specified
        result = embeddings[0]
        logger.info(f"Using first of {len(embeddings)} embeddings (no aggregation)")
    
    return result

def run_embed(
    clip_id: int,
    keyframe_s3_keys: list,
    model_name: str,
    generation_strategy: str,
    device: str = "cpu",
    **kwargs
):
    """
    Downloads keyframe images, generates embeddings, and returns structured data.
    
    Args:
        clip_id: The ID of the clip (for reference only)
        keyframe_s3_keys: List of S3 keys to keyframe images
        model_name: The name of the embedding model to use
        generation_strategy: Strategy for selecting/aggregating embeddings
        device: Device to run model on ('cpu' or 'cuda')
        **kwargs: Additional options
    
    Returns:
        dict: Structured data about the embedding including vector and metadata
    """
    logger.info(f"RUNNING EMBED for clip_id: {clip_id}")
    logger.info(f"Model: {model_name}, Strategy: {generation_strategy}, Device: {device}")
    logger.info(f"Processing {len(keyframe_s3_keys)} keyframe(s)")
    
    # Parse generation strategy
    match = re.match(r"keyframe_([a-zA-Z0-9]+)(?:_(avg))?$", generation_strategy)
    if not match:
        raise ValueError(f"Invalid generation_strategy format: '{generation_strategy}'")
    
    keyframe_strategy_name = match.group(1)
    aggregation_method = match.group(2)
    logger.info(f"Parsed strategy: keyframe_type='{keyframe_strategy_name}', aggregation='{aggregation_method}'")
    
    # Get S3 resources from environment (provided by Elixir)
    s3_bucket_name = os.getenv("S3_BUCKET_NAME")
    if not s3_bucket_name:
        raise ValueError("S3_BUCKET_NAME environment variable not set")

    try:
        s3_client = boto3.client("s3")
    except NoCredentialsError:
        logger.error("S3 credentials not found")
        raise

    # Load model
    model, processor, model_type, embedding_dim = get_cached_model_and_processor(model_name, device)

    with tempfile.TemporaryDirectory() as temp_dir:
        temp_dir_path = Path(temp_dir)
        
        try:
            # Step 1: Download keyframe images
            local_image_paths = []
            for i, s3_key in enumerate(keyframe_s3_keys):
                local_filename = f"keyframe_{i}_{Path(s3_key).name}"
                local_path = temp_dir_path / local_filename
                
                logger.info(f"Downloading keyframe {i+1}/{len(keyframe_s3_keys)}: s3://{s3_bucket_name}/{s3_key}")
                s3_client.download_file(s3_bucket_name, s3_key, str(local_path))
                local_image_paths.append(str(local_path))
            
            # Step 2: Generate embeddings for each keyframe
            embeddings = []
            total_keyframes = len(local_image_paths)
            for i, image_path in enumerate(local_image_paths):
                progress_percentage = int(((i + 1) / total_keyframes) * 100)
                logger.info(f"Embedding generation: {progress_percentage}% complete ({i+1}/{total_keyframes} keyframes)")
                embedding = generate_image_embedding(image_path, model, processor, model_type, device)
                embeddings.append(embedding)
            
            # Step 3: Aggregate embeddings if needed
            logger.info("Embedding generation: Aggregating embeddings")
            final_embedding = aggregate_embeddings(embeddings, aggregation_method)
            
            # Convert to list for JSON serialization
            embedding_vector = final_embedding.tolist()
            
            logger.info("Embedding generation: 100% complete")
            
            # Return structured data for Elixir to process
            return {
                "status": "success",
                "model_name": model_name,
                "generation_strategy": generation_strategy,
                "embedding": embedding_vector,
                "metadata": {
                    "clip_id": clip_id,
                    "model_type": model_type,
                    "embedding_dimension": embedding_dim,
                    "keyframes_processed": len(keyframe_s3_keys),
                    "aggregation_method": aggregation_method,
                    "device_used": device
                }
            }

        except Exception as e:
            logger.error(f"Error processing embeddings: {e}")
            raise

def main():
    """Main entry point for standalone execution"""
    parser = argparse.ArgumentParser(description="Embedding generation task")
    parser.add_argument("--clip-id", type=int, required=True)
    parser.add_argument("--keyframe-s3-keys", required=True, 
                       help="JSON array of S3 keys to keyframe images")
    parser.add_argument("--model-name", required=True)
    parser.add_argument("--generation-strategy", required=True)
    parser.add_argument("--device", default="cpu", choices=["cpu", "cuda"])
    
    args = parser.parse_args()
    
    # Parse keyframe S3 keys from JSON
    try:
        keyframe_s3_keys = json.loads(args.keyframe_s3_keys)
        if not isinstance(keyframe_s3_keys, list):
            raise ValueError("keyframe-s3-keys must be a JSON array")
    except json.JSONDecodeError as e:
        print(f"Error parsing keyframe-s3-keys JSON: {e}")
        exit(1)
    
    try:
        result = run_embed(
            args.clip_id,
            keyframe_s3_keys,
            args.model_name,
            args.generation_strategy,
            args.device
        )
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