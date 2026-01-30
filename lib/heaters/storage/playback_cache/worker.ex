defmodule Heaters.Storage.PlaybackCache.Worker do
  @moduledoc """
  Background job for generating temporary clip files asynchronously.

  This prevents LiveView blocking during FFmpeg processing and provides
  a better user experience with loading states and instant UI responses.

  ## Features

  - **Oban Uniqueness**: Uses 60-second uniqueness constraints to prevent duplicate jobs
  - **PubSub Integration**: Broadcasts completion events to LiveView for reactive updates
  - **Error Handling**: Single attempt with detailed logging for failure analysis
  - **Dedicated Queue**: Runs on `temp_clips` queue for responsive review interface

  ## Troubleshooting

  **Duplicate Job Prevention**
  If you see logs like "Job already queued for clip X, skipping duplicate", this is
  normal behavior preventing redundant FFmpeg processes. The uniqueness constraint
  ensures only one generation job runs per clip within a 60-second window.

  **Failed Generation**
  Single-attempt jobs fail fast. Check:
  - Source video proxy file availability in S3
  - FFmpeg command execution in temp_clip.ex
  - PubSub message delivery to LiveView
  """

  use Oban.Worker,
    queue: :temp_clips,
    max_attempts: 1,
    unique: [period: 60]

  alias Heaters.Media.Clip
  alias Heaters.Repo
  alias Heaters.Storage.PlaybackCache.TempClip
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"clip_id" => clip_id}}) do
    Logger.info("PlaybackCache.Worker: Starting async generation for clip #{clip_id}")

    clip =
      Repo.get!(Clip, clip_id)
      |> Repo.preload(:source_video)

    case TempClip.build(clip) do
      {:ok, "/temp/" <> filename} ->
        Logger.info("PlaybackCache.Worker: Successfully generated temp clip #{filename}")

        # Broadcast to LiveView that temp file is ready
        broadcast_result =
          HeatersWeb.Endpoint.broadcast("clips:#{clip_id}", "temp_ready", %{
            path: "/temp/#{filename}",
            clip_id: clip_id
          })

        Logger.info(
          "PlaybackCache.Worker: Broadcast result: #{inspect(broadcast_result)} for clips:#{clip_id}"
        )

        :ok

      {:error, reason} ->
        Logger.error("PlaybackCache.Worker: Failed to generate temp clip #{clip_id}: #{reason}")

        # Broadcast error to LiveView
        HeatersWeb.Endpoint.broadcast("clips:#{clip_id}", "temp_error", %{
          error: reason,
          clip_id: clip_id
        })

        # Discard job - don't retry since these are ephemeral temp files
        {:discard, reason}
    end
  end
end
