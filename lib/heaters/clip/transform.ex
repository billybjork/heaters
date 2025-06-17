defmodule Heaters.Clip.Transform do
  @moduledoc """
  Context for managing clip transformation operations including keyframing, sprite generation,
  and artifact management. This module handles all state management that was previously done in Python.
  """

  alias Heaters.Repo
  alias Heaters.Clips.Clip
  alias Heaters.Clip.Queries, as: ClipQueries
  alias Heaters.Clip.Transform.ClipArtifact
  require Logger

  # State transition functions for clip transformation workflow

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
  Create keyframe artifacts from processing results.
  """
  @spec create_keyframe_artifacts(integer(), list(map())) :: {:ok, list(ClipArtifact.t())} | {:error, any()}
  def create_keyframe_artifacts(clip_id, artifacts_data) when is_list(artifacts_data) do
    Logger.info("Creating #{length(artifacts_data)} keyframe artifacts for clip_id: #{clip_id}")

    artifacts_attrs =
      artifacts_data
      |> Enum.map(fn artifact_data ->
        build_keyframe_artifact_attrs(clip_id, artifact_data)
      end)

    case Repo.insert_all(ClipArtifact, artifacts_attrs, returning: true) do
      {count, artifacts} when count > 0 ->
        Logger.info("Successfully created #{count} keyframe artifacts for clip_id: #{clip_id}")
        {:ok, artifacts}

      {0, _} ->
        Logger.error("Failed to create keyframe artifacts for clip_id: #{clip_id}")
        {:error, "No artifacts were created"}
    end
  rescue
    e ->
      Logger.error("Error creating keyframe artifacts for clip_id #{clip_id}: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @doc """
  Transition a clip from review_approved to keyframing state.
  """
  @spec start_keyframing_from_approved(integer()) :: {:ok, Clip.t()} | {:error, any()}
  def start_keyframing_from_approved(clip_id) do
    with {:ok, clip} <- ClipQueries.get_clip(clip_id),
         :ok <- validate_state_transition(clip.ingest_state, "keyframing") do
      update_clip(clip, %{
        ingest_state: "keyframing",
        last_error: nil
      })
    end
  end

  @doc """
  Mark a clip transformation as failed.
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
  Build S3 prefix for keyframe outputs.
  """
  @spec build_keyframe_prefix(Clip.t()) :: String.t()
  def build_keyframe_prefix(%Clip{id: id, source_video_id: source_video_id}) do
    "source_videos/#{source_video_id}/clips/#{id}/keyframes"
  end



  @doc """
  Process successful keyframe results from Python task.
  """
  @spec process_keyframe_success(Clip.t(), map()) :: {:ok, Clip.t()} | {:error, any()}
  def process_keyframe_success(%Clip{} = clip, result) do
    Repo.transaction(fn ->
      with {:ok, updated_clip} <- complete_keyframing(clip.id),
           {:ok, _artifacts} <- create_keyframe_artifacts(clip.id, Map.get(result, "artifacts", [])) do
        updated_clip
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end



  # Private helper functions

  defp update_clip(%Clip{} = clip, attrs) do
    clip
    |> Clip.changeset(attrs)
    |> Repo.update()
  end

  defp validate_state_transition(current_state, target_state) do
    case {current_state, target_state} do
      # Valid transitions for keyframing (now from approved clips)
      {"review_approved", "keyframing"} -> :ok
      {"keyframing_failed", "keyframing"} -> :ok
      {"keyframe_failed", "keyframing"} -> :ok

      # Invalid transitions
      _ ->
        Logger.warning("Invalid state transition from '#{current_state}' to '#{target_state}'")
        {:error, :invalid_state_transition}
    end
  end

  defp build_keyframe_artifact_attrs(clip_id, artifact_data) do
    now = DateTime.utc_now()

    %{
      clip_id: clip_id,
      artifact_type: Map.get(artifact_data, :artifact_type, "keyframe"),
      s3_key: Map.fetch!(artifact_data, :s3_key),
      metadata: Map.get(artifact_data, :metadata, %{}),
      inserted_at: now,
      updated_at: now
    }
  end



  defp format_error_message(error_reason) when is_binary(error_reason), do: error_reason
  defp format_error_message(error_reason), do: inspect(error_reason)
end
