defmodule Heaters.Clips.Operations.Edits.Split.Validation do
  @moduledoc """
  Validation logic for split operations.

  This module provides pure validation functions for split operations, ensuring clips
  are in the correct state and split parameters are valid before processing.

  ## Frame Calculation Consistency

  The validation logic uses the same FPS calculation method as sprite metadata generation
  to ensure consistent frame range calculations between frontend and backend:

  - **FPS Priority**: sprite metadata fps → source video fps → processing metadata fps → 30.0 fallback
  - **Frame Calculation**: `Float.ceil(duration * fps)` to match sprite sheet logic exactly
  - **Range Validation**: Ensures `1 < split_frame < total_frames` (prevents zero-duration segments)

  This eliminates "Split frame X is outside clip range" errors that occurred when frontend
  and backend used different FPS values for frame calculations.

  Used by Operations.Edits.Split for business logic validation.
  """

  alias Heaters.Clips.Operations.Shared.ClipValidation
  alias Heaters.Clips.Operations.Shared.ErrorFormatting

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
        {:error, ErrorFormatting.format_domain_error(:invalid_state_for_split, state)}
    end
  end

  @doc """
  Validates split operation requirements.

  ## Frame Number Convention: CLIP-RELATIVE FRAMES

  **CRITICAL**: The `split_at_frame` parameter MUST be a clip-relative frame number
  (1-indexed), NOT an absolute source video frame number.

  - ✅ Correct: If clip has 100 frames and user wants to split at frame 50,
    pass `split_at_frame = 50` (clip-relative frame)
  - ❌ Incorrect: Passing absolute source video frames will fail validation

  The validation checks: `1 < split_at_frame < clip_total_frames`
  This ensures the split point creates two non-zero duration segments.

  ## Parameters
  - `clip`: Clip struct with duration and FPS metadata for calculating total frames
  - `split_at_frame`: **CLIP-RELATIVE** frame number where to split (1-indexed)

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
  Validates that the split frame is within the clip's boundaries using clip-relative frames.

  **Frame Calculation Consistency**: This function now uses the same FPS calculation
  logic as sprite metadata generation to ensure the frontend and backend calculate
  identical frame ranges.

  ## Parameters
  - `clip`: Clip struct with duration and FPS metadata
  - `split_at_frame`: Clip-relative frame number where to split (1-indexed)

  ## Returns
  - `:ok` if split frame is within bounds
  - `{:error, String.t()}` if split frame is outside valid range
  """
  @spec validate_split_frame_bounds(map(), integer()) :: :ok | {:error, String.t()}
  def validate_split_frame_bounds(clip, split_at_frame) do
    clip_duration_seconds = clip.end_time_seconds - clip.start_time_seconds

    # Use the same FPS calculation logic as sprite metadata to ensure consistency
    # Priority: sprite metadata fps -> source video fps -> fallback 30.0
    fps = extract_consistent_fps(clip)

    # Use Float.ceil() to match sprite metadata calculation exactly
    total_frames = Float.ceil(clip_duration_seconds * fps) |> trunc()

    # Valid range: 2 to (total_frames - 1) to prevent zero-duration segments
    min_frame = 2
    max_frame = total_frames - 1

    if split_at_frame >= min_frame and split_at_frame <= max_frame do
      :ok
    else
      {:error,
       ErrorFormatting.format_domain_error(
         :split_frame_out_of_bounds,
         {split_at_frame, min_frame, max_frame}
       )}
    end
  end

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
    {:error, ErrorFormatting.format_domain_error(:invalid_split_frame_type, invalid_frame)}
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
  defp validate_clip_has_video_file(clip) do
    case ClipValidation.validate_clip_has_video_file(clip) do
      :ok ->
        :ok

      {:error, :clip_missing_video_file} ->
        {:error, ErrorFormatting.format_domain_error(:clip_missing_video_file, "unknown")}
    end
  end

  @spec validate_clip_has_source_video(map()) :: :ok | {:error, String.t()}
  defp validate_clip_has_source_video(clip) do
    case ClipValidation.validate_clip_has_source_video(clip) do
      :ok ->
        :ok

      {:error, :clip_missing_source_video} ->
        {:error, ErrorFormatting.format_domain_error(:clip_missing_source_video, "unknown")}
    end
  end

  @spec extract_fps_from_clip_fallback(map()) :: float() | nil
  defp extract_fps_from_clip_fallback(%{processing_metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "fps") || Map.get(metadata, :fps) do
      fps when is_number(fps) and fps > 0 -> fps * 1.0
      _ -> nil
    end
  end

  defp extract_fps_from_clip_fallback(_clip), do: nil

  @spec extract_consistent_fps(map()) :: float()
  defp extract_consistent_fps(clip) do
    # Use the same FPS priority logic as sprite metadata generation
    # 1. Try sprite metadata fps (from clip artifacts)
    # 2. Try source video fps
    # 3. Try processing metadata fps
    # 4. Fallback to 30.0

    sprite_fps = extract_sprite_metadata_fps(clip)
    source_fps = extract_source_video_fps(clip)
    processing_fps = extract_fps_from_clip_fallback(clip)

    sprite_fps || source_fps || processing_fps || 30.0
  end

  @spec extract_sprite_metadata_fps(map()) :: float() | nil
  defp extract_sprite_metadata_fps(%{clip_artifacts: artifacts}) when is_list(artifacts) do
    # Find sprite sheet artifact and extract fps from metadata
    case Enum.find(artifacts, &(&1.artifact_type == "sprite_sheet")) do
      %{metadata: metadata} when is_map(metadata) ->
        # Try both clip_fps_source (video fps) and clip_fps (effective fps)
        # Prioritize clip_fps_source to match sprite calculation logic
        metadata["clip_fps_source"] || metadata["clip_fps"]

      _ -> nil
    end
  end

  defp extract_sprite_metadata_fps(_clip), do: nil

  @spec extract_source_video_fps(map()) :: float() | nil
  defp extract_source_video_fps(%{source_video: %{fps: fps}}) when is_number(fps) and fps > 0, do: fps * 1.0
  defp extract_source_video_fps(_clip), do: nil
end
