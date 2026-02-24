defmodule Heaters.Processing.Download.Downloader do
  @moduledoc """
  Downloads videos using yt-dlp via System.cmd with a fallback strategy.

  All configuration comes from `YtDlpConfig`, all execution happens
  through the yt-dlp CLI.

  ## Architecture

  - `download/1` is the single entry point
  - Tries each format strategy in order, stops on first success
  - Runs ffprobe for metadata extraction
  - Applies FFmpeg normalization when the strategy requires it
  - Returns a result map ready for the worker to consume
  """

  alias Heaters.Processing.Download.YtDlpConfig
  alias Heaters.Processing.Support.FFmpeg.Config, as: FFmpegConfig

  require Logger

  @type download_opts :: %{
          url: String.t(),
          source_video_id: integer(),
          timestamp: String.t(),
          config: map(),
          normalize_args: [String.t()]
        }

  @type download_result :: %{
          status: :success,
          filepath: String.t(),
          local_filepath: String.t(),
          duration_seconds: float() | nil,
          fps: float() | nil,
          width: integer() | nil,
          height: integer() | nil,
          file_size_bytes: integer(),
          metadata: map()
        }

  @doc """
  Downloads a video from `url` using the yt-dlp CLI with fallback strategies.

  Returns `{:ok, result}` with metadata and local file path, or `{:error, reason}`.
  """
  @spec download(download_opts()) :: {:ok, download_result()} | {:error, String.t()}
  def download(%{url: url, source_video_id: source_video_id, timestamp: timestamp} = opts) do
    config = Map.get(opts, :config, YtDlpConfig.get_download_config())
    normalize_args = Map.get(opts, :normalize_args, FFmpegConfig.get_args(:download_normalization))

    with :ok <- validate_dependencies(url),
         {:ok, temp_dir} <- create_temp_dir() do
      try do
        strategies = strategies_as_list(config.format_strategies)

        with {:ok, downloaded_path, strategy} <- download_with_fallback(url, temp_dir, strategies, config),
             final_path <- maybe_normalize(downloaded_path, temp_dir, strategy, normalize_args),
             :ok <- validate_file(final_path),
             probe <- extract_metadata(final_path),
             title <- read_info_json_title(temp_dir),
             {:ok, local_filepath} <- persist_to_cache(final_path, source_video_id, timestamp) do
          {:ok,
           %{
             status: :success,
             filepath: "temp_#{source_video_id}_#{timestamp}.mp4",
             local_filepath: local_filepath,
             duration_seconds: probe[:duration_seconds],
             fps: probe[:fps],
             width: probe[:width],
             height: probe[:height],
             file_size_bytes: File.stat!(final_path).size,
             metadata: %{
               title: title,
               original_url: url,
               download_method: strategy.name,
               transcoded: strategy.requires_normalization,
               processing_timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
               cache_key: "temp_#{source_video_id}_#{timestamp}.mp4",
               timestamp: timestamp
             }
           }}
        end
      after
        File.rm_rf(temp_dir)
      end
    end
  end

  # -- Fallback strategy -------------------------------------------------------

  defp download_with_fallback(_url, _temp_dir, [], _config) do
    {:error, "all download strategies failed"}
  end

  defp download_with_fallback(url, temp_dir, [strategy | rest], config) do
    Logger.info("yt-dlp: Attempting #{strategy.name} — #{strategy.description}")

    case try_strategy(url, temp_dir, strategy, config) do
      {:ok, path} ->
        Logger.info("yt-dlp: #{strategy.name} succeeded")
        {:ok, path, strategy}

      {:error, reason} ->
        Logger.warning("yt-dlp: #{strategy.name} failed: #{reason}")
        cleanup_dir_contents(temp_dir)
        download_with_fallback(url, temp_dir, rest, config)
    end
  end

  defp try_strategy(url, temp_dir, strategy, config) do
    args = build_ytdlp_args(url, temp_dir, strategy.format, config)

    Logger.info("yt-dlp: Running with format '#{strategy.format}'")

    try do
      case System.cmd("yt-dlp", args, stderr_to_stdout: true, timeout: download_timeout(config)) do
        {_output, 0} ->
          case find_downloaded_file(temp_dir) do
            {:ok, path} -> {:ok, path}
            :none -> {:error, "yt-dlp exited 0 but no output file found"}
          end

        {output, exit_code} ->
          {:error, "exit #{exit_code}: #{String.slice(output, 0, 500)}"}
      end
    rescue
      e in ErlangError ->
        {:error, "timed out after #{div(download_timeout(config), 1_000)}s: #{Exception.message(e)}"}
    end
  end

  defp build_ytdlp_args(url, temp_dir, format, config) do
    base = config.base_options
    timeouts = config.timeout_config

    [
      # Format selection
      "-f", format,
      "--merge-output-format", "mp4",

      # Output template
      "-o", Path.join(temp_dir, "%(title).200B.%(ext)s"),

      # Reliability
      "--retries", to_string(Map.get(base, :retries, 3)),
      "--fragment-retries", to_string(Map.get(base, :fragment_retries, 5)),
      "--socket-timeout", to_string(Map.get(timeouts, :socket_timeout, 300)),

      # Single video only
      "--no-playlist",
      "--playlist-items", "1",

      # No caching (prevents stale video downloads)
      "--no-cache-dir",

      # Filesystem
      "--restrict-filenames",
      "--no-overwrites",

      # Certificate handling
      "--no-check-certificates",

      # FFmpeg postprocessor args for merge operations
      "--postprocessor-args", "ffmpeg_i:-err_detect ignore_err -fflags +genpts",

      # Concurrent fragment downloads for speed
      "--concurrent-fragments", to_string(Map.get(base, :concurrent_fragment_downloads, 5)),

      # Write info JSON for title/metadata extraction without extra network call
      "--write-info-json",

      # The URL
      url
    ]
  end

  # -- Normalization -----------------------------------------------------------

  defp maybe_normalize(path, _temp_dir, %{requires_normalization: false}, _args), do: path

  defp maybe_normalize(path, temp_dir, %{requires_normalization: true}, normalize_args) do
    normalized_path = Path.join(temp_dir, "normalized_" <> Path.basename(path))

    ffmpeg_args =
      ["-i", to_string(path)] ++ normalize_args ++ ["-y", normalized_path]

    Logger.info("Normalizing download with FFmpeg")

    try do
      case System.cmd("ffmpeg", ffmpeg_args, stderr_to_stdout: true, timeout: 600_000) do
        {_output, 0} ->
          if File.exists?(normalized_path) do
            Logger.info("Normalization succeeded")
            normalized_path
          else
            Logger.warning("Normalization output missing, using original")
            path
          end

        {output, code} ->
          Logger.warning("Normalization failed (exit #{code}), using original: #{String.slice(output, 0, 300)}")
          path
      end
    rescue
      _ ->
        Logger.warning("Normalization timed out, using original")
        path
    end
  end

  # -- Metadata via ffprobe ----------------------------------------------------

  defp extract_metadata(path) do
    args = [
      "-v", "quiet",
      "-print_format", "json",
      "-show_format", "-show_streams",
      to_string(path)
    ]

    case System.cmd("ffprobe", args, stderr_to_stdout: true) do
      {output, 0} ->
        parse_ffprobe_json(output)

      {_output, _code} ->
        Logger.warning("ffprobe failed, returning empty metadata")
        %{}
    end
  end

  defp parse_ffprobe_json(json_string) do
    case Jason.decode(json_string) do
      {:ok, data} ->
        video_stream =
          data
          |> Map.get("streams", [])
          |> Enum.find(&(&1["codec_type"] == "video"))

        duration = get_in(data, ["format", "duration"])

        %{
          duration_seconds: safe_float(duration),
          fps: video_stream && parse_frame_rate(video_stream["r_frame_rate"]),
          width: video_stream && video_stream["width"],
          height: video_stream && video_stream["height"]
        }

      {:error, _} ->
        %{}
    end
  end

  # -- Title extraction from info JSON written during download ----------------

  defp read_info_json_title(temp_dir) do
    case Path.wildcard(Path.join(temp_dir, "*.info.json")) do
      [info_path | _] ->
        case File.read(info_path) do
          {:ok, content} ->
            case Jason.decode(content) do
              {:ok, %{"title" => title}} -> title
              _ -> nil
            end

          _ ->
            nil
        end

      [] ->
        nil
    end
  end

  # -- File helpers ------------------------------------------------------------

  defp find_downloaded_file(dir) do
    dir
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.filter(&(Path.extname(&1) in ~w(.mp4 .mkv .webm .avi)))
    |> Enum.sort_by(&File.stat!(&1).size, :desc)
    |> case do
      [largest | _] -> {:ok, largest}
      [] -> :none
    end
  end

  defp persist_to_cache(path, source_video_id, timestamp) do
    persist_dir = Path.join(System.tmp_dir!(), "heaters_persistent")
    File.mkdir_p!(persist_dir)

    dest = Path.join(persist_dir, "temp_#{source_video_id}_#{timestamp}.mp4")
    File.cp!(to_string(path), dest)

    Logger.info("Persisted download to #{dest}")
    {:ok, dest}
  end

  defp validate_file(path) do
    path = to_string(path)

    cond do
      not File.exists?(path) -> {:error, "downloaded file not found: #{path}"}
      File.stat!(path).size == 0 -> {:error, "downloaded file is empty: #{path}"}
      true -> :ok
    end
  end

  defp cleanup_dir_contents(dir) do
    dir
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.each(&File.rm_rf/1)
  end

  defp create_temp_dir do
    path = Path.join(System.tmp_dir!(), "heaters_dl_#{System.unique_integer([:positive])}")

    case File.mkdir_p(path) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, "failed to create temp dir: #{inspect(reason)}"}
    end
  end

  # -- Validation --------------------------------------------------------------

  defp validate_dependencies(_url) do
    with :ok <- check_executable("yt-dlp"),
         :ok <- check_executable("ffprobe"),
         :ok <- check_executable("ffmpeg") do
      :ok
    end
  end

  defp check_executable(name) do
    case System.find_executable(name) do
      nil -> {:error, "#{name} not found in PATH"}
      _path -> :ok
    end
  end

  # -- Config helpers ----------------------------------------------------------

  defp strategies_as_list(strategies) when is_map(strategies) do
    # Ordered: primary → fallback1 → fallback2
    [:primary, :fallback1, :fallback2]
    |> Enum.filter(&Map.has_key?(strategies, &1))
    |> Enum.map(fn key ->
      strategy = Map.fetch!(strategies, key)
      %{
        name: to_string(key),
        format: strategy.format,
        description: strategy.description,
        requires_normalization: Map.get(strategy, :requires_normalization, false)
      }
    end)
  end

  defp download_timeout(config) do
    # Default 20 minutes, from config if available
    (get_in(config, [:timeout_config, :download_timeout]) || 1200) * 1_000
  end

  # -- Parsing helpers ---------------------------------------------------------

  defp safe_float(nil), do: nil
  defp safe_float(val) when is_float(val), do: val
  defp safe_float(val) when is_integer(val), do: val * 1.0

  defp safe_float(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_frame_rate(nil), do: nil

  defp parse_frame_rate(fps_str) when is_binary(fps_str) do
    case String.split(fps_str, "/") do
      [num, den] ->
        with {n, _} <- Float.parse(num),
             {d, _} <- Float.parse(den),
             true <- d > 0 do
          Float.round(n / d, 3)
        else
          _ -> nil
        end

      _ ->
        case Float.parse(fps_str) do
          {f, _} -> f
          :error -> nil
        end
    end
  end

  defp parse_frame_rate(_), do: nil
end
