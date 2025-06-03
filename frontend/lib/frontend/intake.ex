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
  require Logger # For more detailed error logging

  @source_videos "source_videos" # Ecto.Repo.insert_all takes table name as string

  @spec submit(String.t()) :: :ok | {:error, String.t()}
  def submit(url) when is_binary(url) do
    with {:ok, _id} <- insert_source_video(url) do
      :ok
    # Propagate specific error messages
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_source_video(url) do
    is_http? = String.starts_with?(url, ["http://", "https://"])

    title =
      if is_http? do
        try do
          URI.parse(url).host || "?"
        rescue
          _ -> "?"
        end
      else
        url
        |> Path.basename()
        |> Path.rootname()
        |> String.slice(0, 250)
      end

    now = DateTime.utc_now()

    fields = %{
      title: title,
      ingest_state: "new",
      original_url: if(is_http?, do: url, else: nil),
      web_scraped: is_http?,
      inserted_at: now,
      updated_at: now
    }

    case Repo.insert_all(@source_videos, [fields], returning: [:id]) do
      {1, [%{id: id} | _]} ->
        Logger.info("Successfully inserted source_video with ID: #{id} for URL: #{url}")
        {:ok, id}

      {0, _} ->
        Logger.error(
          "DB insert_all returned 0 inserted rows for source_videos with fields: #{inspect(fields)}"
        )
        {:error, "DB insert failed: No rows inserted."}

      {_, error_info_list} ->
        Logger.error(
          "DB insert_all failed for source_videos with fields: #{inspect(fields)}. Error info: #{inspect(error_info_list)}"
        )
        {:error, "DB insert failed with errors."}
    end
  rescue
    e in Postgrex.Error ->
      query_details = if Map.has_key?(e, :query), do: " query: #{e.query}", else: ""

      Logger.error(
        "Postgrex DB error during source_video insert for URL '#{url}'. Error: #{Exception.message(e)}#{query_details}"
      )
      {:error, "DB error: #{Exception.message(e)}"}

    e ->
      Logger.error(
        "Generic error during source_video insert for URL '#{url}'. Error: #{Exception.message(e)} Trace: #{inspect(__STACKTRACE__)}" # Corrected Here
      )
      {:error, "DB error: #{Exception.message(e)}"}
  end

  defp resolve_deployment_id(api_url, deployment_ref) do
    cond do
      Regex.match?(~r/^[0-9a-fA-F-]{36}$/, deployment_ref) ->
        {:ok, deployment_ref}

      String.contains?(deployment_ref, "/") ->
        [flow_name, deployment_name] = String.split(deployment_ref, "/", parts: 2)
        encoded_flow_name = URI.encode(flow_name)
        encoded_deployment_name = URI.encode(deployment_name)
        url = "#{api_url}/deployments/name/#{encoded_flow_name}/#{encoded_deployment_name}"

        Logger.debug("Resolving deployment ID for slug: #{deployment_ref} via URL: #{url}")

        case Req.get(url) do
          {:ok, %Req.Response{status: 200, body: %{"id" => id}}} ->
            Logger.info("Resolved deployment slug '#{deployment_ref}' to ID: #{id}")
            {:ok, id}

          {:ok, %Req.Response{status: status, body: body}} ->
            error_msg =
              "Prefect API error resolving deployment slug '#{deployment_ref}': Status #{status}, Body: #{inspect(body)}"
            Logger.error(error_msg)
            {:error, error_msg}

          {:error, reason} ->
            error_msg =
              "HTTP error resolving deployment slug '#{deployment_ref}': #{inspect(reason)}"
            Logger.error(error_msg)
            {:error, error_msg}
        end

      true ->
        error_msg = "Invalid deployment reference format: '#{deployment_ref}'. Expected UUID or 'flow_name/deployment_name'."
        Logger.error(error_msg)
        {:error, error_msg}
    end
  end

  defp create_prefect_run(source_id, url) do
    api_url = System.get_env("PREFECT_API_URL", "http://localhost:4200/api")

    deployment_ref =
      System.get_env("INTAKE_DEPLOYMENT_ID") ||
        System.get_env("INTAKE_DEPLOYMENT_SLUG")

    unless deployment_ref do
      # This is a configuration error, better to raise
      raise RuntimeError, "INTAKE_DEPLOYMENT_ID or INTAKE_DEPLOYMENT_SLUG environment variable must be set."
    end

    # Get the environment from APP_ENV, defaulting to "development"
    environment = System.get_env("APP_ENV", "development")

    Logger.info(
      "Creating Prefect flow run for source_id: #{source_id}, deployment_ref: #{deployment_ref}, environment: #{environment}"
    )

    with {:ok, deployment_id} <- resolve_deployment_id(api_url, deployment_ref),
         idempotency_key_string <- "frontend_submit_source_id_#{source_id}",
         {:ok, req_response} <-
           Req.post(
             "#{api_url}/deployments/#{deployment_id}/create_flow_run",
             json: %{
               parameters: %{
                 "source_video_id" => source_id,
                 "input_source" => url,
                 "re_encode_for_qt" => true,
                 "overwrite_existing" => false,
                 "environment" => environment
               },
               state: %{type: "SCHEDULED", message: "Flow run submitted from Elixir frontend."},
               idempotency_key: idempotency_key_string
             }
           ) do
      handle_prefect_response(req_response, source_id, deployment_id)
    else
      {:error, msg} ->
        Logger.error("Error in Prefect flow run creation pipeline: #{inspect(msg)}")
        {:error, "Prefect flow run creation setup failed: #{inspect(msg)}"}
    end
  end

  defp handle_prefect_response(req_response, source_id, deployment_id) do
    case req_response do
      %Req.Response{status: status_code, body: body} when status_code in [200, 201] ->
        flow_run_id = if is_map(body), do: body["id"], else: "N/A"
        Logger.info(
          "Successfully created Prefect flow run (ID: #{flow_run_id}) for source_id: #{source_id}, deployment_id: #{deployment_id}"
        )
        :ok

      %Req.Response{status: status_code, body: body} ->
        error_msg =
          "Prefect API error creating flow run for source_id: #{source_id}, deployment_id: #{deployment_id}. Status: #{status_code}, Body: #{inspect(body)}"
        Logger.error(error_msg)
        {:error, "Prefect flow run creation failed with status #{status_code}."}
    end
  end
end
