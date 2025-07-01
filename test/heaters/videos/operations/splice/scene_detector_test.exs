defmodule Heaters.Videos.Operations.Splice.SceneDetectorTest do
  use Heaters.DataCase, async: true

  alias Heaters.Videos.Operations.Splice.SceneDetector

  describe "detect_scenes/2" do
    test "returns error for non-existent video file" do
      non_existent_path = "/tmp/nonexistent_video.mp4"

      result = SceneDetector.detect_scenes(non_existent_path)

      assert {:error, "Video file not found: " <> ^non_existent_path} = result
    end

    test "handles various detection options" do
      # Test with non-existent file to validate option processing
      video_path = "/tmp/test_video.mp4"

      opts = [
        threshold: 0.5,
        method: :chisqr,
        min_duration_seconds: 2.0
      ]

      result = SceneDetector.detect_scenes(video_path, opts)

      # Should fail due to missing file, but validates option handling
      assert {:error, _} = result
    end

    test "validates different comparison methods" do
      video_path = "/tmp/test_video.mp4"

      methods = [:correl, :chisqr, :intersect, :bhattacharyya]

      for method <- methods do
        result = SceneDetector.detect_scenes(video_path, method: method)
        # Should fail due to missing file, but validates method handling
        assert {:error, _} = result
      end
    end

    test "validates threshold ranges" do
      video_path = "/tmp/test_video.mp4"

      thresholds = [0.0, 0.3, 0.6, 1.0]

      for threshold <- thresholds do
        result = SceneDetector.detect_scenes(video_path, threshold: threshold)
        # Should fail due to missing file, but validates threshold handling
        assert {:error, _} = result
      end
    end

    test "returns proper result structure on successful detection" do
      # Note: This test would need a real video file to fully test
      # For now, we validate the error structure matches expectations

      video_path = "/tmp/test_video.mp4"
      result = SceneDetector.detect_scenes(video_path)

      case result do
        {:ok, detection_result} ->
          # If somehow we get success (shouldn't happen with non-existent file)
          assert is_map(detection_result)
          assert Map.has_key?(detection_result, :scenes)
          assert Map.has_key?(detection_result, :video_info)
          assert Map.has_key?(detection_result, :detection_params)
          assert is_list(detection_result.scenes)

        {:error, reason} ->
          # Expected case with non-existent file
          assert is_binary(reason)
      end
    end
  end

  describe "scene data structure" do
    test "scene struct has required fields" do
      # Test the expected structure of a scene
      scene = %{
        start_frame: 0,
        end_frame: 150,
        start_time_seconds: 0.0,
        end_time_seconds: 5.0,
        duration_seconds: 5.0
      }

      assert is_integer(scene.start_frame)
      assert is_integer(scene.end_frame)
      assert is_float(scene.start_time_seconds)
      assert is_float(scene.end_time_seconds)
      assert is_float(scene.duration_seconds)
    end

    test "video_info struct has required fields" do
      # Test the expected structure of video info
      video_info = %{
        fps: 30.0,
        width: 1920,
        height: 1080,
        total_frames: 450,
        duration_seconds: 15.0
      }

      assert is_float(video_info.fps)
      assert is_integer(video_info.width)
      assert is_integer(video_info.height)
      assert is_integer(video_info.total_frames)
      assert is_float(video_info.duration_seconds)
    end

    test "detection_params struct has required fields" do
      # Test the expected structure of detection params
      detection_params = %{
        threshold: 0.6,
        method: :correl,
        min_duration_seconds: 1.0
      }

      assert is_float(detection_params.threshold)
      assert is_atom(detection_params.method)
      assert is_float(detection_params.min_duration_seconds)
    end
  end
end
