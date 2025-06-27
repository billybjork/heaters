defmodule Heaters.SourceVideos do
  @moduledoc """
  Main context for source video operations and lifecycle management.

  This module serves as the primary entry point for all source video-related operations,
  providing a clean public API while delegating to specialized sub-modules.

  ## Sub-contexts

  - **Intake**: Source video submission and initial processing (`Heaters.SourceVideos.Intake`)
  - **Ingest**: Source video ingestion workflow management (`Heaters.SourceVideos.Ingest`)

  ## Schema

  - **SourceVideo**: The main source video schema (`Heaters.SourceVideos.SourceVideo`)

  ## Examples

      # Intake operations
      SourceVideos.submit("https://example.com/video.mp4")
      SourceVideos.update_source_video(source_video, %{title: "New Title"})

      # Ingest operations
      SourceVideos.start_download(source_video_id)
      SourceVideos.complete_download(source_video_id, download_data)
  """

  # Delegated functions for common operations
  alias Heaters.SourceVideos.Intake

  # Intake operations
  defdelegate submit(url), to: Intake
  defdelegate update_source_video(source_video, attrs), to: Intake

  # Query operations
  alias Heaters.SourceVideos.Queries

  defdelegate get_source_video(id), to: Queries
  defdelegate get_videos_by_state(state), to: Queries
end
