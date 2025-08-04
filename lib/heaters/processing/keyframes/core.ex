defmodule Heaters.Processing.Keyframes.Core do
  @moduledoc """
  Keyframe extraction operations - I/O orchestration layer.

  Orchestrates keyframe extraction via Elixir FFmpeg integration, managing
  workflow state transitions and artifact creation for embedding generation.

  Uses domain modules for business logic and infrastructure adapters for I/O operations.
  Follows "I/O at the edges" architecture pattern.
  """

  require Logger

  alias Heaters.Media.Artifacts
  alias Heaters.Media.Support.{Types, ErrorFormatting}

  # Domain modules (pure business logic)
  alias Heaters.Processing.Keyframes.{Strategy, Validation}

  # Infrastructure adapters (I/O operations)
  alias Heaters.Media.Clips
  alias Heaters.Processing.Render.FFmpegAdapter
  alias Heaters.Storage.S3
  alias Heaters.Storage.PipelineCache.TempCache

  @doc """
  Runs keyframe extraction workflow for the specified clip.

  ## Parameters
  - `clip_id`: ID of the clip to process
  - `strategy`: Keyframe strategy ("midpoint" or "multi")

  ## Returns
  - `{:ok, Types.KeyframeResult.t()}` on success
  - `{:error, String.t()}` on failure
  """
  @spec run_keyframe_extraction(integer(), String.t()) ::
          {:ok, Types.KeyframeResult.t()} | {:error, String.t()}
  def run_keyframe_extraction(clip_id, strategy \\ "multi") do
    Logger.info("Keyframe: Starting extraction for clip #{clip_id} with strategy #{strategy}")

    with {:ok, clip} <- get_clip_with_validation(clip_id),
         {:ok, strategy_config} <- configure_extraction_strategy(strategy),
         :ok <- validate_keyframe_requirements(clip, strategy),
         {:ok, _updated_clip} <- transition_to_keyframing(clip),
         {:ok, artifact_prefix} <- build_artifact_prefix(clip) do
      execute_elixir_keyframe_extraction(clip, strategy_config, artifact_prefix)
    else
      {:error, reason} ->
        Logger.error(
          "Keyframe: Failed to extract keyframes for clip #{clip_id}: #{inspect(reason)}"
        )

        {:error, ErrorFormatting.format_error(reason)}
    end
  end

  ## Private Implementation

  defp get_clip_with_validation(clip_id) do
    case Clips.get_clip_with_artifacts(clip_id) do
      {:ok, clip} -> {:ok, clip}
      {:error, :not_found} -> {:error, "Clip not found: #{clip_id}"}
    end
  end

  defp configure_extraction_strategy(strategy) do
    Strategy.configure_strategy(strategy)
  end

  defp validate_keyframe_requirements(clip, strategy) do
    Validation.validate_keyframe_requirements(clip, strategy)
  end

  defp transition_to_keyframing(clip) do
    Clips.update_state(clip, "keyframing")
  end

  defp build_artifact_prefix(clip) do
    prefix = "keyframes/clip_#{clip.id}_#{:os.system_time(:second)}"
    {:ok, prefix}
  end

  defp execute_elixir_keyframe_extraction(clip, strategy_config, artifact_prefix) do
    Logger.info("Keyframe: Running Elixir-based keyframe extraction for clip #{clip.id}")

    perform_keyframe_extraction(clip, strategy_config, artifact_prefix, :elixir)
  end

  defp perform_keyframe_extraction(clip, strategy_config, artifact_prefix, extraction_method) do
    Logger.info(
      "Keyframe: Extracting #{strategy_config.count} keyframes using #{extraction_method}"
    )

    with {:ok, local_video_path} <- download_clip_video(clip, extraction_method),
         {:ok, keyframe_data} <-
           extract_keyframes_with_strategy(
             local_video_path,
             strategy_config,
             artifact_prefix,
             extraction_method
           ),
         {:ok, uploaded_keyframes} <- upload_keyframes_to_s3(keyframe_data, artifact_prefix) do
      process_extraction_success(clip, uploaded_keyframes, strategy_config, extraction_method)
    else
      {:error, reason} ->
        Logger.error("Keyframe extraction failed: #{inspect(reason)}")
        handle_extraction_failure(clip, reason)
    end
  end

  defp download_clip_video(%{clip_filepath: filepath}, _method) when is_binary(filepath) do
    case TempCache.get_or_download(filepath, operation_name: "KeyframeExtraction") do
      {:ok, local_path, _cache_status} ->
        Logger.debug("Downloaded clip video to: #{local_path}")
        {:ok, local_path}

      {:error, reason} ->
        {:error, "Failed to download clip video: #{inspect(reason)}"}
    end
  end

  defp download_clip_video(_clip, _method) do
    {:error, "Clip does not have a video file"}
  end

  defp extract_keyframes_with_strategy(video_path, strategy_config, artifact_prefix, method) do
    keyframe_data =
      strategy_config.percentages
      |> Enum.with_index()
      |> Enum.map(fn {percentage, index} ->
        output_path = "#{artifact_prefix}_#{strategy_config.tags[index]}.jpg"

        case extract_single_keyframe(video_path, percentage, output_path, method) do
          {:ok, keyframe_path} ->
            {:ok,
             %{
               percentage: percentage,
               tag: Enum.at(strategy_config.tags, index),
               local_path: keyframe_path,
               s3_key: output_path
             }}

          {:error, reason} ->
            {:error, reason}
        end
      end)

    case Enum.find(keyframe_data, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(keyframe_data, fn {:ok, data} -> data end)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_single_keyframe(video_path, percentage, output_path, :elixir) do
    output_dir = Path.dirname(output_path)

    case FFmpegAdapter.extract_keyframes_by_percentage(video_path, output_dir, [percentage]) do
      {:ok, keyframe_paths} ->
        case List.first(keyframe_paths) do
          nil -> {:error, "No keyframes extracted"}
          keyframe_path -> {:ok, keyframe_path}
        end

      {:error, reason} ->
        {:error, "FFmpeg extraction failed: #{inspect(reason)}"}
    end
  end

  defp build_keyframe_data(uploaded_keyframes, strategy_config) do
    keyframes_with_metadata =
      Enum.map(uploaded_keyframes, fn keyframe ->
        Map.merge(keyframe, %{
          artifact_type: "keyframe",
          processing_metadata: %{
            strategy: strategy_config.strategy,
            extraction_method: "elixir_ffmpeg"
          }
        })
      end)

    %{
      keyframes: keyframes_with_metadata,
      strategy: strategy_config.strategy,
      count: length(keyframes_with_metadata)
    }
  end

  defp upload_keyframes_to_s3(keyframe_data, _artifact_prefix) do
    upload_results =
      Enum.map(keyframe_data, fn keyframe ->
        case S3.upload_file(keyframe.local_path, keyframe.s3_key) do
          {:ok, s3_url} ->
            {:ok, Map.put(keyframe, :s3_url, s3_url)}

          {:error, reason} ->
            {:error, "S3 upload failed for #{keyframe.s3_key}: #{inspect(reason)}"}
        end
      end)

    case Enum.find(upload_results, &match?({:error, _}, &1)) do
      nil ->
        uploaded = Enum.map(upload_results, fn {:ok, data} -> data end)
        Logger.info("Successfully uploaded #{length(uploaded)} keyframes to S3")
        {:ok, uploaded}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_extraction_success(clip, uploaded_keyframes, strategy_config, extraction_method) do
    keyframe_metadata = build_keyframe_data(uploaded_keyframes, strategy_config)

    with {:ok, _artifacts} <- create_keyframe_artifacts(clip.id, uploaded_keyframes),
         {:ok, _updated_clip} <- update_clip_to_keyframed(clip.id, keyframe_metadata) do
      build_success_result(
        clip.id,
        length(uploaded_keyframes),
        strategy_config.strategy,
        extraction_method,
        keyframe_metadata
      )
    else
      {:error, reason} ->
        Logger.error("Failed to process extraction success: #{inspect(reason)}")
        handle_extraction_failure(clip, reason)
    end
  end

  defp create_keyframe_artifacts(clip_id, keyframes) do
    artifacts =
      Enum.map(keyframes, fn keyframe ->
        %{
          s3_key: keyframe.s3_key,
          metadata: keyframe.processing_metadata || %{}
        }
      end)

    Artifacts.create_artifacts(clip_id, "keyframe", artifacts)
  end

  defp update_clip_to_keyframed(clip_id, _keyframe_metadata) do
    with {:ok, clip} <- Clips.get_clip(clip_id) do
      Clips.update_state(clip, "keyframed")
    end
  end

  defp build_success_result(clip_id, keyframe_count, strategy, _method, metadata) do
    result = %Types.KeyframeResult{
      clip_id: clip_id,
      status: "success",
      artifacts: Map.get(metadata, :keyframes, []),
      keyframe_count: keyframe_count,
      strategy: strategy,
      metadata: metadata,
      duration_ms: calculate_duration(metadata),
      processed_at: DateTime.utc_now()
    }

    {:ok, result}
  end

  defp handle_extraction_failure(clip, reason) do
    error_message = ErrorFormatting.format_error(reason)

    with {:ok, clip} <- Clips.get_clip(clip.id) do
      case Clips.mark_failed(clip, "keyframe_failed", error_message) do
        {:ok, _} ->
          Logger.error("Marked clip #{clip.id} as keyframe_failed: #{error_message}")

        {:error, db_error} ->
          Logger.error("Failed to mark clip as failed: #{inspect(db_error)}")
      end
    end

    {:error, error_message}
  end

  defp calculate_duration(metadata) do
    # Simple duration calculation - could be enhanced
    Map.get(metadata, :processing_duration, 0)
  end
end
