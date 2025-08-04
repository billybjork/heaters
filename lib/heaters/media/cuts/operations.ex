defmodule Heaters.Media.Cuts.Operations do
  @moduledoc """
  Core cut point operations: add, remove, and move cuts.

  This module orchestrates all cut operations using the declarative configuration
  from `Cuts.Config` and validation from `Cuts.Validation`. Each operation:

  1. **Validates** all preconditions using declarative rules
  2. **Executes** effects atomically within database transactions

  ## Operation Patterns

  All operations follow the same pattern:
  - Validate using `Cuts.Validation`
  - Execute effects in database transaction
  - Return success/error with clear messaging

  ## Database Consistency

  Operations maintain MECE (Mutually Exclusive, Collectively Exhaustive) properties:
  - **Add Cut**: Archives containing clip, creates two new clips
  - **Remove Cut**: Archives adjacent clips, creates one merged clip
  - **Move Cut**: Updates adjacent clips with new boundaries

  ## Usage

      # Add a cut point
      {:ok, {first_clip, second_clip}} = 
        Operations.add_cut(source_video_id, frame_number, user_id)

      # Remove a cut point
      {:ok, merged_clip} = 
        Operations.remove_cut(source_video_id, frame_number, user_id)

      # Move a cut point
      {:ok, {updated_first, updated_second}} = 
        Operations.move_cut(source_video_id, old_frame, new_frame, user_id)
  """

  import Ecto.Query, warn: false
  alias Heaters.Repo
  alias Heaters.Media.{Cut, Clip}
  alias Heaters.Media.Cuts.Validation
  require Logger

  @doc """
  Add a cut point within an existing segment, splitting it into two segments.

  Creates a new cut at the specified frame, archives the existing clip that
  contains this frame, and creates two new clips representing the split segments.

  ## Parameters
  - `source_video_id`: ID of the source video
  - `frame_number`: Frame number where to add the cut (must be within existing segment)
  - `user_id`: ID of the user performing the operation
  - `opts`: Optional parameters
    - `:metadata`: Additional metadata for the operation

  ## Returns
  - `{:ok, {first_clip, second_clip}}` on successful split
  - `{:error, reason}` on validation or operation failure

  ## Examples

      iex> Operations.add_cut(123, 150, 456)
      {:ok, {%Clip{start_frame: 100, end_frame: 150}, %Clip{start_frame: 150, end_frame: 200}}}

      iex> Operations.add_cut(123, 50, 456)  # Frame not in any segment
      {:error, "Frame 50 is not within any existing segment"}
  """
  @spec add_cut(integer(), integer(), integer() | nil, keyword()) ::
          {:ok, {Clip.t(), Clip.t()}} | {:error, String.t()}
  def add_cut(source_video_id, frame_number, user_id, opts \\ []) do
    Logger.info("Adding cut at frame #{frame_number} for source_video_id #{source_video_id}")

    params = %{frame_number: frame_number, user_id: user_id}

    with :ok <- Validation.validate_operation(:add_cut, source_video_id, params),
         {:ok, result} <- execute_add_cut(source_video_id, frame_number, user_id, opts) do
      Logger.info("Successfully added cut at frame #{frame_number}")
      {:ok, result}
    else
      {:error, reason} ->
        Logger.warning("Failed to add cut at frame #{frame_number}: #{reason}")
        {:error, reason}
    end
  end

  @doc """
  Remove a cut point between two adjacent segments, merging them.

  Removes the cut at the specified frame, archives the two clips adjacent to
  this cut, and creates a single merged clip representing the combined segment.

  ## Parameters
  - `source_video_id`: ID of the source video
  - `frame_number`: Frame number of the cut to remove
  - `user_id`: ID of the user performing the operation
  - `opts`: Optional parameters
    - `:metadata`: Additional metadata for the operation

  ## Returns
  - `{:ok, merged_clip}` on successful merge
  - `{:error, reason}` on validation or operation failure

  ## Examples

      iex> Operations.remove_cut(123, 150, 456)
      {:ok, %Clip{start_frame: 100, end_frame: 200}}

      iex> Operations.remove_cut(123, 999, 456)  # Cut doesn't exist
      {:error, "No cut exists at frame 999"}
  """
  @spec remove_cut(integer(), integer(), integer() | nil, keyword()) ::
          {:ok, Clip.t()} | {:error, String.t()}
  def remove_cut(source_video_id, frame_number, user_id, opts \\ []) do
    Logger.info("Removing cut at frame #{frame_number} for source_video_id #{source_video_id}")

    params = %{frame_number: frame_number, user_id: user_id}

    with :ok <- Validation.validate_operation(:remove_cut, source_video_id, params),
         {:ok, result} <- execute_remove_cut(source_video_id, frame_number, user_id, opts) do
      Logger.info("Successfully removed cut at frame #{frame_number}")
      {:ok, result}
    else
      {:error, reason} ->
        Logger.warning("Failed to remove cut at frame #{frame_number}: #{reason}")
        {:error, reason}
    end
  end

  @doc """
  Move a cut point from one frame to another, adjusting adjacent segment boundaries.

  Updates the cut position and adjusts the boundaries of the two clips that
  are adjacent to this cut. The clips maintain their identity but get updated
  boundaries.

  ## Parameters
  - `source_video_id`: ID of the source video
  - `old_frame`: Current frame number of the cut
  - `new_frame`: New frame number for the cut
  - `user_id`: ID of the user performing the operation
  - `opts`: Optional parameters
    - `:metadata`: Additional metadata for the operation

  ## Returns
  - `{:ok, {first_clip, second_clip}}` on successful move
  - `{:error, reason}` on validation or operation failure

  ## Examples

      iex> Operations.move_cut(123, 150, 160, 456)
      {:ok, {%Clip{end_frame: 160}, %Clip{start_frame: 160}}}

      iex> Operations.move_cut(123, 150, 50, 456)  # Outside bounds
      {:error, "New frame 50 is outside bounds [100, 200]"}
  """
  @spec move_cut(integer(), integer(), integer(), integer() | nil, keyword()) ::
          {:ok, {Clip.t(), Clip.t()}} | {:error, String.t()}
  def move_cut(source_video_id, old_frame, new_frame, user_id, opts \\ []) do
    Logger.info(
      "Moving cut from frame #{old_frame} to #{new_frame} for source_video_id #{source_video_id}"
    )

    params = %{old_frame: old_frame, new_frame: new_frame, user_id: user_id}

    with :ok <- Validation.validate_operation(:move_cut, source_video_id, params),
         {:ok, result} <- execute_move_cut(source_video_id, old_frame, new_frame, user_id, opts) do
      Logger.info("Successfully moved cut from frame #{old_frame} to #{new_frame}")
      {:ok, result}
    else
      {:error, reason} ->
        Logger.warning("Failed to move cut from frame #{old_frame} to #{new_frame}: #{reason}")
        {:error, reason}
    end
  end

  @doc """
  Create initial cuts from scene detection results.

  This is used during the scene detection pipeline stage to create the initial
  set of cuts that define the segments for human review.

  ## Parameters
  - `source_video_id`: ID of the source video
  - `cut_points`: List of cut point maps from scene detection
    - Each map should have: `%{"frame_number" => integer(), "time_seconds" => float()}`
  - `metadata`: Optional metadata from scene detection process

  ## Returns
  - `{:ok, {cuts, clips}}` on successful creation
  - `{:error, reason}` on validation or creation failure

  ## Examples

      cut_points = [
        %{"frame_number" => 100, "time_seconds" => 4.0},
        %{"frame_number" => 200, "time_seconds" => 8.0}
      ]

      {:ok, {cuts, clips}} = Operations.create_initial_cuts(123, cut_points, %{})
  """
  @spec create_initial_cuts(integer(), [map()], map()) ::
          {:ok, {[Cut.t()], [Clip.t()]}} | {:error, String.t()}
  def create_initial_cuts(source_video_id, cut_points, metadata \\ %{}) do
    Logger.info(
      "Creating initial cuts from scene detection: #{length(cut_points)} cuts for source_video_id #{source_video_id}"
    )

    case Repo.transaction(fn ->
           with {:ok, cuts} <- create_cuts_from_scene_detection(source_video_id, cut_points, metadata),
                {:ok, clips} <- create_clips_from_cuts(source_video_id, cuts) do
             Logger.info(
               "Successfully created #{length(cuts)} cuts and #{length(clips)} clips for source_video_id #{source_video_id}"
             )

             {cuts, clips}
           else
             {:error, reason} ->
               Logger.error("Failed to create initial cuts: #{reason}")
               Repo.rollback(reason)
           end
         end) do
      {:ok, {cuts, clips}} -> {:ok, {cuts, clips}}
      {:error, reason} -> {:error, reason}
    end
  end

  ## Private Implementation Functions

  @spec execute_add_cut(integer(), integer(), integer(), keyword()) ::
          {:ok, {Clip.t(), Clip.t()}} | {:error, String.t()}
  defp execute_add_cut(source_video_id, frame_number, user_id, opts) do
    case Repo.transaction(fn ->
           source_video = Repo.get!(Heaters.Media.Video, source_video_id)

           with {:ok, cut} <- create_cut(source_video_id, frame_number, source_video, user_id, opts),
                {:ok, containing_clip} <- find_containing_clip(source_video_id, frame_number),
                {:ok, {first_clip, second_clip}} <-
                  split_clip_at_cut(containing_clip, cut, user_id, opts) do

             {first_clip, second_clip}
           else
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, {first_clip, second_clip}} -> {:ok, {first_clip, second_clip}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec execute_remove_cut(integer(), integer(), integer(), keyword()) ::
          {:ok, Clip.t()} | {:error, String.t()}
  defp execute_remove_cut(source_video_id, frame_number, user_id, opts) do
    case Repo.transaction(fn ->
           with {:ok, cut} <- find_cut_to_remove(source_video_id, frame_number),
                {:ok, {left_clip, right_clip}} <- find_adjacent_clips(source_video_id, frame_number),
                {:ok, merged_clip} <- merge_clips(left_clip, right_clip, user_id, opts),
                :ok <- delete_cut(cut) do

             merged_clip
           else
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, merged_clip} -> {:ok, merged_clip}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec execute_move_cut(integer(), integer(), integer(), integer(), keyword()) ::
          {:ok, {Clip.t(), Clip.t()}} | {:error, String.t()}
  defp execute_move_cut(source_video_id, old_frame, new_frame, user_id, opts) do
    case Repo.transaction(fn ->
           source_video = Repo.get!(Heaters.Media.Video, source_video_id)

           with {:ok, cut} <- find_cut_to_move(source_video_id, old_frame),
                {:ok, {left_clip, right_clip}} <- find_adjacent_clips(source_video_id, old_frame),
                {:ok, updated_cut} <- update_cut_position(cut, new_frame, source_video, user_id, opts),
                {:ok, {updated_left, updated_right}} <-
                  update_adjacent_clips(left_clip, right_clip, updated_cut, user_id, opts) do

             {updated_left, updated_right}
           else
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, {updated_left, updated_right}} -> {:ok, {updated_left, updated_right}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec create_cuts_from_scene_detection(integer(), [map()], map()) ::
          {:ok, [Cut.t()]} | {:error, String.t()}
  defp create_cuts_from_scene_detection(source_video_id, cut_points, metadata) do
    source_video = Repo.get!(Heaters.Media.Video, source_video_id)

    # Validate cut points format
    with :ok <- validate_scene_detection_format(cut_points) do
      # Create cuts from scene detection data
      cuts =
        cut_points
        |> Enum.with_index()
        |> Enum.map(fn {cut_point, index} ->
          create_cut_from_scene_detection(source_video_id, cut_point, source_video, index, metadata)
        end)

      # Check for any errors
      case Enum.split_with(cuts, fn
             {:ok, _} -> true
             {:error, _} -> false
           end) do
        {successes, []} ->
          actual_cuts = Enum.map(successes, fn {:ok, cut} -> cut end)
          {:ok, actual_cuts}

        {_, errors} ->
          first_error = errors |> List.first() |> elem(1)
          {:error, first_error}
      end
    end
  end

  @spec create_clips_from_cuts(integer(), [Cut.t()]) :: {:ok, [Clip.t()]} | {:error, String.t()}
  defp create_clips_from_cuts(source_video_id, _cuts) do
    source_video = Repo.get!(Heaters.Media.Video, source_video_id)
    segments = Cut.derive_clips_from_cuts(source_video_id, source_video)

    # Create clips from segments
    clips =
      segments
      |> Enum.with_index()
      |> Enum.map(fn {segment, index} ->
        create_clip_from_segment(segment, index)
      end)

    # Check for any errors
    case Enum.split_with(clips, fn
           {:ok, _} -> true
           {:error, _} -> false
         end) do
      {successes, []} ->
        actual_clips = Enum.map(successes, fn {:ok, clip} -> clip end)
        {:ok, actual_clips}

      {_, errors} ->
        first_error = errors |> List.first() |> elem(1)
        {:error, first_error}
    end
  end

  @spec create_cut(integer(), integer(), Heaters.Media.Video.t(), integer(), keyword()) ::
          {:ok, Cut.t()} | {:error, String.t()}
  defp create_cut(source_video_id, frame_number, source_video, user_id, opts) do
    # Calculate time from frame number
    time_seconds =
      if source_video.fps do
        frame_number / source_video.fps
      else
        # Fallback estimation if FPS not available
        frame_number * 0.033333
      end

    metadata = Keyword.get(opts, :metadata, %{})

    attrs = %{
      source_video_id: source_video_id,
      frame_number: frame_number,
      time_seconds: time_seconds,
      created_by_user_id: user_id,
      operation_metadata: Map.merge(metadata, %{operation: "add_cut", created_at: DateTime.utc_now()})
    }

    case %Cut{}
         |> Cut.changeset(attrs)
         |> Repo.insert() do
      {:ok, cut} -> {:ok, cut}
      {:error, changeset} -> {:error, "Failed to create cut: #{inspect(changeset.errors)}"}
    end
  end

  @spec find_containing_clip(integer(), integer()) :: {:ok, Clip.t()} | {:error, String.t()}
  defp find_containing_clip(source_video_id, frame_number) do
    # Find active clip that contains this frame
    case from(c in Clip,
           where:
             c.source_video_id == ^source_video_id and
               c.ingest_state != "archived" and
               c.start_frame < ^frame_number and
               c.end_frame > ^frame_number
         )
         |> Repo.one() do
      %Clip{} = clip -> {:ok, clip}
      nil -> {:error, "No active clip contains frame #{frame_number}"}
    end
  end

  @spec split_clip_at_cut(Clip.t(), Cut.t(), integer(), keyword()) ::
          {:ok, {Clip.t(), Clip.t()}} | {:error, String.t()}
  defp split_clip_at_cut(original_clip, cut, user_id, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    # Archive original clip
    case original_clip
         |> Clip.changeset(%{
           ingest_state: "archived",
           processing_metadata:
             Map.merge(original_clip.processing_metadata || %{}, %{
               archived_reason: "split_operation",
               archived_at: DateTime.utc_now(),
               archived_by_user_id: user_id
             })
         })
         |> Repo.update() do
      {:ok, _archived} ->
        # Create two new clips
        with {:ok, first_clip} <-
               create_clip_from_split(original_clip, cut, :first, user_id, metadata),
             {:ok, second_clip} <-
               create_clip_from_split(original_clip, cut, :second, user_id, metadata) do
          {:ok, {first_clip, second_clip}}
        end

      {:error, changeset} ->
        {:error, "Failed to archive original clip: #{inspect(changeset.errors)}"}
    end
  end

  @spec create_clip_from_split(Clip.t(), Cut.t(), :first | :second, integer(), map()) ::
          {:ok, Clip.t()} | {:error, String.t()}
  defp create_clip_from_split(original_clip, cut, position, user_id, metadata) do
    {start_frame, end_frame, start_time, end_time, suffix} =
      case position do
        :first ->
          {
            original_clip.start_frame,
            cut.frame_number,
            original_clip.start_time_seconds,
            cut.time_seconds,
            "split_first"
          }

        :second ->
          {
            cut.frame_number,
            original_clip.end_frame,
            cut.time_seconds,
            original_clip.end_time_seconds,
            "split_second"
          }
      end

    timestamp = System.system_time(:millisecond)
    clip_identifier = "#{original_clip.source_video_id}_#{suffix}_#{timestamp}"

    attrs = %{
      source_video_id: original_clip.source_video_id,
      clip_identifier: clip_identifier,
      start_frame: start_frame,
      end_frame: end_frame,
      start_time_seconds: start_time,
      end_time_seconds: end_time,
      ingest_state: "pending_review",
      processing_metadata:
        Map.merge(metadata, %{
          created_by_user_id: user_id,
          operation_type: "split_#{position}",
          original_clip_id: original_clip.id,
          created_at: DateTime.utc_now()
        })
    }

    case %Clip{}
         |> Clip.changeset(attrs)
         |> Repo.insert() do
      {:ok, clip} -> {:ok, clip}
      {:error, changeset} -> {:error, "Failed to create #{position} clip: #{inspect(changeset.errors)}"}
    end
  end

  @spec find_cut_to_remove(integer(), integer()) :: {:ok, Cut.t()} | {:error, String.t()}
  defp find_cut_to_remove(source_video_id, frame_number) do
    Cut.find_cut_at_frame(source_video_id, frame_number)
  end

  @spec find_adjacent_clips(integer(), integer()) ::
          {:ok, {Clip.t(), Clip.t()}} | {:error, String.t()}
  defp find_adjacent_clips(source_video_id, frame_number) do
    # Find clip that ends at this frame
    left_clip =
      from(c in Clip,
        where:
          c.source_video_id == ^source_video_id and
            c.ingest_state != "archived" and
            c.end_frame == ^frame_number
      )
      |> Repo.one()

    # Find clip that starts at this frame  
    right_clip =
      from(c in Clip,
        where:
          c.source_video_id == ^source_video_id and
            c.ingest_state != "archived" and
            c.start_frame == ^frame_number
      )
      |> Repo.one()

    case {left_clip, right_clip} do
      {%Clip{} = left, %Clip{} = right} ->
        {:ok, {left, right}}

      {nil, _} ->
        {:error, "No clip ends at frame #{frame_number}"}

      {_, nil} ->
        {:error, "No clip starts at frame #{frame_number}"}
    end
  end

  @spec merge_clips(Clip.t(), Clip.t(), integer(), keyword()) :: {:ok, Clip.t()} | {:error, String.t()}
  defp merge_clips(left_clip, right_clip, user_id, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    # Archive both clips
    Enum.each([left_clip, right_clip], fn clip ->
      clip
      |> Clip.changeset(%{
        ingest_state: "archived",
        processing_metadata:
          Map.merge(clip.processing_metadata || %{}, %{
            archived_reason: "merge_operation",
            archived_at: DateTime.utc_now(),
            archived_by_user_id: user_id
          })
      })
      |> Repo.update!()
    end)

    # Create merged clip
    timestamp = System.system_time(:millisecond)
    clip_identifier = "#{left_clip.source_video_id}_merged_#{timestamp}"

    attrs = %{
      source_video_id: left_clip.source_video_id,
      clip_identifier: clip_identifier,
      start_frame: left_clip.start_frame,
      end_frame: right_clip.end_frame,
      start_time_seconds: left_clip.start_time_seconds,
      end_time_seconds: right_clip.end_time_seconds,
      ingest_state: "pending_review",
      processing_metadata:
        Map.merge(metadata, %{
          created_by_user_id: user_id,
          operation_type: "merge_result",
          original_clip_ids: [left_clip.id, right_clip.id],
          created_at: DateTime.utc_now()
        })
    }

    case %Clip{}
         |> Clip.changeset(attrs)
         |> Repo.insert() do
      {:ok, clip} -> {:ok, clip}
      {:error, changeset} -> {:error, "Failed to create merged clip: #{inspect(changeset.errors)}"}
    end
  end

  @spec delete_cut(Cut.t()) :: :ok | {:error, String.t()}
  defp delete_cut(cut) do
    case Repo.delete(cut) do
      {:ok, _deleted} -> :ok
      {:error, changeset} -> {:error, "Failed to delete cut: #{inspect(changeset.errors)}"}
    end
  end

  @spec find_cut_to_move(integer(), integer()) :: {:ok, Cut.t()} | {:error, String.t()}
  defp find_cut_to_move(source_video_id, frame_number) do
    Cut.find_cut_at_frame(source_video_id, frame_number)
  end

  @spec update_cut_position(Cut.t(), integer(), Heaters.Media.Video.t(), integer(), keyword()) ::
          {:ok, Cut.t()} | {:error, String.t()}
  defp update_cut_position(cut, new_frame, source_video, user_id, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    # Calculate new time
    new_time =
      if source_video.fps do
        new_frame / source_video.fps
      else
        new_frame * 0.033333
      end

    attrs = %{
      frame_number: new_frame,
      time_seconds: new_time,
      operation_metadata:
        Map.merge(cut.operation_metadata || %{}, 
          Map.merge(metadata, %{
            last_moved_by_user_id: user_id,
            last_moved_at: DateTime.utc_now(),
            operation: "move_cut"
          })
        )
    }

    case cut
         |> Cut.changeset(attrs)
         |> Repo.update() do
      {:ok, updated_cut} -> {:ok, updated_cut}
      {:error, changeset} -> {:error, "Failed to update cut: #{inspect(changeset.errors)}"}
    end
  end

  @spec update_adjacent_clips(Clip.t(), Clip.t(), Cut.t(), integer(), keyword()) ::
          {:ok, {Clip.t(), Clip.t()}} | {:error, String.t()}
  defp update_adjacent_clips(left_clip, right_clip, updated_cut, user_id, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    # Update left clip (ends at new cut position)
    left_attrs = %{
      end_frame: updated_cut.frame_number,
      end_time_seconds: updated_cut.time_seconds,
      processing_metadata:
        Map.merge(left_clip.processing_metadata || %{}, 
          Map.merge(metadata, %{
            last_modified_by_user_id: user_id,
            last_modified_at: DateTime.utc_now(),
            operation: "move_cut_adjust"
          })
        )
    }

    # Update right clip (starts at new cut position)
    right_attrs = %{
      start_frame: updated_cut.frame_number,
      start_time_seconds: updated_cut.time_seconds,
      processing_metadata:
        Map.merge(right_clip.processing_metadata || %{}, 
          Map.merge(metadata, %{
            last_modified_by_user_id: user_id,
            last_modified_at: DateTime.utc_now(),
            operation: "move_cut_adjust"
          })
        )
    }

    with {:ok, updated_left} <- left_clip |> Clip.changeset(left_attrs) |> Repo.update(),
         {:ok, updated_right} <- right_clip |> Clip.changeset(right_attrs) |> Repo.update() do
      {:ok, {updated_left, updated_right}}
    else
      {:error, changeset} -> {:error, "Failed to update adjacent clips: #{inspect(changeset.errors)}"}
    end
  end

  @spec validate_scene_detection_format([map()]) :: :ok | {:error, String.t()}
  defp validate_scene_detection_format(cut_points) when is_list(cut_points) do
    case Enum.find(cut_points, fn cut_point ->
           not (is_map(cut_point) and
                  Map.has_key?(cut_point, "frame_number") and
                  Map.has_key?(cut_point, "time_seconds") and
                  is_integer(cut_point["frame_number"]) and
                  is_number(cut_point["time_seconds"]))
         end) do
      nil -> :ok
      _invalid -> {:error, "Invalid cut point format"}
    end
  end

  defp validate_scene_detection_format(_), do: {:error, "Cut points must be a list"}

  @spec create_cut_from_scene_detection(integer(), map(), Heaters.Media.Video.t(), integer(), map()) ::
          {:ok, Cut.t()} | {:error, String.t()}
  defp create_cut_from_scene_detection(source_video_id, cut_point, _source_video, index, metadata) do
    attrs = %{
      source_video_id: source_video_id,
      frame_number: cut_point["frame_number"],
      time_seconds: cut_point["time_seconds"],
      created_by_user_id: nil,  # System-generated
      operation_metadata: Map.merge(metadata, %{
        source: "scene_detection",
        detection_index: index,
        created_at: DateTime.utc_now()
      })
    }

    case %Cut{}
         |> Cut.changeset(attrs)
         |> Repo.insert() do
      {:ok, cut} -> {:ok, cut}
      {:error, changeset} -> {:error, "Failed to create cut from scene detection: #{inspect(changeset.errors)}"}
    end
  end

  @spec create_clip_from_segment(map(), integer()) :: {:ok, Clip.t()} | {:error, String.t()}
  defp create_clip_from_segment(segment, index) do
    clip_identifier = "#{segment.source_video_id}_segment_#{String.pad_leading(to_string(index + 1), 3, "0")}"

    attrs = %{
      source_video_id: segment.source_video_id,
      clip_identifier: clip_identifier,
      start_frame: segment.start_frame,
      end_frame: segment.end_frame,
      start_time_seconds: segment.start_time_seconds,
      end_time_seconds: segment.end_time_seconds,
      ingest_state: "pending_review",
      processing_metadata: %{
        created_from: "scene_detection",
        segment_index: index,
        created_at: DateTime.utc_now()
      }
    }

    case %Clip{}
         |> Clip.changeset(attrs)
         |> Repo.insert() do
      {:ok, clip} -> {:ok, clip}
      {:error, changeset} -> {:error, "Failed to create clip from segment: #{inspect(changeset.errors)}"}
    end
  end

end