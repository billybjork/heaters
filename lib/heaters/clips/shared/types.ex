defmodule Heaters.Clips.Shared.Types do
  @moduledoc """
  Shared type definitions for clip operations.

  This module consolidates all result structs and type definitions used across
  keyframe extraction and other clip operations, providing consistent patterns and eliminating duplication.
  """

  defmodule TransformResult do
    @moduledoc """
    Base result type for clip operations.

    Contains common fields shared across operation results.
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

  defmodule KeyframeResult do
    @moduledoc """
    Structured result type for Keyframe operations.
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

  # Parameter types used for keyframe operations

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
          {:ok, [Heaters.Clips.Artifacts.ClipArtifact.t()]} | {:error, any()}
end
