defmodule Heaters.Media.Cut do
  @moduledoc """
  Core domain entity representing cut points in source videos.

  Cuts are the source of truth for video segmentation. They define the boundaries
  where one segment ends and another begins. Clips are derived entities representing
  the segments between cuts.

  ## Domain Logic

  - Cuts are immutable once created (operations create new cuts, archive old ones)
  - Cuts naturally order by frame_number for temporal sequencing
  - Scene detection creates initial cuts; human review adds/removes/moves cuts
  - All cut operations maintain MECE (Mutually Exclusive, Collectively Exhaustive) properties

  ## Cut Operations

  - **Add Cut**: Creates new boundary → splits existing segment
  - **Remove Cut**: Eliminates boundary → merges adjacent segments  
  - **Move Cut**: Adjusts boundary → resizes adjacent segments

  All operations are handled through `Heaters.Media.Cuts.Operations` with
  declarative rules defined in `Heaters.Media.Cuts.Config`.
  """

  use Heaters.Schema
  import Ecto.Query, warn: false

  @type t :: %__MODULE__{
          id: integer(),
          frame_number: integer(),
          time_seconds: float(),
          source_video_id: integer(),
          created_by_user_id: integer() | nil,
          operation_metadata: map() | nil,
          source_video: Heaters.Media.Video.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "cuts" do
    field(:frame_number, :integer)
    field(:time_seconds, :float)
    field(:created_by_user_id, :integer)
    field(:operation_metadata, :map)

    belongs_to(:source_video, Heaters.Media.Video)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for a cut.

  ## Required Fields
  - `:source_video_id`: The source video this cut belongs to
  - `:frame_number`: Frame number where the cut occurs (must be positive)
  - `:time_seconds`: Time in seconds where the cut occurs (must be positive)

  ## Optional Fields
  - `:created_by_user_id`: User who created this cut (nil for system-generated cuts)
  - `:operation_metadata`: Additional metadata about the cut creation operation
  """
  def changeset(cut, attrs) do
    cut
    |> cast(attrs, [
      :source_video_id,
      :frame_number,
      :time_seconds,
      :created_by_user_id,
      :operation_metadata
    ])
    |> validate_required([:source_video_id, :frame_number, :time_seconds])
    |> validate_number(:frame_number, greater_than: 0)
    |> validate_number(:time_seconds, greater_than_or_equal_to: 0.0)
    |> unique_constraint([:source_video_id, :frame_number],
      name: "cuts_source_video_id_frame_number_index"
    )
  end

  @doc """
  Get all cuts for a source video, ordered by frame number.

  ## Parameters
  - `source_video_id`: ID of the source video

  ## Returns
  - List of cuts ordered chronologically by frame number
  """
  @spec get_cuts_for_source(integer()) :: [t()]
  def get_cuts_for_source(source_video_id) do
    from(c in __MODULE__,
      where: c.source_video_id == ^source_video_id,
      order_by: [asc: c.frame_number]
    )
    |> Heaters.Repo.all()
  end

  @doc """
  Get cuts within a specific frame range for a source video.

  ## Parameters
  - `source_video_id`: ID of the source video
  - `start_frame`: Starting frame number (inclusive)
  - `end_frame`: Ending frame number (inclusive)

  ## Returns
  - List of cuts within the specified range, ordered by frame number
  """
  @spec get_cuts_in_range(integer(), integer(), integer()) :: [t()]
  def get_cuts_in_range(source_video_id, start_frame, end_frame) do
    from(c in __MODULE__,
      where:
        c.source_video_id == ^source_video_id and
          c.frame_number >= ^start_frame and
          c.frame_number <= ^end_frame,
      order_by: [asc: c.frame_number]
    )
    |> Heaters.Repo.all()
  end

  @doc """
  Find the cut at a specific frame number for a source video.

  ## Parameters
  - `source_video_id`: ID of the source video
  - `frame_number`: Frame number to look for

  ## Returns
  - `{:ok, cut}` if found
  - `{:error, :not_found}` if no cut exists at that frame
  """
  @spec find_cut_at_frame(integer(), integer()) :: {:ok, t()} | {:error, :not_found}
  def find_cut_at_frame(source_video_id, frame_number) do
    case Heaters.Repo.get_by(__MODULE__,
           source_video_id: source_video_id,
           frame_number: frame_number
         ) do
      %__MODULE__{} = cut -> {:ok, cut}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Derive clips (segments) from cuts for a source video.

  Clips are the segments between cuts. This function computes the segments
  based on the current cut positions, including implicit start/end boundaries.

  ## Parameters
  - `source_video_id`: ID of the source video
  - `source_video`: Optional preloaded source video struct for metadata

  ## Returns
  - List of clip data maps with segment boundaries and metadata

  ## Examples

      iex> cuts = [
      ...>   %Cut{frame_number: 100, time_seconds: 4.0},
      ...>   %Cut{frame_number: 200, time_seconds: 8.0}
      ...> ]
      iex> # This creates 3 segments: [0-100], [100-200], [200-end]

  """
  @spec derive_clips_from_cuts(integer(), Heaters.Media.Video.t() | nil) :: [map()]
  def derive_clips_from_cuts(source_video_id, source_video \\ nil) do
    cuts = get_cuts_for_source(source_video_id)
    
    # Get source video if not provided
    source_video = source_video || Heaters.Repo.get!(Heaters.Media.Video, source_video_id)
    
    derive_segments_from_cuts(cuts, source_video)
  end

  # Private helper to derive segments from cut boundaries
  @spec derive_segments_from_cuts([t()], Heaters.Media.Video.t()) :: [map()]
  defp derive_segments_from_cuts(cuts, source_video) do
    # Create boundary points including implicit start and end
    boundaries = [
      %{frame: 0, time: 0.0, type: :start}
      | Enum.map(cuts, fn cut ->
          %{frame: cut.frame_number, time: cut.time_seconds, type: :cut}
        end)
    ]

    # Add implicit end boundary if we have video duration
    boundaries = 
      if source_video.duration_seconds && source_video.fps do
        end_frame = trunc(source_video.duration_seconds * source_video.fps)
        boundaries ++ [%{frame: end_frame, time: source_video.duration_seconds, type: :end}]
      else
        boundaries
      end

    # Create segments from consecutive boundary pairs
    boundaries
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.with_index()
    |> Enum.map(fn {[start_boundary, end_boundary], index} ->
      %{
        start_frame: start_boundary.frame,
        end_frame: end_boundary.frame,
        start_time_seconds: start_boundary.time,
        end_time_seconds: end_boundary.time,
        source_video_id: source_video.id,
        segment_index: index,
        duration_seconds: end_boundary.time - start_boundary.time,
        frame_count: end_boundary.frame - start_boundary.frame
      }
    end)
  end
end