defmodule Heaters.Infrastructure.Orchestration.Dispatcher do
  use Oban.Worker, queue: :background_jobs, unique: [period: 60]

  require Logger

  alias Heaters.Video.Queries, as: VideoQueries
  alias Heaters.Clip.Queries, as: ClipQueries
  alias Heaters.Clip.Review, as: ClipReview
  alias Heaters.Video.Ingest.IntakeWorker
  alias Heaters.Clip.Review.SpriteWorker
  alias Heaters.Clip.Transform.KeyframeWorker
  alias Heaters.Infrastructure.Orchestration.ArchiveWorker

  @impl Oban.Worker
  def perform(_job) do
    Logger.info("Dispatcher[start]: Starting perform.")

    # 1. Look for new videos from external sources
    Logger.info("Dispatcher[step 1]: Checking for new videos to ingest.")
    new_videos = VideoQueries.get_videos_by_state("new")
    Logger.info("Dispatcher[step 1]: Found #{Enum.count(new_videos)} new videos.")

    if Enum.any?(new_videos) do
      Logger.info("Dispatcher[step 1]: Enqueuing IntakeWorker jobs.")
      new_jobs = Enum.map(new_videos, &IntakeWorker.new(%{source_video_id: &1.id}))
      Oban.insert_all(new_jobs, on_conflict: :raise)
      Logger.info("Dispatcher[step 1]: Finished enqueuing IntakeWorker jobs.")
    end

    # 2. Look for spliced clips that need sprite generation
    Logger.info("Dispatcher[step 2]: Checking for spliced clips needing sprite generation.")
    spliced_clips = ClipQueries.get_clips_by_state("spliced")
    Logger.info("Dispatcher[step 2]: Found #{Enum.count(spliced_clips)} spliced clips.")

    if Enum.any?(spliced_clips) do
      Logger.info("Dispatcher[step 2]: Enqueuing SpriteWorker jobs.")
      sprite_jobs = Enum.map(spliced_clips, &SpriteWorker.new(%{clip_id: &1.id}))
      Oban.insert_all(sprite_jobs, on_conflict: :raise)
      Logger.info("Dispatcher[step 2]: Finished enqueuing SpriteWorker jobs.")
    end

    # 3. Process actions from the review UI (merge, split, etc.)
    Logger.info("Dispatcher[step 3]: Committing pending UI actions.")
    ClipReview.commit_pending_actions()
    Logger.info("Dispatcher[step 3]: Finished committing pending UI actions.")

    # 4. Look for approved clips to start the enrichment pipeline.
    Logger.info("Dispatcher[step 4]: Checking for approved clips for keyframing.")
    approved_clips = ClipQueries.get_clips_by_state("review_approved")
    Logger.info("Dispatcher[step 4]: Found #{Enum.count(approved_clips)} approved clips.")

    if Enum.any?(approved_clips) do
      Logger.info("Dispatcher[step 4]: Enqueuing KeyframeWorker jobs.")

      keyframe_jobs =
        Enum.map(approved_clips, &KeyframeWorker.new(%{clip_id: &1.id, strategy: "multi"}))

      Oban.insert_all(keyframe_jobs, on_conflict: :raise)
      Logger.info("Dispatcher[step 4]: Finished enqueuing KeyframeWorker jobs.")
    end

    # 5. Look for archived clips
    Logger.info("Dispatcher[step 5]: Checking for clips to archive.")
    archived_clips = ClipQueries.get_clips_by_state("review_archived")
    Logger.info("Dispatcher[step 5]: Found #{Enum.count(archived_clips)} clips to archive.")

    if Enum.any?(archived_clips) do
      Logger.info("Dispatcher[step 5]: Enqueuing ArchiveWorker jobs.")
      archive_jobs = Enum.map(archived_clips, &ArchiveWorker.new(%{clip_id: &1.id}))
      Oban.insert_all(archive_jobs, on_conflict: :raise)
      Logger.info("Dispatcher[step 5]: Finished enqueuing ArchiveWorker jobs.")
    end

    Logger.info("Dispatcher[finish]: Finished perform.")
    :ok
  end
end
