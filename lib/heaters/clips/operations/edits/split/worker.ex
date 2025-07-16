defmodule Heaters.Clips.Operations.Edits.Split.Worker do
  @moduledoc """
  Oban worker for split operations with idempotency and error handling.

  This worker handles video clip splitting operations through the queue system,
  providing reliable job processing with automatic retry and idempotency patterns.

  ## Idempotency Features
  - Detects already-processed splits (clips exist or archived state)
  - Handles `:already_processed` errors gracefully without failing jobs
  - Supports safe retries when partial operations are interrupted

  ## Unique Constraints
  - 15-minute uniqueness window prevents duplicate split jobs
  - Keyed by clip_id and split_at_frame to prevent concurrent processing

  ## Error Handling
  - Graceful handling of file-not-found scenarios
  - Database conflict resolution for duplicate clip records
  - Comprehensive logging for debugging failed operations
  """

  use Heaters.Infrastructure.Orchestration.WorkerBehavior,
    queue: :media_processing,
    # 15 minutes, prevent duplicate split jobs
    unique: [period: 900, fields: [:args]]

  alias Heaters.Clips.Operations.Edits.Split
  alias Heaters.Clips.Operations.Shared.Types
  alias Heaters.Infrastructure.Orchestration.WorkerBehavior
  require Logger

  @impl WorkerBehavior
  def handle_work(args) do
    handle_split_work(args)
  end

  defp handle_split_work(%{"clip_id" => clip_id, "split_at_frame" => split_at_frame}) do
    case Split.run_split(clip_id, split_at_frame) do
      {:ok, %Types.SplitResult{status: "success", new_clip_ids: new_clip_ids}}
      when is_list(new_clip_ids) ->
        :ok

      {:ok, %Types.SplitResult{status: status}} ->
        {:error, "Split finished with unexpected status: #{status}"}

      {:error, :already_processed} ->
        WorkerBehavior.handle_already_processed("Clip", clip_id)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
