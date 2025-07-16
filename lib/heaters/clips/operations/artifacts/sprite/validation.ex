defmodule Heaters.Clips.Operations.Artifacts.Sprite.Validation do
  @moduledoc """
  Validation logic for sprite operations.
  Used by Operations.Artifacts.Sprite for business logic.

  This module contains validation logic for sprite operations, including
  clip state validation and sprite parameter validation. All functions are pure.
  """

  alias Heaters.Clips.Operations.Artifacts.Sprite.VideoMetadata
  alias Heaters.Clips.Operations.Shared.ClipValidation
  alias Heaters.Clips.Operations.Artifacts.Sprite.Calculations
  alias Heaters.Clips.Operations.Edits.Split.Calculations, as: SplitCalculations

  @doc """
  Validate that a clip and parameters are suitable for sprite generation.

  This is the main validation function that checks all requirements for
  sprite generation in a single call.

  ## Examples

      iex> clip = %{ingest_state: "spliced", id: 123}
      iex> params = %{tile_width: 480, fps: 24, cols: 5}
      iex> video_metadata = %{duration: 120.0, fps: 30.0}
      iex> Validation.validate_sprite_requirements(clip, params, video_metadata)
      :ok

      iex> clip = %{ingest_state: "pending_review", id: 123}
      iex> Validation.validate_sprite_requirements(clip, params, video_metadata)
      {:error, :invalid_state_for_sprite}
  """
  @spec validate_sprite_requirements(map(), map(), map()) :: :ok | {:error, atom()}
  def validate_sprite_requirements(clip, params, video_metadata)
      when is_map(clip) and is_map(params) and is_map(video_metadata) do
    with :ok <- validate_clip_for_sprite(clip),
         :ok <- validate_sprite_params(params),
         :ok <- validate_video_metadata_for_sprite(video_metadata),
         :ok <- validate_sprite_feasibility(video_metadata, params) do
      :ok
    end
  end

  @doc """
  Validate that a clip is in the correct state for sprite generation.

  ## Examples

      iex> clip = %{ingest_state: "spliced"}
      iex> Validation.validate_clip_for_sprite(clip)
      :ok

      iex> clip = %{ingest_state: "pending_review"}
      iex> Validation.validate_clip_for_sprite(clip)
      {:error, :invalid_state_for_sprite}
  """
  @spec validate_clip_for_sprite(map()) :: :ok | {:error, atom()}
  def validate_clip_for_sprite(%{ingest_state: state}) do
    ClipValidation.validate_clip_state_for_sprite(state)
  end

  def validate_clip_for_sprite(_clip) do
    {:error, :missing_ingest_state}
  end

  @doc """
  Validate sprite parameters for correctness and reasonableness.

  ## Examples

      iex> params = %{tile_width: 480, tile_height: -1, fps: 24, cols: 5}
      iex> Validation.validate_sprite_params(params)
      :ok

      iex> params = %{tile_width: 0, fps: 24, cols: 5}
      iex> Validation.validate_sprite_params(params)
      {:error, :invalid_sprite_params}
  """
  @spec validate_sprite_params(map()) :: :ok | {:error, atom()}
  def validate_sprite_params(params) when is_map(params) do
    merged_params = Calculations.merge_sprite_params(params)

    case Calculations.validate_sprite_params(merged_params) do
      :ok -> :ok
      {:error, _reason} -> {:error, :invalid_sprite_params}
    end
  end

  @doc """
  Validate video metadata for sprite generation requirements.

  ## Examples

      iex> metadata = %{duration: 120.0, fps: 30.0}
      iex> Validation.validate_video_metadata_for_sprite(metadata)
      :ok

      iex> metadata = %{duration: 0.05, fps: 30.0}
      iex> Validation.validate_video_metadata_for_sprite(metadata)
      {:error, :video_too_short}
  """
  @spec validate_video_metadata_for_sprite(map()) :: :ok | {:error, atom()}
  def validate_video_metadata_for_sprite(metadata) when is_map(metadata) do
    with :ok <- VideoMetadata.validate_metadata(metadata),
         true <-
           VideoMetadata.sufficient_duration?(
             metadata.duration,
             SplitCalculations.min_clip_duration()
           ) do
      :ok
    else
      {:error, _reason} -> {:error, :invalid_video_metadata}
      false -> {:error, :video_too_short}
    end
  end

  @doc """
  Validate that sprite generation is feasible for the given video and parameters.

  ## Examples

      iex> video_metadata = %{duration: 120.0, fps: 30.0}
      iex> params = %{tile_width: 480, fps: 24, cols: 5}
      iex> Validation.validate_sprite_feasibility(video_metadata, params)
      :ok
  """
  @spec validate_sprite_feasibility(map(), map()) :: :ok | {:error, atom()}
  def validate_sprite_feasibility(video_metadata, params)
      when is_map(video_metadata) and is_map(params) do
    merged_params = Calculations.merge_sprite_params(params)

    case Calculations.sprite_generation_feasible?(video_metadata, merged_params) do
      {:ok, %{feasible: true}} -> :ok
      {:ok, %{feasible: false}} -> {:error, :sprite_generation_not_feasible}
      {:error, _reason} -> {:error, :sprite_feasibility_check_failed}
    end
  end

  @doc """
  Validate multiple clips for batch sprite generation.
  Returns a list of validation results for each clip.

  ## Examples

      iex> clips = [%{ingest_state: "spliced", id: 1}, %{ingest_state: "pending_review", id: 2}]
      iex> params = %{tile_width: 480, fps: 24}
      iex> video_metadata = %{duration: 120.0, fps: 30.0}
      iex> Validation.validate_batch_sprite_requirements(clips, params, video_metadata)
      [
        {1, :ok},
        {2, {:error, :invalid_state_for_sprite}}
      ]
  """
  @spec validate_batch_sprite_requirements([map()], map(), map()) :: [
          {integer(), :ok | {:error, atom()}}
        ]
  def validate_batch_sprite_requirements(clips, params, video_metadata)
      when is_list(clips) and is_map(params) and is_map(video_metadata) do
    Enum.map(clips, fn clip ->
      result = validate_sprite_requirements(clip, params, video_metadata)
      {Map.get(clip, :id), result}
    end)
  end

  @doc """
  Check if sprite parameters would result in a reasonable output size.

  ## Examples

      iex> params = %{tile_width: 480, fps: 24, cols: 5}
      iex> video_metadata = %{duration: 120.0, fps: 30.0}
      iex> Validation.reasonable_sprite_output?(video_metadata, params)
      {:ok, true}

      iex> params = %{tile_width: 1920, fps: 60, cols: 10}  # Very large sprite
      iex> video_metadata = %{duration: 3600.0, fps: 60.0}  # 1 hour video
      iex> Validation.reasonable_sprite_output?(video_metadata, params)
      {:ok, false}
  """
  @spec reasonable_sprite_output?(map(), map()) :: {:ok, boolean()} | {:error, atom()}
  def reasonable_sprite_output?(video_metadata, params)
      when is_map(video_metadata) and is_map(params) do
    merged_params = Calculations.merge_sprite_params(params)

    case Calculations.calculate_sprite_grid(video_metadata, merged_params) do
      {:ok, sprite_spec} ->
        # Define reasonable limits
        max_reasonable_frames = 10_000
        max_reasonable_rows = 500

        reasonable =
          sprite_spec.num_frames <= max_reasonable_frames and
            sprite_spec.rows <= max_reasonable_rows

        {:ok, reasonable}

      error ->
        error
    end
  end

  @doc """
  Get validation summary for sprite generation requirements.
  Provides detailed information about what validations passed/failed.

  ## Examples

      iex> clip = %{ingest_state: "spliced", id: 123}
      iex> params = %{tile_width: 480, fps: 24, cols: 5}
      iex> video_metadata = %{duration: 120.0, fps: 30.0}
      iex> Validation.get_validation_summary(clip, params, video_metadata)
      %{
        overall: :ok,
        clip_state: :ok,
        sprite_params: :ok,
        video_metadata: :ok,
        feasibility: :ok
      }
  """
  @spec get_validation_summary(map(), map(), map()) :: map()
  def get_validation_summary(clip, params, video_metadata)
      when is_map(clip) and is_map(params) and is_map(video_metadata) do
    clip_state_result = validate_clip_for_sprite(clip)
    params_result = validate_sprite_params(params)
    video_result = validate_video_metadata_for_sprite(video_metadata)
    feasibility_result = validate_sprite_feasibility(video_metadata, params)

    overall_result =
      case {clip_state_result, params_result, video_result, feasibility_result} do
        {:ok, :ok, :ok, :ok} -> :ok
        _ -> :error
      end

    %{
      overall: overall_result,
      clip_state: clip_state_result,
      sprite_params: params_result,
      video_metadata: video_result,
      feasibility: feasibility_result
    }
  end
end
