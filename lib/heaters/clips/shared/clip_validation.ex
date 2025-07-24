defmodule Heaters.Clips.Shared.ClipValidation do
  @moduledoc """
  Pure clip state validation functions for domain operations.

  This module contains pure business logic for validating whether clips
  are in the correct state for keyframe extraction and other operations.
  No side effects or I/O operations.
  """

  @valid_keyframe_states ~w[review_approved keyframe_failed]

  @doc """
  Validate that a clip is in the correct state for keyframe extraction.
  """
  @spec validate_clip_state_for_keyframe(String.t()) :: :ok | {:error, atom()}
  def validate_clip_state_for_keyframe(state) when state in @valid_keyframe_states, do: :ok
  def validate_clip_state_for_keyframe(_), do: {:error, :invalid_state_for_keyframe}

  @doc """
  Get all valid states for a given operation type.
  Useful for error messages and documentation.

  ## Examples

      iex> ClipValidation.valid_states_for_operation(:keyframe)
      ["review_approved", "keyframe_failed"]
  """
  @spec valid_states_for_operation(atom()) :: [String.t()]
  def valid_states_for_operation(:keyframe), do: @valid_keyframe_states

  @doc """
  Validate that a clip has an associated video file.

  Shared validation function used across keyframe and other operations.

  ## Examples

      iex> clip = %{clip_filepath: "/path/to/video.mp4"}
      iex> ClipValidation.validate_clip_has_video_file(clip)
      :ok

      iex> clip = %{clip_filepath: nil}
      iex> ClipValidation.validate_clip_has_video_file(clip)
      {:error, :clip_missing_video_file}
  """
  @spec validate_clip_has_video_file(map()) :: :ok | {:error, atom()}
  def validate_clip_has_video_file(%{clip_filepath: filepath})
      when is_binary(filepath) and filepath != "" do
    :ok
  end

  def validate_clip_has_video_file(_clip) do
    {:error, :clip_missing_video_file}
  end
end
