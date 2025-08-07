defmodule Heaters.Processing.Keyframe.Core do
  @moduledoc """
  Keyframe extraction operations - I/O orchestration layer.

  Orchestrates keyframe extraction via Elixir FFmpeg integration, managing
  workflow state transitions and artifact creation for embedding generation.

  Uses domain modules for business logic and infrastructure adapters for I/O operations.
  Follows "I/O at the edges" architecture pattern.
  """

  require Logger

  # TODO: Restore aliases when keyframes functionality is rewritten
  # alias Heaters.Media.Artifacts
  # alias Heaters.Media.Support.{Types, ErrorFormatting}
  # alias Heaters.Processing.Keyframe.{Strategy, Validation}
  # alias Heaters.Media.Clips
  # alias Heaters.Processing.Render.FFmpegAdapter
  # alias Heaters.Storage.S3
  # alias Heaters.Storage.PipelineCache.TempCache

  @doc """
  Runs keyframe extraction workflow for the specified clip.

  ## Parameters
  - `clip_id`: ID of the clip to process
  - `strategy`: Keyframe strategy (:midpoint or :multi)

  ## Returns
  - `{:ok, Types.KeyframeResult.t()}` on success
  - `{:error, String.t()}` on failure
  """
  @spec run_keyframe_extraction(integer(), atom()) :: {:error, String.t()}
  def run_keyframe_extraction(clip_id, _strategy \\ :multi) do
    Logger.info("Keyframe: Core functionality disabled - returning error for clip #{clip_id}")
    {:error, "Keyframes functionality disabled - needs rewrite for cuts-based architecture"}
  end

  ## Private Implementation - DISABLED
  ## TODO: All keyframes functionality needs to be rewritten for cuts-based architecture
  ## All private functions have been removed to eliminate dialyzer warnings until rewrite
end
