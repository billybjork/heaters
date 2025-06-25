defmodule Heaters.Events.EventProcessor do
  @moduledoc """
  Event sourcing - read side (event processing).

  This module handles the processing of events that have been created by the Events context.
  It follows the CQRS pattern where this module handles the "query" side -
  reading events from the event store and converting them into worker jobs.

  The write side (event creation) is handled by Events.
  """

  import Ecto.Query, warn: false

  alias Heaters.Events.ClipEvent
  alias Heaters.Repo
  alias Heaters.Workers.Clip.{SplitWorker, MergeWorker}
  require Logger

  @doc """
  Finds unprocessed clip events and enqueues the appropriate worker jobs.

  This function is designed to be called periodically by the Dispatcher. It looks
  for "selected_split" and "selected_merge_source" events that haven't been
  processed yet, enqueues the corresponding SplitWorker or MergeWorker, and
  marks the events as processed in a single transaction.

  Returns :ok on success, :error on failure.
  """
  @spec commit_pending_actions() :: :ok | :error
  def commit_pending_actions do
    unprocessed_events = get_unprocessed_events()
    event_count = Enum.count(unprocessed_events)

    if event_count > 0 do
      Logger.info("EventProcessor: Found #{event_count} pending actions to process.")

      jobs =
        unprocessed_events
        |> Enum.map(&build_worker_job/1)
        # Filter out nil jobs (invalid data)
        |> Enum.reject(&is_nil/1)

      event_ids = Enum.map(unprocessed_events, & &1.id)

      Logger.info("EventProcessor: Built #{length(jobs)} valid jobs, attempting to enqueue...")

      # Enqueue all jobs in a single call
      try do
        inserted_jobs = Oban.insert_all(jobs)

        if is_list(inserted_jobs) do
          Logger.info("EventProcessor: Successfully enqueued #{length(inserted_jobs)} jobs.")
        else
          Logger.error(
            "EventProcessor: Unexpected return format from Oban.insert_all: #{inspect(inserted_jobs, limit: 3)}"
          )
        end

        # Mark all processed events in a single call
        {update_count, _} = mark_events_processed(event_ids)
        Logger.info("EventProcessor: Marked #{update_count} events as processed.")
      rescue
        error ->
          Logger.error("EventProcessor: Oban.insert_all raised an exception: #{inspect(error)}")
          Logger.error("EventProcessor: Error details: #{Exception.message(error)}")
      end
    end

    :ok
  rescue
    exception ->
      Logger.error("EventProcessor: Exception occurred: #{inspect(exception)}")
      Logger.error("EventProcessor: Stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}")
      :error
  end

  @doc """
  Get all unprocessed events that require worker job creation.

  Currently processes "selected_split" and "selected_merge_source" events.
  Returns a list of ClipEvent structs.
  """
  @spec get_unprocessed_events() :: list(ClipEvent.t())
  def get_unprocessed_events do
    from(e in ClipEvent,
      where: is_nil(e.processed_at) and e.action in ["selected_split", "selected_merge_source"]
    )
    |> Repo.all()
  end

  @doc """
  Mark a single event as processed by setting its processed_at timestamp.
  """
  @spec mark_event_processed(integer()) :: {:ok, ClipEvent.t()} | {:error, any()}
  def mark_event_processed(event_id) do
    case Repo.get(ClipEvent, event_id) do
      nil ->
        {:error, :not_found}

      event ->
        event
        |> ClipEvent.changeset(%{processed_at: DateTime.utc_now()})
        |> Repo.update()
    end
  end

  @doc """
  Mark multiple events as processed in a single database operation.
  Returns the number of updated records.
  """
  @spec mark_events_processed(list(integer())) :: {integer(), any()}
  def mark_events_processed(event_ids) when is_list(event_ids) do
    from(e in ClipEvent, where: e.id in ^event_ids)
    |> Repo.update_all(set: [processed_at: DateTime.utc_now()])
  end

  @doc """
  Build an appropriate worker job for the given event.

  Converts ClipEvent structs into Oban job structs that can be enqueued.
  Returns the job struct or nil if the event cannot be processed.
  """
  @spec build_worker_job(ClipEvent.t()) :: Oban.Job.t() | nil
  def build_worker_job(%ClipEvent{action: "selected_split"} = event) do
    # Use Access.key to handle both atom and string keys gracefully.
    split_at_frame = get_in(event.event_data, [Access.key("split_at_frame")])

    if split_at_frame do
      Logger.debug(
        "EventProcessor: Building SplitWorker job for clip_id=#{event.clip_id}, split_at_frame=#{split_at_frame}"
      )

      SplitWorker.new(%{
        clip_id: event.clip_id,
        split_at_frame: split_at_frame
      })
    else
      Logger.warning(
        "EventProcessor: Skipping SplitWorker job for clip_id=#{event.clip_id} - missing split_at_frame"
      )

      nil
    end
  end

  def build_worker_job(%ClipEvent{action: "selected_merge_source"} = event) do
    # Use Access.key to handle both atom and string keys gracefully.
    target_clip_id = get_in(event.event_data, [Access.key("merge_target_clip_id")])

    if target_clip_id do
      Logger.debug(
        "EventProcessor: Building MergeWorker job for clip_id_source=#{event.clip_id}, clip_id_target=#{target_clip_id}"
      )

      MergeWorker.new(%{
        clip_id_source: event.clip_id,
        clip_id_target: target_clip_id
      })
    else
      Logger.warning(
        "EventProcessor: Skipping MergeWorker job for clip_id=#{event.clip_id} - missing merge_target_clip_id"
      )

      nil
    end
  end

  def build_worker_job(%ClipEvent{action: action}) do
    Logger.debug("EventProcessor: No worker job defined for action: #{action}")
    nil
  end

  @doc """
  Get statistics about event processing.

  Returns a map with counts of processed and unprocessed events.
  """
  @spec get_processing_stats() :: map()
  def get_processing_stats do
    total_query = from(e in ClipEvent, select: count())
    processed_query = from(e in ClipEvent, where: not is_nil(e.processed_at), select: count())
    unprocessed_query = from(e in ClipEvent, where: is_nil(e.processed_at), select: count())

    %{
      total_events: Repo.one(total_query),
      processed_events: Repo.one(processed_query),
      unprocessed_events: Repo.one(unprocessed_query)
    }
  end
end
