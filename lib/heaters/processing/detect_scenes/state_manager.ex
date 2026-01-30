defmodule Heaters.Processing.DetectScenes.StateManager do
  @moduledoc """
  State management for the scene detection workflow.

  This module handles state transitions specific to the scene detection process.
  Scene detection creates virtual clips from encoded videos using the proxy file.

  ## State Machine Diagram

  ```
                              ┌─────────────────┐
                              │                 │
                              ▼                 │ retry
                       ┌─────────────┐         │
                       │   encoded   │─────────┼───────────────┐
                       │ needs_splicing=true   │               │
                       └──────┬──────┘         │               │
                              │                │               │
               start_scene_detection/1         │               │
                              │                │               │
                              ▼                │               │
                   ┌──────────────────┐        │               │
          ┌──────▶│ detecting_scenes │────────┘               │
          │        └────────┬─────────┘                        │
          │                 │                                  │
          │    complete_scene_detection/1                      │
          │                 │                                  │
          │                 ▼                                  │
          │          ┌─────────────┐                           │
          │          │   encoded   │◀──────────────────────────┘
          │          │ needs_splicing=false     (recovery)
          │          └─────────────┘
          │                 │
          │                 │ (clips now in :pending_review)
          │                 ▼
          │ mark_scene_detection_failed/2
          │
          │    ┌───────────────────────┐
          └────│ detect_scenes_failed  │
               └───────────────────────┘
  ```

  ## State Transitions

  | From State           | To State               | Function                        | Trigger                |
  |----------------------|------------------------|---------------------------------|------------------------|
  | `:encoded` (splicing)| `:detecting_scenes`    | `start_scene_detection/1`       | Worker starts          |
  | `:detecting_scenes`  | `:encoded` (no splicing)| `complete_scene_detection/1`   | Cuts created           |
  | `:detecting_scenes`  | `:detect_scenes_failed`| `mark_scene_detection_failed/2` | Python/OpenCV error    |
  | `:detect_scenes_failed`| `:detecting_scenes`  | `start_scene_detection/1`       | Retry attempt          |

  ## Key Invariants

  - `needs_splicing = true` indicates scene detection is needed
  - `needs_splicing = false` indicates scene detection is complete
  - Clips are created in `:pending_review` state when scene detection completes
  - `proxy_filepath` must exist before scene detection can start

  ## Responsibilities
  - Scene detection state transitions
  - Scene detection failure handling with retry count
  - State validation for scene detection workflow
  """

  alias Heaters.Repo
  alias Heaters.Media.Video
  alias Heaters.Media.Videos
  require Logger

  @doc """
  Transition a source video to :detecting_scenes state.

  ## Parameters
  - `source_video_id`: ID of the source video to transition

  ## Returns
  - `{:ok, updated_video}` on successful transition
  - `{:error, reason}` if video not found or invalid state

  ## Examples

      {:ok, video} = StateManager.start_scene_detection(123)
      video.ingest_state  # :detecting_scenes
  """
  @spec start_scene_detection(integer()) :: {:ok, Video.t()} | {:error, any()}
  def start_scene_detection(source_video_id) do
    with {:ok, source_video} <- Videos.get_source_video(source_video_id),
         :ok <- validate_scene_detection_prerequisites(source_video) do
      update_source_video(source_video, %{
        ingest_state: :detecting_scenes,
        last_error: nil
      })
    end
  end

  @doc """
  Mark scene detection as complete by setting needs_splicing = false.

  ## Parameters
  - `source_video_id`: ID of the source video to mark as complete

  ## Returns
  - `{:ok, updated_video}` on successful transition
  - `{:error, reason}` if video not found

  ## Examples

      {:ok, video} = StateManager.complete_scene_detection(123)
      video.needs_splicing  # false
  """
  @spec complete_scene_detection(integer()) :: {:ok, Video.t()} | {:error, any()}
  def complete_scene_detection(source_video_id) do
    with {:ok, source_video} <- Videos.get_source_video(source_video_id) do
      update_source_video(source_video, %{
        ingest_state: :encoded,
        needs_splicing: false,
        last_error: nil
      })
    end
  end

  @doc """
  Mark scene detection as complete without changing ingest_state.
  Used when virtual clips already exist but needs_splicing flag needs updating.

  ## Parameters
  - `source_video_id`: ID of the source video to mark as complete

  ## Returns
  - `{:ok, updated_video}` on successful update
  - `{:error, reason}` if video not found
  """
  @spec mark_scene_detection_complete(integer()) :: {:ok, Video.t()} | {:error, any()}
  def mark_scene_detection_complete(source_video_id) do
    with {:ok, source_video} <- Videos.get_source_video(source_video_id) do
      update_source_video(source_video, %{
        needs_splicing: false
      })
    end
  end

  @doc """
  Mark a source video as failed during scene detection with error details.

  ## Parameters
  - `source_video_id`: ID of the source video to mark as failed
  - `error_reason`: Error reason (will be formatted as string)

  ## Returns
  - `{:ok, updated_video}` on successful error recording
  - `{:error, reason}` if video not found or update fails

  ## Examples

      {:ok, video} = StateManager.mark_scene_detection_failed(123, "Scene detection timeout")
      video.ingest_state    # :detect_scenes_failed
      video.last_error      # "Scene detection timeout"
      video.retry_count     # incremented
  """
  @spec mark_scene_detection_failed(integer(), any()) :: {:ok, Video.t()} | {:error, any()}
  def mark_scene_detection_failed(source_video_id, error_reason)
      when is_integer(source_video_id) do
    with {:ok, source_video} <- Videos.get_source_video(source_video_id) do
      error_message = format_error_message(error_reason)

      Logger.error(
        "StateManager: Marking video #{source_video.id} as detect_scenes_failed: #{error_message}"
      )

      update_source_video(source_video, %{
        ingest_state: :detect_scenes_failed,
        last_error: error_message,
        retry_count: source_video.retry_count + 1
      })
    end
  end

  # Private helper functions

  defp validate_scene_detection_prerequisites(source_video) do
    cond do
      is_nil(source_video.proxy_filepath) ->
        {:error, "No proxy file available - encoding must be completed first"}

      source_video.needs_splicing == false ->
        {:error, "Scene detection already complete (needs_splicing = false)"}

      true ->
        :ok
    end
  end

  defp update_source_video(%Video{} = source_video, attrs) do
    source_video
    |> Video.changeset(attrs)
    |> Repo.update([])
  end

  defp format_error_message(error) when is_binary(error), do: error
  defp format_error_message(error), do: inspect(error)
end
