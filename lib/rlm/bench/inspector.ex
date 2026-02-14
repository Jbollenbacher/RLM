defmodule RLM.Bench.Inspector do
  @moduledoc false

  def inspect_run(run, opts \\ []) do
    results = Map.get(run, :results, [])
    run_dir = Map.get(run, :run_dir)
    summary = Map.get(run, :summary, %{})

    limit = Keyword.get(opts, :limit, 3)
    tail_lines = Keyword.get(opts, :tail_lines, 120)

    if investigate?(summary) and is_binary(run_dir) do
      inspected =
        results
        |> Enum.sort_by(&severity_score/1, :desc)
        |> Enum.take(max(limit, 1))
        |> Enum.map(&inspect_task(&1, tail_lines))

      signal_counts =
        inspected
        |> Enum.flat_map(&Map.get(&1, :signals, []))
        |> Enum.frequencies()

      out = %{
        enabled: true,
        run_id: Map.get(summary, :run_id),
        investigated_tasks: inspected,
        signal_counts: signal_counts,
        recommendations: recommendations(signal_counts)
      }

      out_path = Path.join(run_dir, "inspection.json")
      File.write!(out_path, Jason.encode!(stringify(out), pretty: true))

      Map.put(out, :path, out_path)
    else
      %{
        enabled: false,
        investigated_tasks: [],
        signal_counts: %{},
        recommendations: [],
        path: nil
      }
    end
  end

  defp investigate?(summary) do
    failed = Map.get(summary, :failed_count, 0)
    objective = as_float(Map.get(summary, :objective, 0.0))
    satisfied = as_float(Map.get(summary, :overall_satisfied_rate, 0.0))
    coverage = as_float(Map.get(summary, :delegation_coverage, 0.0))

    failed > 0 or objective < 0.45 or satisfied < 0.65 or coverage < 0.55
  end

  defp inspect_task(result, tail_lines) do
    log_path = Map.get(result, :log_path)
    export_path = Map.get(result, :export_path)

    log_body = read_file(log_path)

    %{
      task_id: Map.get(result, :task_id),
      status: Map.get(result, :status),
      log_path: log_path,
      export_path: export_path,
      signals: detect_signals(log_body, export_path, result),
      log_tail: tail_lines(log_body, tail_lines)
    }
  end

  defp severity_score(result) do
    status_score = if Map.get(result, :status) == :error, do: 20, else: 0

    metrics = Map.get(result, :metrics, %{})

    status_score +
      Map.get(metrics, :dispatch_missing, 0) * 5 +
      Map.get(metrics, :subagent_missing, 0) * 5 +
      Map.get(metrics, :dispatch_dissatisfied, 0) * 3 +
      Map.get(metrics, :subagent_dissatisfied, 0) * 3
  end

  defp detect_signals(log_body, export_path, result) do
    metrics = Map.get(result, :metrics, %{})

    signals =
      []
      |> add_signal(Map.get(result, :status) == :error, :task_error)
      |> add_signal(Map.get(metrics, :dispatch_missing, 0) > 0, :dispatch_survey_missing)
      |> add_signal(Map.get(metrics, :subagent_missing, 0) > 0, :subagent_survey_missing)
      |> add_signal(Map.get(metrics, :dispatch_dissatisfied, 0) > 0, :dispatch_dissatisfied)
      |> add_signal(Map.get(metrics, :subagent_dissatisfied, 0) > 0, :subagent_dissatisfied)
      |> add_signal(Regex.match?(~r/no code block found/i, log_body), :no_code_block)
      |> add_signal(Regex.match?(~r/max iterations/i, log_body), :max_iterations)
      |> add_signal(Regex.match?(~r/timed out|timeout/i, log_body), :timeout)
      |> add_signal(Regex.match?(~r/invalid final_answer/i, log_body), :invalid_final_answer)
      |> add_signal(Regex.match?(~r/nameerror|syntaxerror|traceback/i, log_body), :python_error)

    event_types = export_event_types(export_path)

    signals
    |> add_signal(Enum.member?(event_types, "llm"), :llm_calls_observed)
    |> add_signal(Enum.member?(event_types, "eval"), :eval_calls_observed)
    |> Enum.uniq()
  end

  defp export_event_types(path) when is_binary(path) do
    with {:ok, body} <- File.read(path),
         {:ok, export} <- Jason.decode(body) do
      collect_event_types(export)
    else
      _ -> []
    end
  end

  defp export_event_types(_), do: []

  defp collect_event_types(%{"agent_tree" => roots}) when is_list(roots) do
    roots
    |> Enum.flat_map(&collect_node_event_types/1)
    |> Enum.uniq()
  end

  defp collect_event_types(_), do: []

  defp collect_node_event_types(%{"timeline" => timeline}) when is_list(timeline) do
    Enum.flat_map(timeline, fn
      %{"kind" => "event", "event" => %{"type" => type}} ->
        [type]

      %{"kind" => "dispatch", "event" => %{"type" => type}, "child_agent" => child} ->
        [type | collect_node_event_types(child)]

      %{"kind" => "child", "child_agent" => child} ->
        collect_node_event_types(child)

      _ ->
        []
    end)
  end

  defp collect_node_event_types(_), do: []

  defp add_signal(list, true, signal), do: [signal | list]
  defp add_signal(list, false, _signal), do: list

  defp recommendations(signal_counts) do
    signal_counts
    |> Enum.sort_by(fn {_signal, count} -> count end, :desc)
    |> Enum.take(3)
    |> Enum.map(fn {signal, _count} -> recommendation_for(signal) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp recommendation_for(:no_code_block),
    do: "Strengthen reminder to always return exactly one executable python code block."

  defp recommendation_for(:max_iterations),
    do:
      "Bias toward explicit decomposition plans and intermediate checkpoints to avoid stalled loops."

  defp recommendation_for(:timeout),
    do: "Encourage smaller subagent chunk sizes and bounded delegation fan-out."

  defp recommendation_for(:dispatch_survey_missing),
    do: "Reinforce final-commit pattern that always includes required assess_dispatch call."

  defp recommendation_for(:subagent_survey_missing),
    do: "Reinforce recording assess_lm_query for sampled terminal subagents before final_answer."

  defp recommendation_for(:dispatch_dissatisfied),
    do:
      "Improve lm_query prompt schema: objective, scope boundaries, expected output shape, and acceptance criteria."

  defp recommendation_for(:subagent_dissatisfied),
    do: "Require delegated outputs to be evidence-backed and composable before synthesis."

  defp recommendation_for(:python_error),
    do:
      "Encourage defensive coding (existence checks, retries, and schema guards) around intermediate variables."

  defp recommendation_for(_), do: nil

  defp read_file(nil), do: ""

  defp read_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, body} -> body
      {:error, _} -> ""
    end
  end

  defp tail_lines(body, n) when is_binary(body) and is_integer(n) and n > 0 do
    body
    |> String.split("\n")
    |> Enum.take(-n)
    |> Enum.join("\n")
  end

  defp tail_lines(body, _n), do: body

  defp stringify(map) when is_map(map) do
    Enum.into(map, %{}, fn {k, v} -> {to_string(k), stringify(v)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other

  defp as_float(v) when is_float(v), do: v
  defp as_float(v) when is_integer(v), do: v * 1.0

  defp as_float(v) when is_binary(v) do
    case Float.parse(v) do
      {num, _} -> num
      _ -> 0.0
    end
  end

  defp as_float(_), do: 0.0
end
