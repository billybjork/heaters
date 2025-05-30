defmodule Frontend.Intake do
  @moduledoc """
  Pure-Elixir helper that

    1. Inserts a **new** row into source_videos.
    2. Triggers your Prefect deployment (intake_task).

  Expects:

    * PREFECT_API_URL         – defaults to http://localhost:4200/api
    * INTAKE_DEPLOYMENT_ID    – deployment id (UUID) of *intake_task*
    * INTAKE_DEPLOYMENT_SLUG  – optional stable slug like `project-name/deployment-name`
  """

  alias Frontend.Repo

  @source_videos "source_videos"

  @spec submit(String.t()) :: :ok | {:error, String.t()}
  def submit(url) when is_binary(url) do
    with {:ok, id} <- insert_source_video(url),
         :ok <- create_prefect_run(id, url) do
      :ok
    end
  end

  defp insert_source_video(url) do
    is_http? = String.starts_with?(url, ["http://", "https://"])

    title =
      if is_http? do
        "?"
      else
        url
        |> Path.basename(".mp4")
        |> String.slice(0, 250)
      end

    fields = %{
      title: title,
      ingest_state: "new",
      original_url: if(is_http?, do: url, else: nil),
      web_scraped: is_http?,
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    case Repo.insert_all(@source_videos, [fields], returning: [:id]) do
      {1, [%{id: id} | _]} -> {:ok, id}
      _ -> {:error, "DB insert failed"}
    end
  rescue
    e -> {:error, "DB error: #{Exception.message(e)}"}
  end

  defp resolve_deployment_id(api, ref) do
    cond do
      Regex.match?(~r/^[0-9a-f-]{36}$/, ref) ->
        {:ok, ref}

      true ->
        [flow, dep] = String.split(ref, "/", parts: 2)
        enc_flow = URI.encode(flow, &URI.char_unreserved?/1)
        enc_dep  = URI.encode(dep,  &URI.char_unreserved?/1)

        case Req.get(url: "#{api}/deployments/name/#{enc_flow}/#{enc_dep}") do
          {:ok, %Req.Response{status: 200, body: %{"id" => id}}} ->
            {:ok, id}

          {:ok, %Req.Response{status: status, body: body}} ->
            {:error, "Prefect returned #{status}: #{inspect(body)}"}

          {:error, reason} ->
            {:error, "HTTP error: #{inspect(reason)}"}
        end
    end
  end

  defp create_prefect_run(source_id, url) do
    api = System.get_env("PREFECT_API_URL", "http://localhost:4200/api")
    ref = System.get_env("INTAKE_DEPLOYMENT_ID") ||
          System.get_env("INTAKE_DEPLOYMENT_SLUG") ||
          raise "INTAKE_DEPLOYMENT_ID or INTAKE_DEPLOYMENT_SLUG must be set"

    with {:ok, deployment_id} <- resolve_deployment_id(api, ref),
        {:ok, %Req.Response{status: 201}} <- Req.post(
                url: "#{api}/deployments/#{deployment_id}/create_flow_run",
                json: %{
                  parameters: %{
                    "source_video_id"    => source_id,
                    "input_source"       => url,
                    "re_encode_for_qt"   => true,
                    "overwrite_existing" => false
                  },
                  idempotency_key: "frontend_submit_#{source_id}"
                })
    do
      :ok
    else
      {:error, msg} -> {:error, msg}
      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "Flow-run creation failed (#{status}): #{inspect(body)}"}
    end
  end
end
