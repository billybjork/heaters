defmodule Heaters.Processing.Keyframe.Worker do
  use Heaters.Pipeline.WorkerBehavior,
    queue: :media_processing,
    # 15 minutes, prevent duplicate keyframe jobs
    unique: [period: 900, fields: [:args]]

  alias Heaters.Processing.Keyframe.Strategy
  alias Heaters.Processing.Keyframe.Validation
  alias Heaters.Processing.Support.FFmpeg.Runner, as: FFmpegRunner
  alias Heaters.Storage.S3.Paths, as: S3Paths
  alias Heaters.Storage.S3.Core, as: S3Core
  alias Heaters.Storage.PipelineCache.TempCache
  alias Heaters.Media.{Clips, Artifacts}
  alias Heaters.Pipeline.WorkerBehavior
  alias Heaters.Pipeline.Config, as: PipelineConfig
  require Logger

  @complete_states [
    :keyframed,
    :keyframe_failed,
    :embedded,
    :review_archived
  ]

  @impl WorkerBehavior
  def handle_work(%{"clip_id" => clip_id} = args) do
    strategy_name = Map.get(args, "strategy", "multi")

    with {:ok, clip} <- Clips.get_clip_with_artifacts(clip_id),
         :ok <- check_idempotency(clip),
         :ok <- ensure_exported_video_available(clip),
         {:ok, strategy_config} <- Strategy.configure_strategy(strategy_name),
         :ok <-
           Validation.validate_keyframe_requirements(
             clip,
             String.to_atom(strategy_config.strategy)
           ),
         {:ok, clip_keyframing} <- transition_state(clip, :keyframing),
         {:ok, local_path} <- download_clip_if_needed(clip_keyframing),
         {:ok, keyframe_files} <- extract_keyframes(local_path, clip_keyframing, strategy_config),
         {:ok, _created} <-
           upload_keyframes_and_create_artifacts(clip_keyframing, keyframe_files, strategy_config),
         {:ok, clip_keyframed} <- transition_state(clip_keyframing, :keyframed) do
      # Chain embedding job if configured
      :ok = PipelineConfig.maybe_chain_next_job(__MODULE__, clip_keyframed)
      {:ok, %{created: length(keyframe_files)}}
    else
      {:error, :not_found} ->
        WorkerBehavior.handle_not_found("Clip", clip_id)

      {:error, :already_processed} ->
        WorkerBehavior.handle_already_processed("Clip", clip_id)

      {:error, reason} ->
        # Mark failure and keep resumable
        case Clips.get_clip(clip_id) do
          {:ok, clip_loaded} ->
            _ = Clips.mark_failed(clip_loaded, :keyframe_failed, inspect(reason))

          _ ->
            :ok
        end

        {:error, reason}
    end
  end

  # Idempotency check: Skip processing if already done or has keyframe artifacts
  defp check_idempotency(clip) do
    with :ok <- WorkerBehavior.check_complete_states(clip, @complete_states),
         :ok <- check_artifact_exists_unless_retry(clip),
         :ok <- check_keyframe_specific_states(clip) do
      :ok
    end
  end

  # For retry states, skip artifact check to allow reprocessing
  defp check_artifact_exists_unless_retry(%{ingest_state: :keyframe_failed}), do: :ok

  defp check_artifact_exists_unless_retry(clip),
    do: WorkerBehavior.check_artifact_exists(clip, :keyframe)

  defp check_keyframe_specific_states(%Heaters.Media.Clip{ingest_state: :exported}), do: :ok

  defp check_keyframe_specific_states(%Heaters.Media.Clip{ingest_state: :keyframe_failed}),
    do: :ok

  defp check_keyframe_specific_states(%Heaters.Media.Clip{ingest_state: state}) do
    Logger.warning("KeyframeWorker: Unexpected clip state '#{state}' for keyframe extraction")
    {:error, :invalid_state}
  end

  defp ensure_exported_video_available(%{clip_filepath: path})
       when is_binary(path) and path != "",
       do: :ok

  defp ensure_exported_video_available(_), do: {:error, "Clip is missing exported video filepath"}

  defp transition_state(clip, target_state) do
    case Clips.update_state(clip, target_state) do
      {:ok, updated} -> {:ok, updated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp download_clip_if_needed(%{clip_filepath: s3_key} = _clip) do
    # Prefer local temp cache (written by export) to avoid immediate S3 re-download
    case TempCache.get_or_download(s3_key, operation_name: "Keyframe") do
      {:ok, cached_path, _origin} -> {:ok, cached_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_keyframes(local_video_path, clip, %{strategy: "midpoint"} = _config) do
    output_dir = build_output_dir(clip)

    case FFmpegRunner.extract_keyframes_by_percentage(local_video_path, output_dir, [0.5],
           prefix: "clip_#{clip.id}"
         ) do
      {:ok, files} -> {:ok, files}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_keyframes(local_video_path, clip, %{strategy: "multi"} = _config) do
    output_dir = build_output_dir(clip)

    case FFmpegRunner.extract_keyframes_by_percentage(
           local_video_path,
           output_dir,
           [0.25, 0.5, 0.75],
           prefix: "clip_#{clip.id}"
         ) do
      {:ok, files} -> {:ok, files}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_output_dir(_clip) do
    Path.join(System.tmp_dir!(), "keyframes")
  end

  defp upload_keyframes_and_create_artifacts(clip, files, strategy_config) do
    uploads =
      Enum.map(files, fn %{path: local_path, filename: filename, timestamp: ts, index: idx} ->
        s3_key = S3Paths.generate_artifact_path(clip.id, :keyframe, filename)

        with {:ok, ^s3_key} <- S3Core.upload_file(local_path, s3_key, operation_name: "Keyframe") do
          %{
            s3_key: s3_key,
            metadata: %{timestamp: ts, index: idx, strategy: strategy_config.strategy}
          }
        else
          {:error, reason} -> throw({:upload_error, reason})
        end
      end)

    case Artifacts.create_artifacts(clip.id, "keyframe", uploads) do
      {:ok, created} -> {:ok, created}
      {:error, reason} -> {:error, reason}
    end
  catch
    {:upload_error, reason} -> {:error, reason}
  end
end
