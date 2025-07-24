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

      iex> ErrorFormatting.format_domain_error(:invalid_state_for_keyframe, "pending_review")
      "Clip state 'pending_review' is not valid for keyframe extraction. Valid states: [\"review_approved\", \"keyframe_failed\"]"

      iex> ErrorFormatting.format_domain_error(:video_too_short, 0.05)
      "Video too short for processing: 0.05s"
  """
  @spec format_domain_error(atom(), any()) :: String.t()
  def format_domain_error(:invalid_state_for_keyframe, state) do
    valid_states = ClipValidation.valid_states_for_operation(:keyframe)

    "Clip state '#{state}' is not valid for keyframe extraction. Valid states: #{inspect(valid_states)}"
  end

  def format_domain_error(:video_too_short, duration) do
    "Video too short for processing: #{duration}s"
  end

  def format_domain_error(:invalid_keyframe_strategy, strategy) do
    "Invalid keyframe strategy: #{strategy}"
  end

  def format_domain_error(:clip_missing_video_file, clip_id) do
    "Clip #{clip_id} does not have an associated video file"
  end

  def format_domain_error(:clip_missing_source_video, clip_id) do
    "Clip #{clip_id} does not have an associated source video"
  end

  def format_domain_error(:invalid_clip_id_type, {clip_type, clip_id}) do
    "#{String.capitalize(clip_type)} clip ID must be an integer, got: #{inspect(clip_id)}"
  end

  def format_domain_error(:invalid_clip_id_value, {clip_type, clip_id}) do
    "#{String.capitalize(clip_type)} clip ID must be positive, got: #{clip_id}"
  end

  def format_domain_error(error_type, details) do
    "Domain error #{error_type}: #{inspect(details)}"
  end

  @doc """
  Format multiple domain errors into a single message.

  ## Examples

      iex> errors = [
      ...>   {:invalid_state_for_keyframe, "pending_review"},
      ...>   {:video_too_short, 0.05}
      ...> ]
      iex> ErrorFormatting.format_multiple_errors(errors)
      "Multiple errors: Clip state 'pending_review' is not valid for keyframe extraction. Valid states: [\"review_approved\", \"keyframe_failed\"]; Video too short for processing: 0.05s"
  """
  @spec format_multiple_errors([{atom(), any()}]) :: String.t()
  def format_multiple_errors(errors) when is_list(errors) do
    error_messages =
      errors
      |> Enum.map(fn {error_type, details} -> format_domain_error(error_type, details) end)
      |> Enum.join("; ")

    "Multiple errors: #{error_messages}"
  end

  @doc """
  Format validation context with operation-specific messaging.

  ## Examples

      iex> ErrorFormatting.format_validation_context(:keyframe, :readiness_check)
      "Keyframe operation readiness validation failed"

      iex> ErrorFormatting.format_validation_context(:export, :requirement_check)
      "Export operation requirement validation failed"
  """
  @spec format_validation_context(atom(), atom()) :: String.t()
  def format_validation_context(operation, context) do
    operation_name = String.capitalize(Atom.to_string(operation))

    case context do
      :readiness_check ->
        "#{operation_name} operation readiness validation failed"

      :requirement_check ->
        "#{operation_name} operation requirement validation failed"

      :frame_bounds_check ->
        "#{operation_name} operation frame bounds validation failed"

      :clip_compatibility_check ->
        "#{operation_name} operation clip compatibility validation failed"

      _ ->
        "#{operation_name} operation validation failed"
    end
  end
end
