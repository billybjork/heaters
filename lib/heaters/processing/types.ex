defmodule Heaters.Processing.Types do
  @moduledoc """
  Structured result types for processing pipeline workers.

  Provides type-safe results with @enforce_keys to ensure data integrity
  and improve observability across the video processing pipeline.
  """

  defmodule DownloadResult do
    @moduledoc """
    Result structure for download operations with rich metadata.
    
    Contains download statistics, quality metrics, and file information
    extracted from yt-dlp processing.
    """
    @enforce_keys [:status, :source_video_id, :filepath]
    @type t :: %__MODULE__{
            status: :success | :failed,
            source_video_id: integer(),
            filepath: String.t(),
            title: String.t() | nil,
            duration_seconds: float() | nil,
            file_size_bytes: integer() | nil,
            format_info: map() | nil,
            quality_metrics: map() | nil,
            metadata: map() | nil,
            duration_ms: integer() | nil,
            processed_at: DateTime.t()
          }

    defstruct [
      :status,
      :source_video_id,
      :filepath,
      :title,
      :duration_seconds,
      :file_size_bytes,
      :format_info,
      :quality_metrics,
      :metadata,
      :duration_ms,
      :processed_at
    ]
  end

  defmodule PreprocessResult do
    @moduledoc """
    Result structure for preprocessing operations.
    
    Contains proxy generation results, encoding statistics,
    and optimization metrics from FFmpeg processing.
    """
    @enforce_keys [:status, :source_video_id, :proxy_filepath]
    @type t :: %__MODULE__{
            status: :success | :failed,
            source_video_id: integer(),
            proxy_filepath: String.t(),
            master_filepath: String.t() | nil,
            keyframe_count: integer() | nil,
            optimization_stats: map() | nil,
            encoding_metrics: map() | nil,
            metadata: map() | nil,
            duration_ms: integer() | nil,
            processed_at: DateTime.t()
          }

    defstruct [
      :status,
      :source_video_id,
      :proxy_filepath,
      :master_filepath,
      :keyframe_count,
      :optimization_stats,
      :encoding_metrics,
      :metadata,
      :duration_ms,
      :processed_at
    ]
  end

  defmodule SceneDetectionResult do
    @moduledoc """
    Result structure for scene detection operations.
    
    Contains cut point creation results, confidence metrics,
    and analysis data from scene detection algorithms.
    """
    @enforce_keys [:status, :source_video_id, :cuts_created]
    @type t :: %__MODULE__{
            status: :success | :failed,
            source_video_id: integer(),
            cuts_created: integer(),
            clips_created: integer() | nil,
            scene_confidence_avg: float() | nil,
            detection_method: String.t() | nil,
            metadata: map() | nil,
            duration_ms: integer() | nil,
            processed_at: DateTime.t()
          }

    defstruct [
      :status,
      :source_video_id,
      :cuts_created,
      :clips_created,
      :scene_confidence_avg,
      :detection_method,
      :metadata,
      :duration_ms,
      :processed_at
    ]
  end

  defmodule ExportResult do
    @moduledoc """
    Result structure for export operations.
    
    Contains batch export statistics and individual clip
    processing outcomes.
    """
    @enforce_keys [:status, :source_video_id, :clips_processed]
    @type t :: %__MODULE__{
            status: :success | :failed,
            source_video_id: integer(),
            clips_processed: integer(),
            successful_exports: integer() | nil,
            failed_exports: integer() | nil,
            total_duration_exported: float() | nil,
            metadata: map() | nil,
            duration_ms: integer() | nil,
            processed_at: DateTime.t()
          }

    defstruct [
      :status,
      :source_video_id,
      :clips_processed,
      :successful_exports,
      :failed_exports,
      :total_duration_exported,
      :metadata,
      :duration_ms,
      :processed_at
    ]
  end

  defmodule CachePersistResult do
    @moduledoc """
    Result structure for cache persistence operations.
    
    Contains file upload statistics, cache performance
    metrics, and S3 operation details.
    """
    @enforce_keys [:status, :source_video_id, :files_persisted]
    @type t :: %__MODULE__{
            status: :success | :failed,
            source_video_id: integer(),
            files_persisted: integer(),
            cache_hit_rate: float() | nil,
            bytes_transferred: integer() | nil,
            metadata: map() | nil,
            duration_ms: integer() | nil,
            processed_at: DateTime.t()
          }

    defstruct [
      :status,
      :source_video_id,
      :files_persisted,
      :cache_hit_rate,
      :bytes_transferred,
      :metadata,
      :duration_ms,
      :processed_at
    ]
  end

  defmodule EmbeddingResult do
    @moduledoc """
    Result structure for embedding generation operations.
    
    Contains embedding statistics, keyframe analysis data,
    and vector processing metrics.
    """
    @enforce_keys [:status, :clip_id, :embeddings_generated]
    @type t :: %__MODULE__{
            status: :success | :failed,
            clip_id: integer(),
            embeddings_generated: integer(),
            keyframes_processed: integer() | nil,
            vector_dimensions: integer() | nil,
            processing_stats: map() | nil,
            metadata: map() | nil,
            duration_ms: integer() | nil,
            processed_at: DateTime.t()
          }

    defstruct [
      :status,
      :clip_id,
      :embeddings_generated,
      :keyframes_processed,
      :vector_dimensions,
      :processing_stats,
      :metadata,
      :duration_ms,
      :processed_at
    ]
  end

  defmodule ArchiveResult do
    @moduledoc """
    Result structure for clip archival operations.
    
    Contains deletion statistics, S3 operation details,
    and cleanup metrics.
    """
    @enforce_keys [:status, :clip_id, :objects_deleted]
    @type t :: %__MODULE__{
            status: :success | :failed,
            clip_id: integer(),
            objects_deleted: integer(),
            bytes_freed: integer() | nil,
            s3_operations: map() | nil,
            metadata: map() | nil,
            duration_ms: integer() | nil,
            processed_at: DateTime.t()
          }

    defstruct [
      :status,
      :clip_id,
      :objects_deleted,
      :bytes_freed,
      :s3_operations,
      :metadata,
      :duration_ms,
      :processed_at
    ]
  end
end