defmodule RLM.Observability.Store do
  @moduledoc "In-memory ETS-backed store for agents, events, and context snapshots."

  use GenServer

  @table_agents :rlm_obs_agents
  @table_events :rlm_obs_events
  @table_snapshots :rlm_obs_snapshots

  @default_limits %{
    max_events_per_agent: 2_000,
    max_context_snapshots_per_agent: 500,
    max_agents: 1_000
  }

  defstruct [
    :limits,
    :agent_order,
    :agent_ids,
    :events_by_agent,
    :snapshots_by_agent,
    :latest_snapshots
  ]

  @type limits :: %{
          max_events_per_agent: pos_integer(),
          max_context_snapshots_per_agent: pos_integer(),
          max_agents: pos_integer()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec put_agent(map()) :: :ok
  def put_agent(agent), do: GenServer.call(__MODULE__, {:put_agent, agent})

  @spec update_agent(String.t(), map()) :: :ok
  def update_agent(agent_id, updates),
    do: GenServer.call(__MODULE__, {:update_agent, agent_id, updates})

  @spec get_agent(String.t()) :: map() | nil
  def get_agent(agent_id), do: GenServer.call(__MODULE__, {:get_agent, agent_id})

  @spec list_agents() :: [map()]
  def list_agents, do: GenServer.call(__MODULE__, :list_agents)

  @spec add_event(map()) :: :ok
  def add_event(event), do: GenServer.call(__MODULE__, {:add_event, event})

  @spec list_events(keyword()) :: [map()]
  def list_events(opts \\ []), do: GenServer.call(__MODULE__, {:list_events, opts})

  @spec add_snapshot(map()) :: :ok
  def add_snapshot(snapshot), do: GenServer.call(__MODULE__, {:add_snapshot, snapshot})

  @spec latest_snapshot(String.t()) :: map() | nil
  def latest_snapshot(agent_id), do: GenServer.call(__MODULE__, {:latest_snapshot, agent_id})

  @impl true
  def init(opts) do
    :ets.new(@table_agents, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@table_events, [:named_table, :ordered_set, :public, read_concurrency: true])
    :ets.new(@table_snapshots, [:named_table, :ordered_set, :public, read_concurrency: true])

    limits =
      @default_limits
      |> Map.merge(Enum.into(opts, %{}))

    state = %__MODULE__{
      limits: limits,
      agent_order: :queue.new(),
      agent_ids: MapSet.new(),
      events_by_agent: %{},
      snapshots_by_agent: %{},
      latest_snapshots: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:put_agent, agent}, _from, state) do
    agent_id = Map.fetch!(agent, :id)
    now = System.system_time(:millisecond)
    agent = agent |> Map.put_new(:created_at, now) |> Map.put(:updated_at, now)

    :ets.insert(@table_agents, {agent_id, agent})

    {agent_order, agent_ids, events_by_agent, snapshots_by_agent, latest_snapshots} =
      enforce_agent_limit(state, agent_id)

    {:reply, :ok,
     %{
       state
       | agent_order: agent_order,
         agent_ids: agent_ids,
         events_by_agent: events_by_agent,
         snapshots_by_agent: snapshots_by_agent,
         latest_snapshots: latest_snapshots
     }}
  end

  def handle_call({:update_agent, agent_id, updates}, _from, state) do
    agent =
      case :ets.lookup(@table_agents, agent_id) do
        [{^agent_id, agent}] -> agent
        [] -> %{id: agent_id, created_at: System.system_time(:millisecond)}
      end

    updated =
      agent
      |> Map.merge(updates)
      |> Map.put(:updated_at, System.system_time(:millisecond))

    :ets.insert(@table_agents, {agent_id, updated})
    {:reply, :ok, state}
  end

  def handle_call({:get_agent, agent_id}, _from, state) do
    agent =
      case :ets.lookup(@table_agents, agent_id) do
        [{^agent_id, agent}] -> agent
        [] -> nil
      end

    {:reply, agent, state}
  end

  def handle_call(:list_agents, _from, state) do
    agents =
      @table_agents
      |> :ets.tab2list()
      |> Enum.map(fn {_id, agent} -> agent end)
      |> Enum.sort_by(& &1.created_at)

    {:reply, agents, state}
  end

  def handle_call({:add_event, event}, _from, state) do
    event_id = System.unique_integer([:positive, :monotonic])
    ts = Map.get(event, :ts) || System.system_time(:millisecond)
    event = Map.put(event, :id, event_id) |> Map.put(:ts, ts)
    key = {ts, event_id}
    :ets.insert(@table_events, {key, event})

    {events_by_agent, _removed} = enforce_event_limit(state, event.agent_id, key)

    {:reply, :ok, %{state | events_by_agent: events_by_agent}}
  end

  def handle_call({:list_events, opts}, _from, state) do
    since_ts = Keyword.get(opts, :since_ts, 0)
    since_id = Keyword.get(opts, :since_id, 0)
    agent_id = Keyword.get(opts, :agent_id)
    limit = Keyword.get(opts, :limit, 500)

    events =
      if agent_id do
        list_events_for_agent(state, agent_id, since_ts, since_id, limit)
      else
        list_events_global(since_ts, since_id, limit)
      end

    {:reply, events, state}
  end

  def handle_call({:add_snapshot, snapshot}, _from, state) do
    snapshot_id = System.unique_integer([:positive, :monotonic])
    snapshot = Map.put(snapshot, :id, snapshot_id)
    :ets.insert(@table_snapshots, {snapshot_id, snapshot})

    {snapshots_by_agent, _removed} =
      enforce_snapshot_limit(state, snapshot.agent_id, snapshot_id)

    latest_snapshots = Map.put(state.latest_snapshots, snapshot.agent_id, snapshot_id)
    {:reply, :ok, %{state | snapshots_by_agent: snapshots_by_agent, latest_snapshots: latest_snapshots}}
  end

  def handle_call({:latest_snapshot, agent_id}, _from, state) do
    snapshot =
      case Map.get(state.latest_snapshots, agent_id) do
        nil ->
          nil

        snapshot_id ->
          case :ets.lookup(@table_snapshots, snapshot_id) do
            [{^snapshot_id, snap}] -> snap
            [] -> nil
          end
      end

    {:reply, snapshot, state}
  end

  defp enforce_agent_limit(state, agent_id) do
    {agent_order, agent_ids, events_by_agent, snapshots_by_agent, latest_snapshots} =
      if MapSet.member?(state.agent_ids, agent_id) do
        {state.agent_order, state.agent_ids, state.events_by_agent, state.snapshots_by_agent, state.latest_snapshots}
      else
        {
          :queue.in(agent_id, state.agent_order),
          MapSet.put(state.agent_ids, agent_id),
          state.events_by_agent,
          state.snapshots_by_agent,
          state.latest_snapshots
        }
      end

    if :queue.len(agent_order) > state.limits.max_agents do
      {{:value, evict_id}, agent_order} = :queue.out(agent_order)
      agent_ids = MapSet.delete(agent_ids, evict_id)
      :ets.delete(@table_agents, evict_id)
      events_by_agent = delete_events_for_agent(events_by_agent, evict_id)
      snapshots_by_agent = delete_snapshots_for_agent(snapshots_by_agent, evict_id)
      latest_snapshots = Map.delete(latest_snapshots, evict_id)
      {agent_order, agent_ids, events_by_agent, snapshots_by_agent, latest_snapshots}
    else
      {agent_order, agent_ids, events_by_agent, snapshots_by_agent, latest_snapshots}
    end
  end

  defp enforce_event_limit(state, agent_id, event_key) do
    queue = Map.get(state.events_by_agent, agent_id, :queue.new())
    queue = :queue.in(event_key, queue)

    {queue, removed} =
      if :queue.len(queue) > state.limits.max_events_per_agent do
        {{:value, remove_key}, queue} = :queue.out(queue)
        :ets.delete(@table_events, remove_key)
        {queue, remove_key}
      else
        {queue, nil}
      end

    {Map.put(state.events_by_agent, agent_id, queue), removed}
  end

  defp enforce_snapshot_limit(state, agent_id, snapshot_id) do
    queue = Map.get(state.snapshots_by_agent, agent_id, :queue.new())
    queue = :queue.in(snapshot_id, queue)

    {queue, removed} =
      if :queue.len(queue) > state.limits.max_context_snapshots_per_agent do
        {{:value, remove_id}, queue} = :queue.out(queue)
        :ets.delete(@table_snapshots, remove_id)
        {queue, remove_id}
      else
        {queue, nil}
      end

    {Map.put(state.snapshots_by_agent, agent_id, queue), removed}
  end

  defp delete_events_for_agent(events_by_agent, agent_id) do
    case Map.get(events_by_agent, agent_id) do
      nil ->
        events_by_agent

      queue ->
        queue
        |> :queue.to_list()
        |> Enum.each(& :ets.delete(@table_events, &1))

        Map.delete(events_by_agent, agent_id)
    end
  end

  defp delete_snapshots_for_agent(snapshots_by_agent, agent_id) do
    case Map.get(snapshots_by_agent, agent_id) do
      nil ->
        snapshots_by_agent

      queue ->
        queue
        |> :queue.to_list()
        |> Enum.each(& :ets.delete(@table_snapshots, &1))

        Map.delete(snapshots_by_agent, agent_id)
    end
  end

  defp list_events_for_agent(state, agent_id, since_ts, since_id, limit) do
    queue = Map.get(state.events_by_agent, agent_id, :queue.new())

    queue
    |> :queue.to_list()
    |> Enum.map(&lookup_event/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&event_after_cursor?(&1, since_ts, since_id))
    |> Enum.sort_by(fn event -> {event.ts, event.id} end)
    |> Enum.take(limit)
  end

  defp list_events_global(since_ts, since_id, limit) do
    start_key = {since_ts, since_id}

    Stream.unfold(:ets.next(@table_events, start_key), fn
      :"$end_of_table" ->
        nil

      key ->
        case :ets.lookup(@table_events, key) do
          [{^key, event}] ->
            next_key = :ets.next(@table_events, key)
            {event, next_key}

          [] ->
            {nil, :ets.next(@table_events, key)}
        end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(limit)
  end

  defp lookup_event(key) do
    case :ets.lookup(@table_events, key) do
      [{^key, event}] -> event
      [] -> nil
    end
  end

  defp event_after_cursor?(event, since_ts, since_id) do
    event.ts > since_ts or (event.ts == since_ts and event.id > since_id)
  end
end
