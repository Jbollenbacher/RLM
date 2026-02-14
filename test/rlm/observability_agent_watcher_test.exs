defmodule RLM.ObservabilityAgentWatcherTest do
  use ExUnit.Case, async: false

  import RLM.TestSupport, only: [assert_eventually: 1]

  alias RLM.Observability.AgentWatcher
  alias RLM.Observability.Store
  alias RLM.Observability.Tracker

  setup do
    {:ok, _pid} =
      start_supervised(
        {Store, [max_events_per_agent: 20, max_context_snapshots_per_agent: 10, max_agents: 10]}
      )

    {:ok, _pid} = start_supervised({AgentWatcher, []})
    :ok
  end

  test "marks running agent as error when owner pid goes down" do
    owner = spawn(fn -> Process.sleep(:infinity) end)

    Tracker.start_agent("agent_watch_1", nil, "model", 0)
    AgentWatcher.watch("agent_watch_1", owner)

    Process.exit(owner, :kill)

    assert_eventually(fn ->
      case Store.get_agent("agent_watch_1") do
        %{status: :error} ->
          events =
            Store.list_events(agent_id: "agent_watch_1", since_ts: 0, since_id: 0, limit: 20)

          Enum.any?(events, &(&1.type == :agent_end && Map.get(&1.payload, :source) == :pid_down))

        _ ->
          false
      end
    end)
  end

  test "does not override explicit completion after unwatch" do
    owner = spawn(fn -> Process.sleep(:infinity) end)

    Tracker.start_agent("agent_watch_2", nil, "model", 0)
    AgentWatcher.watch("agent_watch_2", owner)
    Tracker.end_agent("agent_watch_2", :done, %{})
    AgentWatcher.unwatch("agent_watch_2")

    Process.exit(owner, :kill)
    Process.sleep(50)

    assert %{status: :done} = Store.get_agent("agent_watch_2")
  end

end
