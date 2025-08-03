defmodule Heaters.Media do
  @moduledoc """
  COMPATIBILITY LAYER: This module provides compatibility functions for Media operations.

  This compatibility layer delegates calls to the appropriate modules in the Media namespace.
  Please update your code to use the specific modules directly:

  - Use `Heaters.Media.Clips` for all clip operations
  - Use `Heaters.Media.Videos` for all video operations
  """

  alias Heaters.Media.Clips
  alias Heaters.Media.Videos

  # Clip operations
  defdelegate get_clip(clip_id), to: Clips
  defdelegate get_clip_with_artifacts(clip_id), to: Clips
  defdelegate get_clip!(id), to: Clips
  defdelegate change_clip(clip, attrs), to: Clips
  defdelegate update_clip(clip, attrs), to: Clips
  defdelegate pending_review_count(), to: Clips
  defdelegate get_clips_by_state(state), to: Clips

  # Video operations
  defdelegate get_source_video(id), to: Videos
end
