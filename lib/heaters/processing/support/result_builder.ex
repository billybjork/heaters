defmodule Heaters.Processing.Support.ResultBuilder do
  @moduledoc """
  Helper functions for building structured worker results.

  Provides consistent patterns for creating success and error results
  with proper metadata and timing information.
  """

  alias Heaters.Processing.Support.Types.{
    DownloadResult,
    EncodeResult,
    SceneDetectionResult,
    ExportResult,
    CachePersistResult,
    EmbeddingResult,
    ArchiveResult
  }

  @doc """
  Builds a successful download result with metadata.
  """
  @spec download_success(integer(), String.t(), map()) :: {:ok, DownloadResult.t()}
  def download_success(source_video_id, filepath, opts \\ %{}) do
    result = %DownloadResult{
      status: :success,
      source_video_id: source_video_id,
      filepath: filepath,
      title: opts[:title],
      duration_seconds: opts[:duration_seconds],
      file_size_bytes: opts[:file_size_bytes],
      format_info: opts[:format_info],
      quality_metrics: opts[:quality_metrics],
      metadata: opts[:metadata],
      duration_ms: opts[:duration_ms],
      processed_at: DateTime.utc_now()
    }

    {:ok, result}
  end

  @doc """
  Builds a failed download result with error context.
  """
  @spec download_error(integer(), any(), map()) :: {:error, any()}
  def download_error(_source_video_id, reason, _metadata \\ %{}) do
    # For now, maintain backward compatibility with simple error tuples
    # Can be enhanced to structured error types later
    {:error, reason}
  end

  @doc """
  Builds a successful encoding result with encoding metrics.
  """
  @spec encode_success(integer(), String.t(), map()) :: {:ok, EncodeResult.t()}
  def encode_success(source_video_id, proxy_filepath, opts \\ %{}) do
    result = %EncodeResult{
      source_video_id: source_video_id,
      proxy_filepath: proxy_filepath,
      master_filepath: opts[:master_filepath],
      keyframe_count: opts[:keyframe_count],
      optimization_stats: opts[:optimization_stats],
      encoding_metrics: opts[:encoding_metrics],
      metadata: opts[:metadata],
      duration_ms: opts[:duration_ms],
      processed_at: DateTime.utc_now()
    }

    {:ok, result}
  end

  # DEPRECATED: Use encode_success/3 instead. Kept for backward compatibility during transition.
  @spec preprocess_success(integer(), String.t(), map()) :: {:ok, EncodeResult.t()}
  def preprocess_success(source_video_id, proxy_filepath, opts \\ %{}) do
    encode_success(source_video_id, proxy_filepath, opts)
  end

  @doc """
  Builds a successful scene detection result with analysis data.
  """
  @spec scene_detection_success(integer(), integer(), map()) :: {:ok, SceneDetectionResult.t()}
  def scene_detection_success(source_video_id, cuts_created, opts \\ %{}) do
    result = %SceneDetectionResult{
      status: :success,
      source_video_id: source_video_id,
      cuts_created: cuts_created,
      clips_created: opts[:clips_created],
      scene_confidence_avg: opts[:scene_confidence_avg],
      detection_method: opts[:detection_method],
      metadata: opts[:metadata],
      duration_ms: opts[:duration_ms],
      processed_at: DateTime.utc_now()
    }

    {:ok, result}
  end

  @doc """
  Builds a successful export result with batch statistics.
  """
  @spec export_success(integer(), [map()], map()) :: {:ok, ExportResult.t()}
  def export_success(source_video_id, exported_clips, opts \\ %{}) do
    result =
      ExportResult.new(
        source_video_id: source_video_id,
        exported_clips: exported_clips,
        proxy_metadata: opts[:proxy_metadata],
        export_method: opts[:export_method] || "legacy_result_builder",
        metadata: opts[:metadata]
      )

    {:ok, result}
  end

  @doc """
  Builds a successful cache persistence result.
  """
  @spec cache_persist_success(integer(), integer(), map()) :: {:ok, CachePersistResult.t()}
  def cache_persist_success(source_video_id, files_persisted, opts \\ %{}) do
    result = %CachePersistResult{
      status: :success,
      source_video_id: source_video_id,
      files_persisted: files_persisted,
      cache_hit_rate: opts[:cache_hit_rate],
      bytes_transferred: opts[:bytes_transferred],
      metadata: opts[:metadata],
      duration_ms: opts[:duration_ms],
      processed_at: DateTime.utc_now()
    }

    {:ok, result}
  end

  @doc """
  Measures execution time for a worker operation and adds duration to result.
  """
  @spec with_timing(fun()) :: {any(), integer()}
  def with_timing(fun) when is_function(fun, 0) do
    start_time = System.monotonic_time(:millisecond)
    result = fun.()
    end_time = System.monotonic_time(:millisecond)
    duration_ms = end_time - start_time

    {result, duration_ms}
  end

  @doc """
  Logs structured result information for observability.
  """
  @spec log_result(atom(), any()) :: :ok
  def log_result(worker_module, {:ok, %{status: :success} = result}) do
    require Logger

    Logger.info(
      "#{worker_module}: Success",
      source_video_id: result.source_video_id,
      duration_ms: result.duration_ms,
      metadata: result.metadata
    )
  end

  def log_result(worker_module, {:error, reason}) do
    require Logger

    Logger.warning(
      "#{worker_module}: Failed",
      reason: inspect(reason)
    )
  end

  def log_result(_worker_module, :ok) do
    # Backward compatibility - simple :ok returns are not logged with structured data
    :ok
  end

  @doc """
  Builds a successful embedding result with vector processing metrics.
  """
  @spec embedding_success(integer(), integer(), map()) :: {:ok, EmbeddingResult.t()}
  def embedding_success(clip_id, embeddings_generated, opts \\ %{}) do
    result = %EmbeddingResult{
      status: :success,
      clip_id: clip_id,
      embeddings_generated: embeddings_generated,
      keyframes_processed: opts[:keyframes_processed],
      vector_dimensions: opts[:vector_dimensions],
      processing_stats: opts[:processing_stats],
      metadata: opts[:metadata],
      duration_ms: opts[:duration_ms],
      processed_at: DateTime.utc_now()
    }

    {:ok, result}
  end

  @doc """
  Builds a successful archive result with deletion statistics.
  """
  @spec archive_success(integer(), integer(), map()) :: {:ok, ArchiveResult.t()}
  def archive_success(clip_id, objects_deleted, opts \\ %{}) do
    result = %ArchiveResult{
      status: :success,
      clip_id: clip_id,
      objects_deleted: objects_deleted,
      bytes_freed: opts[:bytes_freed],
      s3_operations: opts[:s3_operations],
      metadata: opts[:metadata],
      duration_ms: opts[:duration_ms],
      processed_at: DateTime.utc_now()
    }

    {:ok, result}
  end
end
