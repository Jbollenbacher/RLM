defmodule RLM.ObservabilityRouterTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias RLM.Observability.Store
  alias RLM.Observability.Router

  setup do
    {:ok, _pid} =
      start_supervised(
        {Store, [max_events_per_agent: 10, max_context_snapshots_per_agent: 10, max_agents: 10]}
      )

    :ok
  end

  test "chat endpoints return and mutate chat state" do
    {:ok, _pid} =
      start_supervised(
        {RLM.Observability.Chat,
         [
           context: "",
           ask_fn: fn session, message ->
             {{:ok, "echo: #{message}"}, session}
           end
         ]}
      )

    conn = conn(:get, "/api/chat") |> Router.call([])
    assert conn.status == 200
    assert conn.resp_body =~ "\"session_id\""

    conn =
      conn(:post, "/api/chat", Jason.encode!(%{message: "hello web"}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Router.call([])

    assert conn.status == 202
    assert conn.resp_body =~ "accepted"

    conn = wait_for_chat_messages(2)
    assert conn.status == 200
    payload = Jason.decode!(conn.resp_body)
    assert length(payload["messages"]) == 2
    assert Enum.at(payload["messages"], 1)["content"] =~ "echo: hello web"
    refute payload["busy"]
  end

  test "chat stop endpoint interrupts running generation" do
    {:ok, _pid} =
      start_supervised(
        {RLM.Observability.Chat,
         [
           context: "",
           ask_fn: fn session, _message ->
             Process.sleep(5_000)
             {{:ok, "should never arrive"}, session}
           end
         ]}
      )

    conn =
      conn(:post, "/api/chat", Jason.encode!(%{message: "hello web"}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Router.call([])

    assert conn.status == 202

    conn = conn(:post, "/api/chat/stop", Jason.encode!(%{})) |> Router.call([])
    assert conn.status == 200
    assert conn.resp_body =~ "\"stopped\":true"

    conn = wait_for_chat_messages(2)
    payload = Jason.decode!(conn.resp_body)
    assert Enum.at(payload["messages"], 1)["content"] =~ "Interrupted"
    refute payload["busy"]
  end

  test "chat endpoint validates body" do
    {:ok, _pid} =
      start_supervised(
        {RLM.Observability.Chat,
         [
           context: "",
           ask_fn: fn session, _message ->
             {{:ok, "ok"}, session}
           end
         ]}
      )

    conn =
      conn(:post, "/api/chat", Jason.encode!(%{}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Router.call([])

    assert conn.status == 422
    assert conn.resp_body =~ "Missing `message`"
  end

  test "chat endpoint reports unavailable when web chat is not started" do
    conn = conn(:get, "/api/chat") |> Router.call([])
    assert conn.status == 404
    assert conn.resp_body =~ "Web chat is not enabled"
  end

  test "agents and snapshots endpoints" do
    Store.put_agent(%{id: "agent_ui", status: :running})

    Store.add_snapshot(%{
      agent_id: "agent_ui",
      iteration: 0,
      context_window_size_chars: 3,
      preview: "abc",
      transcript: "abc",
      compacted?: false
    })

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

    conn =
      conn(:get, "/api/events?since=0&since_id=0&agent_id=agent_evt&debug=1") |> Router.call([])

    assert conn.status == 200
    assert conn.resp_body =~ "one"
    assert conn.resp_body =~ "two"
    assert conn.resp_body =~ "\"log_view\":\"debug\""
  end

  test "events endpoint defaults to filtered normal log view" do
    Store.put_agent(%{id: "agent_filtered"})
    Store.add_event(%{agent_id: "agent_filtered", type: :llm, payload: %{status: :ok}, ts: 1000})

    Store.add_event(%{
      agent_id: "agent_filtered",
      type: :iteration,
      payload: %{status: :ok},
      ts: 1010
    })

    Store.add_event(%{
      agent_id: "agent_filtered",
      type: :iteration,
      payload: %{status: :error},
      ts: 1020
    })

    Store.add_event(%{
      agent_id: "agent_filtered",
      type: :agent_end,
      payload: %{status: :done},
      ts: 1030
    })

    conn = conn(:get, "/api/events?since=0&since_id=0&agent_id=agent_filtered") |> Router.call([])
    assert conn.status == 200

    body = Jason.decode!(conn.resp_body)
    assert body["log_view"] == "normal"
    types = Enum.map(body["events"], & &1["type"])
    assert "llm" in types
    assert "iteration" in types
    assert "agent_end" in types
  end

  test "full log export endpoint returns downloadable JSON" do
    Store.put_agent(%{id: "agent_export", status: :running})
    Store.add_event(%{agent_id: "agent_export", type: :agent_start, payload: %{}, ts: 1000})

    Store.add_snapshot(%{
      agent_id: "agent_export",
      ts: 1001,
      iteration: 0,
      context_window_size_chars: 10,
      preview: "preview",
      transcript: "[PRINCIPAL]\nhello",
      transcript_without_system: "[PRINCIPAL]\nhello",
      compacted?: false
    })

    conn = conn(:get, "/api/export/full_logs?include_system=1") |> Router.call([])
    assert conn.status == 200

    assert Plug.Conn.get_resp_header(conn, "content-type")
           |> Enum.any?(&String.starts_with?(&1, "application/json"))

    assert Plug.Conn.get_resp_header(conn, "content-disposition")
           |> Enum.any?(&String.contains?(&1, "attachment; filename=\"rlm_agent_logs_"))

    body = Jason.decode!(conn.resp_body)
    assert body["format"] == "rlm_agent_log_v1"
    assert body["log_view"] == "normal"
    assert is_list(body["agent_tree"])
  end

  defp wait_for_chat_messages(min_count, retries \\ 60)

  defp wait_for_chat_messages(_min_count, 0) do
    conn(:get, "/api/chat") |> Router.call([])
  end

  defp wait_for_chat_messages(min_count, retries) do
    conn = conn(:get, "/api/chat") |> Router.call([])
    payload = Jason.decode!(conn.resp_body)

    if length(payload["messages"] || []) >= min_count do
      conn
    else
      Process.sleep(20)
      wait_for_chat_messages(min_count, retries - 1)
    end
  end
end
