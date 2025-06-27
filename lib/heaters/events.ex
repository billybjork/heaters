defmodule Heaters.Events do
  @moduledoc """
  Main context for event sourcing and review workflow events.

  This module serves as the primary entry point for all event-related operations,
  providing a clean public API while delegating to specialized sub-modules.

  ## Sub-contexts

  - **ReviewEvents**: Review event creation and logging (write side - CQRS) (`Heaters.Events.ReviewEvents`)
  - **EventProcessor**: Event processing and job orchestration (read side - CQRS) (`Heaters.Events.EventProcessor`)

  ## Schema

  - **ReviewEvent**: Review workflow event schema (`Heaters.Events.ReviewEvent`)

  ## Examples

      # Write side - logging events
      Events.log_review_action(123, "approve", "admin")
      Events.log_merge_action(123, 456, "admin")
      Events.log_split_action(123, 450, "admin")

      # Read side - processing events
      Events.commit_pending_actions()
      Events.get_processing_stats()
  """

  # Delegated functions for event operations
  alias Heaters.Events.{ReviewEvents, EventProcessor}

  # Write side operations (command handling)
  defdelegate log_review_action(clip_id, action, reviewer_id, event_data \\ %{}), to: ReviewEvents
  defdelegate log_merge_action(target_clip_id, source_clip_id, reviewer_id), to: ReviewEvents
  defdelegate log_split_action(clip_id, split_frame, reviewer_id), to: ReviewEvents
  defdelegate log_group_action(target_clip_id, source_clip_id, reviewer_id), to: ReviewEvents
  defdelegate create_event(attrs), to: ReviewEvents

  # Legacy support
  defdelegate log_clip_action!(clip_id, action, reviewer_id), to: ReviewEvents

  # Read side operations (event processing)
  defdelegate commit_pending_actions(), to: EventProcessor
  defdelegate get_unprocessed_events(), to: EventProcessor
  defdelegate mark_event_processed(event_id), to: EventProcessor
  defdelegate mark_events_processed(event_ids), to: EventProcessor
  defdelegate build_worker_job(event), to: EventProcessor
  defdelegate get_processing_stats(), to: EventProcessor
end
