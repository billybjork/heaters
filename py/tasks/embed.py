"""
ONNX Runtime embed task focused on image embedding generation.

This task:
- Receives local keyframe image paths from Elixir
- Generates embeddings via ONNX Runtime (no PyTorch runtime dependency)
- Returns structured embedding data for Elixir to persist
"""

import argparse
import json
import logging
import re
from pathlib import Path

import numpy as np
from PIL import Image

try:
    from onnx_clip import OnnxClip
except ImportError:
    OnnxClip = None

# --- Logging Configuration ---
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

# --- Global Model Cache ---
_model_cache = {}

# Accepted aliases for the current ONNX CLIP backend.
_SUPPORTED_MODEL_ALIASES = {
    "openai/clip-vit-base-patch32": "clip-vit-base-patch32",
    "xenova/clip-vit-base-patch32": "clip-vit-base-patch32",
    "clip-vit-base-patch32": "clip-vit-base-patch32",
    "onnx-clip-vit-base-patch32": "clip-vit-base-patch32",
}


def _resolve_model_alias(model_name: str) -> str:
    normalized = (model_name or "").strip().lower()

    if normalized in _SUPPORTED_MODEL_ALIASES:
        return _SUPPORTED_MODEL_ALIASES[normalized]

    supported = ", ".join(sorted(_SUPPORTED_MODEL_ALIASES.keys()))
    raise ValueError(
        f"Unsupported ONNX embedding model '{model_name}'. Supported aliases: {supported}"
    )


def get_cached_model(model_name: str):
    """Loads ONNX CLIP model or retrieves it from cache."""
    resolved_model = _resolve_model_alias(model_name)

    if resolved_model in _model_cache:
        logger.debug("Using cached ONNX model backend: %s", resolved_model)
        return _model_cache[resolved_model]

    if OnnxClip is None:
        raise ImportError("onnx_clip is required for embedding generation")

    logger.info("Loading ONNX CLIP backend for model alias: %s", resolved_model)
    model = OnnxClip()
    model_info = (model, "clip_onnx")
    _model_cache[resolved_model] = model_info
    return model_info


def generate_image_embedding(image_path: str, model) -> np.ndarray:
    """Generates an embedding for a single image via ONNX CLIP backend."""
    try:
        image = Image.open(image_path).convert("RGB")
        embedding_batch = model.get_image_embeddings([image])

        if embedding_batch is None:
            raise ValueError("ONNX CLIP backend returned no embeddings")

        embedding_array = np.asarray(embedding_batch)

        if embedding_array.ndim == 1:
            embedding = embedding_array.astype(np.float32)
        else:
            embedding = embedding_array[0].astype(np.float32)

        logger.debug("Generated embedding shape: %s", embedding.shape)
        return embedding.flatten()
    except Exception as err:
        logger.error("Error processing image %s: %s", image_path, err)
        raise


def aggregate_embeddings(embeddings: list, aggregation_method: str = None) -> np.ndarray:
    """Aggregates multiple embeddings using the specified method."""
    if len(embeddings) == 1:
        return embeddings[0]

    embeddings_array = np.stack(embeddings)

    if aggregation_method == "avg":
        result = np.mean(embeddings_array, axis=0)
        logger.info("Averaged %d embeddings", len(embeddings))
    else:
        # Default: return the first embedding if no aggregation specified
        result = embeddings[0]
        logger.info("Using first of %d embeddings (no aggregation)", len(embeddings))

    return result


def run_embed(
    clip_id: int,
    image_paths: list,
    model_name: str,
    generation_strategy: str,
    device: str = "cpu",
    **kwargs,
):
    """
    Generates image embeddings and returns structured data.

    Args:
        clip_id: The ID of the clip (reference only)
        image_paths: List of local image paths
        model_name: Embedding model alias
        generation_strategy: Strategy for selecting/aggregating embeddings
        device: Requested device (currently informational; ONNX CLIP backend is CPU-oriented)
        **kwargs: Additional options

    Returns:
        dict: Structured data about the embedding including vector and metadata
    """
    logger.info("RUNNING EMBED for clip_id: %s", clip_id)
    logger.info("Model: %s, Strategy: %s, Device: %s", model_name, generation_strategy, device)
    logger.info("Processing %d keyframe(s)", len(image_paths))

    if device == "cuda":
        logger.warning("CUDA requested, but ONNX CLIP backend currently runs with CPU provider")

    # Parse generation strategy
    match = re.match(r"keyframe_([a-zA-Z0-9]+)(?:_(avg))?$", generation_strategy)
    if not match:
        raise ValueError(f"Invalid generation_strategy format: '{generation_strategy}'")

    keyframe_strategy_name = match.group(1)
    aggregation_method = match.group(2)
    logger.info(
        "Parsed strategy: keyframe_type='%s', aggregation='%s'",
        keyframe_strategy_name,
        aggregation_method,
    )

    model, model_type = get_cached_model(model_name)

    try:
        # Step 1: Validate local image paths exist
        missing = [p for p in image_paths if not Path(p).exists()]
        if missing:
            raise FileNotFoundError(f"Missing image paths: {missing}")

        # Step 2: Generate embeddings for each keyframe
        embeddings = []
        total_keyframes = len(image_paths)

        for i, image_path in enumerate(image_paths):
            progress_percentage = int(((i + 1) / total_keyframes) * 100)
            logger.info(
                "Embedding generation: %d%% complete (%d/%d keyframes)",
                progress_percentage,
                i + 1,
                total_keyframes,
            )
            embedding = generate_image_embedding(image_path, model)
            embeddings.append(embedding)

        # Step 3: Aggregate embeddings if needed
        logger.info("Embedding generation: Aggregating embeddings")
        final_embedding = aggregate_embeddings(embeddings, aggregation_method)
        embedding_dim = int(final_embedding.shape[0])

        # Convert to list for JSON serialization
        embedding_vector = final_embedding.tolist()

        logger.info("Embedding generation: 100%% complete")

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
                "keyframes_processed": len(image_paths),
                "aggregation_method": aggregation_method,
                "device_used": "cpu",
                "backend": "onnxruntime",
            },
        }

    except Exception as err:
        logger.error("Error processing embeddings: %s", err)
        raise


def main():
    """Main entry point for standalone execution"""
    parser = argparse.ArgumentParser(description="Embedding generation task")
    parser.add_argument("--clip-id", type=int, required=True)
    parser.add_argument("--image-paths", required=True, help="JSON array of local image paths")
    parser.add_argument("--model-name", required=True)
    parser.add_argument("--generation-strategy", required=True)
    parser.add_argument("--device", default="cpu", choices=["cpu", "cuda"])

    args = parser.parse_args()

    # Parse image paths from JSON
    try:
        image_paths = json.loads(args.image_paths)
        if not isinstance(image_paths, list):
            raise ValueError("image-paths must be a JSON array")
    except json.JSONDecodeError as err:
        print(f"Error parsing image-paths JSON: {err}")
        exit(1)

    try:
        result = run_embed(
            args.clip_id,
            image_paths,
            args.model_name,
            args.generation_strategy,
            args.device,
        )
        print(json.dumps(result, indent=2))
    except Exception as err:
        error_result = {
            "status": "error",
            "error": str(err),
            "error_type": type(err).__name__,
        }
        print(json.dumps(error_result, indent=2))
        exit(1)


if __name__ == "__main__":
    main()
