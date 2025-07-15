defmodule Heaters.Clips.Operations.Shared.TempManager do
  @moduledoc """
  Centralized temporary directory management for transformation operations.

  This module provides consistent temporary directory creation, cleanup, and
  management patterns across all transformation operations, eliminating
  duplicate implementations.

  ## Startup Cleanup

  Call `cleanup_orphaned_temp_files/0` during application startup to remove
  temporary files from previous runs that may have been interrupted.
  """

  require Logger

  @doc """
  Clean up orphaned temporary files from previous runs.

  Searches for and removes temporary directories that match our naming pattern
  but were left behind from previous runs. This should be called during
  application startup to ensure a clean state.

  ## Returns
  - `{:ok, cleanup_count}` on success with number of directories cleaned
  - `{:error, reason}` on failure

  ## Examples

      {:ok, cleanup_count} = TempManager.cleanup_orphaned_temp_files()
      Logger.info("Cleaned up orphaned temp directories: " <> Integer.to_string(cleanup_count))
  """
  @spec cleanup_orphaned_temp_files() :: {:ok, non_neg_integer()} | {:error, any()}
  def cleanup_orphaned_temp_files() do
    case System.tmp_dir() do
      nil ->
        Logger.warning("TempManager: Could not access system temp directory for orphan cleanup")
        {:error, "Could not access system temp directory"}

      temp_root ->
        Logger.info("TempManager: Starting orphaned temp file cleanup in #{temp_root}")
        cleanup_matching_directories(temp_root)
    end
  end

  @doc """
  Create a temporary directory for transformation operations.

  Creates a unique temporary directory with an optional prefix to help
  identify which operation created it.

  ## Parameters
  - `prefix` (optional): String prefix for the temp directory name.
    Defaults to "heaters_transform"

  ## Examples

      # Create with default prefix
      {:ok, temp_dir} = TempManager.create_temp_directory()

      # Create with operation-specific prefix
      {:ok, temp_dir} = TempManager.create_temp_directory("split")
      # Creates: /tmp/heaters_split_123456789

      {:ok, temp_dir} = TempManager.create_temp_directory("sprite")
      # Creates: /tmp/heaters_sprite_987654321

  ## Returns
  - `{:ok, temp_dir_path}` on success
  - `{:error, reason}` on failure
  """
  @spec create_temp_directory(String.t()) :: {:ok, String.t()} | {:error, any()}
  def create_temp_directory(prefix \\ "transform") do
    case System.tmp_dir() do
      nil ->
        Logger.error("TempManager: Could not access system temp directory")
        {:error, "Could not access system temp directory"}

      temp_root ->
        temp_dir = Path.join(temp_root, "heaters_#{prefix}_#{System.unique_integer([:positive])}")

        case File.mkdir_p(temp_dir) do
          :ok ->
            Logger.debug("TempManager: Created temp directory: #{temp_dir}")
            {:ok, temp_dir}

          {:error, reason} ->
            Logger.error("TempManager: Failed to create temp directory: #{reason}")
            {:error, "Failed to create temp directory: #{reason}"}
        end
    end
  end

  @doc """
  Clean up a temporary directory and all its contents.

  Safely removes the specified directory and all files/subdirectories within it.

  ## Parameters
  - `temp_dir`: Path to the temporary directory to remove

  ## Examples

      TempManager.cleanup_temp_directory("/tmp/heaters_split_123456789")

  ## Returns
  - `:ok` on success (even if directory doesn't exist)
  - `{:error, reason}` on failure
  """
  @spec cleanup_temp_directory(String.t()) :: :ok | {:error, any()}
  def cleanup_temp_directory(temp_dir) do
    if File.exists?(temp_dir) do
      Logger.debug("TempManager: Cleaning up temp directory: #{temp_dir}")

      case File.rm_rf(temp_dir) do
        {:ok, _deleted_files} ->
          Logger.debug("TempManager: Successfully cleaned up temp directory: #{temp_dir}")
          :ok

        {:error, reason, _path} ->
          Logger.error("TempManager: Failed to cleanup temp directory #{temp_dir}: #{reason}")
          {:error, "Failed to cleanup temp directory: #{reason}"}
      end
    else
      Logger.debug("TempManager: Temp directory does not exist, skipping cleanup: #{temp_dir}")
      :ok
    end
  end

  @doc """
  Execute a function with automatic temporary directory management.

  Creates a temporary directory, executes the provided function with it,
  and ensures cleanup happens regardless of success or failure.

  ## Parameters
  - `prefix`: String prefix for the temp directory name
  - `fun`: Function that takes the temp directory path and returns a result

  ## Examples

      result = TempManager.with_temp_directory("split", fn temp_dir ->
        # Your processing logic here
        # temp_dir is automatically cleaned up after this function
        process_video(temp_dir)
      end)

  ## Returns
  - Returns whatever the provided function returns
  - Temp directory is always cleaned up, even if function raises an exception
  """
  @spec with_temp_directory(String.t(), (String.t() -> any())) :: any()
  def with_temp_directory(prefix, fun) when is_function(fun, 1) do
    with {:ok, temp_dir} <- create_temp_directory(prefix) do
      try do
        Logger.debug("TempManager: Executing function with temp directory: #{temp_dir}")
        fun.(temp_dir)
      after
        Logger.debug(
          "TempManager: Cleaning up temp directory after function execution: #{temp_dir}"
        )

        cleanup_temp_directory(temp_dir)
      end
    else
      error ->
        Logger.error(
          "TempManager: Could not create temp directory for function execution: #{inspect(error)}"
        )

        error
    end
  end

  @doc """
  Get information about a temporary directory.

  Returns basic information about the directory including existence,
  size, and file count.

  ## Parameters
  - `temp_dir`: Path to the temporary directory

  ## Returns
  - `{:ok, info_map}` with directory information
  - `{:error, reason}` if directory doesn't exist or can't be accessed
  """
  @spec get_temp_directory_info(String.t()) :: {:ok, map()} | {:error, any()}
  def get_temp_directory_info(temp_dir) do
    if File.exists?(temp_dir) do
      try do
        file_list = File.ls!(temp_dir)
        file_count = length(file_list)

        # Calculate total size of all files in directory
        total_size =
          file_list
          |> Enum.map(&Path.join(temp_dir, &1))
          |> Enum.filter(&File.regular?/1)
          |> Enum.map(fn file_path ->
            case File.stat(file_path) do
              {:ok, %File.Stat{size: size}} -> size
              _ -> 0
            end
          end)
          |> Enum.sum()

        info = %{
          path: temp_dir,
          exists: true,
          file_count: file_count,
          total_size_bytes: total_size,
          files: file_list
        }

        {:ok, info}
      rescue
        e ->
          Logger.error(
            "TempManager: Error getting directory info for #{temp_dir}: #{Exception.message(e)}"
          )

          {:error, "Error accessing directory: #{Exception.message(e)}"}
      end
    else
      {:error, "Directory does not exist: #{temp_dir}"}
    end
  end

  # Private helper functions

  @spec cleanup_matching_directories(String.t()) :: {:ok, non_neg_integer()} | {:error, any()}
  defp cleanup_matching_directories(temp_root) do
    try do
      # Our temp directories follow the pattern: heaters_<prefix>_<unique_integer>
      heaters_dirs =
        File.ls!(temp_root)
        |> Enum.filter(&String.starts_with?(&1, "heaters_"))
        |> Enum.filter(&File.dir?(Path.join(temp_root, &1)))

      cleaned_count =
        heaters_dirs
        |> Enum.map(&Path.join(temp_root, &1))
        |> Enum.reduce(0, fn dir_path, acc ->
          case cleanup_temp_directory(dir_path) do
            :ok ->
              Logger.debug("TempManager: Cleaned orphaned directory: #{dir_path}")
              acc + 1

            {:error, reason} ->
              Logger.warning(
                "TempManager: Failed to clean orphaned directory #{dir_path}: #{reason}"
              )

              acc
          end
        end)

      if cleaned_count > 0 do
        Logger.info("TempManager: Cleaned up #{cleaned_count} orphaned temp directories")
      else
        Logger.debug("TempManager: No orphaned temp directories found")
      end

      {:ok, cleaned_count}
    rescue
      e ->
        error_msg = "Failed to cleanup orphaned temp directories: #{Exception.message(e)}"
        Logger.error("TempManager: #{error_msg}")
        {:error, error_msg}
    end
  end
end
