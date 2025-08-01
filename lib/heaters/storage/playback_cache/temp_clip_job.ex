defmodule Heaters.Storage.PlaybackCache.TempClipJob do
  @moduledoc """
  Background job for generating temporary clip files asynchronously.

  This prevents LiveView blocking during FFmpeg processing and provides
  a better user experience with loading states and instant UI responses.
  """

  use Oban.Worker, queue: :temp_clips, max_attempts: 1

  @repo_port Application.compile_env(:heaters, :repo_port, Heaters.Database.EctoAdapter)
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"clip_id" => clip_id}}) do
    Logger.info("TempClipJob: Starting async generation for clip #{clip_id}")

    clip =
      @repo_port.get!(Heaters.Media.Clip, clip_id)
      |> @repo_port.preload(:source_video)

    case Heaters.Storage.PlaybackCache.TempClip.build(clip) do
      {:ok, "/temp/" <> filename} ->
        Logger.info("TempClipJob: Successfully generated temp clip #{filename}")

        # Broadcast to LiveView that temp file is ready
        broadcast_result =
          HeatersWeb.Endpoint.broadcast("clips:#{clip_id}", "temp_ready", %{
            path: "/temp/#{filename}",
            clip_id: clip_id
          })

        Logger.info(
          "TempClipJob: Broadcast result: #{inspect(broadcast_result)} for clips:#{clip_id}"
        )

        :ok

      {:error, reason} ->
        Logger.error("TempClipJob: Failed to generate temp clip #{clip_id}: #{reason}")

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
