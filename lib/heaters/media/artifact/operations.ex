defmodule Heaters.Media.Artifact.Operations do
  @moduledoc """
  Artifact management operations and utilities.

  This module provides shared utilities for artifact generation and management
  across all artifact types (keyframes, sprites, etc.).

  ## Responsibilities

  - **Artifact Creation**: `create_artifacts/3` for database artifact creation
  - **S3 Path Management**: `build_artifact_prefix/2` for consistent S3 paths
  - **Error Handling**: Specialized error handling for artifact operations

  ## Usage

  For artifact generation (pipeline stages):

      # Keyframe extraction (after export)
      {:ok, result} = Artifacts.Keyframe.run_keyframe_extraction(clip_id, "multi")

  For artifact utilities (used internally by artifact modules):

      # Artifact creation
      Artifacts.Operations.create_artifacts(clip_id, "keyframe", artifacts_data)

      # S3 path management
      prefix = Artifacts.Operations.build_artifact_prefix(clip, "keyframes")
  """

  @repo_port Application.compile_env(:heaters, :repo_port, Heaters.Database.EctoAdapter)
  alias Heaters.Media.Clip
  alias Heaters.Media.Queries.Video, as: VideoQueries
  alias Heaters.Media.Artifact.ClipArtifact
  require Logger

  @doc """
  Build S3 prefix for artifact outputs.

  Creates a consistent S3 path structure for storing transformation artifacts.

  ## Examples

      # For keyframes
      prefix = Artifacts.Operations.build_artifact_prefix(clip, "keyframes")
      # Returns: "clip_artifacts/Berlin_Skies_Snow_VANS/keyframes"

      # For sprites
      prefix = Artifacts.Operations.build_artifact_prefix(clip, "sprite_sheets")
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

      {:ok, artifacts} = Artifacts.Operations.create_artifacts(clip_id, "keyframe", artifacts_data)
  """
  @spec create_artifacts(integer(), String.t(), list(map())) ::
          {:ok, list(ClipArtifact.t())} | {:error, any()}
  def create_artifacts(clip_id, artifact_type, artifacts_data) when is_list(artifacts_data) do
    Logger.info(
      "Artifacts.Operations: Creating #{length(artifacts_data)} #{artifact_type} artifacts for clip_id: #{clip_id}"
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
        case @repo_port.insert_all(ClipArtifact, artifacts_attrs, returning: true) do
          {count, artifacts} when count > 0 ->
            Logger.info(
              "Artifacts.Operations: Successfully created #{count} #{artifact_type} artifacts for clip_id: #{clip_id}"
            )

            {:ok, artifacts}

          {0, _} ->
            Logger.error(
              "Artifacts.Operations: Failed to create #{artifact_type} artifacts for clip_id: #{clip_id}"
            )

            {:error, "No artifacts were created"}
        end

      {:error, errors} ->
        Logger.error(
          "Artifacts.Operations: Validation failed for #{artifact_type} artifacts for clip_id: #{clip_id}. Errors: #{inspect(errors)}"
        )

        {:error, "Validation failed: #{format_artifact_validation_errors(errors)}"}
    end
  rescue
    e ->
      Logger.error(
        "Artifacts.Operations: Error creating #{artifact_type} artifacts for clip_id #{clip_id}: #{Exception.message(e)}"
      )

      {:error, Exception.message(e)}
  end

  # Private Helper Functions

  @spec validate_artifact_changesets(list(Ecto.Changeset.t())) :: :ok | {:error, list()}
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

  @spec format_artifact_validation_errors(list()) :: String.t()
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

  @spec build_artifact_attrs(integer(), String.t(), map()) :: map()
  defp build_artifact_attrs(clip_id, artifact_type, artifact_data) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %{
      clip_id: clip_id,
      artifact_type: artifact_type,
      s3_key: Map.fetch!(artifact_data, :s3_key),
      metadata: Map.get(artifact_data, :metadata, %{}),
      inserted_at: now,
      updated_at: now
    }
  end
end
