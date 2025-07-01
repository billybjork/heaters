defmodule Heaters.Clips.Operations.Shared.Types do
  @moduledoc """
  Shared type definitions for the Transform context.

  This module consolidates all result structs and type definitions used across
  transformation operations, providing consistent patterns and eliminating duplication.
  """

  defmodule TransformResult do
    @moduledoc """
    Base result type for all transformation operations.

    Contains common fields shared across all transform results.
    """

    @enforce_keys [:status, :operation_type]
    defstruct [
      :status,
      :operation_type,
      :metadata,
      :duration_ms,
      :processed_at
    ]

    @type t :: %__MODULE__{
            status: String.t(),
            operation_type: String.t(),
            metadata: map() | nil,
            duration_ms: integer() | nil,
            processed_at: DateTime.t() | nil
          }
  end

  defmodule SplitResult do
    @moduledoc """
    Structured result type for Split transform operations.
    """

    @enforce_keys [:status, :original_clip_id, :new_clip_ids]
    defstruct [
      :status,
      :original_clip_id,
      :new_clip_ids,
      :created_clips,
      :cleanup,
      :metadata,
      :duration_ms,
      :processed_at
    ]

    @type t :: %__MODULE__{
            status: String.t(),
            original_clip_id: integer(),
            new_clip_ids: [integer()],
            created_clips: [map()] | nil,
            cleanup: map() | nil,
            metadata: map() | nil,
            duration_ms: integer() | nil,
            processed_at: DateTime.t() | nil
          }
  end

  defmodule SpriteResult do
    @moduledoc """
    Structured result type for Sprite transform operations.
    """

    @enforce_keys [:status, :clip_id, :artifacts]
    defstruct [
      :status,
      :clip_id,
      :artifacts,
      :metadata,
      :duration_ms,
      :processed_at
    ]

    @type t :: %__MODULE__{
            status: String.t(),
            clip_id: integer(),
            artifacts: [map()],
            metadata: map() | nil,
            duration_ms: integer() | nil,
            processed_at: DateTime.t() | nil
          }
  end

  defmodule KeyframeResult do
    @moduledoc """
    Structured result type for Keyframe transform operations.
    """

    @enforce_keys [:status, :clip_id, :artifacts]
    defstruct [
      :status,
      :clip_id,
      :artifacts,
      :keyframe_count,
      :strategy,
      :metadata,
      :duration_ms,
      :processed_at
    ]

    @type t :: %__MODULE__{
            status: String.t(),
            clip_id: integer(),
            artifacts: [map()],
            keyframe_count: integer() | nil,
            strategy: String.t() | nil,
            metadata: map() | nil,
            duration_ms: integer() | nil,
            processed_at: DateTime.t() | nil
          }
  end

  defmodule MergeResult do
    @moduledoc """
    Structured result type for Merge transform operations.
    """

    @enforce_keys [:status, :merged_clip_id, :source_clip_ids]
    defstruct [
      :status,
      :merged_clip_id,
      :source_clip_ids,
      :cleanup,
      :metadata,
      :duration_ms,
      :processed_at
    ]

    @type t :: %__MODULE__{
            status: String.t(),
            merged_clip_id: integer(),
            source_clip_ids: [integer()],
            cleanup: map() | nil,
            metadata: map() | nil,
            duration_ms: integer() | nil,
            processed_at: DateTime.t() | nil
          }
  end

  defmodule SpliceResult do
    @moduledoc """
    Structured result type for Splice (video-to-clips) operations.

    Used for the native Elixir scene detection workflow to replace
    the Python subprocess approach.
    """

    @enforce_keys [:status, :source_video_id, :clips_data]
    defstruct [
      :status,
      :source_video_id,
      :clips_data,
      :total_scenes_detected,
      :clips_created,
      :detection_params,
      :metadata,
      :duration_ms,
      :processed_at
    ]

    @type t :: %__MODULE__{
            status: String.t(),
            source_video_id: integer(),
            clips_data: [map()],
            total_scenes_detected: integer() | nil,
            clips_created: integer() | nil,
            detection_params: map() | nil,
            metadata: map() | nil,
            duration_ms: integer() | nil,
            processed_at: DateTime.t() | nil
          }
  end

  # Parameter types used across different transformation operations

  @type split_params :: %{
          split_at_frame: integer(),
          original_start_time: float(),
          original_end_time: float(),
          original_start_frame: integer(),
          original_end_frame: integer(),
          source_title: String.t(),
          fps: float() | nil,
          source_video_id: integer()
        }

  @type sprite_params :: %{
          tile_width: integer(),
          tile_height: integer(),
          fps: integer(),
          cols: integer()
        }

  @type keyframe_params :: %{
          strategy: String.t(),
          count: integer()
        }

  # Artifact data types

  @type artifact_data :: %{
          s3_key: String.t(),
          metadata: map() | nil
        }

  @type upload_data :: %{
          s3_key: String.t(),
          local_path: String.t(),
          metadata: map() | nil
        }

  # Common response patterns used across operations

  @type operation_response(result_type) ::
          {:ok, result_type} | {:error, any()}

  @type clip_operation_response ::
          {:ok, Heaters.Clips.Clip.t()} | {:error, any()}

  @type artifacts_response ::
          {:ok, [Heaters.Clips.Operations.Artifacts.ClipArtifact.t()]} | {:error, any()}
end
