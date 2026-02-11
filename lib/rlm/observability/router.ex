defmodule RLM.Observability.Router do
  use Plug.Router

  plug :fetch_qs
  plug :match
  plug :dispatch

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
end
