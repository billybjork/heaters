defmodule Heaters.Media.Cuts.Validation do
  @moduledoc """
  Validation logic for cut point operations.

  Implements all precondition checks defined in `Cuts` as pure functions.
  Each validation function takes operation parameters and returns `:ok` or `{:error, reason}`.

  ## Validation Strategy

  - **Pure Functions**: All validations are side-effect free
  - **Composable**: Individual checks can be combined for complex validations
  - **Declarative**: Rules are data-driven from `Cuts`
  - **Comprehensive**: Covers all edge cases and business rules

  ## Usage

  This module is primarily used by `Cuts.Operations` to validate operations
  before execution, but can also be used standalone for validation without
  side effects.

  ## Examples

      iex> Validation.validate_operation(:add_cut, source_video_id, frame_number, user_id)
      :ok

      iex> Validation.validate_operation(:add_cut, source_video_id, invalid_frame, user_id)
      {:error, "Cut must be within existing segment boundaries"}
  """

  import Ecto.Query, warn: false
  alias Heaters.Media.Cut
  alias Heaters.Media.Cuts
  alias Heaters.Repo

  @doc """
  Validate a complete cut operation against all preconditions.

  ## Parameters
  - `operation_type`: :add_cut, :remove_cut, or :move_cut
  - `source_video_id`: ID of the source video
  - `params`: Operation-specific parameters
    - For `:add_cut`: `%{frame_number: integer(), user_id: integer()}`
    - For `:remove_cut`: `%{frame_number: integer(), user_id: integer()}`
    - For `:move_cut`: `%{old_frame: integer(), new_frame: integer(), user_id: integer()}`

  ## Returns
  - `:ok` if all preconditions pass
  - `{:error, reason}` if any precondition fails
  """
  @spec validate_operation(atom(), integer(), map()) :: :ok | {:error, String.t()}
  def validate_operation(operation_type, source_video_id, params) do
    preconditions = Cuts.get_preconditions(operation_type)

    case run_precondition_checks(preconditions, source_video_id, params) do
      [] -> :ok
      [first_error | _] -> {:error, first_error}
    end
  end

  @doc """
  Run all precondition checks for an operation.

  ## Parameters
  - `preconditions`: List of precondition tuples from Config
  - `source_video_id`: ID of the source video
  - `params`: Operation parameters

  ## Returns
  - `[]` if all checks pass
  - List of error messages if any checks fail
  """
  @spec run_precondition_checks([tuple()], integer(), map()) :: [String.t()]
  def run_precondition_checks(preconditions, source_video_id, params) do
    preconditions
    |> Enum.map(fn precondition ->
      run_single_precondition(precondition, source_video_id, params)
    end)
    |> Enum.filter(fn
      :ok -> false
      {:error, _} -> true
    end)
    |> Enum.map(fn {:error, reason} -> reason end)
  end

  ## Individual Precondition Implementations

  @doc """
  Check if a cut position is within an existing segment.

  Used for add_cut operations to ensure the new cut point falls within
  a valid segment boundary.

  CRITICAL: This validation expects absolute source video frame numbers.
  Virtual subclip split operations must convert from virtual coordinates
  before calling this function. See assets/js/review-hotkeys.js for the
  correct coordinate translation: (currentTime - clipStartTime) * fps + clipStartFrame
  """
  @spec validate_cut_within_segment(integer(), integer()) :: :ok | {:error, String.t()}
  def validate_cut_within_segment(source_video_id, frame_number) do
    segments = get_current_segments(source_video_id)

    case Enum.find(segments, fn segment ->
           frame_number > segment.start_frame and frame_number < segment.end_frame
         end) do
      nil ->
        {:error, "Frame #{frame_number} is not within any existing segment"}

      _segment ->
        :ok
    end
  end

  @doc """
  Check if resulting segments would meet minimum size requirements.

  Used for add_cut and move_cut operations to prevent creating segments
  that are too small to be useful.
  """
  @spec validate_minimum_segment_size(integer(), integer()) :: :ok | {:error, String.t()}
  def validate_minimum_segment_size(source_video_id, frame_number) do
    segments = get_current_segments(source_video_id)
    min_frames = Cuts.minimum_segment_frames()

    # Find the segment that would be split
    case Enum.find(segments, fn segment ->
           frame_number > segment.start_frame and frame_number < segment.end_frame
         end) do
      nil ->
        {:error, "No segment found for validation"}

      segment ->
        first_segment_size = frame_number - segment.start_frame
        second_segment_size = segment.end_frame - frame_number

        cond do
          first_segment_size < min_frames ->
            {:error,
             "First segment would be #{first_segment_size} frames (minimum: #{min_frames})"}

          second_segment_size < min_frames ->
            {:error,
             "Second segment would be #{second_segment_size} frames (minimum: #{min_frames})"}

          true ->
            :ok
        end
    end
  end

  @doc """
  Check if a cut doesn't duplicate an existing cut position.

  Used for add_cut operations to prevent creating duplicate cuts.
  """
  @spec validate_not_duplicate_cut(integer(), integer()) :: :ok | {:error, String.t()}
  def validate_not_duplicate_cut(source_video_id, frame_number) do
    case Cuts.find_cut_at_frame(source_video_id, frame_number) do
      {:ok, _cut} ->
        {:error, "Cut already exists at frame #{frame_number}"}

      {:error, :not_found} ->
        :ok
    end
  end

  @doc """
  Check if a cut exists at the specified position.

  Used for remove_cut and move_cut operations to ensure the target cut exists.
  """
  @spec validate_cut_exists(integer(), integer()) :: :ok | {:error, String.t()}
  def validate_cut_exists(source_video_id, frame_number) do
    case Cuts.find_cut_at_frame(source_video_id, frame_number) do
      {:ok, _cut} ->
        :ok

      {:error, :not_found} ->
        {:error, "No cut exists at frame #{frame_number}"}
    end
  end

  @doc """
  Check if there are segments on both sides of a cut.

  Used for remove_cut operations to ensure we're not trying to remove
  a boundary cut (start/end of video).
  """
  @spec validate_has_adjacent_segments(integer(), integer()) :: :ok | {:error, String.t()}
  def validate_has_adjacent_segments(source_video_id, frame_number) do
    segments = get_current_segments(source_video_id)

    has_left_segment =
      Enum.any?(segments, fn segment -> segment.end_frame == frame_number end)

    has_right_segment =
      Enum.any?(segments, fn segment -> segment.start_frame == frame_number end)

    case {has_left_segment, has_right_segment} do
      {true, true} ->
        :ok

      {false, _} ->
        {:error, "No segment ends at frame #{frame_number}"}

      {_, false} ->
        {:error, "No segment starts at frame #{frame_number}"}
    end
  end

  @doc """
  Check if cut is not a boundary cut (video start/end).

  Used for remove_cut operations to prevent removing implicit video boundaries.
  """
  @spec validate_not_boundary_cut(integer(), integer()) :: :ok | {:error, String.t()}
  def validate_not_boundary_cut(source_video_id, frame_number) do
    source_video = Repo.get!(Heaters.Media.Video, source_video_id)

    cond do
      frame_number == 0 ->
        {:error, "Cannot remove start boundary cut"}

      source_video.duration_seconds && source_video.fps &&
          frame_number >= trunc(source_video.duration_seconds * source_video.fps) ->
        {:error, "Cannot remove end boundary cut"}

      true ->
        :ok
    end
  end

  @doc """
  Check if new cut position is within outer segment boundaries.

  Used for move_cut operations to ensure the new position is valid.
  """
  @spec validate_within_outer_bounds(integer(), integer(), integer()) ::
          :ok | {:error, String.t()}
  def validate_within_outer_bounds(source_video_id, old_frame, new_frame) do
    segments = get_current_segments(source_video_id)

    # Find segments adjacent to the old cut
    left_segment = Enum.find(segments, fn segment -> segment.end_frame == old_frame end)
    right_segment = Enum.find(segments, fn segment -> segment.start_frame == old_frame end)

    case {left_segment, right_segment} do
      {%{start_frame: left_start}, %{end_frame: right_end}} ->
        if new_frame > left_start and new_frame < right_end do
          :ok
        else
          {:error, "New frame #{new_frame} is outside bounds [#{left_start}, #{right_end}]"}
        end

      _ ->
        {:error, "Cannot find adjacent segments for validation"}
    end
  end

  @doc """
  Check minimum distances from adjacent cuts.

  Used for move_cut operations to ensure cuts don't get too close together.
  """
  @spec validate_minimum_distances(integer(), integer(), integer()) :: :ok | {:error, String.t()}
  def validate_minimum_distances(source_video_id, old_frame, new_frame) do
    cuts = Cuts.get_cuts_for_source(source_video_id)
    min_distance = Cuts.minimum_cut_distance()
    other_cuts = Enum.reject(cuts, fn cut -> cut.frame_number == old_frame end)
    {left_cut, right_cut} = find_nearest_cuts(other_cuts, new_frame)

    with :ok <- check_cut_distance(left_cut, new_frame, min_distance, :left) do
      check_cut_distance(right_cut, new_frame, min_distance, :right)
    end
  end

  @spec check_cut_distance(Cut.t() | nil, integer(), integer(), :left | :right) ::
          :ok | {:error, String.t()}
  defp check_cut_distance(nil, _new_frame, _min_distance, _direction), do: :ok

  defp check_cut_distance(cut, new_frame, min_distance, :left) do
    distance = new_frame - cut.frame_number

    if distance >= min_distance,
      do: :ok,
      else: {:error, distance_error_msg(cut.frame_number, distance, min_distance)}
  end

  defp check_cut_distance(cut, new_frame, min_distance, :right) do
    distance = cut.frame_number - new_frame

    if distance >= min_distance,
      do: :ok,
      else: {:error, distance_error_msg(cut.frame_number, distance, min_distance)}
  end

  defp distance_error_msg(frame_number, distance, min_distance) do
    "New position too close to cut at frame #{frame_number} (distance: #{distance}, minimum: #{min_distance})"
  end

  @doc """
  Check if new position doesn't duplicate an existing cut.

  Used for move_cut operations to prevent moving a cut to an existing position.
  """
  @spec validate_not_duplicate_position(integer(), integer(), integer()) ::
          :ok | {:error, String.t()}
  def validate_not_duplicate_position(source_video_id, old_frame, new_frame) do
    # Allow moving to the same position (no-op)
    if old_frame == new_frame do
      :ok
    else
      validate_not_duplicate_cut(source_video_id, new_frame)
    end
  end

  ## Private Helper Functions

  # Dispatch precondition checks to individual handler functions
  @spec run_single_precondition(tuple(), integer(), map()) :: :ok | {:error, String.t()}
  defp run_single_precondition({:cut_within_segment, error_msg}, source_video_id, params) do
    check_with_error_msg(
      &validate_cut_within_segment/2,
      [source_video_id, params.frame_number],
      error_msg
    )
  end

  defp run_single_precondition(
         {:minimum_segment_size, _min_frames, error_msg},
         source_video_id,
         params
       ) do
    check_with_error_msg(
      &validate_minimum_segment_size/2,
      [source_video_id, params.frame_number],
      error_msg
    )
  end

  defp run_single_precondition({:not_duplicate_cut, error_msg}, source_video_id, params) do
    check_with_error_msg(
      &validate_not_duplicate_cut/2,
      [source_video_id, params.frame_number],
      error_msg
    )
  end

  defp run_single_precondition({:cut_exists, error_msg}, source_video_id, params) do
    frame = Map.get(params, :frame_number) || Map.get(params, :old_frame)
    check_with_error_msg(&validate_cut_exists/2, [source_video_id, frame], error_msg)
  end

  defp run_single_precondition({:has_adjacent_segments, error_msg}, source_video_id, params) do
    frame = Map.get(params, :frame_number) || Map.get(params, :old_frame)
    check_with_error_msg(&validate_has_adjacent_segments/2, [source_video_id, frame], error_msg)
  end

  defp run_single_precondition({:not_boundary_cut, error_msg}, source_video_id, params) do
    frame = Map.get(params, :frame_number) || Map.get(params, :old_frame)
    check_with_error_msg(&validate_not_boundary_cut/2, [source_video_id, frame], error_msg)
  end

  defp run_single_precondition({:within_outer_bounds, error_msg}, source_video_id, params) do
    check_with_error_msg(
      &validate_within_outer_bounds/3,
      [source_video_id, params.old_frame, params.new_frame],
      error_msg
    )
  end

  defp run_single_precondition(
         {:minimum_distances, _min_distance, error_msg},
         source_video_id,
         params
       ) do
    check_with_error_msg(
      &validate_minimum_distances/3,
      [source_video_id, params.old_frame, params.new_frame],
      error_msg
    )
  end

  defp run_single_precondition({:not_duplicate_position, error_msg}, source_video_id, params) do
    check_with_error_msg(
      &validate_not_duplicate_position/3,
      [source_video_id, params.old_frame, params.new_frame],
      error_msg
    )
  end

  defp run_single_precondition(precondition, _source_video_id, _params) do
    {:error, "Unknown precondition: #{inspect(precondition)}"}
  end

  # Helper to apply validation function and map error to configured message
  @spec check_with_error_msg(function(), [term()], String.t()) :: :ok | {:error, String.t()}
  defp check_with_error_msg(validator_fn, args, error_msg) do
    case apply(validator_fn, args) do
      :ok -> :ok
      {:error, _} -> {:error, error_msg}
    end
  end

  @spec get_current_segments(integer()) :: [map()]
  defp get_current_segments(source_video_id) do
    source_video = Repo.get!(Heaters.Media.Video, source_video_id)
    Cuts.derive_clips_from_cuts(source_video_id, source_video)
  end

  @spec find_nearest_cuts([Cut.t()], integer()) :: {Cut.t() | nil, Cut.t() | nil}
  defp find_nearest_cuts(cuts, frame_number) do
    left_cut =
      cuts
      |> Enum.filter(fn cut -> cut.frame_number < frame_number end)
      |> Enum.max_by(fn cut -> cut.frame_number end, fn -> nil end)

    right_cut =
      cuts
      |> Enum.filter(fn cut -> cut.frame_number > frame_number end)
      |> Enum.min_by(fn cut -> cut.frame_number end, fn -> nil end)

    {left_cut, right_cut}
  end
end
