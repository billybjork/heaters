defmodule Heaters.Videos do
  @moduledoc """
  Main context for video operations and lifecycle management.

  This module serves as the primary entry point for all video-related operations,
  providing a clean public API while delegating to specialized sub-modules.

  ## Sub-contexts

  - **Intake**: Video submission and initial processing (`Heaters.Videos.Intake`)
  - **Ingest**: Video ingestion workflow management (`Heaters.Videos.Ingest`)

  ## Schema

  - **SourceVideo**: The main source video schema (`Heaters.Videos.SourceVideo`)

  ## Examples

      # Intake operations
      Videos.submit("https://example.com/video.mp4")
      Videos.update_source_video(source_video, %{title: "New Title"})

      # Ingest operations
      Videos.start_download(source_video_id)
      Videos.complete_download(source_video_id, download_data)
  """

  # Delegated functions for common operations
  alias Heaters.Videos.Intake

  # Intake operations
  defdelegate submit(url), to: Intake
  defdelegate update_source_video(source_video, attrs), to: Intake

  # Query operations (if any exist in queries.ex)
  # Note: We'll need to check what functions exist in videos/queries.ex
end
