defmodule Heaters.Pipeline.ConfigTest do
  use ExUnit.Case, async: true

  alias Ecto.Changeset
  alias Heaters.Pipeline.Config
  alias Heaters.Processing.Export.Worker, as: ExportWorker
  alias Heaters.Processing.Keyframe.Worker, as: KeyframeWorker

  describe "find_next_stage_for_worker/1" do
    test "returns keyframe stage for export worker" do
      assert {:ok, %{worker: KeyframeWorker, condition: condition_fn, args: args_fn}} =
               Config.find_next_stage_for_worker(ExportWorker)

      assert is_function(condition_fn, 1)
      assert is_function(args_fn, 1)
    end
  end

  describe "maybe_chain_next_job/3" do
    test "enqueues next-stage worker when condition passes" do
      item = %{id: 123, ingest_state: :exported, clip_filepath: "clips/clip_123.mp4"}

      insert_fun = fn changeset ->
        send(self(), {:inserted, Changeset.apply_changes(changeset)})
        {:ok, %Oban.Job{id: 999}}
      end

      assert :ok = Config.maybe_chain_next_job(ExportWorker, item, insert_fun)

      assert_received {:inserted,
                       %Oban.Job{
                         worker: "Elixir.Heaters.Processing.Keyframe.Worker",
                         args: %{"clip_id" => 123, "strategy" => strategy}
                       }}

      assert is_binary(strategy)
    end

    test "returns enqueue error when insert fails" do
      item = %{id: 456, ingest_state: :exported, clip_filepath: "clips/clip_456.mp4"}

      assert {:error, :insert_failed} =
               Config.maybe_chain_next_job(ExportWorker, item, fn _ ->
                 {:error, :insert_failed}
               end)
    end

    test "returns :ok without enqueue when condition does not pass" do
      item = %{id: 789, ingest_state: :review_approved, clip_filepath: nil}

      assert :ok =
               Config.maybe_chain_next_job(ExportWorker, item, fn _ ->
                 flunk("insert function should not run when condition is false")
               end)
    end
  end
end
