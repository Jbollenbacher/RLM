defmodule RLM.ObservabilityStoreTest do
  use ExUnit.Case

  alias RLM.Observability.Store

  setup do
    {:ok, _pid} =
      start_supervised(
        {Store, [max_events_per_agent: 3, max_context_snapshots_per_agent: 2, max_agents: 2]}
      )

    :ok
  end

  test "event cursor ordering uses (ts, id)" do
    Store.put_agent(%{id: "agent_a"})

    # Force same timestamp by injecting ts
    Store.add_event(%{agent_id: "agent_a", type: :a, payload: %{}, ts: 1000})
    Store.add_event(%{agent_id: "agent_a", type: :b, payload: %{}, ts: 1000})
    Store.add_event(%{agent_id: "agent_a", type: :c, payload: %{}, ts: 1000})

    events = Store.list_events(agent_id: "agent_a", since_ts: 0, since_id: 0, limit: 10)
    assert Enum.map(events, & &1.type) == [:a, :b, :c]

    last = List.last(events)

    events2 =
      Store.list_events(agent_id: "agent_a", since_ts: last.ts, since_id: last.id, limit: 10)

    assert events2 == []
  end

  test "event eviction respects max_events_per_agent" do
    Store.put_agent(%{id: "agent_b"})

    Enum.each(1..5, fn idx ->
      Store.add_event(%{agent_id: "agent_b", type: {:evt, idx}, payload: %{}})
    end)

    events = Store.list_events(agent_id: "agent_b", since_ts: 0, since_id: 0, limit: 10)
    assert length(events) == 3
    assert Enum.map(events, & &1.type) == [{:evt, 3}, {:evt, 4}, {:evt, 5}]
  end

  test "snapshot truncation keeps tail and marker" do
    Store.put_agent(%{id: "agent_c"})

    long = String.duplicate("a", 50)

    config =
      RLM.Config.load(
        truncation_head: 5,
        truncation_tail: 5,
        obs_max_context_window_chars: 20
      )

    RLM.Observability.Tracker.snapshot_context(
      "agent_c",
      0,
      [%{role: :user, content: long}],
      config
    )

    snapshot = Store.latest_snapshot("agent_c")
    assert snapshot.truncated_bytes > 0
    assert String.contains?(snapshot.transcript, "[truncated")
    assert String.ends_with?(snapshot.transcript, String.duplicate("a", 20))
  end

  test "snapshot preserves leading system blocks from user messages" do
    Store.put_agent(%{id: "agent_d"})

    config =
      RLM.Config.load(
        truncation_head: 5,
        truncation_tail: 5,
        obs_max_context_window_chars: 10_000
      )

    content = """
    [SYSTEM]
    Workspace access is read-write.

    [PRINCIPAL]
    Hello! can you tell me about that book?
    """

    RLM.Observability.Tracker.snapshot_context(
      "agent_d",
      0,
      [%{role: :user, content: content}],
      config
    )

    snapshot = Store.latest_snapshot("agent_d")
    assert String.starts_with?(snapshot.transcript, "[SYSTEM]\nWorkspace access is read-write.")
    refute String.starts_with?(snapshot.transcript, "[PRINCIPAL]\n[SYSTEM]")
  end

  test "snapshot preserves subagent return label for user runtime notices" do
    Store.put_agent(%{id: "agent_subret"})

    config =
      RLM.Config.load(
        truncation_head: 50,
        truncation_tail: 50,
        obs_max_context_window_chars: 10_000
      )

    RLM.Observability.Tracker.snapshot_context(
      "agent_subret",
      0,
      [%{role: :user, content: "[SUBAGENT_RETURN]\nchild_agent_id: agent_2\nstatus: ok"}],
      config
    )

    snapshot = Store.latest_snapshot("agent_subret")
    assert String.starts_with?(snapshot.transcript, "[SUBAGENT_RETURN]\nchild_agent_id: agent_2")
  end

  test "agent eviction removes events and snapshots" do
    Store.put_agent(%{id: "agent_1"})
    Store.add_event(%{agent_id: "agent_1", type: :a, payload: %{}})

    Store.add_snapshot(%{
      agent_id: "agent_1",
      iteration: 0,
      context_window_size_chars: 1,
      preview: "x",
      transcript: "x",
      compacted?: false
    })

    Store.put_agent(%{id: "agent_2"})
    Store.add_event(%{agent_id: "agent_2", type: :b, payload: %{}})

    Store.put_agent(%{id: "agent_3"})

    # max_agents=2 should evict agent_1 (and its events/snapshots)
    assert Store.get_agent("agent_1") == nil
    assert Store.list_events(agent_id: "agent_1", since_ts: 0, since_id: 0, limit: 10) == []
    assert Store.latest_snapshot("agent_1") == nil
  end

  test "list_snapshots returns snapshots ordered by timestamp" do
    Store.put_agent(%{id: "agent_snap"})

    Store.add_snapshot(%{
      agent_id: "agent_snap",
      ts: 2000,
      iteration: 2,
      context_window_size_chars: 1,
      preview: "c",
      transcript: "c",
      compacted?: false
    })

    Store.add_snapshot(%{
      agent_id: "agent_snap",
      ts: 1000,
      iteration: 1,
      context_window_size_chars: 1,
      preview: "b",
      transcript: "b",
      compacted?: false
    })

    snapshots = Store.list_snapshots(agent_id: "agent_snap", limit: 10)
    assert Enum.map(snapshots, & &1.iteration) == [1, 2]
  end
end
