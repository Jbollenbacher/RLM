defmodule RLM.Bench.Metrics do
  @moduledoc false

  alias RLM.Bench.Reasons

  @dispatch_survey_id "dispatch_quality"
  @subagent_survey_id "subagent_usefulness"

  def from_export(export_path, required_min_dispatches \\ 0) do
    with {:ok, body} <- File.read(export_path),
         {:ok, export} <- Jason.decode(body) do
      events = collect_export_events(export)

      dispatch = score_survey_family(events, @dispatch_survey_id)
      subagent = score_survey_family(events, @subagent_survey_id)
      survey_events_observed = dispatch.events_observed + subagent.events_observed

      dispatch_count = count_events(events, "lm_query")
      reasons = dispatch.reasons ++ subagent.reasons
      warnings = survey_warnings(survey_events_observed)

      {:ok,
       %{
         dispatch_count: dispatch_count,
         required_min_dispatches: required_min_dispatches,
         delegation_requirement_met: dispatch_count >= required_min_dispatches,
         dispatch_satisfied: dispatch.satisfied,
         dispatch_dissatisfied: dispatch.dissatisfied,
         dispatch_missing: dispatch.missing,
         subagent_satisfied: subagent.satisfied,
         subagent_dissatisfied: subagent.dissatisfied,
         subagent_missing: subagent.missing,
         survey_events_observed: survey_events_observed,
         warnings: warnings,
         reasons: reasons
       }}
    end
  end

  def summarize_results(results) when is_list(results) do
    task_count = length(results)
    completed_count = Enum.count(results, &(&1[:status] == :ok))
    failed_count = task_count - completed_count

    dispatch_satisfied = Enum.reduce(results, 0, &(&2 + get_metric(&1, :dispatch_satisfied)))

    dispatch_dissatisfied =
      Enum.reduce(results, 0, &(&2 + get_metric(&1, :dispatch_dissatisfied)))

    dispatch_missing = Enum.reduce(results, 0, &(&2 + get_metric(&1, :dispatch_missing)))

    subagent_satisfied = Enum.reduce(results, 0, &(&2 + get_metric(&1, :subagent_satisfied)))

    subagent_dissatisfied =
      Enum.reduce(results, 0, &(&2 + get_metric(&1, :subagent_dissatisfied)))

    subagent_missing = Enum.reduce(results, 0, &(&2 + get_metric(&1, :subagent_missing)))

    delegation_met_count = Enum.count(results, &get_metric(&1, :delegation_requirement_met))

    tasks_with_no_survey_events =
      Enum.count(results, &(get_metric(&1, :survey_events_observed) == 0))

    dispatch_total = dispatch_satisfied + dispatch_dissatisfied + dispatch_missing
    subagent_total = subagent_satisfied + subagent_dissatisfied + subagent_missing
    survey_total = dispatch_total + subagent_total
    satisfied_total = dispatch_satisfied + subagent_satisfied

    delegation_coverage = safe_div(delegation_met_count, task_count)
    task_completion_rate = safe_div(completed_count, task_count)
    overall_satisfied_rate = safe_div(satisfied_total, survey_total)

    reasons = Enum.flat_map(results, &get_metric(&1, :reasons, []))
    warnings = results |> Enum.flat_map(&get_metric(&1, :warnings, [])) |> Enum.uniq()

    %{
      task_count: task_count,
      completed_count: completed_count,
      failed_count: failed_count,
      task_completion_rate: task_completion_rate,
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
      assessment_volume: survey_total,
      tasks_with_no_survey_events: tasks_with_no_survey_events,
      warnings: warnings,
      objective: overall_satisfied_rate * delegation_coverage,
      reasons: Reasons.summarize(reasons)
    }
  end

  @doc false
  def collect_export_events(%{"agent_tree" => roots}) when is_list(roots) do
    {events, _visited} =
      Enum.reduce(roots, {[], MapSet.new()}, fn root, {acc, visited} ->
        collect_node_events(root, acc, visited)
      end)

    Enum.reverse(events)
  end

  def collect_export_events(_), do: []

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

  defp count_events(events, type) do
    Enum.count(events, &(Map.get(&1, "type") == type))
  end

  defp score_survey_family(events, survey_id) do
    survey_answered =
      Enum.filter(events, &survey_event?(&1, "survey_answered", survey_id))

    survey_missing =
      Enum.filter(events, &survey_event?(&1, "survey_missing", survey_id))

    %{
      satisfied: Enum.count(survey_answered, &event_verdict?(&1, "response", :satisfied)),
      dissatisfied: Enum.count(survey_answered, &event_verdict?(&1, "response", :dissatisfied)),
      missing: length(survey_missing),
      events_observed: length(survey_answered) + length(survey_missing),
      reasons: survey_reasons(survey_answered, survey_missing)
    }
  end

  defp survey_event?(event, type, survey_id) do
    Map.get(event, "type") == type and get_in(event, ["payload", "survey_id"]) == survey_id
  end

  defp event_verdict?(event, key, verdict) do
    event
    |> get_in(["payload", key])
    |> normalize_token()
    |> Kernel.==(normalize_token(verdict))
  end

  defp survey_reasons(answered, missing) do
    dissatisfied_reasons =
      answered
      |> Enum.filter(&event_verdict?(&1, "response", :dissatisfied))
      |> Enum.map(&(get_in(&1, ["payload", "reason"]) |> to_string()))

    missing_reasons =
      Enum.map(missing, fn event ->
        status = get_in(event, ["payload", "status"]) || "unknown"
        "survey missing (status=#{status})"
      end)

    Enum.reject(dissatisfied_reasons ++ missing_reasons, &(&1 == ""))
  end

  defp normalize_token(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> normalize_token()
  end

  defp normalize_token(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading(":")
    |> String.downcase()
  end

  defp normalize_token(value), do: to_string(value) |> normalize_token()

  defp safe_div(_numerator, 0), do: 0.0
  defp safe_div(numerator, denominator), do: numerator / denominator

  defp survey_warnings(0), do: ["no survey events observed; objective defaults to 0.0"]
  defp survey_warnings(_count), do: []

  defp get_metric(result, key, default \\ 0) do
    case Map.get(result, :metrics) do
      metrics when is_map(metrics) -> Map.get(metrics, key, default)
      _ -> default
    end
  end
end
