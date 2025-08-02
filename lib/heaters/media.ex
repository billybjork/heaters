defmodule Heaters.Media do
  @moduledoc """
  COMPATIBILITY LAYER: This module provides compatibility functions for Media operations.

  This compatibility layer delegates calls to the appropriate modules in the Media namespace.
  Please update your code to use the specific modules directly.
  """

  alias Heaters.Media.Queries.Clip, as: ClipQueries
  alias Heaters.Media.Queries.Video, as: VideoQueries
  alias Heaters.Media.Commands.Clip, as: ClipCommands

  # Clip queries
  defdelegate get_clip(clip_id), to: ClipQueries
  defdelegate get_clip_with_artifacts(clip_id), to: ClipQueries
  defdelegate get_clip!(id), to: ClipQueries
  defdelegate change_clip(clip, attrs), to: ClipCommands
  defdelegate update_clip(clip, attrs), to: ClipCommands
  defdelegate pending_review_count(), to: ClipQueries
  defdelegate get_clips_by_state(state), to: ClipQueries

  # Video queries
  defdelegate get_source_video(id), to: VideoQueries
end
