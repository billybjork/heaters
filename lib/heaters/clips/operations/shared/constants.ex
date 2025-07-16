defmodule Heaters.Clips.Operations.Shared.Constants do
  @moduledoc """
  Centralized constants for clip operations to avoid duplication.

  This module defines system-wide constants used across different clip operations
  to ensure consistency and make configuration changes easier.
  """

  @doc """
  Minimum clip duration in seconds for processing operations.

  This applies to:
  - Split operation validation (minimum viable segment length)
  - Sprite generation validation (minimum duration for sprite creation)
  - Other clip processing operations that require minimum duration

  Note: Scene detection for splice operations may use different thresholds
  as they serve a different purpose (automatic video segmentation).
  """
  @min_clip_duration_seconds 0.1

  @spec min_clip_duration_seconds() :: float()
  def min_clip_duration_seconds, do: @min_clip_duration_seconds
end
