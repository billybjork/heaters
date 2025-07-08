defmodule Heaters.Clips.Operations.Artifacts.Sprite.Calculations do
  @moduledoc """
  Calculation logic for sprite operations.
  Used by Operations.Artifacts.Sprite for business logic.

  This module contains business logic for sprite sheet generation
  extracted from the Operations.Sprite module. All functions are pure - they take
  explicit inputs and return predictable outputs without any I/O operations.
  """

  alias Heaters.Clips.Operations.Shared.VideoMetadata

  # Default sprite parameters matching the current Transform.Sprite module
  @default_tile_width 480
  # -1 preserves aspect ratio
  @default_tile_height -1
  @default_sprite_fps 24
  @default_cols 5

  @type sprite_params :: %{
          tile_width: integer(),
          tile_height: integer(),
          fps: integer(),
          cols: integer()
        }

  @type sprite_grid_spec :: %{
          effective_fps: float(),
          num_frames: integer(),
          cols: integer(),
          rows: integer(),
          tile_width: integer(),
          tile_height: integer(),
          grid_dimensions: String.t()
        }

  @doc """
  Merge user-provided sprite parameters with defaults.

  ## Examples

      iex> Calculations.merge_sprite_params(%{})
      %{tile_width: 480, tile_height: -1, fps: 24, cols: 5}

      iex> Calculations.merge_sprite_params(%{tile_width: 640, fps: 30})
      %{tile_width: 640, tile_height: -1, fps: 30, cols: 5}
  """
  @spec merge_sprite_params(map()) :: sprite_params()
  def merge_sprite_params(input_params) when is_map(input_params) do
    defaults = %{
      tile_width: @default_tile_width,
      tile_height: @default_tile_height,
      fps: @default_sprite_fps,
      cols: @default_cols
    }

    Map.merge(defaults, input_params)
  end

  @doc """
  Calculate sprite grid specifications from video metadata and sprite parameters.

  This is the core business logic extracted from the current sprite generation code.
  It determines the effective FPS, number of frames, and grid dimensions.

  ## Examples

      iex> video_metadata = %{duration: 120.0, fps: 30.0}
      iex> sprite_params = %{tile_width: 480, tile_height: -1, fps: 24, cols: 5}
      iex> {:ok, result} = Calculations.calculate_sprite_grid(video_metadata, sprite_params)
      iex> result.effective_fps
      24.0
      iex> result.num_frames
      2880
      iex> result.rows
      576
  """
  @spec calculate_sprite_grid(map(), sprite_params()) ::
          {:ok, sprite_grid_spec()} | {:error, String.t()}
  def calculate_sprite_grid(video_metadata, sprite_params)
      when is_map(video_metadata) and is_map(sprite_params) do
    %{duration: duration, fps: video_fps, width: video_width, height: video_height} =
      video_metadata

    %{tile_width: tile_width, tile_height: tile_height, fps: sprite_fps, cols: cols} =
      sprite_params

    # Calculate effective sprite FPS - don't exceed video's native FPS
    effective_sprite_fps = VideoMetadata.calculate_effective_fps(video_fps, sprite_fps)

    # Calculate total number of sprite frames needed
    num_sprite_frames = VideoMetadata.calculate_total_frames(duration, effective_sprite_fps)

    if num_sprite_frames <= 0 do
      {:error, "Video too short for sprite generation: #{duration}s"}
    else
      # Calculate actual tile height (handles -1 for aspect ratio preservation)
      actual_tile_height =
        VideoMetadata.calculate_tile_height(video_width, video_height, tile_width, tile_height)

      # Calculate grid dimensions
      num_rows = max(1, ceil(num_sprite_frames / cols))

      sprite_spec = %{
        effective_fps: effective_sprite_fps,
        num_frames: num_sprite_frames,
        cols: cols,
        rows: num_rows,
        tile_width: tile_width,
        tile_height: actual_tile_height,
        grid_dimensions: "#{cols}x#{num_rows}"
      }

      {:ok, sprite_spec}
    end
  end

  @doc """
  Calculate the total dimensions of the final sprite sheet.

  ## Examples

      iex> sprite_spec = %{cols: 5, rows: 10, tile_width: 480, tile_height: 270}
      iex> Calculations.calculate_sprite_sheet_dimensions(sprite_spec)
      %{width: 2400, height: 2700}
  """
  @spec calculate_sprite_sheet_dimensions(sprite_grid_spec()) :: %{
          width: integer(),
          height: integer()
        }
  def calculate_sprite_sheet_dimensions(sprite_spec) when is_map(sprite_spec) do
    %{cols: cols, rows: rows, tile_width: tile_width, tile_height: tile_height} = sprite_spec

    total_width = cols * tile_width

    total_height =
      if tile_height > 0 do
        rows * tile_height
      else
        # When tile_height is -1 (preserve aspect ratio), we can't predict the exact height
        # without knowing the video's aspect ratio. Return nil to indicate this.
        nil
      end

    %{width: total_width, height: total_height}
  end

  @doc """
  Calculate estimated sprite sheet file size based on specifications.
  This is a rough estimate for planning purposes.

  ## Examples

      iex> sprite_spec = %{cols: 5, rows: 10, tile_width: 480}
      iex> Calculations.estimate_sprite_file_size(sprite_spec)
      {:ok, 1048576}  # Estimated size in bytes
  """
  @spec estimate_sprite_file_size(sprite_grid_spec()) :: {:ok, integer()} | {:error, String.t()}
  def estimate_sprite_file_size(sprite_spec) when is_map(sprite_spec) do
    %{cols: cols, rows: rows, tile_width: tile_width} = sprite_spec

    # Rough estimation: assume ~10KB per tile for JPEG compression
    # This is very approximate and depends on video content complexity
    total_tiles = cols * rows
    # Very rough heuristic
    estimated_bytes_per_tile = round(tile_width * 0.02)
    estimated_total_size = total_tiles * estimated_bytes_per_tile

    {:ok, estimated_total_size}
  end

  @doc """
  Validate sprite parameters for mathematical correctness.

  ## Examples

      iex> params = %{tile_width: 480, tile_height: -1, fps: 24, cols: 5}
      iex> Calculations.validate_sprite_params(params)
      :ok

      iex> Calculations.validate_sprite_params(%{tile_width: 0, cols: 5})
      {:error, "tile_width must be positive"}
  """
  @spec validate_sprite_params(sprite_params()) :: :ok | {:error, String.t()}
  def validate_sprite_params(params) when is_map(params) do
    %{tile_width: tile_width, tile_height: tile_height, fps: fps, cols: cols} = params

    cond do
      tile_width <= 0 ->
        {:error, "tile_width must be positive"}

      tile_height != -1 and tile_height <= 0 ->
        {:error, "tile_height must be positive or -1 for aspect ratio preservation"}

      fps <= 0 ->
        {:error, "fps must be positive"}

      cols <= 0 ->
        {:error, "cols must be positive"}

      true ->
        :ok
    end
  end

  @doc """
  Check if the sprite generation is feasible given video and parameter constraints.

  ## Examples

      iex> video_metadata = %{duration: 120.0, fps: 30.0}
      iex> sprite_params = %{tile_width: 480, fps: 24, cols: 5}
      iex> Calculations.sprite_generation_feasible?(video_metadata, sprite_params)
      {:ok, %{feasible: true, estimated_frames: 2880, estimated_rows: 576}}
  """
  @spec sprite_generation_feasible?(map(), sprite_params()) :: {:ok, map()} | {:error, String.t()}
  def sprite_generation_feasible?(video_metadata, sprite_params)
      when is_map(video_metadata) and is_map(sprite_params) do
    with :ok <- validate_sprite_params(sprite_params),
         {:ok, sprite_spec} <- calculate_sprite_grid(video_metadata, sprite_params) do
      # Check for reasonable limits (e.g., not generating massive sprite sheets)
      # Configurable limit
      max_reasonable_rows = 1000

      feasibility = %{
        feasible: sprite_spec.rows <= max_reasonable_rows,
        estimated_frames: sprite_spec.num_frames,
        estimated_rows: sprite_spec.rows,
        estimated_grid: sprite_spec.grid_dimensions
      }

      if feasibility.feasible do
        {:ok, feasibility}
      else
        {:error,
         "Sprite generation would create #{sprite_spec.rows} rows, exceeding limit of #{max_reasonable_rows}"}
      end
    end
  end
end
