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
  """

  import Ecto.Query, warn: false
  alias Heaters.Repo
  alias Heaters.Media.Clip
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

      {:ok, clips} = VirtualClip.create_virtual_clips_from_cut_points(123, cut_points, %{})
  """
  @spec create_virtual_clips_from_cut_points(integer(), list(), map()) ::
          {:ok, list(Clip.t())} | {:error, any()}
  def create_virtual_clips_from_cut_points(source_video_id, cut_points, metadata \\ %{}) do
    Logger.info(
      "VirtualClip: Creating #{length(cut_points)} virtual clips for source_video_id: #{source_video_id}"
    )

    # IDEMPOTENCY: Check if virtual clips already exist for this source video
    case get_existing_virtual_clips(source_video_id) do
      [] ->
        # No existing clips, create new ones
        case validate_cut_points(cut_points) do
          :ok ->
            create_clips_from_validated_cut_points(source_video_id, cut_points, metadata)

          {:error, reason} ->
            Logger.error("VirtualClip: Cut points validation failed: #{reason}")
            {:error, reason}
        end

      existing_clips ->
        # Virtual clips already exist, return them
        Logger.info(
          "VirtualClip: Found #{length(existing_clips)} existing virtual clips for source_video_id: #{source_video_id}"
        )

        {:ok, existing_clips}
    end
  end

  @doc """
  Get all virtual clips for a source video.

  ## Parameters
  - `source_video_id`: ID of the source video

  ## Returns
  - List of virtual clips ordered by ID
  """
  @spec get_virtual_clips_for_source(integer()) :: list(Clip.t())
  def get_virtual_clips_for_source(source_video_id) do
    from(c in Clip,
      where: c.source_video_id == ^source_video_id and c.is_virtual == true,
      order_by: [asc: c.id]
    )
    |> Repo.all()
  end

  # Private functions for core creation logic

  defp get_existing_virtual_clips(source_video_id) do
    get_virtual_clips_for_source(source_video_id)
  end

  defp validate_cut_points(cut_points) when is_list(cut_points) do
    case cut_points do
      [] ->
        {:error, "No cut points provided"}

      points ->
        case Enum.find(points, &validate_single_cut_point_error/1) do
          nil -> :ok
          {:error, reason} -> {:error, reason}
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
    # Check if clips already exist BEFORE starting transaction (idempotency)
    expected_identifiers =
      Enum.with_index(cut_points)
      |> Enum.map(fn {_cut_point, index} ->
        generate_virtual_clip_identifier(source_video_id, index)
      end)

    existing_clips =
      from(c in Clip,
        where: c.clip_identifier in ^expected_identifiers,
        order_by: [asc: c.id]
      )
      |> Repo.all()

    case existing_clips do
      [] ->
        # No existing clips, proceed with creation in transaction
        Repo.transaction(fn ->
          cut_points
          |> Enum.with_index()
          |> Enum.map(fn {cut_point, index} ->
            create_single_virtual_clip(source_video_id, cut_point, index, metadata)
          end)
          |> handle_clip_creation_results()
        end)

      clips when length(clips) == length(cut_points) ->
        # All expected clips exist, return them (idempotent)
        Logger.info(
          "VirtualClip: Found all #{length(clips)} existing virtual clips for source_video_id: #{source_video_id}"
        )

        {:ok, clips}

      partial_clips ->
        # Partial creation scenario - this shouldn't happen but handle gracefully
        Logger.warning(
          "VirtualClip: Found #{length(partial_clips)} of #{length(cut_points)} expected clips - cleaning up and retrying"
        )

        # Delete partial clips and retry
        clip_ids = Enum.map(partial_clips, & &1.id)
        Repo.delete_all(from(c in Clip, where: c.id in ^clip_ids))

        # Retry creation
        Repo.transaction(fn ->
          cut_points
          |> Enum.with_index()
          |> Enum.map(fn {cut_point, index} ->
            create_single_virtual_clip(source_video_id, cut_point, index, metadata)
          end)
          |> handle_clip_creation_results()
        end)
    end
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
      source_video_order: index + 1,
      cut_point_version: 1,
      processing_metadata: metadata
    }

    case %Clip{}
         |> Clip.changeset(clip_attrs)
         |> Repo.insert() do
      {:ok, clip} ->
        Logger.debug("VirtualClip: Created virtual clip #{clip.id} (#{clip_identifier})")
        {:ok, clip}

      {:error, changeset} ->
        # Check if this is a unique constraint error (idempotency fallback)
        case changeset.errors do
          [
            clip_identifier:
              {"has already been taken",
               [constraint: :unique, constraint_name: "clips_clip_identifier_key"]}
          ] ->
            # This clip already exists, try to find it
            case Repo.get_by(Clip, clip_identifier: Map.get(clip_attrs, :clip_identifier)) do
              %Clip{} = existing_clip ->
                Logger.debug(
                  "VirtualClip: Found existing virtual clip #{existing_clip.id} (#{existing_clip.clip_identifier})"
                )

                {:ok, existing_clip}

              nil ->
                Logger.error(
                  "VirtualClip: Unique constraint error but clip not found: #{inspect(changeset.errors)}"
                )

                {:error, changeset}
            end

          _ ->
            Logger.error(
              "VirtualClip: Failed to create virtual clip: #{inspect(changeset.errors)}"
            )

            {:error, changeset}
        end
    end
  end

  defp handle_clip_creation_results(results) do
    {successes, errors} =
      Enum.split_with(results, fn
        {:ok, _} -> true
        {:error, _} -> false
      end)

    case errors do
      [] ->
        clips = Enum.map(successes, fn {:ok, clip} -> clip end)
        Logger.info("VirtualClip: Successfully created #{length(clips)} virtual clips")
        clips

      _ ->
        error_count = length(errors)
        Logger.error("VirtualClip: Failed to create #{error_count} virtual clips")
        Repo.rollback("Failed to create #{error_count} virtual clips")
    end
  end

  defp generate_virtual_clip_identifier(source_video_id, index) do
    "#{source_video_id}_virtual_clip_#{String.pad_leading(to_string(index + 1), 3, "0")}"
  end
end
