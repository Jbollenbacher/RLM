defmodule RLM.Observability.Router do
  use Plug.Router

  plug(:fetch_qs)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:match)
  plug(:dispatch)

  get "/" do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, RLM.Observability.UI.html())
  end

  get "/api/agents" do
    agents = RLM.Observability.Store.list_agents()
    json(conn, 200, %{agents: agents})
  end

  get "/api/agents/:id" do
    agent = RLM.Observability.Store.get_agent(id)
    json(conn, 200, %{agent: agent})
  end

  get "/api/agents/:id/context" do
    include_system = parse_bool(Map.get(conn.query_params, "include_system", "0"))
    snapshot = RLM.Observability.Store.latest_snapshot(id)
    snapshot = maybe_strip_system_prompt(snapshot, include_system)
    json(conn, 200, %{snapshot: snapshot})
  end

  get "/api/events" do
    params = conn.query_params
    since_ts = parse_int(Map.get(params, "since", "0"))
    since_id = parse_int(Map.get(params, "since_id", "0"))
    agent_id = Map.get(params, "agent_id")
    limit = parse_int(Map.get(params, "limit", "500"))

    events =
      RLM.Observability.Store.list_events(
        since_ts: since_ts,
        since_id: since_id,
        agent_id: agent_id,
        limit: limit
      )

    json(conn, 200, %{events: events})
  end

  get "/api/chat" do
    case RLM.Observability.Chat.state() do
      {:ok, chat_state} ->
        json(conn, 200, chat_state)

      {:error, reason} ->
        json(conn, 404, %{error: reason})
    end
  end

  post "/api/chat" do
    case message_from_body(conn.body_params) do
      {:ok, message} ->
        case RLM.Observability.Chat.ask(message) do
          {:ok, response} -> json(conn, 202, response)
          {:error, reason} -> json(conn, 409, %{error: reason})
        end

      {:error, reason} ->
        json(conn, 422, %{error: reason})
    end
  end

  post "/api/chat/stop" do
    case RLM.Observability.Chat.stop() do
      {:ok, response} ->
        json(conn, 200, response)

      {:error, reason} ->
        json(conn, 404, %{error: reason})
    end
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end

  defp fetch_qs(conn, _opts) do
    Plug.Conn.fetch_query_params(conn)
  end

  defp json(conn, status, data) do
    body = Jason.encode!(data)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  defp parse_int(nil), do: 0

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 0
    end
  end

  defp parse_bool(value) when value in [true, "true", "1", "yes", "on"], do: true
  defp parse_bool(_value), do: false

  defp maybe_strip_system_prompt(nil, _include_system), do: nil
  defp maybe_strip_system_prompt(snapshot, true), do: snapshot

  defp maybe_strip_system_prompt(snapshot, false) do
    filtered =
      Map.get(snapshot, :transcript_without_system) ||
        Map.get(snapshot, :transcript) ||
        ""

    Map.put(snapshot, :transcript, filtered)
  end

  defp message_from_body(params) when is_map(params) do
    message = Map.get(params, "message") || Map.get(params, :message)

    case message do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: {:error, "Message cannot be empty"}, else: {:ok, trimmed}

      _ ->
        {:error, "Missing `message` in request body"}
    end
  end

  defp message_from_body(_), do: {:error, "Invalid request body"}
end
