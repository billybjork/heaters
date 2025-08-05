defmodule Heaters.Storage.PlaybackCache.CleanupWorker do
  @moduledoc """
  Scheduled maintenance worker for playback cache cleanup and monitoring.

  This worker performs regular maintenance tasks:
  - Cleans up expired temporary clip files
  - Monitors total cache size and enforces limits
  - Checks disk space availability
  - Logs cache statistics for monitoring

  Runs every 4 hours via Oban cron schedule.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  # Configuration
  @tmp_dir System.tmp_dir!()

  # Get configuration values at runtime
  defp get_config do
    Application.get_env(:heaters, :playback_cache, [])
  end

  defp max_cache_size_bytes, do: Keyword.get(get_config(), :max_cache_size_bytes, 1_000_000_000)
  defp min_free_disk_bytes, do: Keyword.get(get_config(), :min_free_disk_bytes, 500_000_000)
  defp max_age_minutes, do: Keyword.get(get_config(), :max_age_minutes, 15)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("PlaybackCache.CleanupWorker: Starting scheduled maintenance")

    try do
      stats = %{
        expired_cleaned: cleanup_expired_clips(),
        cache_size_bytes: get_cache_size(),
        lru_evicted: enforce_cache_limits(),
        free_disk_bytes: check_disk_space()
      }

      log_cache_statistics(stats)

      if stats.free_disk_bytes < min_free_disk_bytes() do
        Logger.warning(
          "PlaybackCache.CleanupWorker: Low disk space detected: #{format_bytes(stats.free_disk_bytes)} free"
        )
      end

      Logger.info("PlaybackCache.CleanupWorker: Maintenance completed successfully")
      :ok
    rescue
      error ->
        Logger.error(
          "PlaybackCache.CleanupWorker: Maintenance failed: #{Exception.message(error)}"
        )

        {:error, Exception.message(error)}
    end
  end

  @doc """
  Clean up expired temporary clip files.

  Removes clip files older than the configured age limit.
  Returns the number of files cleaned up.
  """
  @spec cleanup_expired_clips() :: non_neg_integer()
  def cleanup_expired_clips do
    Logger.debug("PlaybackCache.CleanupWorker: Starting expired clip cleanup")

    cutoff_time = System.system_time(:second) - max_age_minutes() * 60

    clip_files = find_clip_files()

    expired_files =
      clip_files
      |> Enum.filter(&file_expired?(&1, cutoff_time))

    cleaned_count =
      expired_files
      |> Enum.reduce(0, fn file_path, acc ->
        case File.rm(file_path) do
          :ok ->
            Logger.debug(
              "PlaybackCache.CleanupWorker: Removed expired file: #{Path.basename(file_path)}"
            )

            acc + 1

          {:error, reason} ->
            Logger.warning(
              "PlaybackCache.CleanupWorker: Failed to remove #{file_path}: #{reason}"
            )

            acc
        end
      end)

    if cleaned_count > 0 do
      Logger.info("PlaybackCache.CleanupWorker: Cleaned up #{cleaned_count} expired clip files")
    end

    cleaned_count
  end

  @doc """
  Get the total size of the playback cache in bytes.
  """
  @spec get_cache_size() :: non_neg_integer()
  def get_cache_size do
    clip_files = find_clip_files()

    total_size =
      clip_files
      |> Enum.reduce(0, fn file_path, acc ->
        case File.stat(file_path) do
          {:ok, %File.Stat{size: size}} -> acc + size
          {:error, _} -> acc
        end
      end)

    Logger.debug("PlaybackCache.CleanupWorker: Total cache size: #{format_bytes(total_size)}")
    total_size
  end

  @doc """
  Enforce cache size limits by removing oldest files if over limit.

  Uses LRU (Least Recently Used) strategy based on file access time.
  Returns the number of files evicted.
  """
  @spec enforce_cache_limits() :: non_neg_integer()
  def enforce_cache_limits do
    current_size = get_cache_size()
    max_size = max_cache_size_bytes()

    if current_size <= max_size do
      0
    else
      Logger.info(
        "PlaybackCache.CleanupWorker: Cache size #{format_bytes(current_size)} exceeds limit #{format_bytes(max_size)}, starting LRU eviction"
      )

      clip_files = find_clip_files()

      # Sort by access time (oldest first) for LRU eviction
      files_by_access =
        clip_files
        |> Enum.map(fn file_path ->
          case File.stat(file_path) do
            {:ok, stat} -> {file_path, stat.atime, stat.size}
            {:error, _} -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(fn {_path, atime, _size} -> atime end)

      # Remove files until we're under the limit
      {_remaining_size, evicted_count} =
        Enum.reduce_while(files_by_access, {current_size, 0}, fn {file_path, _atime, file_size},
                                                                 {size_acc, count_acc} ->
          if size_acc > max_size do
            case File.rm(file_path) do
              :ok ->
                Logger.debug(
                  "PlaybackCache.CleanupWorker: Evicted file: #{Path.basename(file_path)} (#{format_bytes(file_size)})"
                )

                {:cont, {size_acc - file_size, count_acc + 1}}

              {:error, reason} ->
                Logger.warning(
                  "PlaybackCache.CleanupWorker: Failed to evict #{file_path}: #{reason}"
                )

                {:cont, {size_acc, count_acc}}
            end
          else
            {:halt, {size_acc, count_acc}}
          end
        end)

      if evicted_count > 0 do
        Logger.info(
          "PlaybackCache.CleanupWorker: Evicted #{evicted_count} files due to cache size limit"
        )
      end

      evicted_count
    end
  end

  @doc """
  Check available disk space in the temp directory.

  Returns available bytes.
  """
  @spec check_disk_space() :: non_neg_integer()
  def check_disk_space do
    case :file.read_file_info(@tmp_dir) do
      {:ok, _} ->
        # Use df command to get disk space (cross-platform)
        case System.cmd("df", ["-k", @tmp_dir], stderr_to_stdout: true) do
          {output, 0} ->
            parse_df_output(output)

          {error_output, _} ->
            Logger.warning(
              "PlaybackCache.CleanupWorker: Failed to check disk space: #{error_output}"
            )

            0
        end

      {:error, reason} ->
        Logger.warning("PlaybackCache.CleanupWorker: Cannot access temp directory: #{reason}")
        0
    end
  end

  # Private helper functions

  defp find_clip_files do
    case File.ls(@tmp_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.match?(&1, ~r/^clip_\d+_\d+\.mp4$/))
        |> Enum.map(&Path.join(@tmp_dir, &1))
        |> Enum.filter(&File.regular?/1)

      {:error, _} ->
        []
    end
  end

  defp file_expired?(file_path, cutoff_time) do
    case File.stat(file_path) do
      {:ok, %File.Stat{mtime: mtime}} ->
        # Convert mtime to seconds since epoch for comparison
        mtime_seconds = :calendar.datetime_to_gregorian_seconds(mtime) - 62_167_219_200
        mtime_seconds < cutoff_time

      {:error, _} ->
        # If we can't stat it, consider it expired
        true
    end
  end

  defp parse_df_output(output) do
    # Parse df output to extract available bytes
    # Example output: "/dev/disk1s1  488245288  350823392  136765632    73%    /System/Volumes/Data"
    lines = String.split(output, "\n", trim: true)

    case lines do
      [_header | [data_line | _]] ->
        # Split by whitespace and get the 4th column (available KB)
        case String.split(data_line, ~r/\s+/, trim: true) do
          [_filesystem, _total, _used, available_kb | _] ->
            case Integer.parse(available_kb) do
              # Convert KB to bytes
              {kb, ""} -> kb * 1024
              _ -> 0
            end

          _ ->
            0
        end

      _ ->
        0
    end
  rescue
    _ -> 0
  end

  defp log_cache_statistics(stats) do
    Logger.info("PlaybackCache.CleanupWorker: Cache Statistics", %{
      expired_files_cleaned: stats.expired_cleaned,
      cache_size: format_bytes(stats.cache_size_bytes),
      cache_size_bytes: stats.cache_size_bytes,
      lru_files_evicted: stats.lru_evicted,
      free_disk_space: format_bytes(stats.free_disk_bytes),
      free_disk_bytes: stats.free_disk_bytes,
      cache_limit: format_bytes(max_cache_size_bytes()),
      cache_utilization_percent:
        Float.round(stats.cache_size_bytes / max_cache_size_bytes() * 100, 1)
    })
  end

  defp format_bytes(bytes) when bytes >= 1_000_000_000 do
    "#{Float.round(bytes / 1_000_000_000, 2)}GB"
  end

  defp format_bytes(bytes) when bytes >= 1_000_000 do
    "#{Float.round(bytes / 1_000_000, 2)}MB"
  end

  defp format_bytes(bytes) when bytes >= 1_000 do
    "#{Float.round(bytes / 1_000, 2)}KB"
  end

  defp format_bytes(bytes), do: "#{bytes}B"
end
