defmodule Frontend.Workers.Dispatcher do
  use Oban.Worker, queue: :background_jobs, unique: [period: 60]

  alias Frontend.Clips
  alias Frontend.Workers.IntakeWorker
  alias Frontend.Workers.KeyframeWorker
  alias Frontend.Workers.ArchiveWorker

  @impl Oban.Worker
  def perform(_job) do
    # 1. Look for new videos from external sources that need to be downloaded
    #    and transcoded.
    Clips.get_videos_by_state("new")
    |> Enum.map(&IntakeWorker.new(%{source_video_id: &1.id}))
    |> Oban.insert_all()

    # 2. Process actions from the review UI (merge, split, etc.)
    Clips.commit_pending_actions()

    # 3. Look for approved clips to start the enrichment pipeline.
    Clips.get_clips_by_state("review_approved")
    |> Enum.map(&KeyframeWorker.new(%{clip_id: &1.id, strategy: "multi"}))
    |> Oban.insert_all()

    # 4. Look for reviewed clips that need to be archived.
    Clips.get_clips_by_state("review_archived")
    |> Enum.map(&ArchiveWorker.new(%{clip_id: &1.id}))
    |> Oban.insert_all()

    :ok
  end
end
