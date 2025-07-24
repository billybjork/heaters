defmodule Heaters.Clips.VirtualClipsTest do
  use Heaters.DataCase, async: true

  alias Heaters.Clips.VirtualClips
  alias Heaters.Clips.Clip
  alias Heaters.Repo

  describe "create_virtual_clips_from_cut_points/3" do
    test "creates virtual clips from valid cut points" do
      source_video = insert(:source_video)

      cut_points = [
        %{
          "start_frame" => 0,
          "end_frame" => 150,
          "start_time_seconds" => 0.0,
          "end_time_seconds" => 5.0
        },
        %{
          "start_frame" => 150,
          "end_frame" => 300,
          "start_time_seconds" => 5.0,
          "end_time_seconds" => 10.0
        }
      ]

      assert {:ok, clips} =
               VirtualClips.create_virtual_clips_from_cut_points(
                 source_video.id,
                 cut_points,
                 %{}
               )

      assert length(clips) == 2

      first_clip = Enum.at(clips, 0)
      assert first_clip.is_virtual == true
      assert first_clip.source_video_id == source_video.id
      assert first_clip.start_frame == 0
      assert first_clip.end_frame == 150
      assert first_clip.ingest_state == "pending_review"
      assert first_clip.source_video_order == 1

      second_clip = Enum.at(clips, 1)
      assert second_clip.start_frame == 150
      assert second_clip.end_frame == 300
      assert second_clip.source_video_order == 2
    end

    test "returns existing clips on duplicate call (idempotent)" do
      source_video = insert(:source_video)

      cut_points = [
        %{
          "start_frame" => 0,
          "end_frame" => 100,
          "start_time_seconds" => 0.0,
          "end_time_seconds" => 3.33
        }
      ]

      # First call creates clips
      assert {:ok, clips1} =
               VirtualClips.create_virtual_clips_from_cut_points(
                 source_video.id,
                 cut_points,
                 %{}
               )

      # Second call returns existing clips
      assert {:ok, clips2} =
               VirtualClips.create_virtual_clips_from_cut_points(
                 source_video.id,
                 cut_points,
                 %{}
               )

      assert length(clips1) == 1
      assert length(clips2) == 1
      assert Enum.at(clips1, 0).id == Enum.at(clips2, 0).id
    end

    test "validates cut points format" do
      source_video = insert(:source_video)

      invalid_cut_points = [
        %{
          "start_frame" => 0,
          # Missing end_frame
          "start_time_seconds" => 0.0,
          "end_time_seconds" => 5.0
        }
      ]

      assert {:error, reason} =
               VirtualClips.create_virtual_clips_from_cut_points(
                 source_video.id,
                 invalid_cut_points,
                 %{}
               )

      assert reason =~ "Missing required field: end_frame"
    end
  end

  describe "add_cut_point/3" do
    test "splits virtual clip at specified frame" do
      source_video = insert(:source_video)
      user_id = 123

      # Create initial virtual clip
      initial_clip =
        insert(:virtual_clip,
          source_video: source_video,
          start_frame: 0,
          end_frame: 300,
          cut_points: %{
            "start_frame" => 0,
            "end_frame" => 300,
            "start_time_seconds" => 0.0,
            "end_time_seconds" => 10.0
          },
          source_video_order: 1
        )

      # Split at frame 150
      assert {:ok, {first_clip, second_clip}} =
               VirtualClips.add_cut_point(
                 source_video.id,
                 150,
                 user_id
               )

      # Original clip should be archived
      updated_original = Repo.get!(Clip, initial_clip.id)
      assert updated_original.ingest_state == "archived"

      # New clips should have correct boundaries
      assert first_clip.start_frame == 0
      assert first_clip.end_frame == 150
      assert first_clip.cut_points["end_frame"] == 150

      assert second_clip.start_frame == 150
      assert second_clip.end_frame == 300
      assert second_clip.cut_points["start_frame"] == 150

      # Verify audit trail was created
      operation = Repo.one(VirtualClips.CutPointOperation)
      assert operation.operation_type == "add"
      assert operation.frame_number == 150
      assert operation.user_id == user_id
      assert operation.source_video_id == source_video.id
    end

    test "rejects split at clip boundaries" do
      source_video = insert(:source_video)
      user_id = 123

      clip =
        insert(:virtual_clip,
          source_video: source_video,
          start_frame: 100,
          end_frame: 200,
          cut_points: %{
            "start_frame" => 100,
            "end_frame" => 200,
            "start_time_seconds" => 3.33,
            "end_time_seconds" => 6.67
          }
        )

      # Try to split at start frame (should fail)
      assert {:error, reason} =
               VirtualClips.add_cut_point(
                 source_video.id,
                 100,
                 user_id
               )

      assert reason =~ "is at or before clip start"

      # Try to split at end frame (should fail)
      assert {:error, reason} =
               VirtualClips.add_cut_point(
                 source_video.id,
                 200,
                 user_id
               )

      assert reason =~ "is at or after clip end"
    end

    test "rejects split when frame is outside any clip" do
      source_video = insert(:source_video)
      user_id = 123

      insert(:virtual_clip,
        source_video: source_video,
        start_frame: 100,
        end_frame: 200,
        cut_points: %{
          "start_frame" => 100,
          "end_frame" => 200,
          "start_time_seconds" => 3.33,
          "end_time_seconds" => 6.67
        }
      )

      # Try to split at frame outside any clip
      assert {:error, reason} =
               VirtualClips.add_cut_point(
                 source_video.id,
                 50,
                 user_id
               )

      assert reason =~ "No virtual clip contains frame 50"
    end
  end

  describe "remove_cut_point/3" do
    test "merges adjacent virtual clips" do
      source_video = insert(:source_video)
      user_id = 123

      # Create two adjacent clips
      first_clip =
        insert(:virtual_clip,
          source_video: source_video,
          start_frame: 0,
          end_frame: 150,
          cut_points: %{
            "start_frame" => 0,
            "end_frame" => 150,
            "start_time_seconds" => 0.0,
            "end_time_seconds" => 5.0
          },
          source_video_order: 1
        )

      second_clip =
        insert(:virtual_clip,
          source_video: source_video,
          start_frame: 150,
          end_frame: 300,
          cut_points: %{
            "start_frame" => 150,
            "end_frame" => 300,
            "start_time_seconds" => 5.0,
            "end_time_seconds" => 10.0
          },
          source_video_order: 2
        )

      # Remove cut point at frame 150
      assert {:ok, merged_clip} =
               VirtualClips.remove_cut_point(
                 source_video.id,
                 150,
                 user_id
               )

      # Original clips should be archived
      updated_first = Repo.get!(Clip, first_clip.id)
      updated_second = Repo.get!(Clip, second_clip.id)
      assert updated_first.ingest_state == "archived"
      assert updated_second.ingest_state == "archived"

      # Merged clip should span both originals
      assert merged_clip.start_frame == 0
      assert merged_clip.end_frame == 300
      assert merged_clip.cut_points["start_frame"] == 0
      assert merged_clip.cut_points["end_frame"] == 300
      assert merged_clip.cut_points["start_time_seconds"] == 0.0
      assert merged_clip.cut_points["end_time_seconds"] == 10.0

      # Verify audit trail was created
      operation = Repo.one(VirtualClips.CutPointOperation)
      assert operation.operation_type == "remove"
      assert operation.frame_number == 150
      assert operation.user_id == user_id
    end

    test "rejects removal when no adjacent clips exist" do
      source_video = insert(:source_video)
      user_id = 123

      # Create single clip
      insert(:virtual_clip,
        source_video: source_video,
        start_frame: 100,
        end_frame: 200,
        cut_points: %{
          "start_frame" => 100,
          "end_frame" => 200,
          "start_time_seconds" => 3.33,
          "end_time_seconds" => 6.67
        }
      )

      # Try to remove cut point that doesn't exist between clips
      assert {:error, reason} =
               VirtualClips.remove_cut_point(
                 source_video.id,
                 100,
                 user_id
               )

      assert reason =~ "No clip ends at frame 100"
    end
  end

  describe "move_cut_point/4" do
    test "adjusts boundaries of adjacent clips" do
      source_video = insert(:source_video)
      user_id = 123

      # Create two adjacent clips
      first_clip =
        insert(:virtual_clip,
          source_video: source_video,
          start_frame: 0,
          end_frame: 150,
          cut_points: %{
            "start_frame" => 0,
            "end_frame" => 150,
            "start_time_seconds" => 0.0,
            "end_time_seconds" => 5.0
          }
        )

      second_clip =
        insert(:virtual_clip,
          source_video: source_video,
          start_frame: 150,
          end_frame: 300,
          cut_points: %{
            "start_frame" => 150,
            "end_frame" => 300,
            "start_time_seconds" => 5.0,
            "end_time_seconds" => 10.0
          }
        )

      # Move cut point from 150 to 180
      assert {:ok, {updated_first, updated_second}} =
               VirtualClips.move_cut_point(
                 source_video.id,
                 150,
                 180,
                 user_id
               )

      # First clip should be extended
      assert updated_first.id == first_clip.id
      assert updated_first.end_frame == 180
      assert updated_first.cut_points["end_frame"] == 180

      # Second clip should be shortened
      assert updated_second.id == second_clip.id
      assert updated_second.start_frame == 180
      assert updated_second.cut_points["start_frame"] == 180

      # Verify audit trail was created
      operation = Repo.one(VirtualClips.CutPointOperation)
      assert operation.operation_type == "move"
      assert operation.frame_number == 180
      assert operation.old_frame_number == 150
      assert operation.user_id == user_id
    end

    test "rejects move beyond clip boundaries" do
      source_video = insert(:source_video)
      user_id = 123

      # Create adjacent clips: 0-150, 150-300
      insert(:virtual_clip,
        source_video: source_video,
        start_frame: 0,
        end_frame: 150,
        cut_points: %{
          "start_frame" => 0,
          "end_frame" => 150,
          "start_time_seconds" => 0.0,
          "end_time_seconds" => 5.0
        }
      )

      insert(:virtual_clip,
        source_video: source_video,
        start_frame: 150,
        end_frame: 300,
        cut_points: %{
          "start_frame" => 150,
          "end_frame" => 300,
          "start_time_seconds" => 5.0,
          "end_time_seconds" => 10.0
        }
      )

      # Try to move cut point beyond first clip start
      assert {:error, reason} =
               VirtualClips.move_cut_point(
                 source_video.id,
                 150,
                 -10,
                 user_id
               )

      assert reason =~ "would be at or before first clip start"

      # Try to move cut point beyond second clip end
      assert {:error, reason} =
               VirtualClips.move_cut_point(
                 source_video.id,
                 150,
                 350,
                 user_id
               )

      assert reason =~ "would be at or after second clip end"
    end
  end

  describe "validate_mece_for_source_video/1" do
    test "validates clips with no gaps or overlaps" do
      source_video = insert(:source_video)

      # Create perfectly adjacent clips
      insert(:virtual_clip,
        source_video: source_video,
        cut_points: %{
          "start_frame" => 0,
          "end_frame" => 100,
          "start_time_seconds" => 0.0,
          "end_time_seconds" => 3.33
        }
      )

      insert(:virtual_clip,
        source_video: source_video,
        cut_points: %{
          "start_frame" => 100,
          "end_frame" => 200,
          "start_time_seconds" => 3.33,
          "end_time_seconds" => 6.67
        }
      )

      assert :ok = VirtualClips.validate_mece_for_source_video(source_video.id)
    end

    test "detects overlapping clips" do
      source_video = insert(:source_video)

      # Create overlapping clips
      insert(:virtual_clip,
        source_video: source_video,
        cut_points: %{
          "start_frame" => 0,
          "end_frame" => 120,
          "start_time_seconds" => 0.0,
          "end_time_seconds" => 4.0
        }
      )

      insert(:virtual_clip,
        source_video: source_video,
        cut_points: %{
          "start_frame" => 100,
          "end_frame" => 200,
          "start_time_seconds" => 3.33,
          "end_time_seconds" => 6.67
        }
      )

      assert {:error, reason} = VirtualClips.validate_mece_for_source_video(source_video.id)
      assert reason =~ "Overlap detected"
    end

    test "detects gaps between clips" do
      source_video = insert(:source_video)

      # Create clips with gap
      insert(:virtual_clip,
        source_video: source_video,
        cut_points: %{
          "start_frame" => 0,
          "end_frame" => 100,
          "start_time_seconds" => 0.0,
          "end_time_seconds" => 3.33
        }
      )

      insert(:virtual_clip,
        source_video: source_video,
        cut_points: %{
          # Gap from 100 to 120
          "start_frame" => 120,
          "end_frame" => 200,
          "start_time_seconds" => 4.0,
          "end_time_seconds" => 6.67
        }
      )

      assert {:error, reason} = VirtualClips.validate_mece_for_source_video(source_video.id)
      assert reason =~ "Gap detected"
    end
  end

  describe "get_cut_points_for_source_video/1" do
    test "returns sorted list of all cut point frames" do
      source_video = insert(:source_video)

      insert(:virtual_clip,
        source_video: source_video,
        cut_points: %{
          "start_frame" => 50,
          "end_frame" => 150,
          "start_time_seconds" => 1.67,
          "end_time_seconds" => 5.0
        }
      )

      insert(:virtual_clip,
        source_video: source_video,
        cut_points: %{
          "start_frame" => 0,
          "end_frame" => 50,
          "start_time_seconds" => 0.0,
          "end_time_seconds" => 1.67
        }
      )

      cut_points = VirtualClips.get_cut_points_for_source_video(source_video.id)
      assert cut_points == [0, 50, 150]
    end
  end

  describe "ensure_complete_coverage/2" do
    test "validates complete coverage from start to end" do
      source_video = insert(:source_video)

      insert(:virtual_clip,
        source_video: source_video,
        cut_points: %{
          "start_frame" => 0,
          "end_frame" => 300,
          "start_time_seconds" => 0.0,
          "end_time_seconds" => 10.0
        }
      )

      assert :ok = VirtualClips.ensure_complete_coverage(source_video.id, 10.0)
    end

    test "detects coverage gap at start" do
      source_video = insert(:source_video)

      insert(:virtual_clip,
        source_video: source_video,
        cut_points: %{
          # Doesn't start at 0
          "start_frame" => 30,
          "end_frame" => 300,
          "start_time_seconds" => 1.0,
          "end_time_seconds" => 10.0
        }
      )

      assert {:error, reason} = VirtualClips.ensure_complete_coverage(source_video.id, 10.0)
      assert reason =~ "Coverage gap at start"
    end

    test "detects coverage gap at end" do
      source_video = insert(:source_video)

      insert(:virtual_clip,
        source_video: source_video,
        cut_points: %{
          "start_frame" => 0,
          # Ends before video end
          "end_frame" => 270,
          "start_time_seconds" => 0.0,
          "end_time_seconds" => 9.0
        }
      )

      assert {:error, reason} = VirtualClips.ensure_complete_coverage(source_video.id, 10.0)
      assert reason =~ "Coverage gap at end"
    end
  end

  describe "update_virtual_clip_cut_points/2" do
    test "updates cut points for virtual clip" do
      clip =
        insert(:virtual_clip,
          cut_points: %{
            "start_frame" => 0,
            "end_frame" => 100,
            "start_time_seconds" => 0.0,
            "end_time_seconds" => 3.33
          }
        )

      new_cut_points = %{
        "start_frame" => 0,
        "end_frame" => 120,
        "start_time_seconds" => 0.0,
        "end_time_seconds" => 4.0
      }

      assert {:ok, updated_clip} =
               VirtualClips.update_virtual_clip_cut_points(
                 clip.id,
                 new_cut_points
               )

      assert updated_clip.cut_points == new_cut_points
      assert updated_clip.end_frame == 120
      assert updated_clip.end_time_seconds == 4.0
    end

    test "rejects update for physical clip" do
      clip = insert(:clip, is_virtual: false)

      new_cut_points = %{
        "start_frame" => 0,
        "end_frame" => 120,
        "start_time_seconds" => 0.0,
        "end_time_seconds" => 4.0
      }

      assert {:error, reason} =
               VirtualClips.update_virtual_clip_cut_points(
                 clip.id,
                 new_cut_points
               )

      assert reason =~ "Cannot update cut points for physical clip"
    end
  end
end
