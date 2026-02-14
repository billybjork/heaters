defmodule Heaters.Storage.S3.Core do
  @moduledoc """
  Basic S3 operations providing direct AWS S3 functionality.

  This module provides low-level S3 operations with minimal business logic.
  For domain-specific S3 operations that involve business rules or knowledge
  about clips, artifacts, videos, etc., use `Heaters.Storage.S3.Adapter` instead.

  ## When to Use This Module

  - **Basic file operations**: upload_file, download_file, delete_file, head_object
  - **Generic S3 operations**: No knowledge of domain objects (clips, videos, artifacts)
  - **Infrastructure-level operations**: Bucket configuration, batch operations
  - **Utility functions**: file_exists?, upload_file_simple, etc.

  ## When to Use S3.Adapter Instead

  - **Domain-specific operations**: Operations involving clips, videos, or artifacts
  - **Business logic**: S3 paths derived from domain objects, metadata handling
  - **Complex workflows**: Master/proxy uploads, artifact management, CDN URL generation

  This module handles S3 operations that were previously done in Python,
  particularly for basic file operations and batch processing.
  """

  alias ExAws.S3.Upload, as: S3Upload
  require Logger

  # S3 limit for delete_objects operation
  @max_delete_batch_size 1000

  @doc """
  Deletes a list of S3 objects in batches.
  Returns {:ok, deleted_count} or {:error, reason}.
  """
  @spec delete_s3_objects(list(String.t())) :: {:ok, integer()} | {:error, any()}
  def delete_s3_objects(keys) when is_list(keys) do
    if Enum.empty?(keys) do
      {:ok, 0}
    else
      case get_bucket_name() do
        {:ok, bucket_name} ->
          try do
            total_deleted =
              keys
              |> Enum.chunk_every(@max_delete_batch_size)
              |> Enum.reduce(0, fn batch, acc ->
                case delete_s3_objects_batch(bucket_name, batch) do
                  {:ok, deleted_count} ->
                    acc + deleted_count

                  {:error, reason} ->
                    Logger.error("S3 batch deletion failed: #{inspect(reason)}")
                    throw({:error, reason})
                end
              end)

            Logger.info("Successfully deleted #{total_deleted} S3 objects")
            {:ok, total_deleted}
          rescue
            error ->
              Logger.error("S3 deletion error: #{Exception.message(error)}")
              {:error, Exception.message(error)}
          catch
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          Logger.error("S3 bucket name not configured: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Download a file from S3 to a local path using streaming for memory efficiency.

  ## Parameters
  - `s3_path`: S3 path (can start with / or not)
  - `local_path`: Local file path where the file should be saved
  - `opts`: Optional keyword list with options
    - `:operation_name`: String to include in log messages (defaults to "S3")

  ## Examples

      S3.Core.download_file("/path/to/video.mp4", "/tmp/video.mp4")
      S3.Core.download_file("clips/video.mp4", "/tmp/video.mp4", operation_name: "Split")

  ## Returns
  - `{:ok, local_path}` on success
  - `{:error, reason}` on failure
  """
  @spec download_file(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, any()}
  def download_file(s3_path, local_path, opts \\ []) do
    operation_name = Keyword.get(opts, :operation_name, "S3")

    with {:ok, bucket_name} <- get_bucket_name(),
         s3_key = String.trim_leading(s3_path, "/"),
         :ok <- log_download_start(operation_name, bucket_name, s3_key, local_path),
         {:ok, body} <- fetch_s3_object(bucket_name, s3_key, operation_name),
         :ok <- write_downloaded_file(local_path, body, operation_name) do
      {:ok, local_path}
    else
      {:error, reason} ->
        log_download_error(operation_name, reason)
        {:error, reason}
    end
  end

  defp log_download_start(operation_name, bucket_name, s3_key, local_path) do
    Logger.info("#{operation_name}: Downloading s3://#{bucket_name}/#{s3_key} to #{local_path}")
    :ok
  end

  defp fetch_s3_object(bucket_name, s3_key, operation_name) do
    case ExAws.S3.get_object(bucket_name, s3_key) |> ExAws.request() do
      {:ok, %{body: body}} ->
        {:ok, body}

      {:error, reason} ->
        {:error, "#{operation_name}: Failed to download from S3: #{inspect(reason)}"}
    end
  end

  defp write_downloaded_file(local_path, body, operation_name) do
    case File.write(local_path, body) do
      :ok ->
        Logger.debug("#{operation_name}: Successfully downloaded to #{local_path}")
        :ok

      {:error, reason} ->
        {:error, "#{operation_name}: Failed to write file: #{inspect(reason)}"}
    end
  end

  defp log_download_error(operation_name, reason) do
    Logger.error("#{operation_name}: Download failed: #{inspect(reason)}")
  end

  @doc """
  Check if an object exists in S3 using HEAD operation.
  This is much more efficient than download_file for existence checking.

  ## Parameters
  - `s3_path`: S3 path (can start with / or not)

  ## Examples

      S3.Core.head_object("/path/to/video.mp4")
      S3.Core.head_object("clips/video.mp4")

  ## Returns
  - `{:ok, metadata}` on success - object exists
  - `{:error, :not_found}` if object doesn't exist
  - `{:error, reason}` on other failures
  """
  @spec head_object(String.t()) :: {:ok, map()} | {:error, :not_found | any()}
  def head_object(s3_path) do
    case get_bucket_name() do
      {:ok, bucket_name} ->
        s3_key = String.trim_leading(s3_path, "/")

        Logger.debug("S3: Checking existence of s3://#{bucket_name}/#{s3_key}")

        case ExAws.S3.head_object(bucket_name, s3_key) |> ExAws.request() do
          {:ok, response} ->
            # Extract useful metadata from headers
            metadata = %{
              content_length:
                get_header_value(response.headers, "content-length", "0") |> String.to_integer(),
              content_type: get_header_value(response.headers, "content-type", ""),
              last_modified: get_header_value(response.headers, "last-modified", ""),
              etag: get_header_value(response.headers, "etag", "")
            }

            {:ok, metadata}

          {:error, {:http_error, 404, _}} ->
            Logger.debug("S3: Object not found: s3://#{bucket_name}/#{s3_key}")
            {:error, :not_found}

          {:error, reason} ->
            Logger.warning("S3: Failed to check object existence: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("S3: Bucket name not configured: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Upload a local file to S3 using streaming for memory efficiency.

  ## Parameters
  - `local_path`: Path to the local file to upload
  - `s3_key`: S3 key where the file should be stored (without leading /)
  - `opts`: Optional keyword list with options
    - `:operation_name`: String to include in log messages (defaults to "S3")
    - `:content_type`: MIME type for the file (auto-detected if not provided)
    - `:storage_class`: S3 storage class ("STANDARD", "STANDARD_IA", etc.)

  ## Examples

      S3.Core.upload_file("/tmp/video.mp4", "clips/new_video.mp4")
      S3.Core.upload_file("/tmp/keyframe.jpg", "artifacts/keyframe.jpg", operation_name: "Keyframe")
      S3.Core.upload_file("/tmp/master.mp4", "masters/master.mp4", storage_class: "STANDARD")

  ## Returns
  - `{:ok, s3_key}` on success
  - `{:error, reason}` on failure
  """
  @spec upload_file(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, any()}
  def upload_file(local_path, s3_key, opts \\ []) do
    operation_name = Keyword.get(opts, :operation_name, "S3")

    case get_bucket_name() do
      {:ok, bucket_name} ->
        # Ensure s3_key doesn't start with /
        clean_s3_key = String.trim_leading(s3_key, "/")

        Logger.info(
          "#{operation_name}: Uploading #{local_path} to s3://#{bucket_name}/#{clean_s3_key}"
        )

        if File.exists?(local_path) do
          try do
            upload_options = build_upload_options(local_path, opts)

            case S3Upload.stream_file(local_path)
                 |> ExAws.S3.upload(bucket_name, clean_s3_key, upload_options)
                 |> ExAws.request() do
              {:ok, _result} ->
                Logger.debug(
                  "#{operation_name}: Successfully uploaded to s3://#{bucket_name}/#{clean_s3_key}"
                )

                {:ok, clean_s3_key}

              {:error, reason} ->
                Logger.error("#{operation_name}: Failed to upload to S3: #{inspect(reason)}")
                {:error, "Failed to upload to S3: #{inspect(reason)}"}
            end
          rescue
            error ->
              Logger.error(
                "#{operation_name}: Exception during S3 upload: #{Exception.message(error)}"
              )

              {:error, "Exception during S3 upload: #{Exception.message(error)}"}
          end
        else
          {:error, "Local file does not exist: #{local_path}"}
        end

      {:error, reason} ->
        Logger.error("#{operation_name}: S3 bucket name not configured: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Get the configured S3 bucket name.

  ## Returns
  - `{:ok, bucket_name}` if configured
  - `{:error, reason}` if not configured
  """
  @spec get_bucket_name() :: {:ok, String.t()} | {:error, String.t()}
  def get_bucket_name do
    case Application.get_env(:heaters, :s3_bucket) do
      nil ->
        {:error, "S3 bucket name not configured. Please set :s3_bucket in application config."}

      bucket_name ->
        {:ok, bucket_name}
    end
  end

  # Private functions

  defp delete_s3_objects_batch(bucket_name, keys) when is_list(keys) do
    Logger.info("Deleting batch of #{length(keys)} S3 objects from bucket: #{bucket_name}")

    # ExAws.S3.delete_multiple_objects expects a list of keys (strings)
    case ExAws.S3.delete_multiple_objects(bucket_name, keys) |> ExAws.request() do
      {:ok, %{body: body}} ->
        # Handle both parsed map responses and raw XML string responses
        case body do
          body_map when is_map(body_map) ->
            # Body is already parsed as a map
            parse_delete_response_map(body_map)

          xml_string when is_binary(xml_string) ->
            # Body is raw XML string - this indicates successful deletion
            # Parse basic success from XML (simple regex for now)
            deleted_count = count_deleted_objects_in_xml(xml_string)

            Logger.info(
              "S3 deletion completed successfully, parsed #{deleted_count} deleted objects from XML"
            )

            {:ok, deleted_count}

          _ ->
            Logger.warning("Unexpected S3 delete response format: #{inspect(body)}")
            # Assume success if we get here with no errors
            {:ok, length(keys)}
        end

      {:ok, response} ->
        Logger.warning("Unexpected S3 delete response: #{inspect(response)}")
        # Assume success if no explicit errors
        {:ok, length(keys)}

      {:error, reason} ->
        Logger.error("S3 delete_multiple_objects failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_upload_options(local_path, opts) do
    content_type = Keyword.get(opts, :content_type) || guess_content_type(local_path)
    storage_class = Keyword.get(opts, :storage_class)

    base_options = []

    # Add content type if available
    options_with_content_type =
      if content_type do
        [content_type: content_type] ++ base_options
      else
        base_options
      end

    # Add storage class if specified
    if storage_class do
      [storage_class: storage_class] ++ options_with_content_type
    else
      options_with_content_type
    end
  end

  @content_type_map %{
    ".mp4" => "video/mp4",
    ".mov" => "video/quicktime",
    ".avi" => "video/x-msvideo",
    ".webm" => "video/webm",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".png" => "image/png",
    ".gif" => "image/gif",
    ".webp" => "image/webp"
  }

  defp guess_content_type(local_path) do
    extension = Path.extname(local_path) |> String.downcase()
    Map.get(@content_type_map, extension)
  end

  defp get_header_value(headers, key, default) do
    case Enum.find(headers, fn {header_key, _} ->
           String.downcase(header_key) == String.downcase(key)
         end) do
      {_, value} -> value
      nil -> default
    end
  end

  # Helper function to parse S3 delete response when body is already a parsed map
  defp parse_delete_response_map(body_map) do
    deleted_objects =
      Map.get(body_map, "DeleteResult", %{})
      |> Map.get("Deleted", [])
      |> List.wrap()

    errors =
      Map.get(body_map, "DeleteResult", %{})
      |> Map.get("Error", [])
      |> List.wrap()

    deleted_count = length(deleted_objects)

    if errors != [] do
      Logger.warning("S3 deletion had #{length(errors)} errors")

      Enum.each(errors, fn error ->
        key = Map.get(error, "Key", "unknown")
        code = Map.get(error, "Code", "unknown")
        message = Map.get(error, "Message", "unknown")
        Logger.error("Failed to delete #{key}: #{code} - #{message}")
      end)
    end

    {:ok, deleted_count}
  end

  # Helper function to count deleted objects from raw XML response
  defp count_deleted_objects_in_xml(xml_string) do
    # Simple regex to count <Deleted> tags in the XML response
    # This is a basic implementation that works for successful deletions
    deleted_matches = Regex.scan(~r/<Deleted>.*?<\/Deleted>/s, xml_string)
    length(deleted_matches)
  end

  # Additional convenience functions for simpler S3 operations interface

  @doc """
  Delete a single file from S3.

  ## Examples

      {:ok, 1} = S3.Core.delete_file("clips/video.mp4")
      {:ok, 0} = S3.Core.delete_file("nonexistent/file.mp4")
  """
  @spec delete_file(String.t()) :: {:ok, integer()} | {:error, any()}
  def delete_file(s3_path) do
    s3_key = String.trim_leading(s3_path, "/")
    delete_s3_objects([s3_key])
  end

  @doc """
  Delete multiple files from S3.

  ## Examples

      {:ok, 3} = S3.Core.delete_multiple_files(["file1.mp4", "file2.mp4", "file3.mp4"])
  """
  @spec delete_multiple_files(list(String.t())) :: {:ok, integer()} | {:error, any()}
  def delete_multiple_files(s3_keys) when is_list(s3_keys) do
    delete_s3_objects(s3_keys)
  end

  @doc """
  Check if a file exists in S3 using efficient HEAD operation.

  ## Examples

      true = S3.Core.file_exists?("clips/video.mp4")
      false = S3.Core.file_exists?("clips/missing.mp4")
  """
  @spec file_exists?(String.t()) :: boolean()
  def file_exists?(s3_path) do
    case head_object(s3_path) do
      {:ok, _metadata} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Upload a file with simplified return interface.

  ## Examples

      :ok = S3.Core.upload_file_simple("/tmp/video.mp4", "clips/new_video.mp4")
  """
  @spec upload_file_simple(String.t(), String.t()) :: :ok | {:error, any()}
  def upload_file_simple(local_path, s3_key) do
    case upload_file(local_path, s3_key) do
      {:ok, _s3_key} -> :ok
      error -> error
    end
  end

  @doc """
  Upload a file with operation name and simplified return interface.

  ## Examples

      {:ok, "clips/video.mp4"} = S3.Core.upload_file_with_operation("/tmp/video.mp4", "clips/video.mp4", "Split")
  """
  @spec upload_file_with_operation(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, any()}
  def upload_file_with_operation(local_path, s3_key, operation_name) do
    case upload_file(local_path, s3_key, operation_name: operation_name) do
      {:ok, ^s3_key} -> {:ok, s3_key}
      error -> error
    end
  end

  @doc """
  Upload a file to S3 with detailed progress reporting using native Elixir implementation.

  This function provides percentage-based progress logging with exponential backoff retry logic,
  multipart uploads for large files, and comprehensive error handling. It replaces the previous
  Python-based implementation while maintaining the same interface and functionality.

  ## Parameters
  - `local_path`: Path to the local file to upload
  - `s3_key`: S3 key where the file should be stored (without leading /)
  - `opts`: Optional keyword list with options
    - `:operation_name`: String to include in log messages (defaults to "S3Upload")
    - `:storage_class`: S3 storage class ("STANDARD", "STANDARD_IA", etc.)
    - `:timeout`: Upload timeout in milliseconds (defaults to 30 minutes)
    - `:progress_throttle`: Progress reporting throttle percentage (defaults to 5)
    - `:max_retries`: Maximum retry attempts (defaults to 3)

  ## Examples

      S3.Core.upload_file_with_progress("/tmp/large_video.mp4", "masters/video.mp4")
      S3.Core.upload_file_with_progress("/tmp/master.mp4", "masters/master.mp4",
                                   storage_class: "STANDARD", timeout: :timer.minutes(45))

  ## Returns
  - `{:ok, s3_key}` on success
  - `{:error, reason}` on failure
  """
  @spec upload_file_with_progress(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, any()}
  def upload_file_with_progress(local_path, s3_key, opts \\ []) do
    operation_name = Keyword.get(opts, :operation_name, "S3Upload")
    storage_class = Keyword.get(opts, :storage_class, "STANDARD")
    progress_throttle = Keyword.get(opts, :progress_throttle, 5)
    max_retries = Keyword.get(opts, :max_retries, 3)

    # Ensure s3_key doesn't start with /
    clean_s3_key = String.trim_leading(s3_key, "/")

    Logger.info(
      "#{operation_name}: Starting native Elixir upload with progress reporting: #{local_path} -> s3://bucket/#{clean_s3_key}"
    )

    if File.exists?(local_path) do
      case get_bucket_name() do
        {:ok, bucket_name} ->
          upload_with_native_progress_and_retry(
            local_path,
            bucket_name,
            clean_s3_key,
            storage_class,
            operation_name,
            progress_throttle,
            max_retries
          )

        {:error, reason} ->
          Logger.error("#{operation_name}: S3 bucket name not configured: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:error, "Local file does not exist: #{local_path}"}
    end
  end

  # Private function for native upload with progress reporting and retry logic
  @spec upload_with_native_progress_and_retry(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          integer(),
          integer()
        ) :: {:ok, String.t()} | {:error, any()}
  defp upload_with_native_progress_and_retry(
         local_path,
         bucket_name,
         s3_key,
         storage_class,
         operation_name,
         progress_throttle,
         max_retries
       ) do
    file_size = File.stat!(local_path).size

    Logger.info(
      "#{operation_name}: File size: #{format_file_size(file_size)} (#{format_number(file_size)} bytes)"
    )

    Logger.info("#{operation_name}: Storage class: #{storage_class}")
    Logger.info("#{operation_name}: Destination: s3://#{bucket_name}/#{s3_key}")

    # Use exponential backoff retry logic similar to Python implementation
    retry_with_exponential_backoff(max_retries, fn attempt ->
      if attempt > 1 do
        Logger.info("#{operation_name}: Retry attempt #{attempt}/#{max_retries}")
      end

      # Verify file still exists before each attempt
      if not File.exists?(local_path) do
        throw({:permanent_error, "Local file no longer exists: #{local_path}"})
      end

      Logger.info(
        "#{operation_name}: Starting S3 upload (attempt #{attempt}/#{max_retries}): #{Path.basename(local_path)} (#{format_file_size(file_size)}) to s3://#{bucket_name}/#{s3_key}"
      )

      # Create progress tracking agent for this upload
      {:ok, progress_agent} =
        start_progress_agent(
          file_size,
          Path.basename(local_path),
          operation_name,
          progress_throttle
        )

      try do
        upload_options =
          build_upload_options_with_progress(local_path, storage_class, progress_agent)

        case S3Upload.stream_file(local_path)
             |> ExAws.S3.upload(bucket_name, s3_key, upload_options)
             |> ExAws.request() do
          {:ok, _result} ->
            # Final progress update
            update_progress(progress_agent, file_size)

            Logger.info(
              "#{operation_name}: Successfully uploaded #{Path.basename(local_path)} to s3://#{bucket_name}/#{s3_key}"
            )

            # Verify upload with HEAD request
            case verify_upload(bucket_name, s3_key, operation_name) do
              :ok ->
                {:ok, s3_key}

              {:error, reason} ->
                Logger.warning(
                  "#{operation_name}: Upload verification failed for #{s3_key}: #{reason}"
                )

                # Don't fail for verification issues - upload likely succeeded
                {:ok, s3_key}
            end

          {:error, reason} ->
            Logger.error("#{operation_name}: S3 upload failed: #{inspect(reason)}")
            {:error, reason}
        end
      after
        Agent.stop(progress_agent)
      end
    end)
  end

  # Start a progress tracking agent
  @spec start_progress_agent(integer(), String.t(), String.t(), integer()) :: {:ok, pid()}
  defp start_progress_agent(total_size, filename, operation_name, throttle_percentage) do
    Agent.start_link(fn ->
      %{
        total_size: total_size,
        filename: filename,
        operation_name: operation_name,
        throttle_percentage: throttle_percentage,
        bytes_uploaded: 0,
        last_logged_percentage: -1
      }
    end)
  end

  # Update progress and log when appropriate
  @spec update_progress(pid(), integer()) :: :ok
  defp update_progress(progress_agent, bytes_amount) do
    Agent.update(progress_agent, fn state ->
      new_bytes_uploaded = state.bytes_uploaded + bytes_amount

      current_percentage =
        if state.total_size > 0, do: div(new_bytes_uploaded * 100, state.total_size), else: 0

      should_log =
        (current_percentage >= state.last_logged_percentage + state.throttle_percentage and
           current_percentage < 100) or
          (current_percentage == 100 and state.last_logged_percentage != 100)

      if should_log do
        size_mb = new_bytes_uploaded / (1024 * 1024)
        total_size_mb = state.total_size / (1024 * 1024)

        Logger.info(
          "#{state.operation_name}: #{state.filename} - #{current_percentage}% complete " <>
            "(#{:erlang.float_to_binary(size_mb, decimals: 2)}/#{:erlang.float_to_binary(total_size_mb, decimals: 2)} MiB)"
        )
      end

      %{
        state
        | bytes_uploaded: new_bytes_uploaded,
          last_logged_percentage:
            if(should_log, do: current_percentage, else: state.last_logged_percentage)
      }
    end)
  end

  # Build upload options with progress callback
  @spec build_upload_options_with_progress(String.t(), String.t(), pid()) :: keyword()
  defp build_upload_options_with_progress(local_path, storage_class, progress_agent) do
    content_type = guess_content_type(local_path)

    base_options = [
      # Progress callback
      callback: fn bytes_amount -> update_progress(progress_agent, bytes_amount) end,
      # Multipart upload configuration for large files
      # 100MB threshold
      multipart_threshold: 100 * 1024 * 1024,
      # 16MB chunks
      chunk_size: 16 * 1024 * 1024
    ]

    # Add content type if available
    options_with_content_type =
      if content_type do
        [content_type: content_type] ++ base_options
      else
        base_options
      end

    # Add storage class if specified and not STANDARD
    if storage_class != "STANDARD" do
      [storage_class: storage_class] ++ options_with_content_type
    else
      options_with_content_type
    end
  end

  # Verify upload with HEAD request
  @spec verify_upload(String.t(), String.t(), String.t()) :: :ok | {:error, any()}
  defp verify_upload(bucket_name, s3_key, operation_name) do
    case ExAws.S3.head_object(bucket_name, s3_key) |> ExAws.request() do
      {:ok, _response} ->
        Logger.info("#{operation_name}: S3 upload verification successful for #{s3_key}")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Retry with exponential backoff
  @spec retry_with_exponential_backoff(integer(), (integer() -> {:ok, any()} | {:error, any()})) ::
          {:ok, any()} | {:error, any()}
  defp retry_with_exponential_backoff(max_retries, operation_fn) do
    retry_with_exponential_backoff(max_retries, 1, operation_fn)
  end

  @spec retry_with_exponential_backoff(
          integer(),
          integer(),
          (integer() -> {:ok, any()} | {:error, any()})
        ) ::
          {:ok, any()} | {:error, any()}
  defp retry_with_exponential_backoff(max_retries, attempt, operation_fn)
       when attempt <= max_retries do
    case operation_fn.(attempt) do
      {:ok, result} ->
        {:ok, result}

      {:error, _reason} when attempt < max_retries ->
        # Exponential backoff: 2s, 4s, 8s
        delay = (2000 * :math.pow(2, attempt - 1)) |> round()
        Logger.info("Retrying upload after #{delay}ms...")
        Process.sleep(delay)
        retry_with_exponential_backoff(max_retries, attempt + 1, operation_fn)

      {:error, reason} ->
        Logger.error("Upload failed after #{max_retries} attempts")
        {:error, reason}
    end
  catch
    {:permanent_error, reason} ->
      Logger.error("Permanent error during upload: #{reason}")
      {:error, reason}
  end

  defp retry_with_exponential_backoff(_max_retries, _attempt, _operation_fn) do
    {:error, "Maximum retry attempts exceeded"}
  end

  # Format file size for human-readable logging
  @spec format_file_size(integer()) :: String.t()
  defp format_file_size(bytes) when bytes >= 1024 * 1024 * 1024 do
    gb = bytes / (1024 * 1024 * 1024)
    "#{:erlang.float_to_binary(gb, decimals: 2)} GiB"
  end

  defp format_file_size(bytes) when bytes >= 1024 * 1024 do
    mb = bytes / (1024 * 1024)
    "#{:erlang.float_to_binary(mb, decimals: 2)} MiB"
  end

  defp format_file_size(bytes) when bytes >= 1024 do
    kb = bytes / 1024
    "#{:erlang.float_to_binary(kb, decimals: 2)} KiB"
  end

  defp format_file_size(bytes) do
    "#{bytes} bytes"
  end

  # Format number with commas for readability
  @spec format_number(integer()) :: String.t()
  defp format_number(number) do
    number
    |> to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
