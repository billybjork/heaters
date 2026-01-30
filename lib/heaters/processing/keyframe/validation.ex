defmodule Heaters.Processing.Keyframe.Validation do
  @moduledoc """
  Validation logic for keyframe operations.
  Used by Processing.Keyframe.Core for business logic.
  """

  alias Heaters.Media.Support.ClipValidation

  @doc """
  Validates if a clip is ready for keyframe extraction.

  ## Parameters
  - `clip`: Clip struct with ingest_state

  ## Returns
  - `:ok` if clip is ready for keyframing
  - `{:error, String.t()}` if clip is not ready
  """
  @spec validate_keyframe_readiness(map()) :: :ok | {:error, String.t()}
  def validate_keyframe_readiness(%{ingest_state: state}) do
    case ClipValidation.validate_clip_state_for_keyframe(state) do
      :ok ->
        :ok

      {:error, :invalid_state_for_keyframe} ->
        {:error,
         "Clip state '#{state}' is not ready for keyframe extraction. Required states: review_approved, keyframe_failed"}
    end
  end

  @doc """
  Validates keyframe extraction requirements.

  ## Parameters
  - `clip`: Clip struct
  - `strategy`: Keyframe strategy name

  ## Returns
  - `:ok` if all requirements are met
  - `{:error, String.t()}` if requirements are not met
  """
  @spec validate_keyframe_requirements(map(), atom()) :: :ok | {:error, String.t()}
  def validate_keyframe_requirements(clip, strategy) do
    with :ok <- validate_keyframe_readiness(clip),
         :ok <- validate_clip_has_video_file(clip) do
      validate_strategy_compatibility(clip, strategy)
    end
  end

  @doc """
  Checks if a clip already has keyframe artifacts to avoid duplicate work.

  ## Parameters
  - `clip`: Clip struct with artifacts

  ## Returns
  - `:ok` if no keyframes exist (can proceed)
  - `{:error, String.t()}` if keyframes already exist
  """
  @spec validate_no_existing_keyframes(map()) :: :ok | {:error, String.t()}
  def validate_no_existing_keyframes(%{clip_artifacts: artifacts}) when is_list(artifacts) do
    if has_keyframe_artifacts?(artifacts) do
      {:error, "Clip already has keyframe artifacts"}
    else
      :ok
    end
  end

  def validate_no_existing_keyframes(_clip), do: :ok

  @doc """
  Validates a state transition for keyframing operations.

  ## Parameters
  - `current_state`: Current clip state
  - `target_state`: Desired state

  ## Returns
  - `:ok` if transition is valid
  - `{:error, atom()}` if transition is invalid
  """
  @spec validate_keyframe_state_transition(atom(), atom()) :: :ok | {:error, atom()}
  # Valid transitions for keyframing
  def validate_keyframe_state_transition(:review_approved, :keyframing), do: :ok
  def validate_keyframe_state_transition(:keyframing_failed, :keyframing), do: :ok
  def validate_keyframe_state_transition(:keyframe_failed, :keyframing), do: :ok
  def validate_keyframe_state_transition(:keyframing, :keyframed), do: :ok
  def validate_keyframe_state_transition(:keyframing, :keyframe_failed), do: :ok
  # Invalid transitions
  def validate_keyframe_state_transition(_, _), do: {:error, :invalid_state_transition}

  ## Private helper functions

  @spec validate_clip_has_video_file(map()) :: :ok | {:error, String.t()}
  defp validate_clip_has_video_file(%{clip_filepath: filepath})
       when is_binary(filepath) and filepath != "" do
    :ok
  end

  defp validate_clip_has_video_file(_clip) do
    {:error, "Clip does not have a video file for keyframe extraction"}
  end

  @spec validate_strategy_compatibility(map(), atom()) :: :ok | {:error, String.t()}
  defp validate_strategy_compatibility(_clip, strategy) when strategy in [:midpoint, :multi] do
    :ok
  end

  defp validate_strategy_compatibility(_clip, invalid_strategy) do
    {:error, "Invalid keyframe strategy: #{invalid_strategy}"}
  end

  @spec has_keyframe_artifacts?(list()) :: boolean()
  defp has_keyframe_artifacts?(artifacts) when is_list(artifacts) do
    Enum.any?(artifacts, &(&1.artifact_type == :keyframe))
  end

  defp has_keyframe_artifacts?(_), do: false
end
