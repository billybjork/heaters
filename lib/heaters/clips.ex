defmodule Heaters.Clips do
  @moduledoc """
  Main context for enhanced virtual clip operations and workflow management.

  This module serves as the primary entry point for all clip-related operations,
  providing a clean public API while delegating to specialized sub-modules.

  ## Sub-contexts

  - **Review**: Virtual clip review workflow with cut point operations (`Heaters.Clips.Review`)
  - **VirtualClips**: Enhanced virtual clip processing operations (`Heaters.Clips.VirtualClips`)
  - **Artifacts**: Keyframe extraction and clip artifact management (`Heaters.Clips.Artifacts`)
  - **Export**: Virtual clip export to physical files (`Heaters.Clips.Export`)
  - **Archive**: Clip archival operations (`Heaters.Clips.Archive`)
  - **Embeddings**: Embedding generation and queries (`Heaters.Clips.Embeddings`)

  ## Schema

  - **Clip**: The main clip schema with virtual/physical support (`Heaters.Clips.Clip`)

  ## Examples

      # Review operations (cut point management)
      Clips.next_pending_review_clips(10)
      Clips.select_clip_and_fetch_next(clip, "approve")

      # Virtual clip operations
      VirtualClips.add_cut_point(source_video_id, frame_num, user_id)
      VirtualClips.remove_cut_point(source_video_id, frame_num, user_id)

      # Export operations (virtual → physical)
      Export.Worker.handle_work(%{clip_id: clip_id})

      # Embedding operations (on exported clips)
      Clips.start_embedding(clip_id)
      Clips.similar_clips(main_clip_id, filters, asc?, page, per)
  """

  # Delegated functions for common operations
  alias Heaters.Clips.{Review, Operations, Embeddings, Queries}

  ## Review delegation

  @doc """
  Fetch clips awaiting review.

  ## Examples

      # Get next 10 clips for review
      clips = Clips.next_pending_review_clips(10)

      # Get next 5 clips, excluding some IDs
      clips = Clips.next_pending_review_clips(5, [123, 456])
  """
  defdelegate next_pending_review_clips(limit, exclude_ids \\ []), to: Review

  # Review operations (enhanced for virtual clips)
  defdelegate select_clip_and_fetch_next(clip, action), to: Review
  defdelegate request_group_and_fetch_next(prev_clip, curr_clip), to: Review

  # Operations (shared utilities)
  defdelegate mark_failed(clip_or_id, failure_state, error_reason), to: Operations
  defdelegate build_artifact_prefix(clip, artifact_type), to: Operations
  defdelegate create_artifacts(clip_id, artifact_type, artifacts_data), to: Operations

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
