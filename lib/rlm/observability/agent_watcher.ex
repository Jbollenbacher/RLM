defmodule RLM.Observability.AgentWatcher do
  @moduledoc "Monitors agent owner processes and auto-closes stuck running agents on process DOWN."

  use GenServer

  alias RLM.Observability.Store
  alias RLM.Observability.Tracker

  @name __MODULE__

  @type state :: %{
          by_agent: %{optional(String.t()) => pid()},
          by_pid: %{optional(pid()) => %{ref: reference(), agents: MapSet.t(String.t())}}
        }

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: @name)
  end

  @spec watch(String.t(), pid()) :: :ok
  def watch(agent_id, owner_pid) when is_binary(agent_id) and is_pid(owner_pid) do
    case Process.whereis(@name) do
      nil -> :ok
      _pid -> GenServer.cast(@name, {:watch, agent_id, owner_pid})
    end
  end

  @spec unwatch(String.t()) :: :ok
  def unwatch(agent_id) when is_binary(agent_id) do
    case Process.whereis(@name) do
      nil -> :ok
      _pid -> GenServer.cast(@name, {:unwatch, agent_id})
    end
  end

  @impl true
  def init(_opts) do
    {:ok, %{by_agent: %{}, by_pid: %{}}}
  end

  @impl true
  def handle_cast({:watch, agent_id, owner_pid}, state) do
    state = unwatch_agent(state, agent_id, true)

    if Process.alive?(owner_pid) do
      {state, ref} = ensure_pid_monitor(state, owner_pid)
      entry = Map.fetch!(state.by_pid, owner_pid)
      updated = %{entry | agents: MapSet.put(entry.agents, agent_id)}

      state = %{
        state
        | by_agent: Map.put(state.by_agent, agent_id, owner_pid),
          by_pid: Map.put(state.by_pid, owner_pid, %{updated | ref: ref})
      }

      {:noreply, state}
    else
      close_if_running(agent_id, :noproc)
      {:noreply, state}
    end
  end

  def handle_cast({:unwatch, agent_id}, state) do
    {:noreply, unwatch_agent(state, agent_id, true)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, owner_pid, reason}, state) do
    case Map.get(state.by_pid, owner_pid) do
      %{ref: ^ref, agents: agents} ->
        agent_ids = MapSet.to_list(agents)
        state = remove_pid(state, owner_pid, false)

        Enum.each(agent_ids, fn agent_id ->
          close_if_running(agent_id, reason)
        end)

        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  defp close_if_running(agent_id, reason) do
    case Store.get_agent(agent_id) do
      %{status: :running} ->
        Tracker.end_agent(agent_id, :error, %{source: :pid_down, reason: inspect(reason)})

      _ ->
        :ok
    end
  end

  defp ensure_pid_monitor(state, owner_pid) do
    case Map.get(state.by_pid, owner_pid) do
      %{ref: ref} ->
        {state, ref}

      nil ->
        ref = Process.monitor(owner_pid)

        entry = %{
          ref: ref,
          agents: MapSet.new()
        }

        {%{state | by_pid: Map.put(state.by_pid, owner_pid, entry)}, ref}
    end
  end

  defp unwatch_agent(state, agent_id, demonitor?) do
    case Map.get(state.by_agent, agent_id) do
      nil ->
        state

      owner_pid ->
        state = %{state | by_agent: Map.delete(state.by_agent, agent_id)}
        entry = Map.get(state.by_pid, owner_pid)

        if entry do
          agents = MapSet.delete(entry.agents, agent_id)

          if MapSet.size(agents) == 0 do
            if demonitor?, do: Process.demonitor(entry.ref, [:flush])
            %{state | by_pid: Map.delete(state.by_pid, owner_pid)}
          else
            updated = %{entry | agents: agents}
            %{state | by_pid: Map.put(state.by_pid, owner_pid, updated)}
          end
        else
          state
        end
    end
  end

  defp remove_pid(state, owner_pid, demonitor?) do
    case Map.get(state.by_pid, owner_pid) do
      nil ->
        state

      %{ref: ref, agents: agents} ->
        if demonitor?, do: Process.demonitor(ref, [:flush])

        by_agent =
          Enum.reduce(agents, state.by_agent, fn agent_id, acc ->
            Map.delete(acc, agent_id)
          end)

        %{state | by_agent: by_agent, by_pid: Map.delete(state.by_pid, owner_pid)}
    end
  end
end
