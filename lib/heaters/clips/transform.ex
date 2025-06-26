defmodule Heaters.Clips.Transform do
  @moduledoc """
  Context for managing clip transformation operations and coordination.

  This module serves as the coordination layer for various clip transformation operations.
  After Phase 2 refactoring, this module provides:

  ## Core Responsibilities
  - General transformation state management and error handling
  - Shared utilities for artifact creation and S3 path management
  - Coordination between different transformation operations

  ## Specific Transformation Modules
  Specialized operations are handled by dedicated modules within this context:

  - **Keyframe extraction**: `Heaters.Clips.Transform.Keyframe`
    - Extracts keyframes from video clips using Python OpenCV
    - Manages keyframing workflow state transitions
    - Creates keyframe artifacts for embedding generation

  - **Sprite generation**: `Heaters.Clips.Transform.Sprite`
    - Generates video sprite sheets for preview
    - Handles sprite-specific artifact management

  - **Merge operations**: `Heaters.Clips.Transform.Merge`
    - Merges multiple clips into a single clip
    - Native Elixir implementation using FFmpeg

  - **Split operations**: `Heaters.Clips.Transform.Split`
    - Splits clips at specific frame boundaries
    - Native Elixir implementation using FFmpeg

  ## Architecture Notes
  This context follows CQRS principles with clear separation of concerns:
  - Each transformation type has its own dedicated module
  - Shared functionality is provided by this coordination module
  - State management is handled consistently across all transformations
  - Error handling and retry logic is centralized

  ## Usage Examples

      # General error handling (used by all transformation modules)
      Transform.mark_failed(clip_id, "keyframe_failed", "OpenCV error")

      # Artifact management (used by all transformation modules)
      Transform.create_artifacts(clip_id, "keyframe", artifacts_data)

      # S3 path management (used by all transformation modules)
      prefix = Transform.build_artifact_prefix(clip, "keyframes")

  For specific operations, use the dedicated modules:

      # Keyframe extraction
      Keyframe.run_keyframe_extraction(clip_id, "multi")

      # Merge clips
      Merge.run_merge([source_clip_id, target_clip_id])

      # Split clip
      Split.run_split(clip_id, split_frame)
  """

  alias Heaters.Repo
  alias Heaters.Clips.Clip
  alias Heaters.Clips.Queries, as: ClipQueries
  alias Heaters.Clips.Transform.ClipArtifact
  alias Heaters.Clips.Transform.Sprite
  require Logger

  @doc """
  Mark a clip transformation as failed with error tracking.

  This function is used by all transformation modules to consistently
  handle failures and track retry attempts.

  ## Parameters
  - `clip_or_id`: Either a Clip struct or clip ID integer
  - `failure_state`: The specific failure state to transition to
  - `error_reason`: The error that caused the failure

  ## Examples

      # Mark keyframe extraction as failed
      Transform.mark_failed(clip_id, "keyframe_failed", "OpenCV initialization error")

      # Mark merge operation as failed
      Transform.mark_failed(clip, "merge_failed", {:ffmpeg_error, "Invalid codec"})
  """
  @spec mark_failed(Clip.t() | integer(), String.t(), any()) :: {:ok, Clip.t()} | {:error, any()}
  def mark_failed(clip_or_id, failure_state, error_reason)

  def mark_failed(%Clip{} = clip, failure_state, error_reason) do
    error_message = format_error_message(error_reason)

    update_clip(clip, %{
      ingest_state: failure_state,
      last_error: error_message,
      retry_count: (clip.retry_count || 0) + 1
    })
  end

  def mark_failed(clip_id, failure_state, error_reason) when is_integer(clip_id) do
    with {:ok, clip} <- ClipQueries.get_clip(clip_id) do
      mark_failed(clip, failure_state, error_reason)
    end
  end

  @doc """
  Build S3 prefix for artifact outputs.

  Creates a consistent S3 path structure for storing transformation artifacts.
  Used by all transformation modules to ensure consistent storage patterns.

  ## Examples

      # For keyframes
      prefix = Transform.build_artifact_prefix(clip, "keyframes")
      # Returns: "source_videos/123/clips/456/keyframes"

      # For sprites
      prefix = Transform.build_artifact_prefix(clip, "sprites")
      # Returns: "source_videos/123/clips/456/sprites"
  """
  @spec build_artifact_prefix(Clip.t(), String.t()) :: String.t()
  def build_artifact_prefix(%Clip{id: id, source_video_id: source_video_id}, artifact_type) do
    "source_videos/#{source_video_id}/clips/#{id}/#{artifact_type}"
  end

  @doc """
  Create multiple artifacts from processing results.

  This function provides a consistent way for all transformation modules
  to create artifact records in the database after successful processing.

  ## Parameters
  - `clip_id`: The ID of the clip the artifacts belong to
  - `artifact_type`: The type of artifacts being created (e.g., "keyframe", "sprite")
  - `artifacts_data`: List of artifact data maps containing s3_key and metadata

  ## Artifact Data Format
  Each artifact data map should contain:
  - `:s3_key` (required) - The S3 key where the artifact is stored
  - `:metadata` (optional) - Additional metadata about the artifact

  ## Examples

      artifacts_data = [
        %{s3_key: "path/to/keyframe1.jpg", metadata: %{frame_index: 100}},
        %{s3_key: "path/to/keyframe2.jpg", metadata: %{frame_index: 200}}
      ]

      {:ok, artifacts} = Transform.create_artifacts(clip_id, "keyframe", artifacts_data)
  """
  @spec create_artifacts(integer(), String.t(), list(map())) ::
          {:ok, list(ClipArtifact.t())} | {:error, any()}
  def create_artifacts(clip_id, artifact_type, artifacts_data) when is_list(artifacts_data) do
    Logger.info(
      "Transform: Creating #{length(artifacts_data)} #{artifact_type} artifacts for clip_id: #{clip_id}"
    )

    artifacts_attrs =
      artifacts_data
      |> Enum.map(fn artifact_data ->
        build_artifact_attrs(clip_id, artifact_type, artifact_data)
      end)

    case Repo.insert_all(ClipArtifact, artifacts_attrs, returning: true) do
      {count, artifacts} when count > 0 ->
        Logger.info(
          "Transform: Successfully created #{count} #{artifact_type} artifacts for clip_id: #{clip_id}"
        )

        {:ok, artifacts}

      {0, _} ->
        Logger.error(
          "Transform: Failed to create #{artifact_type} artifacts for clip_id: #{clip_id}"
        )

        {:error, "No artifacts were created"}
    end
  rescue
    e ->
      Logger.error(
        "Transform: Error creating #{artifact_type} artifacts for clip_id #{clip_id}: #{Exception.message(e)}"
      )

      {:error, Exception.message(e)}
  end

  # Private helper functions

  defp update_clip(%Clip{} = clip, attrs) do
    clip
    |> Clip.changeset(attrs)
    |> Repo.update()
  end

  defp build_artifact_attrs(clip_id, artifact_type, artifact_data) do
    now = DateTime.utc_now()

    %{
      clip_id: clip_id,
      artifact_type: artifact_type,
      s3_key: Map.fetch!(artifact_data, :s3_key),
      metadata: Map.get(artifact_data, :metadata, %{}),
      inserted_at: now,
      updated_at: now
    }
  end

  defp format_error_message(error_reason) when is_binary(error_reason), do: error_reason
  defp format_error_message(error_reason), do: inspect(error_reason)

  @doc """
  Transition a clip to "generating_sprite" state for sprite generation.
  """
  @spec start_sprite_generation(integer()) :: {:ok, Clip.t()} | {:error, any()}
  def start_sprite_generation(clip_id) do
    with {:ok, clip} <- ClipQueries.get_clip(clip_id),
         :ok <- validate_sprite_transition(clip.ingest_state) do
      update_clip(clip, %{
        ingest_state: "generating_sprite",
        last_error: nil
      })
    end
  end

  @doc """
  Mark sprite generation as complete and transition to pending_review.

  This function handles the successful completion of sprite generation,
  creates sprite artifacts, and transitions the clip to pending_review state.
  """
  @spec complete_sprite_generation(integer(), map()) :: {:ok, Clip.t()} | {:error, any()}
  def complete_sprite_generation(clip_id, sprite_data \\ %{}) do
    Repo.transaction(fn ->
      with {:ok, clip} <- ClipQueries.get_clip(clip_id),
           {:ok, updated_clip} <-
             update_clip(clip, %{
               ingest_state: "pending_review",
               last_error: nil
             }),
           {:ok, _artifacts} <- maybe_create_sprite_artifacts(clip_id, sprite_data) do
        updated_clip
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Mark sprite generation as failed.

  This is a convenience function that calls the generic mark_failed/3
  with sprite-specific parameters.
  """
  @spec mark_sprite_failed(integer(), any()) :: {:ok, Clip.t()} | {:error, any()}
  def mark_sprite_failed(clip_id, error_reason) do
    mark_failed(clip_id, "sprite_failed", error_reason)
  end

  @doc """
  Process successful sprite generation results.

  This is a convenience function for processing sprite success results
  from workers or direct calls.
  """
  @spec process_sprite_success(Clip.t(), Sprite.SpriteResult.t()) ::
          {:ok, Clip.t()} | {:error, any()}
  def process_sprite_success(%Clip{} = clip, %Sprite.SpriteResult{artifacts: artifacts}) do
    # Convert SpriteResult to the map format expected by complete_sprite_generation
    sprite_data = %{"artifacts" => artifacts}
    complete_sprite_generation(clip.id, sprite_data)
  end

  # Private helper functions

  defp validate_sprite_transition(current_state) do
    case current_state do
      "spliced" -> :ok
      "sprite_failed" -> :ok
      _ -> {:error, :invalid_state_transition}
    end
  end

  defp maybe_create_sprite_artifacts(clip_id, sprite_data) when map_size(sprite_data) > 0 do
    artifacts_data = Map.get(sprite_data, "artifacts", [])

    if Enum.any?(artifacts_data) do
      create_artifacts(clip_id, "sprite_sheet", artifacts_data)
    else
      {:ok, []}
    end
  end

  defp maybe_create_sprite_artifacts(_clip_id, _sprite_data), do: {:ok, []}

  @doc """
  Transition a clip to "keyframing" state for keyframe extraction.
  """
  @spec start_keyframing(integer()) :: {:ok, Clip.t()} | {:error, any()}
  def start_keyframing(clip_id) do
    with {:ok, clip} <- ClipQueries.get_clip(clip_id),
         :ok <- validate_keyframe_transition(clip.ingest_state) do
      update_clip(clip, %{
        ingest_state: "keyframing",
        last_error: nil
      })
    end
  end

  @doc """
  Mark keyframe extraction as complete and transition to keyframed state.

  This function handles the successful completion of keyframe extraction
  and transitions the clip to keyframed state.
  """
  @spec complete_keyframing(integer()) :: {:ok, Clip.t()} | {:error, any()}
  def complete_keyframing(clip_id) do
    with {:ok, clip} <- ClipQueries.get_clip(clip_id) do
      update_clip(clip, %{
        ingest_state: "keyframed",
        keyframed_at: DateTime.utc_now(),
        last_error: nil
      })
    end
  end

  @doc """
  Mark keyframe extraction as failed.

  This is a convenience function that calls the generic mark_failed/3
  with keyframe-specific parameters.
  """
  @spec mark_keyframe_failed(integer(), any()) :: {:ok, Clip.t()} | {:error, any()}
  def mark_keyframe_failed(clip_id, error_reason) do
    mark_failed(clip_id, "keyframe_failed", error_reason)
  end

  # Private helper functions for keyframing

  defp validate_keyframe_transition(current_state) do
    case current_state do
      "review_approved" -> :ok
      "keyframe_failed" -> :ok
      _ -> {:error, :invalid_state_transition}
    end
  end
end
