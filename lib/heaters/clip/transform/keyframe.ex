defmodule Heaters.Clip.Transform.Keyframe do
  @moduledoc """
  Context for keyframe extraction operations.

  This module handles keyframe extraction workflows, including:
  - State transitions for keyframing workflow
  - Keyframe artifact creation and management
  - Integration with Python keyframe extraction task
  - Error handling and retry logic
  """

  alias Heaters.Repo
  alias Heaters.Clips.Clip
  alias Heaters.Clip.Queries, as: ClipQueries
  alias Heaters.Clip.Transform.ClipArtifact
  alias Heaters.Infrastructure.PyRunner
  require Logger

  @doc """
  Main entry point for keyframe extraction workflow.

  This orchestrates the complete keyframe extraction process:
  1. Validates clip state and transitions to "keyframing"
  2. Calls Python keyframe extraction script
  3. Processes results and creates artifacts
  4. Handles errors and state transitions

  Args:
    clip_id: The ID of the clip to extract keyframes from
    strategy: Keyframe extraction strategy ("midpoint" or "multi")

  Returns:
    {:ok, clip} on success
    {:error, reason} on failure
  """
  @spec run_keyframe_extraction(integer(), String.t()) :: {:ok, Clip.t()} | {:error, any()}
  def run_keyframe_extraction(clip_id, strategy \\ "multi") do
    Logger.info("Keyframe: Starting keyframe extraction for clip_id: #{clip_id}, strategy: #{strategy}")

    with {:ok, _clip} <- ClipQueries.get_clip_with_artifacts(clip_id),
         {:ok, updated_clip} <- start_keyframing(clip_id) do

      # Python task receives explicit S3 paths and keyframe parameters
      py_args = %{
        clip_id: updated_clip.id,
        input_s3_path: String.trim_leading(updated_clip.clip_filepath, "/"),
        output_s3_prefix: build_keyframe_prefix(updated_clip),
        keyframe_params: %{
          strategy: strategy,
          count: if(strategy == "multi", do: 3, else: 1)
        }
      }

      case PyRunner.run("keyframe", py_args) do
        {:ok, result} ->
          Logger.info("Keyframe: Python extraction succeeded for clip_id: #{clip_id}")
          process_keyframe_success(updated_clip, result)

        {:error, reason} ->
          Logger.error("Keyframe: Python extraction failed for clip_id: #{clip_id}, reason: #{inspect(reason)}")
          mark_keyframe_failed(updated_clip.id, reason)
      end
    end
  end

  @doc """
  Transition a clip to "keyframing" state.
  """
  @spec start_keyframing(integer()) :: {:ok, Clip.t()} | {:error, any()}
  def start_keyframing(clip_id) do
    with {:ok, clip} <- ClipQueries.get_clip(clip_id),
         :ok <- validate_state_transition(clip.ingest_state, "keyframing") do
      update_clip(clip, %{
        ingest_state: "keyframing",
        last_error: nil
      })
    end
  end

  @doc """
  Mark a clip as successfully keyframed and create keyframe artifacts.
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
  Mark a clip as failed during keyframe extraction.
  """
  @spec mark_keyframe_failed(integer(), any()) :: {:ok, Clip.t()} | {:error, any()}
  def mark_keyframe_failed(clip_id, error_reason) do
    error_message = format_error_message(error_reason)

    with {:ok, clip} <- ClipQueries.get_clip(clip_id) do
      update_clip(clip, %{
        ingest_state: "keyframe_failed",
        last_error: error_message,
        retry_count: (clip.retry_count || 0) + 1
      })
    end
  end

  @doc """
  Create keyframe artifacts from processing results.
  """
  @spec create_keyframe_artifacts(integer(), list(map())) :: {:ok, list(ClipArtifact.t())} | {:error, any()}
  def create_keyframe_artifacts(clip_id, artifacts_data) when is_list(artifacts_data) do
    Logger.info("Keyframe: Creating #{length(artifacts_data)} keyframe artifacts for clip_id: #{clip_id}")

    artifacts_attrs =
      artifacts_data
      |> Enum.map(fn artifact_data ->
        build_keyframe_artifact_attrs(clip_id, artifact_data)
      end)

    case Repo.insert_all(ClipArtifact, artifacts_attrs, returning: true) do
      {count, artifacts} when count > 0 ->
        Logger.info("Keyframe: Successfully created #{count} keyframe artifacts for clip_id: #{clip_id}")
        {:ok, artifacts}

      {0, _} ->
        Logger.error("Keyframe: Failed to create keyframe artifacts for clip_id: #{clip_id}")
        {:error, "No artifacts were created"}
    end
  rescue
    e ->
      Logger.error("Keyframe: Error creating keyframe artifacts for clip_id #{clip_id}: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @doc """
  Process successful keyframe results from Python task.
  """
  @spec process_keyframe_success(Clip.t(), map()) :: {:ok, Clip.t()} | {:error, any()}
  def process_keyframe_success(%Clip{} = clip, result) do
    Repo.transaction(fn ->
      with {:ok, updated_clip} <- complete_keyframing(clip.id),
           {:ok, _artifacts} <- create_keyframe_artifacts(clip.id, Map.get(result, "artifacts", [])) do
        Logger.info("Keyframe: Successfully completed keyframe extraction for clip_id: #{clip.id}")
        updated_clip
      else
        {:error, reason} ->
          Logger.error("Keyframe: Failed to process keyframe success for clip_id: #{clip.id}, reason: #{inspect(reason)}")
          Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Build S3 prefix for keyframe outputs.
  """
  @spec build_keyframe_prefix(Clip.t()) :: String.t()
  def build_keyframe_prefix(%Clip{id: id, source_video_id: source_video_id}) do
    "source_videos/#{source_video_id}/clips/#{id}/keyframes"
  end

  @doc """
  Check if a clip already has keyframe artifacts to avoid duplicate work.
  """
  @spec has_keyframe_artifacts?(Clip.t()) :: boolean()
  def has_keyframe_artifacts?(%Clip{clip_artifacts: artifacts}) when is_list(artifacts) do
    Enum.any?(artifacts, &(&1.artifact_type == "keyframe"))
  end
  def has_keyframe_artifacts?(_clip), do: false

  @doc """
  Check if a clip is ready for keyframe extraction.
  """
  @spec ready_for_keyframing?(Clip.t()) :: boolean()
  def ready_for_keyframing?(%Clip{ingest_state: state}) do
    state in ["review_approved", "keyframe_failed"]
  end

  # Private helper functions

  defp update_clip(%Clip{} = clip, attrs) do
    clip
    |> Clip.changeset(attrs)
    |> Repo.update()
  end

  defp validate_state_transition(current_state, target_state) do
    case {current_state, target_state} do
      # Valid transitions for keyframing (from approved clips)
      {"review_approved", "keyframing"} -> :ok
      {"keyframing_failed", "keyframing"} -> :ok
      {"keyframe_failed", "keyframing"} -> :ok

      # Invalid transitions
      _ ->
        Logger.warning("Keyframe: Invalid state transition from '#{current_state}' to '#{target_state}'")
        {:error, :invalid_state_transition}
    end
  end

  defp build_keyframe_artifact_attrs(clip_id, artifact_data) do
    now = DateTime.utc_now()

    %{
      clip_id: clip_id,
      artifact_type: Map.get(artifact_data, "artifact_type", "keyframe"),
      s3_key: Map.fetch!(artifact_data, "s3_key"),
      metadata: Map.get(artifact_data, "metadata", %{}),
      inserted_at: now,
      updated_at: now
    }
  end

  defp format_error_message(error_reason) when is_binary(error_reason), do: error_reason
  defp format_error_message(error_reason), do: inspect(error_reason)
end
