defmodule Heaters.EventsTest do
  use Heaters.DataCase, async: true

  alias Heaters.Events
  alias Heaters.Events.ClipEvent
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
      refute is_nil(event.created_at)
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
      target_clip = insert(:clip, source_video: source_video)
      source_clip = insert(:clip, source_video: source_video)

      %{target_clip: target_clip, source_clip: source_clip}
    end

    test "creates both target and source events", %{
      target_clip: target_clip,
      source_clip: source_clip
    } do
      assert {:ok, {target_event, source_event}} =
               Events.log_merge_action(target_clip.id, source_clip.id, "admin")

      # Target event
      assert target_event.clip_id == target_clip.id
      assert target_event.action == "selected_merge_target"
      assert target_event.reviewer_id == "admin"

      # Source event
      assert source_event.clip_id == source_clip.id
      assert source_event.action == "selected_merge_source"
      assert source_event.reviewer_id == "admin"
      assert source_event.event_data == %{"merge_target_clip_id" => target_clip.id}
    end

    test "rollbacks on error" do
      # Using invalid source_clip_id should rollback the entire transaction
      source_video = insert(:source_video)
      target_clip = insert(:clip, source_video: source_video)

      assert {:error, _changeset} = Events.log_merge_action(target_clip.id, 99999, "admin")

      # No events should be created
      assert Repo.all(ClipEvent) == []
    end
  end

  describe "log_split_action/3" do
    setup do
      source_video = insert(:source_video)
      clip = insert(:clip, source_video: source_video)

      %{clip: clip}
    end

    test "creates split event with frame data", %{clip: clip} do
      split_frame = 450
      assert {:ok, event} = Events.log_split_action(clip.id, split_frame, "admin")

      assert event.clip_id == clip.id
      assert event.action == "selected_split"
      assert event.reviewer_id == "admin"
      assert event.event_data == %{"split_at_frame" => split_frame}
    end

    test "handles different frame values", %{clip: clip} do
      frames = [0, 100, 1000, 5000]

      for frame <- frames do
        assert {:ok, event} = Events.log_split_action(clip.id, frame, "admin#{frame}")
        assert event.event_data["split_at_frame"] == frame
      end
    end
  end

  describe "log_group_action/3" do
    setup do
      source_video = insert(:source_video)
      target_clip = insert(:clip, source_video: source_video)
      source_clip = insert(:clip, source_video: source_video)

      %{target_clip: target_clip, source_clip: source_clip}
    end

    test "creates both target and source events", %{
      target_clip: target_clip,
      source_clip: source_clip
    } do
      assert {:ok, {target_event, source_event}} =
               Events.log_group_action(target_clip.id, source_clip.id, "admin")

      # Target event
      assert target_event.clip_id == target_clip.id
      assert target_event.action == "selected_group_target"
      assert target_event.reviewer_id == "admin"

      # Source event
      assert source_event.clip_id == source_clip.id
      assert source_event.action == "selected_group_source"
      assert source_event.reviewer_id == "admin"
      assert source_event.event_data == %{"group_with_clip_id" => target_clip.id}
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

  # Helper function to verify event relationships
  defp insert(schema, attrs \\ %{}) do
    case schema do
      :source_video ->
        %SourceVideo{
          title: "Test Video #{System.unique_integer()}",
          ingest_state: "new"
        }
        |> SourceVideo.changeset(attrs)
        |> Repo.insert!()

      :clip ->
        default_attrs = %{
          clip_filepath: "/tmp/test_clip_#{System.unique_integer()}.mp4",
          clip_identifier: "test_clip_#{System.unique_integer()}",
          start_frame: 0,
          end_frame: 100,
          ingest_state: "pending_review"
        }

        %Clip{}
        |> Clip.changeset(Map.merge(default_attrs, attrs))
        |> Repo.insert!()
    end
  end
end
