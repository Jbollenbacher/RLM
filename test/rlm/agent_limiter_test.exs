defmodule RLM.AgentLimiterTest do
  use ExUnit.Case

  setup do
    existing_pid = Process.whereis(RLM.AgentLimiter)

    if existing_pid do
      GenServer.stop(existing_pid, :normal)
    end

    ensure_limiter_running(existing_pid)
    :ok
  end

  test "enforces max_concurrent_agents limit" do
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

  defp ensure_limiter_running(previous_pid, attempts \\ 50)

  defp ensure_limiter_running(_previous_pid, 0) do
    case RLM.AgentLimiter.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp ensure_limiter_running(previous_pid, attempts) do
    case Process.whereis(RLM.AgentLimiter) do
      nil ->
        Process.sleep(10)
        ensure_limiter_running(previous_pid, attempts - 1)

      pid when pid == previous_pid ->
        Process.sleep(10)
        ensure_limiter_running(previous_pid, attempts - 1)

      _pid ->
        :ok
    end
  end
end
