defmodule Heaters.Videos do
  @moduledoc """
  Main context for video operations and lifecycle management.

  This module serves as the primary entry point for all video-related operations,
  providing a clean public API while delegating to specialized sub-modules.

  ## Sub-contexts

  - **Submit**: Video submission and initial processing (`Heaters.Videos.Submit`)
  - **Download**: Video download workflow management (`Heaters.Videos.Operations.Download`)

  ## Schema

  - **SourceVideo**: The main source video schema (`Heaters.Videos.SourceVideo`)

  ## Examples

      # Submit operations
      Videos.submit("https://example.com/video.mp4")
      Videos.update_source_video(source_video, %{title: "New Title"})

      # Ingest operations
      Videos.start_download(source_video_id)
      Videos.complete_download(source_video_id, download_data)
  """

  # Delegated functions for common operations
  alias Heaters.Videos.Submit

  # Submit operations
  defdelegate submit(url), to: Submit
  defdelegate update_source_video(source_video, attrs), to: Submit

  # Query operations
  alias Heaters.Videos.Queries

  defdelegate get_source_video(id), to: Queries
  defdelegate get_videos_by_state(state), to: Queries
end
