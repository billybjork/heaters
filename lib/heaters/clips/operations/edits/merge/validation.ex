defmodule Heaters.Clips.Operations.Edits.Merge.Validation do
  @moduledoc """
  Validation logic for merge operations.
  Used by Operations.Edits.Merge for business logic.
  """

  alias Heaters.Clips.Operations.Shared.ClipValidation
  alias Heaters.Clips.Operations.Shared.ErrorFormatting

  @doc """
  Validates if clips are ready for merge operations.

  ## Parameters
  - `target_clip`: The target clip with ingest_state
  - `source_clip`: The source clip with ingest_state

  ## Returns
  - `:ok` if clips are ready for merging
  - `{:error, String.t()}` if clips are not ready
  """
  @spec validate_merge_readiness(map(), map()) :: :ok | {:error, String.t()}
  def validate_merge_readiness(target_clip, source_clip) do
    with :ok <- validate_clip_ready_for_merge(target_clip, "target"),
         :ok <- validate_clip_ready_for_merge(source_clip, "source") do
      :ok
    end
  end

  @doc """
  Validates merge operation requirements.

  ## Parameters
  - `target_clip_id`: ID of the target clip
  - `source_clip_id`: ID of the source clip
  - `target_clip`: Target clip struct
  - `source_clip`: Source clip struct

  ## Returns
  - `:ok` if all requirements are met
  - `{:error, String.t()}` if requirements are not met
  """
  @spec validate_merge_requirements(integer(), integer(), map(), map()) ::
          :ok | {:error, String.t()}
  def validate_merge_requirements(target_clip_id, source_clip_id, target_clip, source_clip) do
    with :ok <- validate_clip_ids(target_clip_id, source_clip_id),
         :ok <- validate_merge_readiness(target_clip, source_clip),
         :ok <- validate_clips_have_video_files(target_clip, source_clip),
         :ok <- validate_clips_same_source_video(target_clip, source_clip),
         :ok <- validate_clips_different(target_clip, source_clip) do
      :ok
    end
  end

  @doc """
  Validates that clip IDs are valid integers.

  ## Parameters
  - `target_clip_id`: ID of the target clip
  - `source_clip_id`: ID of the source clip

  ## Returns
  - `:ok` if IDs are valid
  - `{:error, String.t()}` if IDs are invalid
  """
  @spec validate_clip_ids(any(), any()) :: :ok | {:error, String.t()}
  def validate_clip_ids(target_clip_id, source_clip_id) do
    cond do
      not is_integer(target_clip_id) ->
        {:error,
         ErrorFormatting.format_domain_error(:invalid_clip_id_type, {"target", target_clip_id})}

      not is_integer(source_clip_id) ->
        {:error,
         ErrorFormatting.format_domain_error(:invalid_clip_id_type, {"source", source_clip_id})}

      target_clip_id <= 0 ->
        {:error,
         ErrorFormatting.format_domain_error(:invalid_clip_id_value, {"target", target_clip_id})}

      source_clip_id <= 0 ->
        {:error,
         ErrorFormatting.format_domain_error(:invalid_clip_id_value, {"source", source_clip_id})}

      target_clip_id == source_clip_id ->
        {:error, ErrorFormatting.format_domain_error(:identical_clip_ids, target_clip_id)}

      true ->
        :ok
    end
  end

  @doc """
  Validates that clips belong to the same source video.

  ## Parameters
  - `target_clip`: Target clip with source_video_id
  - `source_clip`: Source clip with source_video_id

  ## Returns
  - `:ok` if clips have same source video
  - `{:error, String.t()}` if clips have different source videos
  """
  @spec validate_clips_same_source_video(map(), map()) :: :ok | {:error, String.t()}
  def validate_clips_same_source_video(target_clip, source_clip) do
    if target_clip.source_video_id == source_clip.source_video_id do
      :ok
    else
      {:error,
       ErrorFormatting.format_domain_error(
         :clips_different_source_videos,
         {target_clip.source_video_id, source_clip.source_video_id}
       )}
    end
  end

  @doc """
  Validates that clips are different clips.

  ## Parameters
  - `target_clip`: Target clip with id
  - `source_clip`: Source clip with id

  ## Returns
  - `:ok` if clips are different
  - `{:error, String.t()}` if clips are the same
  """
  @spec validate_clips_different(map(), map()) :: :ok | {:error, String.t()}
  def validate_clips_different(target_clip, source_clip) do
    if target_clip.id != source_clip.id do
      :ok
    else
      {:error,
       ErrorFormatting.format_domain_error(:clips_not_different, {target_clip.id, target_clip.id})}
    end
  end

  @doc """
  Validates that both clips have video files for merging.

  ## Parameters
  - `target_clip`: Target clip with clip_filepath
  - `source_clip`: Source clip with clip_filepath

  ## Returns
  - `:ok` if both clips have video files
  - `{:error, String.t()}` if any clip lacks a video file
  """
  @spec validate_clips_have_video_files(map(), map()) :: :ok | {:error, String.t()}
  def validate_clips_have_video_files(target_clip, source_clip) do
    with :ok <- validate_clip_has_video_file(target_clip, "target"),
         :ok <- validate_clip_has_video_file(source_clip, "source") do
      :ok
    end
  end

  ## Private helper functions

  @spec validate_clip_ready_for_merge(map(), String.t()) :: :ok | {:error, String.t()}
  defp validate_clip_ready_for_merge(%{ingest_state: state} = _clip, _clip_type) do
    case ClipValidation.validate_clip_state_for_merge(state) do
      :ok ->
        :ok

      {:error, :invalid_state_for_merge} ->
        {:error, ErrorFormatting.format_domain_error(:invalid_state_for_merge, state)}
    end
  end

  @spec validate_clip_has_video_file(map(), String.t()) :: :ok | {:error, String.t()}
  defp validate_clip_has_video_file(clip, clip_type) do
    case ClipValidation.validate_clip_has_video_file(clip) do
      :ok ->
        :ok

      {:error, :clip_missing_video_file} ->
        {:error, ErrorFormatting.format_domain_error(:clip_missing_video_file, clip_type)}
    end
  end
end
