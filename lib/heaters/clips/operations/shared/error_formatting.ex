defmodule Heaters.Clips.Operations.Shared.ErrorFormatting do
  @moduledoc """
  Pure error formatting functions for domain operations.

  This module contains pure business logic for converting domain error atoms
  and data into human-readable error messages. No side effects or I/O operations.
  """

  alias Heaters.Clips.Operations.Shared.ClipValidation

  @doc """
  Format domain errors into human-readable messages.

  ## Examples

      iex> ErrorFormatting.format_domain_error(:invalid_state_for_sprite, "pending_review")
      "Clip state 'pending_review' is not valid for sprite generation. Valid states: [\"spliced\"]"

      iex> ErrorFormatting.format_domain_error(:video_too_short, 0.5)
      "Video too short for processing: 0.5s"
  """
  @spec format_domain_error(atom(), any()) :: String.t()
  def format_domain_error(:invalid_state_for_sprite, state) do
    valid_states = ClipValidation.valid_states_for_operation(:sprite)

    "Clip state '#{state}' is not valid for sprite generation. Valid states: #{inspect(valid_states)}"
  end

  def format_domain_error(:invalid_state_for_keyframe, state) do
    valid_states = ClipValidation.valid_states_for_operation(:keyframe)

    "Clip state '#{state}' is not valid for keyframe extraction. Valid states: #{inspect(valid_states)}"
  end

  def format_domain_error(:invalid_state_for_split, state) do
    valid_states = ClipValidation.valid_states_for_operation(:split)
    "Clip state '#{state}' is not valid for splitting. Valid states: #{inspect(valid_states)}"
  end

  def format_domain_error(:invalid_state_for_merge, state) do
    valid_states = ClipValidation.valid_states_for_operation(:merge)
    "Clip state '#{state}' is not valid for merging. Valid states: #{inspect(valid_states)}"
  end

  def format_domain_error(:video_too_short, duration) do
    "Video too short for processing: #{duration}s"
  end

  def format_domain_error(:invalid_sprite_params, details) do
    "Invalid sprite parameters: #{inspect(details)}"
  end

  def format_domain_error(:invalid_keyframe_strategy, strategy) do
    "Invalid keyframe strategy: #{strategy}"
  end

  def format_domain_error(:invalid_split_frame, frame_num) do
    "Invalid split frame number: #{frame_num}"
  end

  def format_domain_error(:invalid_merge_clips, details) do
    "Invalid clips for merging: #{inspect(details)}"
  end

  def format_domain_error(error_type, details) do
    "Domain error #{error_type}: #{inspect(details)}"
  end

  @doc """
  Format multiple domain errors into a single message.

  ## Examples

      iex> errors = [
      ...>   {:invalid_state_for_sprite, "pending_review"},
      ...>   {:video_too_short, 0.5}
      ...> ]
      iex> ErrorFormatting.format_multiple_errors(errors)
      "Multiple errors: Clip state 'pending_review' is not valid for sprite generation. Valid states: [\"spliced\"]; Video too short for processing: 0.5s"
  """
  @spec format_multiple_errors([{atom(), any()}]) :: String.t()
  def format_multiple_errors(errors) when is_list(errors) do
    error_messages =
      errors
      |> Enum.map(fn {error_type, details} -> format_domain_error(error_type, details) end)
      |> Enum.join("; ")

    "Multiple errors: #{error_messages}"
  end
end
