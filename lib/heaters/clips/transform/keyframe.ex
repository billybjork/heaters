defmodule Heaters.Clips.Transform.Keyframe do
  @moduledoc """
  Keyframe extraction operations - pure business logic.

  Orchestrates keyframe extraction via Python OpenCV integration, managing
  workflow state transitions and artifact creation for embedding generation.

  Uses shared infrastructure modules for artifact management and result structures.
  """

  require Logger

  alias Heaters.Repo
  alias Heaters.Clips.Clip
  alias Heaters.Clips.Queries, as: ClipQueries
  alias Heaters.Clips.Transform
  alias Heaters.Clips.Transform.Shared.Types
  alias Heaters.Infrastructure.PyRunner

  @doc """
  Runs keyframe extraction workflow for the specified clip.

  ## Parameters
  - `clip_id`: The ID of the clip to extract keyframes from
  - `strategy`: Keyframe extraction strategy ("midpoint" or "multi")

  ## Returns
  - `{:ok, KeyframeResult.t()}` on success
  - `{:error, reason}` on failure
  """
  @spec run_keyframe_extraction(integer(), String.t()) ::
          {:ok, Types.KeyframeResult.t()} | {:error, any()}
  def run_keyframe_extraction(clip_id, strategy \\ "multi") do
    Logger.info(
      "Keyframe: Starting keyframe extraction for clip_id: #{clip_id}, strategy: #{strategy}"
    )

    with {:ok, _clip} <- ClipQueries.get_clip_with_artifacts(clip_id),
         {:ok, updated_clip} <- start_keyframing(clip_id) do
      # Python task receives explicit S3 paths and keyframe parameters
      py_args = %{
        clip_id: updated_clip.id,
        input_s3_path: String.trim_leading(updated_clip.clip_filepath, "/"),
        output_s3_prefix: Transform.build_artifact_prefix(updated_clip, "keyframes"),
        keyframe_params: %{
          strategy: strategy,
          count: if(strategy == "multi", do: 3, else: 1)
        }
      }

      case PyRunner.run("keyframe", py_args) do
        {:ok, result} ->
          Logger.info("Keyframe: Python extraction succeeded for clip_id: #{clip_id}")
          process_keyframe_success(updated_clip, result, strategy)

        {:error, reason} ->
          Logger.error(
            "Keyframe: Python extraction failed for clip_id: #{clip_id}, reason: #{inspect(reason)}"
          )

          Transform.mark_failed(updated_clip.id, "keyframe_failed", reason)
      end
    end
  end

  @doc """
  Transitions a clip to "keyframing" state.
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
  Marks a clip as successfully keyframed.
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
  Checks if a clip already has keyframe artifacts to avoid duplicate work.
  """
  @spec has_keyframe_artifacts?(Clip.t()) :: boolean()
  def has_keyframe_artifacts?(%Clip{clip_artifacts: artifacts}) when is_list(artifacts) do
    Enum.any?(artifacts, &(&1.artifact_type == "keyframe"))
  end

  def has_keyframe_artifacts?(_clip), do: false

  @doc """
  Checks if a clip is ready for keyframe extraction.
  """
  @spec ready_for_keyframing?(Clip.t()) :: boolean()
  def ready_for_keyframing?(%Clip{ingest_state: state}) do
    state in ["review_approved", "keyframe_failed"]
  end

  ## Private functions implementing keyframe-specific business logic

  @spec process_keyframe_success(Clip.t(), map(), String.t()) ::
          {:ok, Types.KeyframeResult.t()} | {:error, any()}
  defp process_keyframe_success(%Clip{} = clip, result, strategy) do
    start_time = System.monotonic_time()

    case Repo.transaction(fn ->
           with {:ok, updated_clip} <- complete_keyframing(clip.id),
                {:ok, artifacts} <-
                  Transform.create_artifacts(
                    clip.id,
                    "keyframe",
                    Map.get(result, "artifacts", [])
                  ) do
             Logger.info(
               "Keyframe: Successfully completed keyframe extraction for clip_id: #{clip.id}"
             )

             {updated_clip, artifacts}
           else
             {:error, reason} ->
               Logger.error(
                 "Keyframe: Failed to process keyframe success for clip_id: #{clip.id}, reason: #{inspect(reason)}"
               )

               Repo.rollback(reason)
           end
         end) do
      {:ok, {_updated_clip, artifacts}} ->
        duration_ms =
          System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

        keyframe_result = %Types.KeyframeResult{
          status: "success",
          clip_id: clip.id,
          artifacts:
            Enum.map(artifacts, fn artifact ->
              %{
                artifact_type: artifact.artifact_type,
                s3_key: artifact.s3_key,
                metadata: artifact.metadata
              }
            end),
          keyframe_count: length(artifacts),
          strategy: strategy,
          metadata: Map.get(result, "metadata", %{}),
          duration_ms: duration_ms,
          processed_at: DateTime.utc_now()
        }

        {:ok, keyframe_result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_clip(%Clip{} = clip, attrs) do
    clip
    |> Clip.changeset(attrs)
    |> Repo.update()
  end

  defp validate_state_transition(current_state, target_state) do
    case {current_state, target_state} do
      # Valid transitions for keyframing (from approved clips)
      {"review_approved", "keyframing"} ->
        :ok

      {"keyframing_failed", "keyframing"} ->
        :ok

      {"keyframe_failed", "keyframing"} ->
        :ok

      # Invalid transitions
      _ ->
        Logger.warning(
          "Keyframe: Invalid state transition from '#{current_state}' to '#{target_state}'"
        )

        {:error, :invalid_state_transition}
    end
  end
end
