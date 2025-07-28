defmodule HeatersWeb.FFmpegPool do
  @moduledoc """
  Process pool manager for FFmpeg streaming operations with rate limiting.

  Uses ETS counters to track active FFmpeg processes and prevent resource exhaustion.
  Returns 429 (Too Many Requests) when the maximum concurrent processes is exceeded.

  ## Configuration

  Add to your config files:

      config :heaters, HeatersWeb.FFmpegPool,
        max_concurrent_processes: 10,
        cleanup_interval: 30_000

  ## Usage

      case FFmpegPool.acquire() do
        :ok -> 
          # Proceed with FFmpeg streaming
          try do
            StreamPorts.stream(conn, cmd)
          after
            FFmpegPool.release()
          end
        :rate_limited -> 
          # Return 429 Too Many Requests
      end
  """

  use GenServer
  require Logger

  @table_name :ffmpeg_process_counter
  @active_processes_key :active_count

  ## Client API

  @doc """
  Start the FFmpeg pool manager.

  Creates ETS table for process counting and starts cleanup timer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Attempt to acquire a slot for FFmpeg processing.

  ## Returns

  - `:ok` - Slot acquired, proceed with FFmpeg operation
  - `:rate_limited` - Maximum processes reached, return 429 response
  """
  def acquire do
    max_processes = max_concurrent_processes()

    case :ets.update_counter(@table_name, @active_processes_key, 1, {@active_processes_key, 0}) do
      count when count <= max_processes ->
        Logger.debug("FFmpeg process acquired (#{count}/#{max_processes})")
        :ok

      count ->
        # Rollback the increment since we're over the limit
        :ets.update_counter(@table_name, @active_processes_key, -1)
        Logger.warning("FFmpeg rate limit exceeded (#{count - 1}/#{max_processes})")
        :rate_limited
    end
  end

  @doc """
  Release a slot after FFmpeg processing completes.

  Should be called in a try/after block to ensure proper cleanup.
  """
  def release do
    case :ets.update_counter(@table_name, @active_processes_key, -1, {@active_processes_key, 0}) do
      count when count >= 0 ->
        Logger.debug("FFmpeg process released (#{count} remaining)")
        :ok

      negative_count ->
        # Reset to 0 if we somehow went negative
        :ets.insert(@table_name, {@active_processes_key, 0})
        Logger.warning("FFmpeg counter went negative (#{negative_count}), reset to 0")
        :ok
    end
  end

  @doc """
  Get current process count for monitoring.

  ## Returns

  - `{active_count, max_count}` tuple
  """
  def status do
    active =
      case :ets.lookup(@table_name, @active_processes_key) do
        [{@active_processes_key, count}] -> count
        [] -> 0
      end

    {active, max_concurrent_processes()}
  end

  @doc """
  Force reset the process counter (for emergencies).

  This should only be used if the counter gets into an inconsistent state.
  """
  def reset_counter do
    GenServer.call(__MODULE__, :reset_counter)
  end

  ## GenServer Implementation

  @impl true
  def init(_opts) do
    # Create ETS table for process counting
    :ets.new(@table_name, [:named_table, :public, :set, {:write_concurrency, true}])
    :ets.insert(@table_name, {@active_processes_key, 0})

    # Schedule periodic cleanup
    schedule_cleanup()

    Logger.info("FFmpeg pool started with max #{max_concurrent_processes()} processes")
    {:ok, %{}}
  end

  @impl true
  def handle_call(:reset_counter, _from, state) do
    old_count =
      case :ets.lookup(@table_name, @active_processes_key) do
        [{@active_processes_key, count}] -> count
        [] -> 0
      end

    :ets.insert(@table_name, {@active_processes_key, 0})
    Logger.warning("FFmpeg process counter reset from #{old_count} to 0")

    {:reply, {:reset, old_count}, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    # Periodic cleanup - could add logic to detect stuck processes here
    # For now, just log current status
    {active, max} = status()

    if active > 0 do
      Logger.debug("FFmpeg pool status: #{active}/#{max} processes active")
    end

    schedule_cleanup()
    {:noreply, state}
  end

  ## Private Functions

  defp max_concurrent_processes do
    Application.get_env(:heaters, __MODULE__, [])
    |> Keyword.get(:max_concurrent_processes, 10)
  end

  defp cleanup_interval do
    Application.get_env(:heaters, __MODULE__, [])
    |> Keyword.get(:cleanup_interval, 30_000)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, cleanup_interval())
  end
end
