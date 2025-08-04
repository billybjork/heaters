defmodule Heaters.Review.Queue do
  @moduledoc """
  Review queue management and workflow queries.

  This module handles all aspects of the human review workflow including
  queue operations, status tracking, and review-specific queries.

  ## When to Add Functions Here

  - **Queue Management**: Fetching pending clips, queue ordering, exclusions
  - **Review Counts**: Pending review counts, queue status metrics
  - **Review Workflow**: Human-driven workflow operations and states
  - **Queue Performance**: Loading clips with associations for review UI

  ## When NOT to Add Functions Here

  - **Core Domain Operations**: Basic clip CRUD, state management → `Media.Clips`
  - **Pipeline Orchestration**: Stage discovery queries → `Pipeline.Queries`
  - **Review Actions**: Approve, skip, archive actions → `Review.Actions`

  Focuses specifically on queue management and workflow support for the
  human review process.
  """

  import Ecto.Query, warn: false
  alias Heaters.Repo
  alias Heaters.Media.Clip

  # -------------------------------------------------------------------------
  # Internal helpers
  # -------------------------------------------------------------------------

  @spec load_clip_with_assocs(integer) :: Clip.t()
  def load_clip_with_assocs(id) do
    from(c in Clip,
      where: c.id == ^id,
      left_join: sv in assoc(c, :source_video),
      left_join: ca in assoc(c, :clip_artifacts),
      preload: [source_video: sv, clip_artifacts: ca]
    )
    |> Repo.one!()
  end

  # -------------------------------------------------------------------------
  # Public API – review queue
  # -------------------------------------------------------------------------

  @doc """
  Fetch the next `limit` clips pending review, excluding specific clip IDs.

  This is the primary function for batch-fetching pending review clips,
  used by the review interface for efficient prefetching.

  ## Parameters
  - `limit`: Maximum number of clips to return
  - `exclude_ids`: List of clip IDs to exclude from results (default: [])

  ## Examples

      # Get next 10 clips for review
      clips = Review.Queue.next_pending_review_clips(10)

      # Get next 5 clips, excluding currently loaded ones
      clips = Review.Queue.next_pending_review_clips(5, [123, 456, 789])
  """
  @spec next_pending_review_clips(integer(), list(integer())) :: list(Clip.t())
  def next_pending_review_clips(limit, exclude_ids \\ []) when is_integer(limit) do
    from(c in Clip,
      where: c.ingest_state == :pending_review and c.id not in ^exclude_ids,
      order_by: [asc: c.id]
    )
    |> limit(^limit)
    |> preload([:source_video, :clip_artifacts])
    |> Repo.all()
  end

  @doc """
  Fast count of clips still in `pending_review`.

  This provides an efficient count for queue status displays and
  review workflow management.
  """
  @spec pending_review_count() :: integer()
  def pending_review_count do
    Clip
    |> where([c], c.ingest_state == :pending_review and is_nil(c.reviewed_at))
    |> select([c], count("*"))
    |> Repo.one()
  end
end
