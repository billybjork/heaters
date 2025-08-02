defmodule Heaters.Review.Queue do
  @moduledoc """
  Review queue management for clips.

  Handles the review queue operations including fetching pending clips
  and loading clips with their associations.
  """

  import Ecto.Query, warn: false
  @repo_port Application.compile_env(:heaters, :repo_port, Heaters.Database.EctoAdapter)
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
    |> @repo_port.one!()
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
      where: c.ingest_state == "pending_review" and c.id not in ^exclude_ids,
      order_by: [asc: c.id]
    )
    |> limit(^limit)
    |> preload([:source_video, :clip_artifacts])
    |> @repo_port.all()
  end
end
