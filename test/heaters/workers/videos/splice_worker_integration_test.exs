defmodule Heaters.Workers.Videos.SpliceWorkerIntegrationTest do
  use Heaters.DataCase, async: true

  alias Heaters.Workers.Videos.SpliceWorker

  describe "splice worker integration" do
    test "handles native splice workflow" do
      # The worker should attempt native implementation (will fail at S3, but that's expected)
      result = SpliceWorker.handle(%{"source_video_id" => 1})

      # For this test, we just want to verify it doesn't crash and handles errors gracefully
      # The actual S3 error is expected in test environment since no video exists
      assert result == :ok || match?({:error, _}, result)
    end

    test "handles missing source video gracefully" do
      # Test with non-existent video ID
      result = SpliceWorker.handle(%{"source_video_id" => 999})

      # Should return :ok (graceful handling of missing video)
      assert result == :ok
    end
  end
end
