defmodule RLM.ObservabilityRouterTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias RLM.Observability.Store
  alias RLM.Observability.Router

  setup do
    {:ok, _pid} = start_supervised({Store, [max_events_per_agent: 10, max_context_snapshots_per_agent: 10, max_agents: 10]})
    :ok
  end

  test "agents and snapshots endpoints" do
    Store.put_agent(%{id: "agent_ui", status: :running})
    Store.add_snapshot(%{agent_id: "agent_ui", iteration: 0, context_window_size_chars: 3, preview: "abc", transcript: "abc", compacted?: false})

    conn = conn(:get, "/api/agents") |> Router.call([])
    assert conn.status == 200
    assert conn.resp_body =~ "agent_ui"

    conn = conn(:get, "/api/agents/agent_ui/context") |> Router.call([])
    assert conn.status == 200
    assert conn.resp_body =~ "\"preview\""
  end

  test "events endpoint respects cursor" do
    Store.put_agent(%{id: "agent_evt"})
    Store.add_event(%{agent_id: "agent_evt", type: :one, payload: %{}, ts: 1000})
    Store.add_event(%{agent_id: "agent_evt", type: :two, payload: %{}, ts: 1000})

    conn = conn(:get, "/api/events?since=0&since_id=0&agent_id=agent_evt") |> Router.call([])
    assert conn.status == 200
    assert conn.resp_body =~ "one"
    assert conn.resp_body =~ "two"
  end
end
