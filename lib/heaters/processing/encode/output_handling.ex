defmodule Heaters.Processing.Encode.OutputHandling do
  @moduledoc """
  Output handling strategies for encoded video files.

  Handles both immediate S3 upload and temporary cache strategies.
  Uses existing infrastructure:
  - `Heaters.Storage.S3.Core` for S3 operations
  """

  require Logger
  alias Heaters.Storage.S3.Core, as: S3Core

  @type output_result :: {:ok, map()} | {:error, String.t()}

  @doc """
  Handle output strategy - either immediate upload or temp cache.

  Chooses between immediate S3 upload or local caching based on the
  use_temp_cache flag.
  """
  @spec handle_output_strategy(map(), map(), map(), boolean(), String.t()) :: output_result()
  def handle_output_strategy(
        proxy_info,
        master_info,
        source_metadata,
        use_temp_cache,
        operation_name
      ) do
    if use_temp_cache do
      handle_temp_cache_strategy(proxy_info, master_info, source_metadata, operation_name)
    else
      handle_immediate_upload_strategy(proxy_info, master_info, source_metadata, operation_name)
    end
  end

  @doc """
  Handle temp cache strategy - cache files locally for later batch upload.

  Creates cached copies of proxy and master files in a temporary directory
  for later batch upload to S3.
  """
  @spec handle_temp_cache_strategy(map(), map(), map(), String.t()) :: output_result()
  def handle_temp_cache_strategy(proxy_info, master_info, source_metadata, operation_name) do
    Logger.info("#{operation_name}: Using temp cache strategy - files will be uploaded later")

    cache_dir = Path.join(System.tmp_dir(), "heaters_encode_cache")
    File.mkdir_p(cache_dir)

    # Cache proxy
    proxy_cache_name = proxy_info.s3_path |> String.replace("/", "_")
    proxy_cached_path = Path.join(cache_dir, proxy_cache_name)
    File.cp!(proxy_info.local_path, proxy_cached_path)

    result = %{
      proxy_path: proxy_info.s3_path,
      proxy_local_path: proxy_cached_path,
      keyframe_offsets: proxy_info.keyframe_offsets,
      metadata: source_metadata
    }

    # Cache master if created
    result =
      if master_info[:local_path] do
        master_cache_name = master_info.s3_path |> String.replace("/", "_")
        master_cached_path = Path.join(cache_dir, master_cache_name)
        File.cp!(master_info.local_path, master_cached_path)

        Map.merge(result, %{
          master_path: master_info.s3_path,
          master_local_path: master_cached_path
        })
      else
        result
      end

    {:ok, result}
  end

  @doc """
  Handle immediate upload strategy - upload files to S3 right away.

  Uploads both proxy and master files immediately to S3 using the
  existing S3 infrastructure.
  """
  @spec handle_immediate_upload_strategy(map(), map(), map(), String.t()) :: output_result()
  def handle_immediate_upload_strategy(proxy_info, master_info, source_metadata, operation_name) do
    Logger.info("#{operation_name}: Using immediate upload strategy")

    # Upload proxy
    case S3Core.upload_file(proxy_info.local_path, proxy_info.s3_path,
           operation_name: operation_name,
           storage_class: "STANDARD"
         ) do
      {:ok, _} ->
        result = %{
          proxy_path: proxy_info.s3_path,
          keyframe_offsets: proxy_info.keyframe_offsets,
          metadata: source_metadata
        }

        # Upload master if created
        if master_info[:local_path] do
          case S3Core.upload_file(master_info.local_path, master_info.s3_path,
                 operation_name: operation_name,
                 storage_class: "STANDARD"
               ) do
            {:ok, _} ->
              result = Map.put(result, :master_path, master_info.s3_path)
              {:ok, result}

            {:error, reason} ->
              {:error, "Failed to upload master: #{reason}"}
          end
        else
          {:ok, result}
        end

      {:error, reason} ->
        {:error, "Failed to upload proxy: #{reason}"}
    end
  end
end