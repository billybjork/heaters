defmodule Heaters.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Heaters.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Heaters.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Heaters.DataCase

      # Import factory function
      import Heaters.DataCase, only: [insert: 1, insert: 2]
    end
  end

  setup tags do
    Heaters.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Heaters.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  @doc """
  Factory function for creating test data.
  """
  def insert(factory_name, attrs \\ %{})

  def insert(:source_video, attrs) do
    default_attrs = %{
      title: "Test Video #{System.unique_integer()}",
      original_url: "https://example.com/video.mp4",
      ingest_state: "downloaded",
      download_url: "https://example.com/video.mp4",
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    attrs = Map.merge(default_attrs, Enum.into(attrs, %{}))

    %Heaters.Video.Intake.SourceVideo{}
    |> Heaters.Video.Intake.SourceVideo.changeset(attrs)
    |> Heaters.Repo.insert!()
  end

  def insert(:clip, attrs) do
    source_video = Map.get(attrs, :source_video) || insert(:source_video)
    attrs = Map.delete(attrs, :source_video)

    default_attrs = %{
      clip_identifier: "test_clip_#{System.unique_integer()}",
      clip_filepath: "/source_videos/123/clips/test_clip.mp4",
      start_frame: 0,
      end_frame: 1000,
      start_time_seconds: 0.0,
      end_time_seconds: 33.33,
      ingest_state: "pending_review",
      source_video_id: source_video.id,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    attrs = Map.merge(default_attrs, Enum.into(attrs, %{}))

    %Heaters.Clips.Clip{}
    |> Heaters.Clips.Clip.changeset(attrs)
    |> Heaters.Repo.insert!()
  end

  def insert(:clip_event, attrs) do
    clip = Map.get(attrs, :clip) || insert(:clip)
    attrs = Map.delete(attrs, :clip)

    default_attrs = %{
      clip_id: clip.id,
      action: "test_action",
      reviewer_id: "test_user",
      event_data: %{},
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    attrs = Map.merge(default_attrs, Enum.into(attrs, %{}))

    %Heaters.Events.ClipEvent{}
    |> Heaters.Events.ClipEvent.changeset(attrs)
    |> Heaters.Repo.insert!()
  end

  def insert(:clip_artifact, attrs) do
    clip = Map.get(attrs, :clip) || insert(:clip)
    attrs = Map.delete(attrs, :clip)

    default_attrs = %{
      clip_id: clip.id,
      artifact_type: "keyframe",
      s3_key: "test/artifact_#{System.unique_integer()}.jpg",
      metadata: %{},
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    attrs = Map.merge(default_attrs, Enum.into(attrs, %{}))

    %Heaters.Clip.Transform.ClipArtifact{}
    |> Heaters.Clip.Transform.ClipArtifact.changeset(attrs)
    |> Heaters.Repo.insert!()
  end
end
