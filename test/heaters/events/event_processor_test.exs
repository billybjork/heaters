defmodule Heaters.Events.EventProcessorTest do
  use Heaters.DataCase, async: true

  alias Heaters.Events.EventProcessor
  alias Heaters.Events.ClipEvent
  alias Heaters.Clips.Clip
  alias Heaters.Video.Intake.SourceVideo
  alias Heaters.Workers.Clip.{SplitWorker, MergeWorker}

  describe "get_unprocessed_events/0" do
    setup do
      source_video = insert(:source_video)
      clip = insert(:clip, source_video: source_video)

      %{clip: clip}
    end

    test "returns only unprocessed split and merge events", %{clip: clip} do
      # Create various events
      split_event = insert(:clip_event, clip: clip, action: "selected_split", processed_at: nil)

      merge_event =
        insert(:clip_event, clip: clip, action: "selected_merge_source", processed_at: nil)

      processed_event =
        insert(:clip_event,
          clip: clip,
          action: "selected_split",
          processed_at: DateTime.utc_now()
        )

      other_event = insert(:clip_event, clip: clip, action: "selected_approve", processed_at: nil)

      unprocessed = EventProcessor.get_unprocessed_events()

      event_ids = Enum.map(unprocessed, & &1.id)
      assert split_event.id in event_ids
      assert merge_event.id in event_ids
      refute processed_event.id in event_ids
      refute other_event.id in event_ids
    end

    test "returns empty list when no unprocessed events" do
      assert EventProcessor.get_unprocessed_events() == []
    end
  end

  describe "mark_event_processed/1" do
    setup do
      source_video = insert(:source_video)
      clip = insert(:clip, source_video: source_video)
      event = insert(:clip_event, clip: clip, processed_at: nil)

      %{event: event}
    end

    test "marks single event as processed", %{event: event} do
      assert is_nil(event.processed_at)

      assert {:ok, updated_event} = EventProcessor.mark_event_processed(event.id)

      refute is_nil(updated_event.processed_at)
      assert DateTime.diff(updated_event.processed_at, DateTime.utc_now()) < 5
    end

    test "returns error for non-existent event" do
      assert {:error, :not_found} = EventProcessor.mark_event_processed(99999)
    end
  end

  describe "mark_events_processed/1" do
    setup do
      source_video = insert(:source_video)
      clip = insert(:clip, source_video: source_video)

      event1 = insert(:clip_event, clip: clip, processed_at: nil)
      event2 = insert(:clip_event, clip: clip, processed_at: nil)
      event3 = insert(:clip_event, clip: clip, processed_at: nil)

      %{event_ids: [event1.id, event2.id, event3.id]}
    end

    test "marks multiple events as processed in batch", %{event_ids: event_ids} do
      {count, _} = EventProcessor.mark_events_processed(event_ids)

      assert count == 3

      # Verify all events are processed
      processed_events = Repo.all(from(e in ClipEvent, where: e.id in ^event_ids))
      assert Enum.all?(processed_events, fn event -> not is_nil(event.processed_at) end)
    end

    test "handles empty list" do
      {count, _} = EventProcessor.mark_events_processed([])
      assert count == 0
    end
  end

  describe "build_worker_job/1" do
    setup do
      source_video = insert(:source_video)
      clip = insert(:clip, source_video: source_video)

      %{clip: clip}
    end

    test "builds SplitWorker job for selected_split event", %{clip: clip} do
      event =
        insert(:clip_event,
          clip: clip,
          action: "selected_split",
          event_data: %{"split_at_frame" => 450}
        )

      job = EventProcessor.build_worker_job(event)

      assert %Oban.Job{worker: "Elixir.Heaters.Workers.Clip.SplitWorker"} = job
      assert job.args == %{"clip_id" => clip.id, "split_at_frame" => 450}
    end

    test "builds MergeWorker job for selected_merge_source event", %{clip: clip} do
      target_clip = insert(:clip, source_video: clip.source_video)

      event =
        insert(:clip_event,
          clip: clip,
          action: "selected_merge_source",
          event_data: %{"merge_target_clip_id" => target_clip.id}
        )

      job = EventProcessor.build_worker_job(event)

      assert %Oban.Job{worker: "Elixir.Heaters.Workers.Clip.MergeWorker"} = job
      assert job.args == %{"clip_id_source" => clip.id, "clip_id_target" => target_clip.id}
    end

    test "returns nil for split event missing split_at_frame", %{clip: clip} do
      event =
        insert(:clip_event,
          clip: clip,
          action: "selected_split",
          # Missing split_at_frame
          event_data: %{}
        )

      assert EventProcessor.build_worker_job(event) == nil
    end

    test "returns nil for merge event missing merge_target_clip_id", %{clip: clip} do
      event =
        insert(:clip_event,
          clip: clip,
          action: "selected_merge_source",
          # Missing merge_target_clip_id
          event_data: %{}
        )

      assert EventProcessor.build_worker_job(event) == nil
    end

    test "returns nil for unsupported action", %{clip: clip} do
      event =
        insert(:clip_event,
          clip: clip,
          action: "selected_approve"
        )

      assert EventProcessor.build_worker_job(event) == nil
    end

    test "handles string and atom keys in event_data", %{clip: clip} do
      # Test string keys
      event_string =
        insert(:clip_event,
          clip: clip,
          action: "selected_split",
          event_data: %{"split_at_frame" => 300}
        )

      job_string = EventProcessor.build_worker_job(event_string)
      assert job_string.args["split_at_frame"] == 300

      # Test atom keys (though less common)
      event_atom =
        insert(:clip_event,
          clip: clip,
          action: "selected_split",
          event_data: %{split_at_frame: 600}
        )

      job_atom = EventProcessor.build_worker_job(event_atom)
      assert job_atom.args["split_at_frame"] == 600
    end
  end

  describe "get_processing_stats/0" do
    setup do
      source_video = insert(:source_video)
      clip = insert(:clip, source_video: source_video)

      # Create some processed and unprocessed events
      insert(:clip_event, clip: clip, processed_at: DateTime.utc_now())
      insert(:clip_event, clip: clip, processed_at: DateTime.utc_now())
      insert(:clip_event, clip: clip, processed_at: nil)

      %{clip: clip}
    end

    test "returns correct event counts" do
      stats = EventProcessor.get_processing_stats()

      assert stats.total_events == 3
      assert stats.processed_events == 2
      assert stats.unprocessed_events == 1
    end

    test "returns zero counts when no events exist" do
      # Clean up existing events
      Repo.delete_all(ClipEvent)

      stats = EventProcessor.get_processing_stats()

      assert stats.total_events == 0
      assert stats.processed_events == 0
      assert stats.unprocessed_events == 0
    end
  end

  describe "commit_pending_actions/0" do
    setup do
      source_video = insert(:source_video)
      clip1 = insert(:clip, source_video: source_video)
      clip2 = insert(:clip, source_video: source_video)
      target_clip = insert(:clip, source_video: source_video)

      %{clip1: clip1, clip2: clip2, target_clip: target_clip}
    end

    test "processes unprocessed events and marks them as processed", %{
      clip1: clip1,
      clip2: clip2,
      target_clip: target_clip
    } do
      # Create unprocessed events
      split_event =
        insert(:clip_event,
          clip: clip1,
          action: "selected_split",
          event_data: %{"split_at_frame" => 300},
          processed_at: nil
        )

      merge_event =
        insert(:clip_event,
          clip: clip2,
          action: "selected_merge_source",
          event_data: %{"merge_target_clip_id" => target_clip.id},
          processed_at: nil
        )

      # Mock Oban.insert_all to avoid actual job creation in tests
      # In a real test environment, you might use a test queue or mock

      assert EventProcessor.commit_pending_actions() == :ok

      # Verify events are marked as processed
      updated_split = Repo.get(ClipEvent, split_event.id)
      updated_merge = Repo.get(ClipEvent, merge_event.id)

      refute is_nil(updated_split.processed_at)
      refute is_nil(updated_merge.processed_at)
    end

    test "returns :ok when no unprocessed events" do
      assert EventProcessor.commit_pending_actions() == :ok
    end

    test "handles events with invalid data gracefully", %{clip1: clip1} do
      # Create event with missing required data
      insert(:clip_event,
        clip: clip1,
        action: "selected_split",
        # Missing split_at_frame
        event_data: %{},
        processed_at: nil
      )

      # Should still return :ok and mark the event as processed
      # even though no job was created
      assert EventProcessor.commit_pending_actions() == :ok

      # Event should still be marked as processed
      event = Repo.one(ClipEvent)
      refute is_nil(event.processed_at)
    end
  end

  # Helper functions for test data creation
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

      :clip_event ->
        default_attrs = %{
          action: "test_action",
          reviewer_id: "test_user",
          event_data: %{},
          processed_at: nil
        }

        %ClipEvent{}
        |> ClipEvent.changeset(Map.merge(default_attrs, attrs))
        |> Repo.insert!()
    end
  end
end
