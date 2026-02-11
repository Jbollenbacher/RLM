defmodule RLM.AgentLimiterTest do
  use ExUnit.Case

  test "enforces max_concurrent_agents limit" do
    unless Process.whereis(RLM.AgentLimiter) do
      start_supervised!(RLM.AgentLimiter)
    end

    config = RLM.Config.load(max_concurrent_agents: 2)
    parent = self()

    hold = fn ->
      send(parent, :slot_acquired)
      Process.sleep(200)
      :ok
    end

    task_1 = Task.async(fn -> RLM.AgentLimiter.with_slot(config.max_concurrent_agents, hold) end)
    task_2 = Task.async(fn -> RLM.AgentLimiter.with_slot(config.max_concurrent_agents, hold) end)

    assert_receive :slot_acquired, 1_000
    assert_receive :slot_acquired, 1_000

    assert {:error, reason} =
             RLM.AgentLimiter.with_slot(config.max_concurrent_agents, fn -> :ok end)

    assert reason =~ "Max concurrent agents (2) reached"
    assert reason =~ "milliseconds"

    assert :ok = Task.await(task_1, 1_000)
    assert :ok = Task.await(task_2, 1_000)
  end

  test "rejects max_concurrent_agents set to 0" do
    assert_raise ArgumentError, ~r/max_concurrent_agents must be nil or an integer >= 1/, fn ->
      RLM.AgentLimiter.with_slot(0, fn -> :ok end)
    end
  end
end
