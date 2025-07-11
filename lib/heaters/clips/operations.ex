defmodule Heaters.Clips.Operations do
  @moduledoc """
  Main coordination context for video clip processing operations.

  This module serves as a clean delegation facade providing shared utilities
  and coordination functions used across all video processing operations.

  ## Architecture

  This context is organized into two main subcontexts based on operation type:

  ### Clip Edits (User Actions → New Clips)
  - **`Operations.Edits.Merge`** - Clip merging using FFmpeg concat
  - **`Operations.Edits.Split`** - Clip splitting using FFmpeg
  - Triggered by user review actions
  - Creates new clip records that re-enter the pipeline
  - Writes to the `clips` table

  ### Artifact Generation (Pipeline Stages → Supplementary Data)
  - **`Operations.Artifacts.Keyframe`** - Keyframe extraction using Python OpenCV
  - **`Operations.Artifacts.Sprite`** - Sprite sheet generation using FFmpeg
  - Triggered by pipeline state transitions
  - Creates supplementary data for existing clips
  - Writes to the `clip_artifacts` table

  ### Shared Infrastructure

  All operation modules use centralized shared infrastructure:

  - **`Operations.Shared.Types`** - Common result structs and type definitions
  - **`Operations.Shared.TempManager`** - Temporary directory management
  - **`Operations.Shared.FFmpegRunner`** - FFmpeg operation standardization
  - **`Infrastructure.S3`** - S3 upload/download operations

  ## This Module's Responsibilities

  This module provides shared utilities used by all operation modules:

  - **Error handling** - `mark_failed/3` for consistent failure tracking
  - **Artifact management** - `create_artifacts/3` for database artifact creation
  - **S3 path management** - `build_artifact_prefix/2` for consistent S3 paths
  - **Sprite workflow** - State management functions for sprite generation workflow

  ## Usage

  For clip edits (review workflow):

      # Clip merging
      {:ok, result} = Operations.Edits.Merge.run_merge(target_clip_id, source_clip_id)

      # Clip splitting
      {:ok, result} = Operations.Edits.Split.run_split(clip_id, split_at_frame)

  For artifact generation (pipeline stages):

      # Keyframe extraction
      {:ok, result} = Operations.Artifacts.Keyframe.run_keyframe_extraction(clip_id, "multi")

      # Sprite generation
      {:ok, result} = Operations.Artifacts.Sprite.run_sprite(clip_id, %{})

  For shared utilities (used internally by operation modules):

      # Error handling
      Operations.mark_failed(clip_id, "keyframe_failed", "OpenCV error")

      # Artifact creation
      Operations.create_artifacts(clip_id, "keyframe", artifacts_data)

      # S3 path management
      prefix = Operations.build_artifact_prefix(clip, "keyframes")
  """

  alias Heaters.Repo
  alias Heaters.Clips.Clip
  alias Heaters.Clips.Queries, as: ClipQueries
  alias Heaters.Videos.Queries, as: VideoQueries
  alias Heaters.Clips.Operations.Artifacts.ClipArtifact
  alias Heaters.Clips.Operations.Shared.Types
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
      Operations.mark_failed(clip_id, "keyframe_failed", "OpenCV initialization error")

      # Mark merge operation as failed
      Operations.mark_failed(clip, "merge_failed", {:ffmpeg_error, "Invalid codec"})
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

  ## Examples

      # For keyframes
      prefix = Operations.build_artifact_prefix(clip, "keyframes")
      # Returns: "clip_artifacts/Berlin_Skies_Snow_VANS/keyframes"

      # For sprites
      prefix = Operations.build_artifact_prefix(clip, "sprite_sheets")
      # Returns: "clip_artifacts/Berlin_Skies_Snow_VANS/sprite_sheets"
  """
  @spec build_artifact_prefix(Clip.t(), String.t()) :: String.t()
  def build_artifact_prefix(%Clip{source_video_id: source_video_id}, artifact_type) do
    # Get the source video to access the title
    case VideoQueries.get_source_video(source_video_id) do
      {:ok, source_video} ->
        sanitized_title = Heaters.Utils.sanitize_filename(source_video.title)
        "clip_artifacts/#{sanitized_title}/#{artifact_type}"

      {:error, _} ->
        # Fallback to ID-based structure if title lookup fails
        "clip_artifacts/video_#{source_video_id}/#{artifact_type}"
    end
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

      {:ok, artifacts} = Operations.create_artifacts(clip_id, "keyframe", artifacts_data)
  """
  @spec create_artifacts(integer(), String.t(), list(map())) ::
          {:ok, list(ClipArtifact.t())} | {:error, any()}
  def create_artifacts(clip_id, artifact_type, artifacts_data) when is_list(artifacts_data) do
    Logger.info(
      "Operations: Creating #{length(artifacts_data)} #{artifact_type} artifacts for clip_id: #{clip_id}"
    )

    artifacts_attrs =
      artifacts_data
      |> Enum.map(fn artifact_data ->
        build_artifact_attrs(clip_id, artifact_type, artifact_data)
      end)

    # Validate all artifacts before bulk insert
    validated_changesets = Enum.map(artifacts_attrs, &ClipArtifact.changeset(%ClipArtifact{}, &1))

    case validate_artifact_changesets(validated_changesets) do
      :ok ->
        case Repo.insert_all(ClipArtifact, artifacts_attrs, returning: true) do
          {count, artifacts} when count > 0 ->
            Logger.info(
              "Operations: Successfully created #{count} #{artifact_type} artifacts for clip_id: #{clip_id}"
            )

            {:ok, artifacts}

          {0, _} ->
            Logger.error(
              "Operations: Failed to create #{artifact_type} artifacts for clip_id: #{clip_id}"
            )

            {:error, "No artifacts were created"}
        end

      {:error, errors} ->
        Logger.error(
          "Operations: Validation failed for #{artifact_type} artifacts for clip_id: #{clip_id}. Errors: #{inspect(errors)}"
        )

        {:error, "Validation failed: #{format_artifact_validation_errors(errors)}"}
    end
  rescue
    e ->
      Logger.error(
        "Operations: Error creating #{artifact_type} artifacts for clip_id #{clip_id}: #{Exception.message(e)}"
      )

      {:error, Exception.message(e)}
  end

  ## Sprite Workflow Functions
  ##
  ## These functions manage the sprite generation workflow state transitions.
  ## They are used by the SpriteWorker to coordinate sprite generation.

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
  @spec process_sprite_success(Clip.t(), Types.SpriteResult.t()) ::
          {:ok, Clip.t()} | {:error, any()}
  def process_sprite_success(%Clip{} = clip, %Types.SpriteResult{artifacts: artifacts}) do
    # Convert SpriteResult to the map format expected by complete_sprite_generation
    sprite_data = %{"artifacts" => artifacts}
    complete_sprite_generation(clip.id, sprite_data)
  end

  ## Private Helper Functions

  defp validate_artifact_changesets(changesets) do
    errors =
      changesets
      |> Enum.with_index()
      |> Enum.filter(fn {changeset, _index} -> not changeset.valid? end)
      |> Enum.map(fn {changeset, index} -> {index, changeset.errors} end)

    if Enum.empty?(errors) do
      :ok
    else
      {:error, errors}
    end
  end

  defp format_artifact_validation_errors(errors) do
    errors
    |> Enum.map(fn {index, changeset_errors} ->
      error_messages =
        changeset_errors
        |> Enum.map(fn {field, {message, _}} -> "#{field}: #{message}" end)
        |> Enum.join(", ")

      "Artifact #{index}: #{error_messages}"
    end)
    |> Enum.join("; ")
  end

  defp update_clip(%Clip{} = clip, attrs) do
    clip
    |> Clip.changeset(attrs)
    |> Repo.update()
  end

  defp build_artifact_attrs(clip_id, artifact_type, artifact_data) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %{
      clip_id: clip_id,
      artifact_type: artifact_type,
      s3_key: Map.fetch!(artifact_data, "s3_key"),
      metadata: Map.get(artifact_data, "metadata", %{}),
      inserted_at: now,
      updated_at: now
    }
  end

  defp format_error_message(error_reason) when is_binary(error_reason), do: error_reason
  defp format_error_message(error_reason), do: inspect(error_reason)

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
end
