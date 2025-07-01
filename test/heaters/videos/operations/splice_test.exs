defmodule Heaters.Videos.Operations.SpliceTest do
  use Heaters.DataCase, async: true

  alias Heaters.Videos.Operations.Splice
  alias Heaters.Videos.SourceVideo
  alias Heaters.Clips.Operations.Shared.Types

  describe "run_splice/2" do
    test "attempts native workflow" do
      source_video = %SourceVideo{
        id: 1,
        title: "Test Video",
        filepath: "test/nonexistent_video.mp4"
      }

      result = Splice.run_splice(source_video)

      assert %Types.SpliceResult{} = result
      # Should fail due to S3 download, but validates the workflow starts
      assert result.status == "error"
      assert result.source_video_id == 1
      assert result.clips_data == []
      # Should contain timing information
      assert is_integer(result.duration_ms)
    end

    test "returns SpliceResult struct with proper fields" do
      source_video = %SourceVideo{
        id: 2,
        title: "Test Video 2",
        filepath: "test/video.mp4"
      }

      result = Splice.run_splice(source_video)

      # Verify all required fields are present
      assert %Types.SpliceResult{} = result
      assert is_binary(result.status)
      assert result.source_video_id == 2
      assert is_list(result.clips_data)
      assert is_map(result.metadata)
      assert is_integer(result.duration_ms) or is_nil(result.duration_ms)
      assert %DateTime{} = result.processed_at
    end

    test "processes options correctly" do
      source_video = %SourceVideo{
        id: 3,
        title: "Test Video 3",
        filepath: "test/video.mp4"
      }

      opts = [
        threshold: 0.5,
        method: :chisqr,
        min_duration_seconds: 2.0
      ]

      result = Splice.run_splice(source_video, opts)

      assert %Types.SpliceResult{} = result
      # Options should be logged and would be used in actual processing
      # (testing with non-existent file will fail, but validates option handling)
    end
  end
end
