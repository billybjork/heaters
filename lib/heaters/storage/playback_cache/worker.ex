defmodule Heaters.Storage.PlaybackCache.Worker do
  @moduledoc """
  Oban worker for generating temporary clip files in the background.

  Builds a temp clip via `TempClip.build/1` and broadcasts the result
  to `clips:{clip_id}` via PubSub so the LiveView can update reactively.
  Single-attempt, 60-second uniqueness constraint to prevent duplicate FFmpeg work.
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
