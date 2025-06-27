defmodule Heaters.Clips.Operations.Artifacts.Keyframe do
  @moduledoc """
  Keyframe extraction operations - I/O orchestration layer.

  Orchestrates keyframe extraction via Python OpenCV integration, managing
  workflow state transitions and artifact creation for embedding generation.

  Uses domain modules for business logic and infrastructure adapters for I/O operations.
  """

  require Logger

  alias Heaters.Repo
  alias Heaters.Clips.Clip
  alias Heaters.Clips.Operations
  alias Heaters.Clips.Operations.Shared.Types

  # Domain modules (pure business logic)
  alias Heaters.Clips.Operations.Artifacts.Keyframe.{Strategy, Validation, PythonArgs}
  alias Heaters.Clips.Operations.Shared.{ResultBuilding, ErrorFormatting}

  # Infrastructure adapters (I/O operations)
  alias Heaters.Infrastructure.Adapters.{DatabaseAdapter, PyRunnerAdapter}

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
    start_time = System.monotonic_time()

    Logger.info(
      "Keyframe: Starting keyframe extraction for clip_id: #{clip_id}, strategy: #{strategy}"
    )

    with {:ok, clip} <- fetch_clip_data(clip_id),
         {:ok, strategy_config} <- configure_extraction_strategy(strategy),
         :ok <- validate_keyframe_requirements(clip, strategy),
         {:ok, updated_clip} <- transition_to_keyframing(clip),
         artifact_prefix <- build_artifact_prefix(updated_clip),
         python_args <- build_python_arguments(updated_clip, artifact_prefix, strategy_config),
         {:ok, python_result} <- execute_keyframe_extraction(python_args),
         {:ok, final_result} <-
           process_extraction_success(updated_clip, python_result, strategy, start_time) do
      Logger.info("Keyframe: Successfully completed keyframe extraction for clip_id: #{clip_id}")
      {:ok, final_result}
    else
      {:error, reason} ->
        Logger.error(
          "Keyframe: Failed keyframe extraction for clip_id: #{clip_id}, reason: #{inspect(reason)}"
        )

        error_message = ErrorFormatting.format_domain_error(:keyframe_extraction_failed, reason)
        Operations.mark_failed(clip_id, "keyframe_failed", error_message)
    end
  end

  @doc """
  Transitions a clip to "keyframing" state.
  """
  @spec start_keyframing(integer()) :: {:ok, Clip.t()} | {:error, any()}
  def start_keyframing(clip_id) do
    with {:ok, clip} <- DatabaseAdapter.get_clip(clip_id),
         :ok <- validate_state_transition(clip.ingest_state, "keyframing") do
      DatabaseAdapter.update_clip(clip, %{
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
    with {:ok, clip} <- DatabaseAdapter.get_clip(clip_id) do
      DatabaseAdapter.update_clip(clip, %{
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

  ## Private functions - I/O orchestration using Domain and Infrastructure layers

  @spec fetch_clip_data(integer()) :: {:ok, Clip.t()} | {:error, any()}
  defp fetch_clip_data(clip_id) do
    DatabaseAdapter.get_clip_with_artifacts(clip_id)
  end

  @spec configure_extraction_strategy(String.t()) ::
          {:ok, Strategy.strategy_config()} | {:error, String.t()}
  defp configure_extraction_strategy(strategy) do
    Strategy.configure_strategy(strategy)
  end

  @spec validate_keyframe_requirements(Clip.t(), String.t()) :: :ok | {:error, String.t()}
  defp validate_keyframe_requirements(clip, strategy) do
    Validation.validate_keyframe_requirements(clip, strategy)
  end

  @spec transition_to_keyframing(Clip.t()) :: {:ok, Clip.t()} | {:error, any()}
  defp transition_to_keyframing(%Clip{id: clip_id}) do
    start_keyframing(clip_id)
  end

  @spec build_artifact_prefix(Clip.t()) :: String.t()
  defp build_artifact_prefix(clip) do
    Operations.build_artifact_prefix(clip, "keyframes")
  end

  @spec build_python_arguments(Clip.t(), String.t(), Strategy.strategy_config()) ::
          PythonArgs.python_args()
  defp build_python_arguments(clip, artifact_prefix, strategy_config) do
    PythonArgs.build_python_args(clip, artifact_prefix, strategy_config)
  end

  @spec execute_keyframe_extraction(PythonArgs.python_args()) ::
          {:ok, map()} | {:error, String.t()}
  defp execute_keyframe_extraction(python_args) do
    PyRunnerAdapter.run_keyframe_extraction(python_args)
  end

  @spec process_extraction_success(Clip.t(), map(), String.t(), integer()) ::
          {:ok, Types.KeyframeResult.t()} | {:error, any()}
  defp process_extraction_success(clip, python_result, strategy, start_time) do
    case Repo.transaction(fn ->
           with {:ok, updated_clip} <- complete_keyframing(clip.id),
                {:ok, artifacts} <-
                  Operations.create_artifacts(
                    clip.id,
                    "keyframe",
                    Map.get(python_result, "artifacts", [])
                  ) do
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
        duration_ms = calculate_duration(start_time)

        result = build_success_result(clip.id, artifacts, python_result, strategy, duration_ms)
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec build_success_result(integer(), list(), map(), String.t(), integer()) ::
          Types.KeyframeResult.t()
  defp build_success_result(clip_id, artifacts, python_result, strategy, duration_ms) do
    formatted_artifacts =
      Enum.map(artifacts, fn artifact ->
        %{
          artifact_type: artifact.artifact_type,
          s3_key: artifact.s3_key,
          metadata: artifact.metadata
        }
      end)

    metadata = Map.get(python_result, "metadata", %{})

    ResultBuilding.build_keyframe_result(
      clip_id,
      formatted_artifacts,
      strategy,
      metadata,
      duration_ms
    )
  end

  @spec calculate_duration(integer()) :: integer()
  defp calculate_duration(start_time) do
    System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)
  end

  @spec validate_state_transition(String.t(), String.t()) :: :ok | {:error, atom()}
  defp validate_state_transition(current_state, target_state) do
    case Validation.validate_keyframe_state_transition(current_state, target_state) do
      :ok ->
        :ok

      {:error, :invalid_state_transition} ->
        Logger.warning(
          "Keyframe: Invalid state transition from '#{current_state}' to '#{target_state}'"
        )

        {:error, :invalid_state_transition}
    end
  end
end
