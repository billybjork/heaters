defmodule Heaters.Clips.Operations do
  @moduledoc """
  Main coordination context for enhanced virtual clip processing operations.

  This module serves as a clean delegation facade providing coordination
  functions used across all video processing operations.

  ## Enhanced Virtual Clips Architecture

  This context supports the enhanced virtual clips workflow:

  ### Virtual Clip Operations
  - **`VirtualClips`** - Core virtual clip creation and management
  - **`VirtualClips.CutPointOperations`** - Cut point add/remove/move operations
  - **`VirtualClips.MeceValidation`** - MECE validation and coverage checking
  - **`VirtualClips.CutPointOperation`** - Audit trail schema
  - Triggered by scene detection and user review actions
  - Creates database records with cut points (virtual) then physical files (export)

  ### Artifact Generation (Pipeline Stages → Supplementary Data)
  - **`Artifacts.Operations`** - Artifact utilities and management
  - **`Artifacts.Keyframe`** - Keyframe extraction for exported clips
  - Triggered by pipeline state transitions after export
  - Creates supplementary data for existing physical clips
  - Writes to the `clip_artifacts` table

  ### Shared Infrastructure

  All operation modules use centralized shared infrastructure:

  - **`Shared.Types`** - Common result structs and type definitions
  - **`Shared.TempManager`** - Temporary directory management
  - **`Shared.FFmpegRunner`** - FFmpeg operation standardization
  - **`Shared.ErrorHandling`** - Consistent error handling and failure tracking
  - **`Infrastructure.S3`** - S3 upload/download operations

  ## This Module's Responsibilities

  This module provides coordination and delegation across operation contexts:

  - **Context Delegation**: Routes operations to appropriate specialized modules
  - **Cross-Context Utilities**: Functions that span multiple operation types
  - **Legacy Compatibility**: Maintains existing API surface during refactoring

  ## Usage

  For virtual clip operations:

      # Core creation
      {:ok, clips} = VirtualClips.create_virtual_clips_from_cut_points(source_video_id, cut_points)

      # Cut point management
      {:ok, clips} = VirtualClips.add_cut_point(source_video_id, frame_num, user_id)

  For artifact generation (pipeline stages):

      # Keyframe extraction (after export)
      {:ok, result} = Artifacts.Keyframe.run_keyframe_extraction(clip_id, "multi")

  For shared utilities (used internally by operation modules):

      # Error handling
      Shared.ErrorHandling.mark_failed(clip_id, "export_failed", "FFmpeg error")
  """

  # Delegate to shared error handling
  alias Heaters.Clips.Shared.ErrorHandling

  # Delegate to artifact operations
  alias Heaters.Clips.Artifacts.Operations, as: ArtifactOperations

  @doc """
  Mark a clip transformation as failed with error tracking.

  Delegates to the shared error handling module for consistent
  failure tracking across all operation types.

  ## Parameters
  - `clip_or_id`: Either a Clip struct or clip ID integer
  - `failure_state`: The specific failure state to transition to
  - `error_reason`: The error that caused the failure

  ## Examples

      # Mark keyframe extraction as failed
      Operations.mark_failed(clip_id, "keyframe_failed", "OpenCV initialization error")

      # Mark export operation as failed
      Operations.mark_failed(clip, "export_failed", {:ffmpeg_error, "Invalid codec"})
  """
  defdelegate mark_failed(clip_or_id, failure_state, error_reason), to: ErrorHandling

  @doc """
  Build S3 prefix for artifact outputs.

  Delegates to the artifact operations module for consistent S3 path structure.

  ## Examples

      # For keyframes
      prefix = Operations.build_artifact_prefix(clip, "keyframes")
      # Returns: "clip_artifacts/Berlin_Skies_Snow_VANS/keyframes"
  """
  defdelegate build_artifact_prefix(clip, artifact_type), to: ArtifactOperations

  @doc """
  Create multiple artifacts from processing results.

  Delegates to the artifact operations module for consistent artifact creation.

  ## Parameters
  - `clip_id`: The ID of the clip the artifacts belong to
  - `artifact_type`: The type of artifacts being created (e.g., "keyframe", "sprite")
  - `artifacts_data`: List of artifact data maps containing s3_key and metadata

  ## Examples

      artifacts_data = [
        %{s3_key: "path/to/keyframe1.jpg", metadata: %{frame_index: 100}},
        %{s3_key: "path/to/keyframe2.jpg", metadata: %{frame_index: 200}}
      ]

      {:ok, artifacts} = Operations.create_artifacts(clip_id, "keyframe", artifacts_data)
  """
  defdelegate create_artifacts(clip_id, artifact_type, artifacts_data), to: ArtifactOperations
end
