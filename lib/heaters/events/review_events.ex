defmodule Heaters.Events.ReviewEvents do
  @moduledoc """
  Review event sourcing - write side (command handling).

  This module provides functions for creating review workflow events in response to user actions.
  It follows the CQRS pattern where this module handles the "command" side -
  writing events to the event store (review_events table).

  The read side (event processing) is handled by EventProcessor.
  """

  alias Heaters.Events.ReviewEvent
  alias Heaters.Repo
  require Logger

  @doc """
  Log a basic review action (approve, skip, archive, undo).

  ## Examples

      iex> ReviewEvents.log_review_action(123, "approve", "admin")
      {:ok, %ReviewEvent{}}

      iex> ReviewEvents.log_review_action(123, "split", "admin", %{"split_at_frame" => 450})
      {:ok, %ReviewEvent{}}
  """
  @spec log_review_action(integer(), String.t(), String.t(), map()) ::
          {:ok, ReviewEvent.t()} | {:error, any()}
  def log_review_action(clip_id, action, reviewer_id, event_data \\ %{}) do
    attrs = %{
      clip_id: clip_id,
      action: action,
      reviewer_id: reviewer_id,
      event_data: event_data
    }

    %ReviewEvent{}
    |> ReviewEvent.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, event} ->
        Logger.info(
          "ReviewEvents: Logged #{action} action for clip_id: #{clip_id} by reviewer: #{reviewer_id}"
        )

        {:ok, event}

      {:error, changeset} ->
        Logger.error(
          "ReviewEvents: Failed to log #{action} action for clip_id: #{clip_id}, errors: #{inspect(changeset.errors)}"
        )

        {:error, changeset}
    end
  end

  @doc """
  Log a merge action between two clips.

  Creates two events:
  - "selected_merge_target" for the target clip
  - "selected_merge_source" for the source clip (with reference to target)

  ## Examples

      iex> ReviewEvents.log_merge_action(123, 456, "admin")
      {:ok, [%ReviewEvent{action: "selected_merge_target"}, %ReviewEvent{action: "selected_merge_source"}]}
  """
  @spec log_merge_action(integer(), integer(), String.t()) ::
          {:ok, list(ReviewEvent.t())} | {:error, any()}
  def log_merge_action(target_clip_id, source_clip_id, reviewer_id) do
    Repo.transaction(fn ->
      # Create target event
      {:ok, target_event} =
        create_event(%{
          clip_id: target_clip_id,
          action: "selected_merge_target",
          reviewer_id: reviewer_id
        })

      # Create source event with reference to target
      {:ok, source_event} =
        create_event(%{
          clip_id: source_clip_id,
          action: "selected_merge_source",
          reviewer_id: reviewer_id,
          event_data: %{"merge_target_clip_id" => target_clip_id}
        })

      Logger.info(
        "ReviewEvents: Logged merge action - target: #{target_clip_id}, source: #{source_clip_id} by reviewer: #{reviewer_id}"
      )

      [target_event, source_event]
    end)
  end

  @doc """
  Log a split action on a clip.

  ## Examples

      iex> ReviewEvents.log_split_action(123, 450, "admin")
      {:ok, %ReviewEvent{action: "selected_split"}}
  """
  @spec log_split_action(integer(), integer(), String.t()) ::
          {:ok, ReviewEvent.t()} | {:error, any()}
  def log_split_action(clip_id, split_frame, reviewer_id) do
    attrs = %{
      clip_id: clip_id,
      action: "selected_split",
      reviewer_id: reviewer_id,
      event_data: %{"split_at_frame" => split_frame}
    }

    create_event(attrs)
    |> case do
      {:ok, event} ->
        Logger.info(
          "ReviewEvents: Logged split action for clip_id: #{clip_id} at frame: #{split_frame} by reviewer: #{reviewer_id}"
        )

        {:ok, event}

      error ->
        Logger.error(
          "ReviewEvents: Failed to log split action for clip_id: #{clip_id}, error: #{inspect(error)}"
        )

        error
    end
  end

  @doc """
  Log a group action between two clips.

  Creates two events:
  - "selected_group_target" for the target clip
  - "selected_group_source" for the source clip (with reference to target)

  ## Examples

      iex> ReviewEvents.log_group_action(123, 456, "admin")
      {:ok, [%ReviewEvent{action: "selected_group_target"}, %ReviewEvent{action: "selected_group_source"}]}
  """
  @spec log_group_action(integer(), integer(), String.t()) ::
          {:ok, list(ReviewEvent.t())} | {:error, any()}
  def log_group_action(target_clip_id, source_clip_id, reviewer_id) do
    Repo.transaction(fn ->
      # Create target event
      {:ok, target_event} =
        create_event(%{
          clip_id: target_clip_id,
          action: "selected_group_target",
          reviewer_id: reviewer_id
        })

      # Create source event with reference to target
      {:ok, source_event} =
        create_event(%{
          clip_id: source_clip_id,
          action: "selected_group_source",
          reviewer_id: reviewer_id,
          event_data: %{"group_with_clip_id" => target_clip_id}
        })

      Logger.info(
        "ReviewEvents: Logged group action - target: #{target_clip_id}, source: #{source_clip_id} by reviewer: #{reviewer_id}"
      )

      [target_event, source_event]
    end)
  end

  @doc """
  Convenience function for creating a single event with error handling.

  This is the internal function used by the public API functions.
  """
  @spec create_event(map()) :: {:ok, ReviewEvent.t()} | {:error, any()}
  def create_event(attrs) do
    %ReviewEvent{}
    |> ReviewEvent.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Legacy function for backwards compatibility.
  Will be deprecated once all callers are updated to use the new functions.
  """
  @spec log_clip_action!(integer(), String.t(), String.t()) :: ReviewEvent.t()
  def log_clip_action!(clip_id, action, reviewer_id) do
    case log_review_action(clip_id, action, reviewer_id) do
      {:ok, event} -> event
      {:error, changeset} -> raise "Failed to create event: #{inspect(changeset.errors)}"
    end
  end
end
