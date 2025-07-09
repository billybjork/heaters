defmodule Heaters.Clips.Operations.Shared.ClipValidation do
  @moduledoc """
  Pure clip state validation functions for domain operations.

  This module contains pure business logic for validating whether clips
  are in the correct state for various transformation operations.
  No side effects or I/O operations.
  """

  @valid_sprite_states ~w[spliced generating_sprite]
  @valid_keyframe_states ~w[review_approved keyframe_failed]
  @valid_split_states ~w[pending_review]
  @valid_merge_states ~w[pending_review]

  @doc """
  Validate that a clip is in the correct state for sprite generation.

  ## Examples

      iex> ClipValidation.validate_clip_state_for_sprite("spliced")
      :ok

      iex> ClipValidation.validate_clip_state_for_sprite("pending_review")
      {:error, :invalid_state_for_sprite}
  """
  @spec validate_clip_state_for_sprite(String.t()) :: :ok | {:error, atom()}
  def validate_clip_state_for_sprite(state) when state in @valid_sprite_states, do: :ok
  def validate_clip_state_for_sprite(_), do: {:error, :invalid_state_for_sprite}

  @doc """
  Validate that a clip is in the correct state for keyframe extraction.
  """
  @spec validate_clip_state_for_keyframe(String.t()) :: :ok | {:error, atom()}
  def validate_clip_state_for_keyframe(state) when state in @valid_keyframe_states, do: :ok
  def validate_clip_state_for_keyframe(_), do: {:error, :invalid_state_for_keyframe}

  @doc """
  Validate that a clip is in the correct state for splitting operations.
  """
  @spec validate_clip_state_for_split(String.t()) :: :ok | {:error, atom()}
  def validate_clip_state_for_split(state) when state in @valid_split_states, do: :ok
  def validate_clip_state_for_split(_), do: {:error, :invalid_state_for_split}

  @doc """
  Validate that a clip is in the correct state for merging operations.
  """
  @spec validate_clip_state_for_merge(String.t()) :: :ok | {:error, atom()}
  def validate_clip_state_for_merge(state) when state in @valid_merge_states, do: :ok
  def validate_clip_state_for_merge(_), do: {:error, :invalid_state_for_merge}

  @doc """
  Get all valid states for a given operation type.
  Useful for error messages and documentation.

  ## Examples

      iex> ClipValidation.valid_states_for_operation(:sprite)
      ["spliced"]
  """
  @spec valid_states_for_operation(atom()) :: [String.t()]
  def valid_states_for_operation(:sprite), do: @valid_sprite_states
  def valid_states_for_operation(:keyframe), do: @valid_keyframe_states
  def valid_states_for_operation(:split), do: @valid_split_states
  def valid_states_for_operation(:merge), do: @valid_merge_states

  @doc """
  Validate that a clip has an associated video file.

  Shared validation function used across split, merge, and keyframe operations.

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

  @doc """
  Validate that a clip has an associated source video.

  Shared validation function used across split operations.

  ## Examples

      iex> clip = %{source_video: %{id: 123}}
      iex> ClipValidation.validate_clip_has_source_video(clip)
      :ok
      
      iex> clip = %{source_video: nil}
      iex> ClipValidation.validate_clip_has_source_video(clip)
      {:error, :clip_missing_source_video}
  """
  @spec validate_clip_has_source_video(map()) :: :ok | {:error, atom()}
  def validate_clip_has_source_video(%{source_video: source_video})
      when not is_nil(source_video) do
    :ok
  end

  def validate_clip_has_source_video(_clip) do
    {:error, :clip_missing_source_video}
  end
end
