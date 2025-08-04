defmodule Heaters.Media.Cuts.Config do
  @moduledoc """
  Declarative configuration for cut point operations.

  Defines operation rules, constraints, and effects as data rather than code,
  following the same pattern as `Pipeline.Config` and `FFmpegConfig`.

  Each operation (add, remove, move) has:
  - **Preconditions**: Validation rules that must pass before execution
  - **Effects**: Database changes and side effects to perform
  - **Audit**: Metadata to track for operation history

  ## Operation Flow

  1. **Validate Preconditions**: Check all constraints using declarative rules
  2. **Execute Effects**: Apply database changes atomically
  3. **Log Audit Trail**: Record operation details for debugging and compliance

  ## Configuration Structure

  ```elixir
  %{
    operation: :add_cut,
    preconditions: [
      {:within_segment, "Cut must be within existing segment boundaries"},
      {:minimum_segment_size, 30, "Segments must be at least 30 frames"}
    ],
    effects: [
      {:archive_clips, :containing_segment},
      {:create_clips, :from_new_boundaries}
    ],
    audit: %{
      operation: "split_segment",
      tracks: [:original_segment, :new_segments, :cut_position]
    }
  }
  ```
  """


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
           "Segments must be at least #{minimum_segment_frames()} frames"},
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

      iex> Config.get_operation(:add_cut)
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

  Prevents creating segments that are too short to be meaningful.
  Can be overridden via application config.
  """
  @spec minimum_segment_frames() :: integer()
  def minimum_segment_frames do
    Application.get_env(:heaters, :minimum_segment_frames, 30)
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
end