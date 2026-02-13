defmodule RLM.ObservabilityExportTest do
  use ExUnit.Case, async: false

  alias RLM.Observability.Export
  alias RLM.Observability.Store

  setup do
    {:ok, _pid} =
      start_supervised(
        {Store, [max_events_per_agent: 50, max_context_snapshots_per_agent: 20, max_agents: 20]}
      )

    :ok
  end

  test "builds nested dispatch timeline with child agent embedded" do
    Store.put_agent(%{id: "parent", status: :running, depth: 0})
    Store.put_agent(%{id: "child", parent_id: "parent", status: :done, depth: 1})

    Store.add_event(%{
      agent_id: "parent",
      type: :lm_query,
      payload: %{child_agent_id: "child", model_size: :small},
      ts: 1000
    })

    Store.add_event(%{
      agent_id: "child",
      type: :agent_end,
      payload: %{status: :done},
      ts: 1010
    })

    Store.add_snapshot(%{
      agent_id: "parent",
      ts: 1005,
      iteration: 0,
      context_window_size_chars: 20,
      transcript: "[PRINCIPAL]\nParent task",
      transcript_without_system: "[PRINCIPAL]\nParent task",
      compacted?: false
    })

    Store.add_snapshot(%{
      agent_id: "parent",
      ts: 1006,
      iteration: 1,
      context_window_size_chars: 32,
      transcript: "[PRINCIPAL]\nParent task\n\n[AGENT]\nWorking...",
      transcript_without_system: "[PRINCIPAL]\nParent task\n\n[AGENT]\nWorking...",
      compacted?: false
    })

    Store.add_snapshot(%{
      agent_id: "child",
      ts: 1015,
      iteration: 0,
      context_window_size_chars: 18,
      transcript: "[AGENT]\nChild done",
      transcript_without_system: "[AGENT]\nChild done",
      compacted?: false
    })

    export = Export.full_agent_logs()

    assert export.format == "rlm_agent_log_v1"
    assert export.root_agent_ids == ["parent"]
    [root] = export.agent_tree
    assert root.agent.id == "parent"
    assert export.context_windows_encoding == "delta"

    [first_window, second_window] = root.context_windows
    assert first_window.delta_kind == "full"
    assert first_window.transcript_delta =~ "Parent task"
    assert second_window.delta_kind == "append"
    assert second_window.transcript_delta =~ "[AGENT]\nWorking..."
    assert second_window.from_snapshot_id == first_window.id

    [dispatch | _] = root.timeline
    assert dispatch.kind == "dispatch"
    assert dispatch.event.type == "lm_query"
    assert dispatch.child_agent.agent.id == "child"
    assert is_list(dispatch.child_agent.context_windows)
  end
end
