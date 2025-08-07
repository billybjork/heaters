defmodule Heaters.Processing.Encode.FileOperations do
  @moduledoc """
  File and directory operations for the encoding process.

  Handles temporary directory setup, source video downloads from S3,
  and file system operations needed during video encoding.

  Uses existing infrastructure:
  - `Heaters.Storage.S3.Core` for S3 operations
  """

  require Logger
  alias Heaters.Storage.S3.Core, as: S3Core

  @type file_result :: {:ok, String.t()} | {:error, String.t()}

  @doc """
  Set up a temporary working directory for encoding operations.
  """
  @spec setup_temp_directory(String.t() | nil, String.t()) :: file_result()
  def setup_temp_directory(nil, operation_name) do
    case System.tmp_dir() do
      nil ->
        {:error, "#{operation_name}: Unable to determine system temporary directory"}

      temp_dir ->
        work_dir = Path.join(temp_dir, "heaters_encode_#{:os.system_time(:millisecond)}")

        case File.mkdir_p(work_dir) do
          :ok ->
            {:ok, work_dir}

          {:error, reason} ->
            {:error, "#{operation_name}: Failed to create temp directory: #{inspect(reason)}"}
        end
    end
  end

  def setup_temp_directory(custom_temp_dir, operation_name) do
    work_dir = Path.join(custom_temp_dir, "heaters_encode_#{:os.system_time(:millisecond)}")

    case File.mkdir_p(work_dir) do
      :ok ->
        {:ok, work_dir}

      {:error, reason} ->
        {:error, "#{operation_name}: Failed to create custom temp directory: #{inspect(reason)}"}
    end
  end

  @doc """
  Get local source video, downloading from S3 if needed.

  Checks if the source path is a local file first. If not, assumes it's an S3 path
  and downloads it to the working directory.
  """
  @spec get_local_source_video(String.t(), String.t(), String.t()) :: file_result()
  def get_local_source_video(source_path, work_dir, operation_name) do
    if File.exists?(source_path) do
      Logger.info("#{operation_name}: Using local source video: #{source_path}")
      {:ok, source_path}
    else
      # Assume it's an S3 path and download it
      local_source_path = Path.join(work_dir, "source.mp4")

      Logger.info("#{operation_name}: Downloading source video from S3: #{source_path}")

      case S3Core.download_file(source_path, local_source_path, operation_name: operation_name) do
        {:ok, ^local_source_path} ->
          {:ok, local_source_path}

        {:error, reason} ->
          {:error, "Failed to download source video: #{reason}"}
      end
    end
  end
end