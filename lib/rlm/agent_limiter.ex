defmodule RLM.AgentLimiter do
  @moduledoc "Limits the number of concurrent agents running in the system."

  use GenServer

  @type state :: %{
          count: non_neg_integer(),
          pid_counts: %{optional(pid()) => pos_integer()},
          monitors: %{optional(pid()) => reference()}
        }

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec with_slot(integer() | nil | :infinity, (() -> any())) :: any()
  def with_slot(max, fun) when is_function(fun, 0) do
    if unlimited?(max) do
      fun.()
    else
      validate_max!(max)
      case Process.whereis(__MODULE__) do
        nil ->
          fun.()

        _pid ->
          case acquire(max) do
            :ok ->
              try do
                fun.()
              after
                release()
              end

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  @spec acquire(pos_integer()) :: :ok | {:error, String.t()}
  def acquire(max) when is_integer(max) and max > 0 do
    GenServer.call(__MODULE__, {:acquire, self(), max})
  end

  @spec release() :: :ok
  def release do
    GenServer.cast(__MODULE__, {:release, self()})
  end

  @spec unavailable_message(pos_integer()) :: String.t()
  def unavailable_message(max) do
    "Max concurrent agents (#{max}) reached. Wait and retry `lm_query` when a slot is free. " <>
      "You can call `Process.sleep(5000)` (milliseconds) and try again, or continue working without a subagent."
  end

  @impl true
  def init(_opts) do
    {:ok, %{count: 0, pid_counts: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call({:acquire, pid, max}, _from, state) do
    if state.count < max do
      {pid_counts, monitors} = ensure_monitor(state.pid_counts, state.monitors, pid)
      pid_counts = Map.update(pid_counts, pid, 1, &(&1 + 1))
      {:reply, :ok, %{state | count: state.count + 1, pid_counts: pid_counts, monitors: monitors}}
    else
      {:reply, {:error, unavailable_message(max)}, state}
    end
  end

  @impl true
  def handle_cast({:release, pid}, state) do
    {:noreply, do_release(state, pid)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.get(state.monitors, pid) do
      ^ref ->
        count = Map.get(state.pid_counts, pid, 0)

        new_state = %{
          state
          | count: max(state.count - count, 0),
            pid_counts: Map.delete(state.pid_counts, pid),
            monitors: Map.delete(state.monitors, pid)
        }

        {:noreply, new_state}

      _ ->
        {:noreply, state}
    end
  end

  defp unlimited?(max) when max in [nil, :infinity], do: true
  defp unlimited?(_max), do: false

  defp validate_max!(max) do
    cond do
      is_integer(max) and max >= 1 ->
        :ok

      true ->
        raise ArgumentError,
              "max_concurrent_agents must be nil or an integer >= 1, got: #{inspect(max)}"
    end
  end

  defp ensure_monitor(pid_counts, monitors, pid) do
    case Map.fetch(monitors, pid) do
      {:ok, _ref} -> {pid_counts, monitors}
      :error -> {pid_counts, Map.put(monitors, pid, Process.monitor(pid))}
    end
  end

  defp do_release(state, pid) do
    case Map.get(state.pid_counts, pid) do
      nil ->
        state

      1 ->
        ref = Map.get(state.monitors, pid)
        if ref, do: Process.demonitor(ref, [:flush])

        %{
          state
          | count: max(state.count - 1, 0),
            pid_counts: Map.delete(state.pid_counts, pid),
            monitors: Map.delete(state.monitors, pid)
        }

      n when is_integer(n) and n > 1 ->
        %{
          state
          | count: max(state.count - 1, 0),
            pid_counts: Map.put(state.pid_counts, pid, n - 1)
        }
    end
  end
end
