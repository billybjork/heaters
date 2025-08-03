defmodule Heaters.Media.VirtualClip do
  @moduledoc """
  Core operations for creating and managing virtual clips.

  Virtual clips are database records with cut points but no physical files.
  They enable instant merge/split operations during review and are only
  encoded to physical files during the final export stage.

  ## Virtual vs Physical Clips

  - **Virtual clips**: Database records with cut_points JSON, no clip_filepath
  - **Physical clips**: Database records with clip_filepath, created during export
  - **Transition**: Virtual clips become physical via export worker

  ## Cut Points Format

  Cut points are stored as JSON with both frame and time information:
  ```json
  {
    "start_frame": 0,
    "end_frame": 150,
    "start_time_seconds": 0.0,
    "end_time_seconds": 5.0
  }
  ```

  ## Architecture

  - **Core Creation**: This module handles virtual clip creation from scene detection
  - **Cut Point Operations**: Delegated to `VirtualClip.CutPointOperations`
  - **MECE Validation**: Delegated to `VirtualClip.Validation`
  - **Audit Trail**: Handled by `VirtualClip.CutPointOperation` schema

  ## Module Organization

  - **`VirtualClip`** (this module) - Core creation and basic management
  - **`VirtualClip.CutPointOperations`** - Add/remove/move cut point operations
  - **`VirtualClip.Validation`** - MECE validation and coverage checking
  - **`VirtualClip.CutPointOperation`** - Audit trail schema
  """

  import Ecto.Query, warn: false
  alias Heaters.Repo
  alias Heaters.Media.Clip
  alias Heaters.Media.VirtualClip.{CutPointOperations, Validation}

  require Logger

  # Delegate cut point operations to specialized module
  defdelegate add_cut_point(source_video_id, frame_number, user_id), to: CutPointOperations
  defdelegate remove_cut_point(source_video_id, frame_number, user_id), to: CutPointOperations

  defdelegate move_cut_point(source_video_id, old_frame, new_frame, user_id),
    to: CutPointOperations

  # Delegate MECE validation to specialized module
  defdelegate validate_mece_for_source_video(source_video_id), to: Validation
  defdelegate get_cut_points_for_source_video(source_video_id), to: Validation

  defdelegate ensure_complete_coverage(source_video_id, total_duration_seconds),
    to: Validation

  @doc """
  Create virtual clip records from scene detection cut points.

  ## Parameters
  - `source_video_id`: ID of the source video
  - `cut_points`: List of cut point maps from scene detection
  - `metadata`: Additional metadata from scene detection

  ## Returns
  - `{:ok, clips}` on successful creation
  - `{:error, reason}` on validation or creation failure

  ## Examples

      cut_points = [
        %{"start_frame" => 0, "end_frame" => 150, "start_time_seconds" => 0.0, "end_time_seconds" => 5.0},
        %{"start_frame" => 150, "end_frame" => 300, "start_time_seconds" => 5.0, "end_time_seconds" => 10.0}
      ]

      {:ok, clips} = VirtualClip.create_virtual_clips_from_cut_points(123, cut_points, %{})
  """
  @spec create_virtual_clips_from_cut_points(integer(), list(), map()) ::
          {:ok, list(Clip.t())} | {:error, any()}
  def create_virtual_clips_from_cut_points(source_video_id, cut_points, metadata \\ %{}) do
    CutPointOperations.create_virtual_clips_from_cut_points(source_video_id, cut_points, metadata)
  end

  @doc """
  Get all virtual clips for a source video, ordered by start frame.
  """
  @spec get_virtual_clips_for_source(integer()) :: [Clip.t()]
  def get_virtual_clips_for_source(source_video_id) do
    query =
      from(c in Clip,
        where:
          c.source_video_id == ^source_video_id and c.is_virtual == true and
            c.ingest_state != "archived",
        order_by: [asc: c.start_frame]
      )

    Repo.all(query)
  end
end
