defmodule Heaters.EventsTest do
  use Heaters.DataCase, async: true

  alias Heaters.Events
  alias Heaters.Events.ReviewEvent
  alias Heaters.Clips.Clip
  alias Heaters.Videos.SourceVideo

  describe "log_review_action/4" do
    setup do
      source_video = insert(:source_video)
      clip = insert(:clip, source_video: source_video)

      %{clip: clip}
    end

    test "creates event with basic review action", %{clip: clip} do
      assert {:ok, event} = Events.log_review_action(clip.id, "approve", "admin")

      assert event.clip_id == clip.id
      assert event.action == "approve"
      assert event.reviewer_id == "admin"
      assert event.event_data == %{}
      assert event.processed_at == nil
      refute is_nil(event.inserted_at)
    end

    test "creates event with event_data", %{clip: clip} do
      event_data = %{"reason" => "high quality"}
      assert {:ok, event} = Events.log_review_action(clip.id, "approve", "admin", event_data)

      assert event.event_data == event_data
    end

    test "returns error for invalid clip_id" do
      assert {:error, changeset} = Events.log_review_action(99999, "approve", "admin")
      assert changeset.errors[:clip] == {"does not exist", []}
    end

    test "returns error for missing required fields" do
      assert {:error, changeset} = Events.log_review_action(nil, "approve", "admin")
      assert changeset.errors[:clip_id] == {"can't be blank", [validation: :required]}
    end

    test "supports all valid review actions", %{clip: clip} do
      actions = ["approve", "skip", "archive", "undo"]

      for action <- actions do
        assert {:ok, event} = Events.log_review_action(clip.id, action, "admin")
        assert event.action == action
      end
    end
  end

  describe "log_merge_action/3" do
    setup do
      source_video = insert(:source_video)
      clip1 = insert(:clip, source_video: source_video)
      clip2 = insert(:clip, source_video: source_video)

      %{clip1: clip1, clip2: clip2}
    end

    test "creates two events for merge action", %{clip1: clip1, clip2: clip2} do
      assert {:ok, events} = Events.log_merge_action(clip1.id, clip2.id, "admin")

      assert length(events) == 2

      [target_event, source_event] = events

      assert target_event.clip_id == clip1.id
      assert target_event.action == "selected_merge_target"
      assert target_event.reviewer_id == "admin"

      assert source_event.clip_id == clip2.id
      assert source_event.action == "selected_merge_source"
      assert source_event.reviewer_id == "admin"
      assert source_event.event_data == %{"merge_target_clip_id" => clip1.id}
    end

    test "handles database transaction properly", %{clip1: clip1, clip2: clip2} do
      # Test that both events are created in same transaction
      {:ok, _events} = Events.log_merge_action(clip1.id, clip2.id, "admin")

      # Both events should exist
      assert Repo.aggregate(ReviewEvent, :count) == 2
    end

    test "returns error for invalid clip_id" do
      assert {:error, _} = Events.log_merge_action(99999, 1, "admin")
      assert Repo.all(ReviewEvent) == []
    end
  end

  describe "log_split_action/3" do
    setup do
      source_video = insert(:source_video)
      clip = insert(:clip, source_video: source_video)

      %{clip: clip}
    end

    test "creates event with split frame data", %{clip: clip} do
      frame = 450

      assert {:ok, event} = Events.log_split_action(clip.id, frame, "admin")

      assert event.clip_id == clip.id
      assert event.action == "selected_split"
      assert event.reviewer_id == "admin"
      assert event.event_data == %{"split_at_frame" => frame}
      assert event.processed_at == nil
    end

    test "returns error for invalid clip_id" do
      assert {:error, _} = Events.log_split_action(99999, 450, "admin")
    end
  end

  describe "log_group_action/3" do
    setup do
      source_video = insert(:source_video)
      clip1 = insert(:clip, source_video: source_video)
      clip2 = insert(:clip, source_video: source_video)

      %{clip1: clip1, clip2: clip2}
    end

    test "creates two events for group action", %{clip1: clip1, clip2: clip2} do
      assert {:ok, events} = Events.log_group_action(clip1.id, clip2.id, "admin")

      assert length(events) == 2

      [target_event, source_event] = events

      assert target_event.clip_id == clip1.id
      assert target_event.action == "selected_group_target"
      assert target_event.reviewer_id == "admin"

      assert source_event.clip_id == clip2.id
      assert source_event.action == "selected_group_source"
      assert source_event.reviewer_id == "admin"
      assert source_event.event_data == %{"group_with_clip_id" => clip1.id}
    end

    test "handles database transaction properly", %{clip1: clip1, clip2: clip2} do
      # Test that both events are created in same transaction
      {:ok, _events} = Events.log_group_action(clip1.id, clip2.id, "admin")

      # Both events should exist
      assert Repo.aggregate(ReviewEvent, :count) == 2
    end

    test "returns error for invalid clip_id" do
      assert {:error, _} = Events.log_group_action(99999, 1, "admin")
      assert Repo.all(ReviewEvent) == []
    end
  end

  describe "create_event/1" do
    setup do
      source_video = insert(:source_video)
      clip = insert(:clip, source_video: source_video)

      %{clip: clip}
    end

    test "creates event with valid attributes", %{clip: clip} do
      attrs = %{
        clip_id: clip.id,
        action: "test_action",
        reviewer_id: "test_user",
        event_data: %{"key" => "value"}
      }

      assert {:ok, event} = Events.create_event(attrs)

      assert event.clip_id == clip.id
      assert event.action == "test_action"
      assert event.reviewer_id == "test_user"
      assert event.event_data == %{"key" => "value"}
    end

    test "returns error changeset for invalid attributes" do
      # Missing required fields
      attrs = %{action: "test_action"}

      assert {:error, changeset} = Events.create_event(attrs)
      assert changeset.errors[:clip_id] == {"can't be blank", [validation: :required]}
    end
  end

  describe "log_clip_action!/3" do
    setup do
      source_video = insert(:source_video)
      clip = insert(:clip, source_video: source_video)

      %{clip: clip}
    end

    test "creates event and returns it", %{clip: clip} do
      event = Events.log_clip_action!(clip.id, "test_action", "admin")

      assert event.clip_id == clip.id
      assert event.action == "test_action"
      assert event.reviewer_id == "admin"
    end

    test "raises on invalid data" do
      assert_raise Ecto.InvalidChangesetError, fn ->
        Events.log_clip_action!(99999, "test_action", "admin")
      end
    end
  end

end
