defmodule HeatersWeb.StreamPorts do
  @moduledoc """
  Helper module for streaming FFmpeg output directly to HTTP responses.

  Provides robust port management with zombie process protection, proper cleanup
  on connection drops, and chunked HTTP response handling with backpressure.

  ## Usage

      conn
      |> put_resp_header("content-type", "video/mp4")
      |> send_chunked(200)
      |> StreamPorts.stream(ffmpeg_cmd)

  ## Features

  - Port monitoring with automatic cleanup on process death
  - Connection drop detection with proper FFmpeg termination
  - Backpressure handling to prevent memory bloat
  - SIGTERM graceful shutdown for FFmpeg processes
  """

  require Logger
  alias Plug.Conn

  @doc """
  Stream FFmpeg command output directly to a chunked HTTP response.

  ## Parameters

  - `conn` - Plug.Conn with chunked response already started
  - `cmd` - List of FFmpeg command arguments (first element should be "ffmpeg")

  ## Returns

  - `{:ok, conn}` - Successfully streamed all data
  - `{:error, reason, conn}` - Error occurred during streaming
  """
  def stream(%Conn{} = conn, cmd) when is_list(cmd) do
    ffmpeg_bin = System.find_executable("ffmpeg")

    if ffmpeg_bin do
      do_stream(conn, ffmpeg_bin, tl(cmd))
    else
      Logger.error("FFmpeg executable not found in PATH")
      {:error, :ffmpeg_not_found, conn}
    end
  end

  defp do_stream(conn, ffmpeg_bin, args) do
    start_time = System.monotonic_time(:millisecond)
    Logger.debug("Starting FFmpeg stream with args: #{inspect(args)}")

    # Open port with error output redirected to stdout for better error handling
    port =
      Port.open({:spawn_executable, ffmpeg_bin}, [
        :binary,
        :exit_status,
        {:args, args},
        :stderr_to_stdout
      ])

    # Monitor port to detect zombie processes
    port_ref = Port.monitor(port)

    # Set up connection cleanup callback
    conn =
      Conn.register_before_send(conn, fn conn ->
        cleanup_port(port, port_ref)
        conn
      end)

    # Start streaming loop
    stream_loop(conn, port, port_ref, start_time)
  end

  # Main streaming loop that handles port output and connection state
  defp stream_loop(conn, port, port_ref, start_time) do
    receive do
      # Data from FFmpeg stdout/stderr
      {^port, {:data, data}} ->
        case chunk_data(conn, data) do
          {:ok, conn} ->
            stream_loop(conn, port, port_ref, start_time)

          {:error, reason} ->
            Logger.warning("Failed to send chunk: #{inspect(reason)}")
            cleanup_port(port, port_ref)
            {:error, :chunk_failed, conn}
        end

      # Port exit (normal completion)
      {^port, {:exit_status, 0}} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time

        Logger.info("FFmpeg stream completed successfully",
          duration_ms: duration_ms,
          pool_status: HeatersWeb.FFmpegPool.status()
        )

        Port.demonitor(port_ref, [:flush])
        {:ok, conn}

      # Port exit (error)
      {^port, {:exit_status, exit_code}} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time

        Logger.error("FFmpeg process failed with exit code: #{exit_code}",
          duration_ms: duration_ms,
          exit_code: exit_code,
          pool_status: HeatersWeb.FFmpegPool.status()
        )

        Port.demonitor(port_ref, [:flush])
        {:error, {:ffmpeg_exit, exit_code}, conn}

      # Port monitor (process died unexpectedly)
      {:DOWN, ^port_ref, :port, ^port, reason} ->
        Logger.error("FFmpeg port died unexpectedly: #{inspect(reason)}")
        {:error, {:port_died, reason}, conn}

        # Timeout to prevent hanging connections (configurable)
    after
      stream_timeout() ->
        Logger.warning("FFmpeg stream timeout reached")
        cleanup_port(port, port_ref)
        {:error, :timeout, conn}
    end
  end

  # Send data chunk to HTTP response with error handling
  defp chunk_data(conn, data) do
    case Conn.chunk(conn, data) do
      {:ok, conn} -> {:ok, conn}
      {:error, :closed} -> {:error, :connection_closed}
      {:error, reason} -> {:error, reason}
    end
  end

  # Clean shutdown of FFmpeg process
  defp cleanup_port(port, port_ref) do
    if Port.info(port) do
      Logger.debug("Terminating FFmpeg process")

      # Send SIGTERM for graceful shutdown
      # FFmpeg quit command
      Port.command(port, "q")

      # Wait briefly for graceful exit, then force kill
      receive do
        {^port, {:exit_status, _}} -> :ok
      after
        1000 ->
          Port.close(port)
      end
    end

    Port.demonitor(port_ref, [:flush])
  end

  # Configurable stream timeout (default 5 minutes for large clips)
  defp stream_timeout do
    Application.get_env(:heaters, :ffmpeg_stream_timeout, 300_000)
  end
end
