defmodule RLM.Bench.Metrics do
  @moduledoc false

  alias RLM.Bench.Reasons

  def from_export(export_path, required_min_dispatches \\ 0) do
    with {:ok, body} <- File.read(export_path),
         {:ok, export} <- Jason.decode(body) do
      events = collect_export_events(export)

      dispatch_satisfied = count_assessment(events, "dispatch_assessment", "satisfied")
      dispatch_dissatisfied = count_assessment(events, "dispatch_assessment", "dissatisfied")
      dispatch_missing = count_events(events, "dispatch_assessment_missing")

      subagent_satisfied = count_assessment(events, "subagent_assessment", "satisfied")
      subagent_dissatisfied = count_assessment(events, "subagent_assessment", "dissatisfied")
      subagent_missing = count_events(events, "subagent_assessment_missing")

      dispatch_count = count_events(events, "lm_query")

      reasons = collect_negative_reasons(events)

      {:ok,
       %{
         dispatch_count: dispatch_count,
         required_min_dispatches: required_min_dispatches,
         delegation_requirement_met: dispatch_count >= required_min_dispatches,
         dispatch_satisfied: dispatch_satisfied,
         dispatch_dissatisfied: dispatch_dissatisfied,
         dispatch_missing: dispatch_missing,
         subagent_satisfied: subagent_satisfied,
         subagent_dissatisfied: subagent_dissatisfied,
         subagent_missing: subagent_missing,
         reasons: reasons
       }}
    end
  end

  def summarize_results(results) when is_list(results) do
    task_count = length(results)
    completed_count = Enum.count(results, &(&1[:status] == :ok))

    dispatch_satisfied = Enum.reduce(results, 0, &(&2 + get_metric(&1, :dispatch_satisfied)))

    dispatch_dissatisfied =
      Enum.reduce(results, 0, &(&2 + get_metric(&1, :dispatch_dissatisfied)))

    dispatch_missing = Enum.reduce(results, 0, &(&2 + get_metric(&1, :dispatch_missing)))

    subagent_satisfied = Enum.reduce(results, 0, &(&2 + get_metric(&1, :subagent_satisfied)))

    subagent_dissatisfied =
      Enum.reduce(results, 0, &(&2 + get_metric(&1, :subagent_dissatisfied)))

    subagent_missing = Enum.reduce(results, 0, &(&2 + get_metric(&1, :subagent_missing)))

    delegation_met_count = Enum.count(results, &get_metric(&1, :delegation_requirement_met))

    dispatch_total = dispatch_satisfied + dispatch_dissatisfied + dispatch_missing
    subagent_total = subagent_satisfied + subagent_dissatisfied + subagent_missing
    assessment_total = dispatch_total + subagent_total
    satisfied_total = dispatch_satisfied + subagent_satisfied

    delegation_coverage = safe_div(delegation_met_count, task_count)
    overall_satisfied_rate = safe_div(satisfied_total, assessment_total)

    reasons = Enum.flat_map(results, &get_metric(&1, :reasons, []))

    %{
      task_count: task_count,
      completed_count: completed_count,
      failed_count: task_count - completed_count,
      dispatch_satisfied: dispatch_satisfied,
      dispatch_dissatisfied: dispatch_dissatisfied,
      dispatch_missing: dispatch_missing,
      subagent_satisfied: subagent_satisfied,
      subagent_dissatisfied: subagent_dissatisfied,
      subagent_missing: subagent_missing,
      dispatch_satisfied_rate: safe_div(dispatch_satisfied, dispatch_total),
      subagent_satisfied_rate: safe_div(subagent_satisfied, subagent_total),
      overall_satisfied_rate: overall_satisfied_rate,
      delegation_coverage: delegation_coverage,
      assessment_volume: assessment_total,
      objective: overall_satisfied_rate * delegation_coverage,
      reasons: Reasons.summarize(reasons)
    }
  end

  defp collect_export_events(%{"agent_tree" => roots}) when is_list(roots) do
    {events, _visited} =
      Enum.reduce(roots, {[], MapSet.new()}, fn root, {acc, visited} ->
        collect_node_events(root, acc, visited)
      end)

    Enum.reverse(events)
  end

  defp collect_export_events(_), do: []

  defp collect_node_events(%{"agent" => %{"id" => id}} = node, acc, visited) do
    if MapSet.member?(visited, id) do
      {acc, visited}
    else
      visited = MapSet.put(visited, id)
      timeline = Map.get(node, "timeline", [])

      Enum.reduce(timeline, {acc, visited}, fn entry, {entry_acc, entry_visited} ->
        collect_timeline_entry(entry, entry_acc, entry_visited)
      end)
    end
  end

  defp collect_node_events(_node, acc, visited), do: {acc, visited}

  defp collect_timeline_entry(%{"kind" => "event", "event" => event}, acc, visited),
    do: {[event | acc], visited}

  defp collect_timeline_entry(
         %{"kind" => "dispatch", "event" => event, "child_agent" => child},
         acc,
         visited
       ) do
    collect_node_events(child, [event | acc], visited)
  end

  defp collect_timeline_entry(%{"kind" => "child", "child_agent" => child}, acc, visited) do
    collect_node_events(child, acc, visited)
  end

  defp collect_timeline_entry(_entry, acc, visited), do: {acc, visited}

  defp count_assessment(events, type, verdict) do
    Enum.count(events, fn event ->
      Map.get(event, "type") == type and get_in(event, ["payload", "verdict"]) == verdict
    end)
  end

  defp count_events(events, type) do
    Enum.count(events, &(Map.get(&1, "type") == type))
  end

  defp collect_negative_reasons(events) do
    events
    |> Enum.flat_map(fn event ->
      type = Map.get(event, "type")
      payload = Map.get(event, "payload", %{})

      cond do
        type in ["dispatch_assessment", "subagent_assessment"] and
            Map.get(payload, "verdict") == "dissatisfied" ->
          [to_string(Map.get(payload, "reason", ""))]

        type in ["dispatch_assessment_missing", "subagent_assessment_missing"] ->
          status = Map.get(payload, "status", "unknown")
          ["assessment missing (status=#{status})"]

        true ->
          []
      end
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp safe_div(_numerator, 0), do: 0.0
  defp safe_div(numerator, denominator), do: numerator / denominator

  defp get_metric(result, key, default \\ 0) do
    case Map.get(result, :metrics) do
      metrics when is_map(metrics) -> Map.get(metrics, key, default)
      _ -> default
    end
  end
end
