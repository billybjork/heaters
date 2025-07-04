defmodule Heaters.Clips do
  @moduledoc """
  Main context for clip operations and workflow management.

  This module serves as the primary entry point for all clip-related operations,
  providing a clean public API while delegating to specialized sub-modules.

  ## Sub-contexts

  - **Review**: Clip review workflow and queue management (`Heaters.Clips.Review`)
  - **Operations**: Video processing operations (`Heaters.Clips.Operations`)
  - **Embeddings**: Embedding generation and queries (`Heaters.Clips.Embeddings`)

  ## Schema

  - **Clip**: The main clip schema (`Heaters.Clips.Clip`)

  ## Examples

      # Review operations
      Clips.next_pending_review_clips(10)
      Clips.select_clip_and_fetch_next(clip, "approve")

      # Operations (use dedicated modules)
      Operations.Artifacts.Keyframe.run_keyframe_extraction(clip_id, "multi")
      Operations.Edits.Merge.run_merge(target_clip_id, source_clip_id)

      # Embedding operations
      Clips.generate_embeddings(clip_id)
      Clips.search_similar_clips(query_vector, limit: 10)
  """

  # Delegated functions for common operations
  alias Heaters.Clips.{Review, Operations, Embeddings, Queries}

  # Review operations
  defdelegate next_pending_review_clips(limit, exclude_ids \\ []), to: Review
  defdelegate next_pending_review_clip(), to: Review
  defdelegate select_clip_and_fetch_next(clip, action), to: Review
  defdelegate request_merge_and_fetch_next(prev_clip, curr_clip), to: Review
  defdelegate request_group_and_fetch_next(prev_clip, curr_clip), to: Review
  defdelegate request_split_and_fetch_next(clip, frame_num), to: Review

  defdelegate for_source_video_with_sprites(source_video_id, exclude_id, page, page_size),
    to: Review

  # Operations
  defdelegate mark_failed(clip_or_id, failure_state, error_reason), to: Operations
  defdelegate build_artifact_prefix(clip, artifact_type), to: Operations
  defdelegate create_artifacts(clip_id, artifact_type, artifacts_data), to: Operations

  # Sprite state management (delegated to Operations)
  defdelegate start_sprite_generation(clip_id), to: Operations
  defdelegate complete_sprite_generation(clip_id, sprite_data \\ %{}), to: Operations
  defdelegate mark_sprite_failed(clip_id, error_reason), to: Operations
  defdelegate process_sprite_success(clip, result), to: Operations

  # Embedding operations
  defdelegate start_embedding(clip_id), to: Embeddings
  defdelegate complete_embedding(clip_id, embedding_data), to: Embeddings
  defdelegate process_embedding_success(clip, result), to: Embeddings
  defdelegate has_embedding?(clip_id, model_name, generation_strategy), to: Embeddings
  defdelegate similar_clips(main_clip_id, filters, asc?, page, per), to: Embeddings
  defdelegate random_embedded_clip(filters), to: Embeddings
  defdelegate embedded_filter_opts(), to: Embeddings

  # Query operations
  defdelegate get_clip(id), to: Queries
  defdelegate get_clip_with_artifacts(id), to: Queries
  defdelegate get_clip!(id), to: Queries
  defdelegate change_clip(clip, attrs), to: Queries
  defdelegate update_clip(clip, attrs), to: Queries
  defdelegate pending_review_count(), to: Queries
  defdelegate get_clips_by_state(state), to: Queries
end
