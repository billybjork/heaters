defmodule Heaters.Clips.Operations.Shared.ResultBuilding do
  @moduledoc """
  Pure result building functions for domain operations.

  This module contains pure business logic for constructing the structured
  result types (SpriteResult, KeyframeResult, etc.) used by transform operations.
  No side effects or I/O operations.
  """

  alias Heaters.Clips.Operations.Shared.Types

  @doc """
  Build a successful SpriteResult from upload data and sprite specifications.

  ## Examples

      iex> upload_data = %{s3_key: "sprites/sprite.jpg", metadata: %{file_size: 1024}}
      iex> sprite_spec = %{grid_dimensions: "5x10", effective_fps: 24}
      iex> result = ResultBuilding.build_sprite_result(123, upload_data, sprite_spec)
      iex> result.status
      "success"
      iex> result.clip_id
      123
  """
  @spec build_sprite_result(integer(), map(), map()) :: Types.SpriteResult.t()
  def build_sprite_result(clip_id, upload_data, sprite_spec) do
    %Types.SpriteResult{
      status: "success",
      clip_id: clip_id,
      artifacts: [
        %{
          artifact_type: "sprite_sheet",
          s3_key: upload_data.s3_key,
          metadata: upload_data.metadata
        }
      ],
      metadata: %{
        sprite_generated: true,
        grid_dimensions: Map.get(sprite_spec, :grid_dimensions),
        effective_fps: Map.get(sprite_spec, :effective_fps),
        num_frames: Map.get(sprite_spec, :num_frames),
        tile_dimensions:
          "#{Map.get(sprite_spec, :tile_width)}x#{Map.get(sprite_spec, :tile_height)}"
      },
      duration_ms: nil,
      processed_at: DateTime.utc_now()
    }
  end

  @doc """
  Build a failed SpriteResult from error information.
  """
  @spec build_sprite_error_result(integer(), String.t()) :: Types.SpriteResult.t()
  def build_sprite_error_result(clip_id, error_message) do
    %Types.SpriteResult{
      status: "error",
      clip_id: clip_id,
      artifacts: [],
      metadata: %{
        sprite_generated: false,
        error_message: error_message
      },
      duration_ms: nil,
      processed_at: DateTime.utc_now()
    }
  end

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

  @doc """
  Build a successful SplitResult from operation data.
  """
  @spec build_split_result(integer(), list(integer()), list(map())) :: Types.SplitResult.t()
  def build_split_result(original_clip_id, new_clip_ids, created_clips) do
    %Types.SplitResult{
      status: "success",
      original_clip_id: original_clip_id,
      new_clip_ids: new_clip_ids,
      created_clips: created_clips,
      metadata: %{
        split_completed: true,
        split_count: length(new_clip_ids)
      },
      duration_ms: nil,
      processed_at: DateTime.utc_now()
    }
  end

  @spec build_split_result_with_details(
          integer(),
          list(integer()),
          list(map()),
          map(),
          map(),
          integer()
        ) :: Types.SplitResult.t()
  def build_split_result_with_details(
        original_clip_id,
        new_clip_ids,
        created_clips,
        cleanup_result,
        split_metadata,
        duration_ms
      ) do
    %Types.SplitResult{
      status: "success",
      original_clip_id: original_clip_id,
      new_clip_ids: new_clip_ids,
      created_clips: created_clips,
      cleanup: cleanup_result,
      metadata: split_metadata,
      duration_ms: duration_ms,
      processed_at: DateTime.utc_now()
    }
  end

  @doc """
  Build a successful MergeResult from operation data.
  """
  @spec build_merge_result(integer(), list(integer()), map(), map()) :: Types.MergeResult.t()
  def build_merge_result(merged_clip_id, source_clip_ids, cleanup_result, metadata) do
    %Types.MergeResult{
      status: "success",
      merged_clip_id: merged_clip_id,
      source_clip_ids: source_clip_ids,
      cleanup: cleanup_result,
      metadata: metadata,
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
  Add timing information to any result struct.

  ## Examples

      iex> result = %Types.SpriteResult{duration_ms: nil}
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
