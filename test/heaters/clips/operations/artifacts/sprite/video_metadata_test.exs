defmodule Heaters.Clips.Operations.Artifacts.Sprite.VideoMetadataTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Heaters.Clips.Operations.Artifacts.Sprite.VideoMetadata

  describe "calculate_effective_fps/2" do
    test "returns video fps when sprite fps is nil" do
      assert VideoMetadata.calculate_effective_fps(30.0, nil) == 30.0
      assert VideoMetadata.calculate_effective_fps(24.0, nil) == 24.0
    end

    test "returns minimum of video fps and sprite fps when provided" do
      # When sprite fps is lower than video fps, use sprite fps
      assert VideoMetadata.calculate_effective_fps(30.0, 15.0) == 15.0
      assert VideoMetadata.calculate_effective_fps(24.0, 1.0) == 1.0

      # When sprite fps is higher than video fps, cap at video fps
      assert VideoMetadata.calculate_effective_fps(15.0, 30.0) == 15.0
      assert VideoMetadata.calculate_effective_fps(24.0, 60.0) == 24.0
    end

    property "effective fps is always positive and finite" do
      check all(
              video_fps <- positive_float(),
              sprite_fps <- one_of([constant(nil), positive_float()])
            ) do
        result = VideoMetadata.calculate_effective_fps(video_fps, sprite_fps)

        assert is_number(result)
        assert result > 0
        assert is_finite(result)
      end
    end

    property "effective fps is minimum of video and sprite fps" do
      check all(
              video_fps <- positive_float(),
              sprite_fps <- positive_float()
            ) do
        result = VideoMetadata.calculate_effective_fps(video_fps, sprite_fps)
        assert result == min(video_fps, sprite_fps)
        assert result <= video_fps
        assert result <= sprite_fps
      end
    end
  end

  describe "calculate_total_frames/2" do
    test "calculates frames correctly for standard cases" do
      # 30 seconds at 30 FPS = 900 frames
      assert VideoMetadata.calculate_total_frames(30.0, 30.0) == 900

      # 10 seconds at 24 FPS = 240 frames
      assert VideoMetadata.calculate_total_frames(10.0, 24.0) == 240

      # 1 second at 1 FPS = 1 frame
      assert VideoMetadata.calculate_total_frames(1.0, 1.0) == 1
    end

    test "handles fractional results by rounding" do
      # 1.5 seconds at 30 FPS = 45 frames
      assert VideoMetadata.calculate_total_frames(1.5, 30.0) == 45

      # 10 seconds at 29.97 FPS ≈ 299.7 → 300 frames
      assert VideoMetadata.calculate_total_frames(10.0, 29.97) == 300
    end

    property "frame count is always non-negative integer" do
      check all(
              duration <- positive_float(),
              fps <- positive_float()
            ) do
        frames = VideoMetadata.calculate_total_frames(duration, fps)

        assert is_integer(frames)
        assert frames >= 0
      end
    end

    property "longer duration means more frames at same fps" do
      check all(
              duration1 <- positive_float(),
              duration2 <- positive_float(),
              fps <- positive_float(),
              duration1 < duration2
            ) do
        frames1 = VideoMetadata.calculate_total_frames(duration1, fps)
        frames2 = VideoMetadata.calculate_total_frames(duration2, fps)

        assert frames1 <= frames2
      end
    end

    property "higher fps means more frames for same duration" do
      check all(
              duration <- positive_float(),
              fps1 <- positive_float(),
              fps2 <- positive_float(),
              fps1 < fps2
            ) do
        frames1 = VideoMetadata.calculate_total_frames(duration, fps1)
        frames2 = VideoMetadata.calculate_total_frames(duration, fps2)

        assert frames1 <= frames2
      end
    end
  end

  describe "sufficient_duration?/2" do
    test "returns true for durations meeting minimum" do
      assert VideoMetadata.sufficient_duration?(5.0, 3.0) == true
      assert VideoMetadata.sufficient_duration?(10.0, 10.0) == true
      assert VideoMetadata.sufficient_duration?(1.0, 1.0) == true
    end

    test "returns false for durations below minimum" do
      assert VideoMetadata.sufficient_duration?(2.0, 3.0) == false
      assert VideoMetadata.sufficient_duration?(0.5, 1.0) == false
      assert VideoMetadata.sufficient_duration?(9.99, 10.0) == false
    end

    property "longer durations are always sufficient if shorter ones are" do
      check all(
              duration <- positive_float(),
              min_duration <- positive_float(),
              extra <- positive_float()
            ) do
        longer_duration = duration + extra

        if VideoMetadata.sufficient_duration?(duration, min_duration) do
          assert VideoMetadata.sufficient_duration?(longer_duration, min_duration)
        end
      end
    end
  end

  describe "validate_metadata/1" do
    test "validates complete metadata successfully" do
      metadata = %{
        duration: 30.0,
        fps: 24.0,
        width: 1920,
        height: 1080
      }

      assert VideoMetadata.validate_metadata(metadata) == :ok
    end

    test "validates metadata with string dimensions" do
      metadata = %{
        duration: 30.0,
        fps: 24.0,
        width: "1920",
        height: "1080"
      }

      assert VideoMetadata.validate_metadata(metadata) == :ok
    end

    test "rejects metadata with missing required fields" do
      incomplete = %{duration: 30.0, fps: 24.0}
      assert {:error, _reason} = VideoMetadata.validate_metadata(incomplete)
    end

    test "rejects metadata with invalid values" do
      invalid_duration = %{duration: -1.0, fps: 24.0, width: 1920, height: 1080}
      assert {:error, _reason} = VideoMetadata.validate_metadata(invalid_duration)

      invalid_fps = %{duration: 30.0, fps: 0, width: 1920, height: 1080}
      assert {:error, _reason} = VideoMetadata.validate_metadata(invalid_fps)

      invalid_dimensions = %{duration: 30.0, fps: 24.0, width: 0, height: 1080}
      assert {:error, _reason} = VideoMetadata.validate_metadata(invalid_dimensions)
    end

    property "valid metadata always passes validation" do
      check all(
              duration <- positive_float(),
              fps <- positive_float(),
              width <- positive_int(),
              height <- positive_int()
            ) do
        metadata = %{
          duration: duration,
          fps: fps,
          width: width,
          height: height
        }

        assert VideoMetadata.validate_metadata(metadata) == :ok
      end
    end
  end

  # Helper generators for property-based testing
  defp positive_float do
    gen all(num <- float(min: 0.01, max: 10000.0)) do
      num
    end
  end

  defp positive_int do
    gen all(num <- integer(1..10000)) do
      num
    end
  end

  defp is_finite(num) when is_number(num) do
    num != :infinity and num != :neg_infinity and not is_nan(num)
  end

  defp is_nan(num) when is_float(num), do: num != num
  defp is_nan(_), do: false
end
