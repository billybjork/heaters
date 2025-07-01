 defmodule Heaters.Videos.Operations.Splice.SceneDetector do
  @moduledoc """
  Pure domain logic for scene detection using Evision (OpenCV bindings).

  This module contains no I/O operations - it accepts local file paths and returns
  scene data. Follows "I/O at the edges" architecture principle.

  **Performance**: Streaming frame-by-frame processing for memory efficiency

  ## Architecture

  - **Pure Functions**: No I/O, accepts file paths, returns scene data
  - **Evision Integration**: Uses OpenCV histogram comparison for scene detection
  - **Memory Efficient**: Streaming frame-by-frame processing for large videos
  - **Configurable**: Supports multiple comparison methods and thresholds

  ## Usage

      {:ok, result} = SceneDetector.detect_scenes("/tmp/video.mp4", threshold: 0.3)
      # %{scenes: [...], video_info: %{fps: 30.0, ...}, detection_params: %{...}}
  """

  alias Evision, as: CV
  require Logger

  @type scene :: %{
    start_frame: non_neg_integer(),
    end_frame: non_neg_integer(),
    start_time_seconds: float(),
    end_time_seconds: float(),
    duration_seconds: float()
  }

  @type video_info :: %{
    fps: float(),
    width: integer(),
    height: integer(),
    total_frames: integer(),
    duration_seconds: float()
  }

  @type detection_params :: %{
    threshold: float(),
    method: atom(),
    min_duration_seconds: float()
  }

  @type detection_result :: %{
    scenes: [scene()],
    video_info: video_info(),
    detection_params: detection_params()
  }

  # OpenCV histogram comparison methods mapping
  @comparison_methods %{
    correl: CV.Constant.cv_HISTCMP_CORREL(),
    chisqr: CV.Constant.cv_HISTCMP_CHISQR(),
    intersect: CV.Constant.cv_HISTCMP_INTERSECT(),
    bhattacharyya: CV.Constant.cv_HISTCMP_BHATTACHARYYA()
  }

  @doc """
  Detect scene cuts in a video file using histogram comparison.

  Uses Evision (OpenCV-Elixir bindings) to:
  1. Open video and extract properties
  2. Stream through frames calculating BGR histograms
  3. Compare adjacent histograms using specified method
  4. Identify scene cuts based on threshold
  5. Build scene list with timing information

  ## Parameters
  - `video_path`: Local path to video file
  - `opts`: Detection options
    - `:threshold`: Similarity threshold (0.0-1.0, default: 0.6)
    - `:method`: Comparison method (:correl, :chisqr, :intersect, :bhattacharyya)
    - `:min_duration_seconds`: Minimum scene duration (default: 1.0)

  ## Returns
  - `{:ok, detection_result()}` on success
  - `{:error, reason}` on failure

  ## Examples

      {:ok, result} = SceneDetector.detect_scenes("/tmp/video.mp4")
      IO.inspect(result.scenes)
      # [%{start_frame: 0, end_frame: 150, start_time_seconds: 0.0, ...}, ...]
  """
  @spec detect_scenes(String.t(), keyword()) :: {:ok, detection_result()} | {:error, any()}
  def detect_scenes(video_path, opts \\ []) do
    # Extract options with defaults
    threshold = Keyword.get(opts, :threshold, 0.6)
    method = Keyword.get(opts, :method, :correl)
    min_duration = Keyword.get(opts, :min_duration_seconds, 1.0)

    Logger.info("SceneDetector: Starting detection for #{video_path}")
    Logger.debug("SceneDetector: Params - threshold: #{threshold}, method: #{method}, min_duration: #{min_duration}")

    case File.exists?(video_path) do
      true ->
        perform_scene_detection(video_path, threshold, method, min_duration)

      false ->
        {:error, "Video file not found: #{video_path}"}
    end
  end

  # Private functions - Real Evision implementation

  defp perform_scene_detection(video_path, threshold, method, min_duration) do
    with {:ok, cap} <- open_video_capture(video_path),
         {:ok, video_info} <- extract_video_properties(cap),
         {:ok, scene_cuts} <- analyze_frames_for_cuts(cap, threshold, method),
         :ok <- release_video_capture(cap) do

      scenes = build_scenes_from_cuts(scene_cuts, video_info.fps, min_duration)

      Logger.info("SceneDetector: Detected #{length(scenes)} scenes from #{length(scene_cuts)} cuts")

      result = %{
        scenes: scenes,
        video_info: video_info,
        detection_params: %{
          threshold: threshold,
          method: method,
          min_duration_seconds: min_duration
        }
      }

      {:ok, result}
    else
      error -> error
    end
  end

  defp open_video_capture(video_path) do
    case CV.VideoCapture.videoCapture(video_path) do
      %CV.VideoCapture{} = cap ->
        # Evision returns the struct directly
        Logger.debug("SceneDetector: Successfully opened video capture")
        {:ok, cap}

      {:error, reason} ->
        Logger.error("SceneDetector: Failed to open video: #{inspect(reason)}")
        {:error, "Failed to open video: #{inspect(reason)}"}
    end
  end

  defp extract_video_properties(cap) do
    try do
      fps = CV.VideoCapture.get(cap, CV.Constant.cv_CAP_PROP_FPS())
      width = CV.VideoCapture.get(cap, CV.Constant.cv_CAP_PROP_FRAME_WIDTH()) |> trunc()
      height = CV.VideoCapture.get(cap, CV.Constant.cv_CAP_PROP_FRAME_HEIGHT()) |> trunc()
      total_frames = CV.VideoCapture.get(cap, CV.Constant.cv_CAP_PROP_FRAME_COUNT()) |> trunc()

      # Validate properties
      cond do
        fps <= 0 -> {:error, "Invalid FPS: #{fps}"}
        total_frames <= 0 -> {:error, "Invalid frame count: #{total_frames}"}
        width <= 0 or height <= 0 -> {:error, "Invalid dimensions: #{width}x#{height}"}
        true ->
          duration_seconds = total_frames / fps

          video_info = %{
            fps: fps,
            width: width,
            height: height,
            total_frames: total_frames,
            duration_seconds: duration_seconds
          }

          Logger.debug("SceneDetector: Video properties - #{width}x#{height}, #{fps} FPS, #{total_frames} frames, #{Float.round(duration_seconds, 2)}s")
          {:ok, video_info}
      end
    rescue
      error ->
        Logger.error("SceneDetector: Failed to extract video properties: #{Exception.message(error)}")
        {:error, "Failed to extract video properties: #{Exception.message(error)}"}
    end
  end

  defp analyze_frames_for_cuts(cap, threshold, method) do
    comparison_method = Map.get(@comparison_methods, method, @comparison_methods.correl)

    Logger.debug("SceneDetector: Starting frame analysis with method #{method} (#{comparison_method})")

    # Always start with frame 0 as a cut
    cut_frames = [0]

    case process_video_stream(cap, threshold, comparison_method, method, cut_frames) do
      {:ok, final_cuts} ->
        Logger.debug("SceneDetector: Found #{length(final_cuts)} scene cuts")
        {:ok, final_cuts}

      error -> error
    end
  end

  defp process_video_stream(cap, threshold, comparison_method, method_name, cut_frames, prev_hist \\ nil, frame_num \\ 0) do
    case CV.VideoCapture.read(cap) do
      %CV.Mat{} = frame ->
        current_hist = calculate_bgr_histogram(frame)

        updated_cuts = case prev_hist do
          nil ->
            cut_frames

          _ ->
            score = CV.compareHist(prev_hist, current_hist, comparison_method)

            if is_scene_cut?(score, threshold, method_name) do
              Logger.debug("SceneDetector: Scene cut detected at frame #{frame_num} (score: #{Float.round(score, 4)})")
              [frame_num | cut_frames]
            else
              cut_frames
            end
        end

        # Continue processing next frame
        process_video_stream(cap, threshold, comparison_method, method_name, updated_cuts, current_hist, frame_num + 1)

      false ->
        # End of video - add final frame if not already present
        final_cuts = if frame_num > 0 and not Enum.member?(cut_frames, frame_num) do
          [frame_num | cut_frames]
        else
          cut_frames
        end

        # Reverse to get chronological order and remove duplicates
        final_cuts = final_cuts |> Enum.reverse() |> Enum.uniq()
        {:ok, final_cuts}

      {:error, reason} ->
        Logger.error("SceneDetector: Failed to read frame #{frame_num}: #{inspect(reason)}")
        {:error, "Failed to read frame #{frame_num}: #{inspect(reason)}"}
    end
  end

  defp calculate_bgr_histogram(frame) do
    # Calculate histogram for each BGR channel
    try do
      # Split into B, G, R channels - CV.split returns a list of Mats
      channels = CV.split(frame)
      [b_channel, g_channel, r_channel] = case channels do
        [b, g, r] -> [b, g, r]
        [gray] -> [gray, gray, gray]  # Fallback for grayscale
        {:error, reason} -> raise "Failed to split channels: #{reason}"
        _ -> raise "Unexpected channel split result: #{inspect(channels)}"
      end

      # Calculate histogram for each channel (256 bins, range 0-256)
      bins = [256]
      ranges = [0, 256]
      mask = CV.Mat.empty()

      hist_b = CV.calcHist([b_channel], [0], mask, bins, ranges)
      hist_g = CV.calcHist([g_channel], [0], mask, bins, ranges)
      hist_r = CV.calcHist([r_channel], [0], mask, bins, ranges)

      # Concatenate histograms
      combined_hist = CV.hconcat([hist_b, hist_g, hist_r])

      # Normalize the histogram
      CV.normalize(combined_hist)
    rescue
      error ->
        Logger.error("SceneDetector: Failed to calculate histogram: #{Exception.message(error)}")
        # Return empty matrix as fallback
        CV.Mat.zeros({768, 1}, :u8)
    end
  end

  defp is_scene_cut?(score, threshold, method_name) do
    case method_name do
      :correl -> score < threshold      # Lower correlation = more different
      :intersect -> score < threshold   # Lower intersection = more different
      :chisqr -> score > threshold      # Higher chi-square = more different
      :bhattacharyya -> score > threshold  # Higher distance = more different
      _ -> score < threshold  # Default to correlation-like behavior
    end
  end

  defp build_scenes_from_cuts(cut_frames, fps, min_duration) when length(cut_frames) >= 2 do
    cut_frames
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [start_frame, end_frame] ->
      start_time = start_frame / fps
      end_time = end_frame / fps
      duration = end_time - start_time

      %{
        start_frame: start_frame,
        end_frame: end_frame,
        start_time_seconds: start_time,
        end_time_seconds: end_time,
        duration_seconds: duration
      }
    end)
    |> Enum.filter(fn scene -> scene.duration_seconds >= min_duration end)
  end

  defp build_scenes_from_cuts(cut_frames, _fps, _min_duration) when length(cut_frames) < 2 do
    Logger.warning("SceneDetector: Not enough cut frames to build scenes: #{inspect(cut_frames)}")
    []
  end

  defp release_video_capture(cap) do
    try do
      CV.VideoCapture.release(cap)
      Logger.debug("SceneDetector: Released video capture")
      :ok
    rescue
      error ->
        Logger.warning("SceneDetector: Failed to release video capture: #{Exception.message(error)}")
        :ok  # Don't fail the entire operation for cleanup issues
    end
  end
end
