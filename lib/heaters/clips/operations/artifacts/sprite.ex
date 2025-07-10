defmodule Heaters.Clips.Operations.Artifacts.Sprite do
  @moduledoc """
  Sprite sheet generation operations - I/O orchestration.

  This module orchestrates sprite sheet generation by coordinating I/O operations
  and delegating business logic to domain modules. It maintains the same public
  API while following the "I/O at the edges" principle.

  ## Architecture

  - **Domain Logic**: Delegated to `Heaters.Clips.Domain.Sprite.*` modules
  - **I/O Operations**: Handled via Infrastructure Adapters
  - **Orchestration**: This module coordinates the workflow
  """

  require Logger

  # Domain modules (pure business logic)
  alias Heaters.Clips.Operations.Artifacts.Sprite.{Calculations, Validation, FileNaming}
  alias Heaters.Clips.Operations.Shared.{ResultBuilding, ErrorFormatting}

  # Infrastructure adapters (I/O operations)
  alias Heaters.Infrastructure.Adapters.{DatabaseAdapter, S3Adapter, FFmpegAdapter}

  # Existing infrastructure (preserved)
  alias Heaters.Clips.Operations.Shared.{Types, TempManager}

  @doc """
  Generates a sprite sheet for the specified clip.

  ## Parameters
  - `clip_id`: The ID of the clip for sprite generation
  - `sprite_params`: Optional sprite generation parameters

  ## Returns
  - `{:ok, SpriteResult.t()}` on success with sprite artifact data
  - `{:error, reason}` on failure

  ## Examples

      {:ok, result} = Operations.Artifacts.Sprite.run_sprite(123, %{tile_width: 640, fps: 30})
      result.status # => "success"
  """
  @spec run_sprite(integer(), map()) :: {:ok, Types.SpriteResult.t()} | {:error, any()}
  def run_sprite(clip_id, sprite_params \\ %{}) do
    Logger.info("Sprite: Starting sprite generation for clip_id: #{clip_id}")
    start_time = System.monotonic_time()

    TempManager.with_temp_directory("sprite", fn temp_dir ->
      with {:ok, clip} <- fetch_clip_data(clip_id),
           initial_params <- merge_sprite_parameters(sprite_params),
           :ok <- validate_sprite_requirements(clip, initial_params),
           {:ok, video_path} <- download_video_file(clip, temp_dir),
           {:ok, video_metadata} <- extract_video_metadata(video_path),
           _ <- Logger.debug("Sprite: About to merge adaptive parameters for duration: #{video_metadata.duration}"),
           final_params <- merge_sprite_parameters_adaptive(video_metadata, sprite_params),
           :ok <- validate_video_metadata(video_metadata, final_params),
           {:ok, sprite_spec} <- calculate_sprite_specifications(video_metadata, final_params),
           filename <- generate_sprite_filename(clip_id, sprite_spec),
           {:ok, sprite_path} <- create_sprite_file(video_path, sprite_spec, filename, temp_dir),
           {:ok, upload_result} <-
             upload_sprite_file(sprite_path, clip, filename, sprite_spec, video_metadata) do
        duration_ms = calculate_duration(start_time)
        result = build_success_result(clip_id, upload_result, sprite_spec, duration_ms)

        Logger.info(
          "Sprite: Successfully completed sprite generation for clip_id: #{clip_id} in #{duration_ms}ms"
        )

        {:ok, result}
      else
        {:error, domain_error} when is_atom(domain_error) ->
          # Get clip data again for error context since it may not be in scope
          clip_for_error =
            case fetch_clip_data(clip_id) do
              {:ok, c} -> c
              _ -> %{ingest_state: "unknown"}
            end

          error_context = get_error_context(domain_error, clip_for_error)
          error_message = ErrorFormatting.format_domain_error(domain_error, error_context)
          Logger.error("Sprite: Domain error for clip_id: #{clip_id}, error: #{error_message}")
          {:error, error_message}

        {:error, reason} = error ->
          Logger.error(
            "Sprite: Failed to generate sprite for clip_id: #{clip_id}, error: #{inspect(reason)}"
          )

          error

        other ->
          Logger.error(
            "Sprite: Unexpected result for clip_id: #{clip_id}, result: #{inspect(other)}"
          )

          {:error, "Unexpected error during sprite generation"}
      end
    end)
  end

  # Private functions for I/O orchestration

  @spec fetch_clip_data(integer()) :: {:ok, map()} | {:error, atom()}
  defp fetch_clip_data(clip_id) do
    Logger.debug("Sprite: Fetching clip data for clip_id: #{clip_id}")
    DatabaseAdapter.get_clip_with_artifacts(clip_id)
  end

  @spec merge_sprite_parameters(map()) :: map()
  defp merge_sprite_parameters(input_params) do
    Logger.debug("Sprite: Merging sprite parameters: #{inspect(input_params)}")
    Calculations.merge_sprite_params(input_params)
  end

  @spec merge_sprite_parameters_adaptive(map(), map()) :: map()
  defp merge_sprite_parameters_adaptive(video_metadata, input_params) do
    Logger.debug("Sprite: Merging sprite parameters with adaptive columns: #{inspect(input_params)}")
    Calculations.merge_sprite_params_adaptive(video_metadata, input_params)
  end

  @spec validate_sprite_requirements(map(), map()) :: :ok | {:error, atom()}
  defp validate_sprite_requirements(clip, params) do
    Logger.debug("Sprite: Validating sprite requirements for clip_id: #{clip.id}")
    # We'll validate video metadata after we extract it
    case Validation.validate_clip_for_sprite(clip) do
      :ok -> Validation.validate_sprite_params(params)
      error -> error
    end
  end

  @spec download_video_file(map(), String.t()) :: {:ok, String.t()} | {:error, any()}
  defp download_video_file(clip, temp_dir) do
    Logger.info("Sprite: Downloading video file for clip_id: #{clip.id}")
    local_filename = Path.basename(clip.clip_filepath)
    S3Adapter.download_clip_video(clip, temp_dir, local_filename)
  end

  @spec extract_video_metadata(String.t()) :: {:ok, map()} | {:error, any()}
  defp extract_video_metadata(video_path) do
    Logger.debug("Sprite: Extracting video metadata from: #{video_path}")
    FFmpegAdapter.get_video_metadata(video_path)
  end

  @spec validate_video_metadata(map(), map()) :: :ok | {:error, atom()}
  defp validate_video_metadata(video_metadata, params) do
    Logger.debug("Sprite: Validating video metadata for sprite generation")

    with :ok <- Validation.validate_video_metadata_for_sprite(video_metadata),
         :ok <- Validation.validate_sprite_feasibility(video_metadata, params) do
      :ok
    end
  end

  @spec calculate_sprite_specifications(map(), map()) :: {:ok, map()} | {:error, atom()}
  defp calculate_sprite_specifications(video_metadata, params) do
    Logger.debug("Sprite: Calculating sprite specifications")

    case Calculations.calculate_sprite_grid(video_metadata, params) do
      {:ok, sprite_spec} -> {:ok, sprite_spec}
      {:error, _reason} -> {:error, :sprite_calculation_failed}
    end
  end

  @spec generate_sprite_filename(integer(), map()) :: String.t()
  defp generate_sprite_filename(clip_id, sprite_spec) do
    timestamp = DateTime.utc_now()
    filename = FileNaming.generate_sprite_filename(clip_id, sprite_spec, timestamp)
    Logger.debug("Sprite: Generated filename: #{filename}")
    filename
  end

  @spec create_sprite_file(String.t(), map(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, any()}
  defp create_sprite_file(video_path, sprite_spec, filename, temp_dir) do
    output_path = Path.join(temp_dir, filename)

    Logger.info("Sprite: Creating sprite sheet: #{filename}")

    Logger.info(
      "Sprite: Parameters - fps: #{sprite_spec.effective_fps}, frames: #{sprite_spec.num_frames}, grid: #{sprite_spec.grid_dimensions}"
    )

    case FFmpegAdapter.create_sprite_sheet(
           video_path,
           output_path,
           sprite_spec.effective_fps,
           sprite_spec.tile_width,
           sprite_spec.tile_height,
           sprite_spec.cols,
           sprite_spec.rows
         ) do
      {:ok, _file_size} -> {:ok, output_path}
      error -> error
    end
  end

  @spec upload_sprite_file(String.t(), map(), String.t(), map(), map()) ::
          {:ok, map()} | {:error, any()}
  defp upload_sprite_file(sprite_path, clip, filename, sprite_spec, video_metadata) do
    Logger.info("Sprite: Uploading sprite sheet for clip_id: #{clip.id}")

    # Build comprehensive metadata for JavaScript player compatibility
    sprite_metadata = build_sprite_metadata(sprite_spec, video_metadata, clip)

    S3Adapter.upload_sprite(sprite_path, clip, filename, sprite_metadata)
  end

  @spec build_success_result(integer(), map(), map(), integer()) :: Types.SpriteResult.t()
  defp build_success_result(clip_id, upload_result, sprite_spec, duration_ms) do
    ResultBuilding.build_sprite_result(clip_id, upload_result, sprite_spec)
    |> ResultBuilding.add_timing(duration_ms)
  end

  @spec calculate_duration(integer()) :: integer()
  defp calculate_duration(start_time) do
    System.convert_time_unit(
      System.monotonic_time() - start_time,
      :native,
      :millisecond
    )
  end

  @spec get_error_context(atom(), map()) :: any()
  defp get_error_context(_, _), do: "unknown"

  @spec build_sprite_metadata(map(), map(), map()) :: map()
  defp build_sprite_metadata(sprite_spec, video_metadata, clip) do
    # Build metadata that matches what the JavaScript player expects
    # Based on sprite_player.ex build_sprite_player_meta function
    %{
      "cols" => sprite_spec.cols,
      "rows" => sprite_spec.rows,
      "tile_width" => sprite_spec.tile_width,
      "tile_height_calculated" => sprite_spec.tile_height,
      "total_sprite_frames" => sprite_spec.num_frames,
      "clip_fps" => sprite_spec.effective_fps,
      "clip_fps_source" => video_metadata.fps,
      "clip_total_frames_source" =>
        if clip.start_time_seconds && clip.end_time_seconds do
          Float.ceil((clip.end_time_seconds - clip.start_time_seconds) * video_metadata.fps)
        else
          sprite_spec.num_frames
        end,
      "video_duration" => video_metadata.duration,
      "video_fps" => video_metadata.fps,
      "effective_fps" => sprite_spec.effective_fps,
      "num_frames" => sprite_spec.num_frames,
      "grid_dimensions" => sprite_spec.grid_dimensions
    }
  end
end
