defmodule Heaters.Clips.Operations.Split.Validation do
  @moduledoc """
  Pure domain functions for split operation validation.
  Used by Operations.Split for business logic.
  """

  alias Heaters.Clips.Operations.Shared.ClipValidation

  @doc """
  Validates if a clip is ready for split operations.

  ## Parameters
  - `clip`: Clip struct with ingest_state

  ## Returns
  - `:ok` if clip is ready for splitting
  - `{:error, String.t()}` if clip is not ready
  """
  @spec validate_split_readiness(map()) :: :ok | {:error, String.t()}
  def validate_split_readiness(%{ingest_state: state}) do
    case ClipValidation.validate_clip_state_for_split(state) do
      :ok ->
        :ok

      {:error, :invalid_state_for_split} ->
        {:error,
         "Clip state '#{state}' is not ready for split operations. Required states: pending_review"}
    end
  end

  @doc """
  Validates split operation requirements.

  ## Parameters
  - `clip`: Clip struct
  - `split_at_frame`: Frame number where to split

  ## Returns
  - `:ok` if all requirements are met
  - `{:error, String.t()}` if requirements are not met
  """
  @spec validate_split_requirements(map(), integer()) :: :ok | {:error, String.t()}
  def validate_split_requirements(clip, split_at_frame) do
    with :ok <- validate_split_readiness(clip),
         :ok <- validate_clip_has_video_file(clip),
         :ok <- validate_clip_has_source_video(clip),
         :ok <- validate_split_frame_is_integer(split_at_frame),
         :ok <- validate_split_frame_bounds(clip, split_at_frame) do
      :ok
    end
  end

  @doc """
  Validates that the split frame is within the clip's boundaries.

  ## Parameters
  - `clip`: Clip struct with start_frame and end_frame
  - `split_at_frame`: Frame number where to split

  ## Returns
  - `:ok` if split frame is within bounds
  - `{:error, String.t()}` if split frame is outside clip range
  """
  @spec validate_split_frame_bounds(map(), integer()) :: :ok | {:error, String.t()}
  def validate_split_frame_bounds(
        %{start_frame: start_frame, end_frame: end_frame},
        split_at_frame
      ) do
    if split_at_frame > start_frame and split_at_frame < end_frame do
      :ok
    else
      {:error,
       "Split frame #{split_at_frame} is outside clip range (#{start_frame}-#{end_frame})"}
    end
  end

  @doc """
  Validates that a clip has an associated source video.

  ## Parameters
  - `clip`: Clip struct with source_video association

  ## Returns
  - `:ok` if clip has source video
  - `{:error, String.t()}` if no source video
  """
  @spec validate_clip_has_source_video(map()) :: :ok | {:error, String.t()}
  def validate_clip_has_source_video(%{source_video: nil}) do
    {:error, "Clip has no associated source video"}
  end

  def validate_clip_has_source_video(%{source_video: _source_video}), do: :ok

  @doc """
  Validates that the split frame parameter is a positive integer.

  ## Parameters
  - `split_at_frame`: Frame number to validate

  ## Returns
  - `:ok` if frame is valid integer
  - `{:error, String.t()}` if frame is invalid
  """
  @spec validate_split_frame_is_integer(any()) :: :ok | {:error, String.t()}
  def validate_split_frame_is_integer(split_at_frame)
      when is_integer(split_at_frame) and split_at_frame > 0 do
    :ok
  end

  def validate_split_frame_is_integer(invalid_frame) do
    {:error, "Split frame must be a positive integer, got: #{inspect(invalid_frame)}"}
  end

  @doc """
  Validates that uploaded clips list is not empty.

  ## Parameters
  - `uploaded_clips`: List of uploaded clip data

  ## Returns
  - `:ok` if clips exist
  - `{:error, String.t()}` if no clips created
  """
  @spec validate_clips_created(list()) :: :ok | {:error, String.t()}
  def validate_clips_created([]), do: {:error, "Split operation did not create any valid clips"}
  def validate_clips_created([_ | _]), do: :ok

  ## Private helper functions

  @spec validate_clip_has_video_file(map()) :: :ok | {:error, String.t()}
  defp validate_clip_has_video_file(%{clip_filepath: filepath})
       when is_binary(filepath) and filepath != "" do
    :ok
  end

  defp validate_clip_has_video_file(_clip) do
    {:error, "Clip does not have a video file for split operation"}
  end
end
