defmodule Heaters.Clips.Operations.Shared.ResultBuilding do
  @moduledoc """
  Pure result building functions for domain operations.

  This module contains pure business logic for constructing the structured
  result types (KeyframeResult, etc.) used by keyframe extraction and other clip operations.
  No side effects or I/O operations.
  """

  alias Heaters.Clips.Operations.Shared.Types

  @doc """
  Build a successful KeyframeResult from artifacts and strategy plan.

  ## Examples

      iex> artifacts = [%{s3_key: "keyframes/frame1.jpg"}, %{s3_key: "keyframes/frame2.jpg"}]
      iex> strategy_plan = %{strategy: "multi", positions: [100, 200]}
      iex> result = ResultBuilding.build_keyframe_result(123, artifacts, strategy_plan)
      iex> result.keyframe_count
      2
  """
  @spec build_keyframe_result(integer(), list(), String.t(), map(), integer()) ::
          Types.KeyframeResult.t()
  def build_keyframe_result(clip_id, artifacts, strategy, metadata, duration_ms) do
    %Types.KeyframeResult{
      status: "success",
      clip_id: clip_id,
      artifacts: artifacts,
      keyframe_count: length(artifacts),
      strategy: strategy,
      metadata: metadata,
      duration_ms: duration_ms,
      processed_at: DateTime.utc_now()
    }
  end

  @spec build_keyframe_result_from_python_output(integer(), map(), String.t(), integer()) ::
          Types.KeyframeResult.t()
  def build_keyframe_result_from_python_output(clip_id, python_result, strategy, duration_ms) do
    artifacts =
      python_result
      |> Map.get("artifacts", [])
      |> Enum.map(fn artifact ->
        %{
          artifact_type: "keyframe",
          s3_key: Map.get(artifact, "s3_key"),
          metadata: Map.get(artifact, "metadata", %{})
        }
      end)

    metadata = Map.get(python_result, "metadata", %{})

    build_keyframe_result(clip_id, artifacts, strategy, metadata, duration_ms)
  end

  @doc """
  Build a failed KeyframeResult from error information.
  """
  @spec build_keyframe_error_result(integer(), String.t(), String.t()) :: Types.KeyframeResult.t()
  def build_keyframe_error_result(clip_id, strategy, error_message) do
    %Types.KeyframeResult{
      status: "error",
      clip_id: clip_id,
      artifacts: [],
      keyframe_count: 0,
      strategy: strategy,
      metadata: %{
        extraction_completed: false,
        error_message: error_message
      },
      duration_ms: nil,
      processed_at: DateTime.utc_now()
    }
  end

  @spec build_error_result(String.t(), integer(), String.t(), any()) :: map()
  def build_error_result(operation, clip_id, error_reason, details \\ nil) do
    %{
      status: "error",
      operation: operation,
      clip_id: clip_id,
      error: error_reason,
      details: details,
      processed_at: DateTime.utc_now()
    }
  end

  @doc """
  Build a simple success result with status and metadata.

  Useful for operations that don't need full result structs.
  """
  @spec build_success_result(map()) :: map()
  def build_success_result(metadata \\ %{}) do
    %{
      status: "success",
      processed_at: DateTime.utc_now()
    }
    |> Map.merge(metadata)
  end

  @doc """
  Add timing information to any result struct.

  ## Examples

      iex> result = %Types.KeyframeResult{status: "success", clip_id: 123, artifacts: [], keyframe_count: 0, strategy: "multi"}
      iex> updated_result = ResultBuilding.add_timing(result, 1500)
      iex> updated_result.duration_ms
      1500
  """
  @spec add_timing(struct(), integer()) :: struct()
  def add_timing(result, duration_ms) when is_integer(duration_ms) do
    Map.put(result, :duration_ms, duration_ms)
  end

  @doc """
  Update result metadata with additional information.
  """
  @spec update_metadata(struct(), map()) :: struct()
  def update_metadata(result, additional_metadata) when is_map(additional_metadata) do
    updated_metadata = Map.merge(result.metadata || %{}, additional_metadata)
    Map.put(result, :metadata, updated_metadata)
  end
end
