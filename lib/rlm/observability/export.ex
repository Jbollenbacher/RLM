defmodule RLM.Observability.Export do
  @moduledoc "Builds an exportable, nested agent log document for offline inspection."

  alias RLM.Observability.LogView
  alias RLM.Observability.Store

  @event_limit 10_000
  @snapshot_limit 10_000

  @spec full_agent_logs(keyword()) :: map()
  def full_agent_logs(opts \\ []) do
    include_system = Keyword.get(opts, :include_system, true)
    log_view = opts |> Keyword.get(:debug, false) |> LogView.normalize()
    agents = Store.list_agents()

    events_by_agent =
      Map.new(agents, fn agent ->
        events =
          Store.list_events(agent_id: agent.id, since_ts: 0, since_id: 0, limit: @event_limit)
          |> LogView.filter_events(log_view)

        {agent.id, events}
      end)

    snapshots_by_agent =
      Map.new(agents, fn agent ->
        snapshots = Store.list_snapshots(agent_id: agent.id, limit: @snapshot_limit)
        {agent.id, snapshots}
      end)

    agents_by_id = Map.new(agents, &{&1.id, &1})

    children_by_parent =
      agents
      |> Enum.group_by(&Map.get(&1, :parent_id))
      |> Map.new(fn {parent_id, grouped} ->
        sorted = Enum.sort_by(grouped, &{Map.get(&1, :created_at, 0), &1.id})
        {parent_id, sorted}
      end)

    roots =
      agents
      |> Enum.filter(fn agent ->
        parent_id = Map.get(agent, :parent_id)
        is_nil(parent_id) or not Map.has_key?(agents_by_id, parent_id)
      end)
      |> Enum.sort_by(&{Map.get(&1, :created_at, 0), &1.id})

    tree =
      Enum.map(roots, fn root ->
        build_agent_node(
          root,
          children_by_parent,
          events_by_agent,
          snapshots_by_agent,
          include_system,
          MapSet.new()
        )
      end)

    total_events =
      events_by_agent
      |> Map.values()
      |> Enum.reduce(0, fn events, acc -> acc + length(events) end)

    total_context_windows =
      snapshots_by_agent
      |> Map.values()
      |> Enum.reduce(0, fn snapshots, acc -> acc + length(snapshots) end)

    %{
      format: "rlm_agent_log_v1",
      exported_at: System.system_time(:millisecond),
      include_system_prompt: include_system,
      log_view: Atom.to_string(log_view),
      context_windows_encoding: "delta",
      summary: %{
        agent_count: length(agents),
        event_count: total_events,
        context_window_count: total_context_windows,
        root_agent_count: length(roots)
      },
      root_agent_ids: Enum.map(roots, & &1.id),
      agent_tree: tree
    }
  end

  defp build_agent_node(
         agent,
         children_by_parent,
         events_by_agent,
         snapshots_by_agent,
         include_system,
         visited
       ) do
    if MapSet.member?(visited, agent.id) do
      %{
        agent: export_agent(agent),
        cycle_detected: true
      }
    else
      visited = MapSet.put(visited, agent.id)
      child_agents = Map.get(children_by_parent, agent.id, [])

      child_nodes =
        Enum.map(child_agents, fn child ->
          build_agent_node(
            child,
            children_by_parent,
            events_by_agent,
            snapshots_by_agent,
            include_system,
            visited
          )
        end)

      child_nodes_by_id =
        Map.new(child_nodes, fn child_node -> {get_in(child_node, [:agent, :id]), child_node} end)

      snapshots = Map.get(snapshots_by_agent, agent.id, [])
      events = Map.get(events_by_agent, agent.id, [])

      {timeline, embedded_child_ids} =
        Enum.map_reduce(events, MapSet.new(), fn event, embedded ->
          child_id = get_child_agent_id(event)

          if (event.type == :lm_query and child_id) && Map.has_key?(child_nodes_by_id, child_id) do
            entry = %{
              kind: "dispatch",
              event: export_event(event),
              child_agent: Map.fetch!(child_nodes_by_id, child_id)
            }

            {entry, MapSet.put(embedded, child_id)}
          else
            {%{kind: "event", event: export_event(event)}, embedded}
          end
        end)

      orphan_children =
        child_nodes
        |> Enum.reject(fn child ->
          MapSet.member?(embedded_child_ids, get_in(child, [:agent, :id]))
        end)
        |> Enum.map(fn child ->
          %{
            kind: "child",
            reason: "child_agent_not_observed_in_parent_lm_query_events",
            child_agent: child
          }
        end)

      context_windows = export_context_windows(snapshots, include_system)

      %{
        agent: export_agent(agent),
        timeline: timeline ++ orphan_children,
        context_windows: context_windows,
        child_agent_ids: Enum.map(child_agents, & &1.id)
      }
    end
  end

  defp get_child_agent_id(event) do
    payload = Map.get(event, :payload, %{})
    Map.get(payload, :child_agent_id) || Map.get(payload, "child_agent_id")
  end

  defp export_agent(agent) do
    %{
      id: agent.id,
      parent_id: Map.get(agent, :parent_id),
      status: stringify_value(Map.get(agent, :status)),
      depth: Map.get(agent, :depth),
      model: Map.get(agent, :model),
      created_at: Map.get(agent, :created_at),
      updated_at: Map.get(agent, :updated_at)
    }
  end

  defp export_event(event) do
    %{
      id: event.id,
      ts: event.ts,
      type: stringify_value(event.type),
      payload: stringify_keys(Map.get(event, :payload, %{}))
    }
  end

  defp export_context_windows(snapshots, include_system) do
    {windows, _state} =
      Enum.map_reduce(snapshots, nil, fn snapshot, previous ->
        transcript = snapshot_transcript(snapshot, include_system)
        {delta_kind, transcript_delta} = transcript_delta(previous, transcript)

        window = %{
          id: snapshot.id,
          ts: Map.get(snapshot, :ts),
          iteration: Map.get(snapshot, :iteration),
          context_window_size_chars: Map.get(snapshot, :context_window_size_chars),
          truncated_bytes: Map.get(snapshot, :truncated_bytes, 0),
          compacted: Map.get(snapshot, :compacted?, false),
          delta_kind: delta_kind,
          transcript_delta: transcript_delta,
          from_snapshot_id: if(previous, do: previous.id, else: nil)
        }

        {window, %{id: snapshot.id, transcript: transcript}}
      end)

    windows
  end

  defp snapshot_transcript(snapshot, include_system) do
    if include_system do
      Map.get(snapshot, :transcript, "")
    else
      Map.get(snapshot, :transcript_without_system) || Map.get(snapshot, :transcript, "")
    end
  end

  defp transcript_delta(nil, transcript), do: {"full", transcript}

  defp transcript_delta(previous, transcript) do
    if String.starts_with?(transcript, previous.transcript) do
      {"append", String.replace_prefix(transcript, previous.transcript, "")}
    else
      {"reset", transcript}
    end
  end

  defp stringify_keys(value) when is_map(value) do
    Enum.into(value, %{}, fn {k, v} ->
      {to_string(k), stringify_keys(v)}
    end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: stringify_value(value)

  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value), do: value
end
