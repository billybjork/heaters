defmodule Heaters.Media.Cuts do
  @moduledoc """
  Core domain operations for `Heaters.Media.Cut` objects.

  This module consolidates cut domain operations and configuration into a single,
  cohesive interface. Complex business operations (add/remove/move cuts) are handled
  by `Cuts.Operations` and `Cuts.Validation` due to their sophistication.

  ## When to Add Functions Here

  - **CRUD Operations**: Creating, reading, updating cuts
  - **Simple Queries**: Basic state-based queries and lookups
  - **Configuration Access**: Operation rules, constraints, and parameters
  - **Domain Validation**: Basic existence checks and simple validations

  ## When NOT to Add Functions Here

  - **Complex Operations**: Cut operations with transactions → `Cuts.Operations`
  - **Complex Validation**: Multi-step validation logic → `Cuts.Validation`
  - **Cross-Entity Operations**: Operations affecting cuts + clips → `Cuts.Operations`

  ## Design Philosophy

  - **Schema Separation**: `Heaters.Media.Cut` defines the data structure
  - **Domain Focus**: This module provides core cut operations and configuration
  - **Complexity Boundary**: Complex orchestration delegated to specialized modules
  - **Single Import**: `alias Heaters.Media.Cuts` provides access to cut domain operations

  All DB interaction goes through `Heaters.Repo`, keeping "I/O at the edges".
  """

  import Ecto.Query, warn: false
  alias Heaters.Media.Cut
  alias Heaters.Repo

  # ---------------------------------------------------------------------------
  # CRUD Operations
  # ---------------------------------------------------------------------------

  @doc """
  Get a cut by ID.
  Returns {:ok, cut} if found, {:error, :not_found} otherwise.
  """
  @spec get_cut(integer()) :: {:ok, Cut.t()} | {:error, :not_found}
  def get_cut(id) do
    case Repo.get(Cut, id) do
      nil -> {:error, :not_found}
      cut -> {:ok, cut}
    end
  end

  @doc """
  Get a cut by ID. Raises if not found.
  """
  @spec get_cut!(integer()) :: Cut.t()
  def get_cut!(id) do
    Repo.get!(Cut, id)
  end

  @doc """
  Create a single cut and return it.
  """
  @spec create_cut(map()) :: {:ok, Cut.t()} | {:error, any()}
  def create_cut(cut_attrs) when is_map(cut_attrs) do
    %Cut{}
    |> Cut.changeset(cut_attrs)
    |> Repo.insert()
  end

  @doc """
  Update a cut with the given attributes.
  """
  @spec update_cut(Cut.t(), map()) :: {:ok, Cut.t()} | {:error, any()}
  def update_cut(%Cut{} = cut, attrs) do
    cut
    |> Cut.changeset(attrs)
    |> Repo.update([])
  end

  # ---------------------------------------------------------------------------
  # Query Functions
  # ---------------------------------------------------------------------------

  @doc """
  Get all cuts for a source video, ordered by frame number.

  ## Parameters
  - `source_video_id`: ID of the source video

  ## Returns
  - List of cuts ordered chronologically by frame number
  """
  @spec get_cuts_for_source(integer()) :: [Cut.t()]
  def get_cuts_for_source(source_video_id) do
    from(c in Cut,
      where: c.source_video_id == ^source_video_id,
      order_by: [asc: c.frame_number]
    )
    |> Repo.all()
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
  @spec get_cuts_in_range(integer(), integer(), integer()) :: [Cut.t()]
  def get_cuts_in_range(source_video_id, start_frame, end_frame) do
    from(c in Cut,
      where:
        c.source_video_id == ^source_video_id and
          c.frame_number >= ^start_frame and
          c.frame_number <= ^end_frame,
      order_by: [asc: c.frame_number]
    )
    |> Repo.all()
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
  @spec find_cut_at_frame(integer(), integer()) :: {:ok, Cut.t()} | {:error, :not_found}
  def find_cut_at_frame(source_video_id, frame_number) do
    case Repo.get_by(Cut,
           source_video_id: source_video_id,
           frame_number: frame_number
         ) do
      %Cut{} = cut -> {:ok, cut}
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
    source_video = source_video || Repo.get!(Heaters.Media.Video, source_video_id)

    derive_segments_from_cuts(cuts, source_video)
  end

  # ---------------------------------------------------------------------------
  # Operation Configuration (formerly Cuts.Config)
  # ---------------------------------------------------------------------------

  @doc """
  Returns the complete operation configuration for all cut operations.

  Each operation defines its preconditions, effects, and audit requirements
  as declarative data structures.
  """
  @spec operations() :: map()
  def operations do
    %{
      add_cut: %{
        description: "Add a cut point within an existing segment, splitting it into two segments",
        preconditions: [
          {:cut_within_segment, "Cut must be within existing segment boundaries"},
          {:minimum_segment_size, minimum_segment_frames(),
           "Segments must be at least #{minimum_segment_frames()} frame"},
          {:not_duplicate_cut, "Cut cannot be at existing cut position"}
        ],
        effects: [
          {:create_cut, :at_position},
          {:archive_clips, :containing_segment},
          {:create_clips, :from_split_segments}
        ],
        audit: %{
          operation: "split_segment",
          operation_type: "add",
          tracks: [:original_clip_id, :new_clip_ids, :cut_position]
        }
      },
      remove_cut: %{
        description: "Remove a cut point between two adjacent segments, merging them",
        preconditions: [
          {:cut_exists, "Cut must exist at specified position"},
          {:has_adjacent_segments, "Must have segments on both sides of cut"},
          {:not_boundary_cut, "Cannot remove start/end boundary cuts"}
        ],
        effects: [
          {:remove_cut, :at_position},
          {:archive_clips, :adjacent_segments},
          {:create_clip, :merged_segment}
        ],
        audit: %{
          operation: "merge_segments",
          operation_type: "remove",
          tracks: [:removed_cut_id, :original_clip_ids, :merged_clip_id]
        }
      },
      move_cut: %{
        description: "Move a cut point to a new position, adjusting adjacent segment boundaries",
        preconditions: [
          {:cut_exists, "Cut must exist at old position"},
          {:within_outer_bounds, "New position must be within outer segment boundaries"},
          {:minimum_distances, minimum_cut_distance(),
           "Must maintain #{minimum_cut_distance()} frame minimum distance from adjacent cuts"},
          {:not_duplicate_position, "New position cannot overlap existing cut"}
        ],
        effects: [
          {:update_cut, :to_new_position},
          {:update_clips, :adjacent_segments}
        ],
        audit: %{
          operation: "adjust_boundary",
          operation_type: "move",
          tracks: [:cut_id, :old_position, :new_position, :affected_clip_ids]
        }
      }
    }
  end

  @doc """
  Get operation configuration for a specific operation type.

  ## Parameters
  - `operation_type`: :add_cut, :remove_cut, or :move_cut

  ## Returns
  - Operation configuration map
  - Raises if operation type is unknown

  ## Examples

      iex> Cuts.get_operation(:add_cut)
      %{description: "Add a cut point...", preconditions: [...], ...}
  """
  @spec get_operation(atom()) :: map()
  def get_operation(operation_type) do
    operations()[operation_type] ||
      raise ArgumentError, "Unknown cut operation: #{operation_type}"
  end

  @doc """
  Get all preconditions for an operation type.

  ## Parameters
  - `operation_type`: :add_cut, :remove_cut, or :move_cut

  ## Returns
  - List of precondition tuples: `{check_type, params..., error_message}`
  """
  @spec get_preconditions(atom()) :: [tuple()]
  def get_preconditions(operation_type) do
    get_operation(operation_type).preconditions
  end

  @doc """
  Get all effects for an operation type.

  ## Parameters
  - `operation_type`: :add_cut, :remove_cut, or :move_cut

  ## Returns
  - List of effect tuples describing database changes to perform
  """
  @spec get_effects(atom()) :: [tuple()]
  def get_effects(operation_type) do
    get_operation(operation_type).effects
  end

  @doc """
  Get audit configuration for an operation type.

  ## Parameters
  - `operation_type`: :add_cut, :remove_cut, or :move_cut

  ## Returns
  - Map with audit metadata structure
  """
  @spec get_audit_config(atom()) :: map()
  def get_audit_config(operation_type) do
    get_operation(operation_type).audit
  end

  @doc """
  Returns all available operation types.
  """
  @spec operation_types() :: [atom()]
  def operation_types do
    Map.keys(operations())
  end

  @doc """
  Check if an operation type is valid.

  ## Parameters
  - `operation_type`: Operation type to validate

  ## Returns
  - `true` if valid, `false` otherwise
  """
  @spec valid_operation?(atom()) :: boolean()
  def valid_operation?(operation_type) do
    operation_type in operation_types()
  end

  ## Configuration Parameters

  @doc """
  Minimum number of frames required for a segment.

  Set to 1 to allow splits of any duration while preventing degenerate segments.
  Can be overridden via application config.
  """
  @spec minimum_segment_frames() :: integer()
  def minimum_segment_frames do
    Application.get_env(:heaters, :minimum_segment_frames, 1)
  end

  @doc """
  Minimum distance required between adjacent cuts.

  Prevents cuts from being placed too close together.
  Can be overridden via application config.
  """
  @spec minimum_cut_distance() :: integer()
  def minimum_cut_distance do
    Application.get_env(:heaters, :minimum_cut_distance, 15)
  end

  @doc """
  Maximum number of cuts allowed per source video.

  Prevents excessive segmentation that could impact performance.
  Can be overridden via application config.
  """
  @spec maximum_cuts_per_video() :: integer()
  def maximum_cuts_per_video do
    Application.get_env(:heaters, :maximum_cuts_per_video, 100)
  end

  @doc """
  Returns debug information about operation configuration.

  Useful for debugging and inspection of the declarative rules.

  ## Parameters
  - `operation_type`: Optional specific operation to inspect (all if nil)

  ## Returns
  - Map with operation details and configuration summary
  """
  @spec debug_info(atom() | nil) :: map()
  def debug_info(operation_type \\ nil) do
    case operation_type do
      nil ->
        %{
          total_operations: length(operation_types()),
          operations: operation_types(),
          configuration: %{
            minimum_segment_frames: minimum_segment_frames(),
            minimum_cut_distance: minimum_cut_distance(),
            maximum_cuts_per_video: maximum_cuts_per_video()
          }
        }

      type when type in [:add_cut, :remove_cut, :move_cut] ->
        config = get_operation(type)

        %{
          operation: type,
          description: config.description,
          precondition_count: length(config.preconditions),
          effect_count: length(config.effects),
          preconditions: Enum.map(config.preconditions, &elem(&1, 0)),
          effects: Enum.map(config.effects, &elem(&1, 0)),
          audit_tracks: config.audit.tracks
        }

      _ ->
        raise ArgumentError, "Unknown operation type: #{operation_type}"
    end
  end

  # ---------------------------------------------------------------------------
  # Private Helper Functions
  # ---------------------------------------------------------------------------

  # Private helper to derive segments from cut boundaries
  @spec derive_segments_from_cuts([Cut.t()], Heaters.Media.Video.t()) :: [map()]
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
