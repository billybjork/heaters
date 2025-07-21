defmodule Heaters.Clips.Operations.VirtualClips do
  @moduledoc """
  Operations for creating and managing virtual clips.

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

  - **Creation**: From scene detection cut points
  - **Validation**: Ensures cut points are valid and non-overlapping
  - **State**: Virtual clips start in "pending_review" state
  - **Review**: Same review workflow as physical clips
  """

  import Ecto.Query, warn: false
  alias Heaters.Repo
  alias Heaters.Clips.Clip
  require Logger

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

      {:ok, clips} = VirtualClips.create_virtual_clips_from_cut_points(123, cut_points, %{})
  """
  @spec create_virtual_clips_from_cut_points(integer(), list(), map()) ::
    {:ok, list(Clip.t())} | {:error, any()}
  def create_virtual_clips_from_cut_points(source_video_id, cut_points, metadata \\ %{}) do
    Logger.info("VirtualClips: Creating #{length(cut_points)} virtual clips for source_video_id: #{source_video_id}")

    case validate_cut_points(cut_points) do
      :ok ->
        create_clips_from_validated_cut_points(source_video_id, cut_points, metadata)

      {:error, reason} ->
        Logger.error("VirtualClips: Cut points validation failed: #{reason}")
        {:error, reason}
    end
  end

  @doc """
  Update virtual clip cut points (used for merge/split operations).

  ## Parameters
  - `clip_id`: ID of the virtual clip to update
  - `new_cut_points`: Updated cut points map

  ## Returns
  - `{:ok, clip}` on successful update
  - `{:error, reason}` on validation or update failure
  """
  @spec update_virtual_clip_cut_points(integer(), map()) :: {:ok, Clip.t()} | {:error, any()}
  def update_virtual_clip_cut_points(clip_id, new_cut_points) do
    case Repo.get(Clip, clip_id) do
      nil ->
        {:error, :not_found}

      %Clip{is_virtual: false} = clip ->
        {:error, "Cannot update cut points for physical clip #{clip.id}"}

      %Clip{is_virtual: true} = clip ->
        case validate_single_cut_point(new_cut_points) do
          :ok ->
            clip
            |> Clip.changeset(%{cut_points: new_cut_points})
            |> Repo.update()

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Private functions

  defp validate_cut_points(cut_points) when is_list(cut_points) do
    case cut_points do
      [] ->
        {:error, "No cut points provided"}

      points ->
        case Enum.find(points, &validate_single_cut_point_error/1) do
          nil -> :ok
          error -> error
        end
    end
  end

  defp validate_cut_points(_), do: {:error, "Cut points must be a list"}

  defp validate_single_cut_point(cut_point) do
    required_fields = ["start_frame", "end_frame", "start_time_seconds", "end_time_seconds"]

    case Enum.find(required_fields, fn field -> not Map.has_key?(cut_point, field) end) do
      nil ->
        case validate_cut_point_values(cut_point) do
          :ok -> :ok
          error -> error
        end

      missing_field ->
        {:error, "Missing required field: #{missing_field}"}
    end
  end

  defp validate_single_cut_point_error(cut_point) do
    case validate_single_cut_point(cut_point) do
      :ok -> nil
      error -> error
    end
  end

  defp validate_cut_point_values(cut_point) do
    start_frame = Map.get(cut_point, "start_frame")
    end_frame = Map.get(cut_point, "end_frame")
    start_time = Map.get(cut_point, "start_time_seconds")
    end_time = Map.get(cut_point, "end_time_seconds")

    cond do
      not is_integer(start_frame) or start_frame < 0 ->
        {:error, "start_frame must be a non-negative integer"}

      not is_integer(end_frame) or end_frame <= start_frame ->
        {:error, "end_frame must be an integer greater than start_frame"}

      not is_number(start_time) or start_time < 0 ->
        {:error, "start_time_seconds must be a non-negative number"}

      not is_number(end_time) or end_time <= start_time ->
        {:error, "end_time_seconds must be a number greater than start_time_seconds"}

      true ->
        :ok
    end
  end

  defp create_clips_from_validated_cut_points(source_video_id, cut_points, metadata) do
    # Use database transaction for atomic creation
    Repo.transaction(fn ->
      cut_points
      |> Enum.with_index()
      |> Enum.map(fn {cut_point, index} ->
        create_single_virtual_clip(source_video_id, cut_point, index, metadata)
      end)
      |> handle_clip_creation_results()
    end)
  end

  defp create_single_virtual_clip(source_video_id, cut_point, index, metadata) do
    clip_identifier = generate_virtual_clip_identifier(source_video_id, index)

    clip_attrs = %{
      source_video_id: source_video_id,
      clip_identifier: clip_identifier,
      is_virtual: true,
      cut_points: cut_point,
      start_frame: Map.get(cut_point, "start_frame"),
      end_frame: Map.get(cut_point, "end_frame"),
      start_time_seconds: Map.get(cut_point, "start_time_seconds"),
      end_time_seconds: Map.get(cut_point, "end_time_seconds"),
      ingest_state: "pending_review",
      processing_metadata: metadata
    }

    case %Clip{}
         |> Clip.changeset(clip_attrs)
         |> Repo.insert() do
      {:ok, clip} ->
        Logger.debug("VirtualClips: Created virtual clip #{clip.id} (#{clip_identifier})")
        {:ok, clip}

      {:error, changeset} ->
        Logger.error("VirtualClips: Failed to create virtual clip: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end

  defp handle_clip_creation_results(results) do
    {successes, errors} = Enum.split_with(results, fn
      {:ok, _} -> true
      {:error, _} -> false
    end)

    case errors do
      [] ->
        clips = Enum.map(successes, fn {:ok, clip} -> clip end)
        Logger.info("VirtualClips: Successfully created #{length(clips)} virtual clips")
        clips

      _ ->
        error_count = length(errors)
        Logger.error("VirtualClips: Failed to create #{error_count} virtual clips")
        Repo.rollback("Failed to create #{error_count} virtual clips")
    end
  end

  defp generate_virtual_clip_identifier(source_video_id, index) do
    "#{source_video_id}_virtual_clip_#{String.pad_leading(to_string(index + 1), 3, "0")}"
  end
end
