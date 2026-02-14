defmodule RLM.Bench.Runner do
  @moduledoc false

  alias RLM.Bench.JSONL
  alias RLM.Bench.Metrics
  alias RLM.Bench.Paths

  def run(opts \\ []) do
    tasks_path = Keyword.fetch!(opts, :tasks_path)
    quiet? = Keyword.get(opts, :quiet, true)
    limit = Keyword.get(opts, :limit)
    seed = Keyword.get(opts, :seed)
    sample_rate = Keyword.get(opts, :sample_rate, 1.0)
    variant_path = Keyword.get(opts, :variant_path)
    export_debug = Keyword.get(opts, :export_debug, true)
    failure_tail_lines = Keyword.get(opts, :failure_tail_lines, 80)
    progress_every = Keyword.get(opts, :progress_every, 5)

    run_id =
      case Keyword.get(opts, :run_id) do
        value when is_binary(value) and value != "" -> value
        _ -> run_id()
      end

    run_dir = Paths.ensure_dir!(Path.join(Paths.runs_dir(), run_id))
    exports_dir = Paths.ensure_dir!(Path.join(run_dir, "exports"))

    log_dir = resolve_log_dir(opts, run_dir)

    tasks =
      tasks_path
      |> JSONL.read()
      |> maybe_shuffle(seed)
      |> maybe_take(limit)

    IO.puts("[bench.run] run_id=#{run_id} tasks=#{length(tasks)} quiet=#{quiet?}")

    {results, _index} =
      Enum.reduce(tasks, {[], 0}, fn task, {acc, index} ->
        result =
          run_one_task(
            task,
            index + 1,
            length(tasks),
            exports_dir,
            log_dir,
            quiet?,
            progress_every,
            failure_tail_lines,
            variant_path,
            sample_rate,
            export_debug
          )

        {[result | acc], index + 1}
      end)

    results = Enum.reverse(results)

    summary =
      results
      |> Metrics.summarize_results()
      |> Map.merge(%{
        run_id: run_id,
        tasks_path: tasks_path,
        variant_path: variant_path,
        quiet: quiet?,
        sample_rate: sample_rate,
        generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      })

    results_path = Path.join(run_dir, "results.jsonl")
    summary_path = Path.join(run_dir, "summary.json")

    JSONL.write!(results_path, Enum.map(results, &stringify_result/1))
    File.write!(summary_path, Jason.encode!(summary, pretty: true))

    IO.puts(
      "[bench.run] complete run_id=#{run_id} objective=#{Float.round(summary.objective, 4)} coverage=#{Float.round(summary.delegation_coverage, 4)} assessment_volume=#{summary.assessment_volume}"
    )

    {:ok,
     %{
       run_id: run_id,
       run_dir: run_dir,
       results_path: results_path,
       summary_path: summary_path,
       summary: summary,
       results: results
     }}
  end

  defp run_one_task(
         task,
         index,
         total,
         exports_dir,
         log_dir,
         quiet?,
         progress_every,
         failure_tail_lines,
         variant_path,
         sample_rate,
         export_debug
       ) do
    task_id = Map.fetch!(task, "task_id")
    query = Map.fetch!(task, "query")
    context_path = Map.fetch!(task, "context_path")
    required_min_dispatches = Map.get(task, "required_min_dispatches", 0)

    export_path = Path.join(exports_dir, "#{task_id}.json")
    log_path = Path.join(log_dir, "#{task_id}.log")
    meta_path = Path.join(log_dir, "#{task_id}.meta.json")

    env =
      []
      |> put_env("RLM_SUBAGENT_ASSESSMENT_SAMPLE_RATE", to_string(sample_rate))
      |> put_env_if("RLM_SYSTEM_PROMPT_PATH", variant_path)

    started_at_ms = System.system_time(:millisecond)
    started_at_native = System.monotonic_time()

    command = mix_rlm_command(context_path, export_path, query, export_debug)

    {output, exit_code} =
      System.cmd(
        "sh",
        ["-lc", command],
        cd: File.cwd!(),
        stderr_to_stdout: true,
        env: env
      )

    duration_ms =
      System.monotonic_time()
      |> Kernel.-(started_at_native)
      |> System.convert_time_unit(:native, :millisecond)

    File.write!(log_path, output)

    {metrics, metric_error} =
      case Metrics.from_export(export_path, required_min_dispatches) do
        {:ok, metrics} -> {metrics, nil}
        {:error, reason} -> {%{delegation_requirement_met: false, reasons: []}, inspect(reason)}
      end

    status = if exit_code == 0 and is_nil(metric_error), do: :ok, else: :error

    meta = %{
      task_id: task_id,
      status: status,
      exit_code: exit_code,
      started_at_ms: started_at_ms,
      duration_ms: duration_ms,
      export_path: export_path,
      log_path: log_path,
      output_bytes: byte_size(output),
      metric_error: metric_error
    }

    File.write!(meta_path, Jason.encode!(meta, pretty: true))

    if quiet? do
      if rem(index, max(progress_every, 1)) == 0 or status == :error or index == total do
        message = "[bench.run] #{index}/#{total} task=#{task_id} status=#{status}"

        if status == :error do
          tail = read_tail_lines(log_path, failure_tail_lines)
          IO.puts(message)

          IO.puts(
            "[bench.run] failure tail (#{failure_tail_lines} lines) for #{task_id}:\n#{tail}"
          )
        else
          IO.puts(message)
        end
      end
    else
      IO.puts("[bench.run] #{index}/#{total} task=#{task_id} status=#{status}")
    end

    %{
      task_id: task_id,
      family: Map.get(task, "family"),
      source_ids: Map.get(task, "source_ids", []),
      status: status,
      exit_code: exit_code,
      duration_ms: duration_ms,
      export_path: export_path,
      log_path: log_path,
      metrics: metrics
    }
  end

  defp stringify_result(result) do
    %{
      task_id: result.task_id,
      family: result.family,
      source_ids: result.source_ids,
      status: Atom.to_string(result.status),
      exit_code: result.exit_code,
      duration_ms: result.duration_ms,
      export_path: result.export_path,
      log_path: result.log_path,
      metrics: result.metrics
    }
  end

  defp maybe_shuffle(tasks, nil), do: tasks

  defp maybe_shuffle(tasks, seed) when is_integer(seed) do
    :rand.seed(:exsplus, {seed, seed + 1, seed + 2})
    Enum.shuffle(tasks)
  end

  defp maybe_take(tasks, nil), do: tasks
  defp maybe_take(tasks, limit) when is_integer(limit) and limit > 0, do: Enum.take(tasks, limit)
  defp maybe_take(tasks, _other), do: tasks

  defp run_id do
    ts =
      DateTime.utc_now()
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()
      |> String.replace(":", "-")

    "run_#{ts}_#{System.unique_integer([:positive])}"
  end

  defp put_env(env, key, value), do: [{key, value} | env]

  defp put_env_if(env, _key, nil), do: env
  defp put_env_if(env, _key, ""), do: env
  defp put_env_if(env, key, value), do: [{key, value} | env]

  defp resolve_log_dir(opts, run_dir) do
    case Keyword.get(opts, :log_dir) do
      value when is_binary(value) and value != "" -> Paths.ensure_dir!(value)
      _ -> Paths.ensure_dir!(Path.join(run_dir, "task_logs"))
    end
  end

  defp mix_rlm_command(context_path, export_path, query, export_debug) do
    debug_flag = if export_debug, do: " --export-logs-debug", else: ""

    "cat #{shell_escape(context_path)} | mix rlm --single-turn --export-logs-path #{shell_escape(export_path)}#{debug_flag} #{shell_escape(query)}"
  end

  defp shell_escape(value) when is_binary(value) do
    escaped = String.replace(value, "'", "'\"'\"'")
    "'#{escaped}'"
  end

  defp read_tail_lines(path, n) when n <= 0, do: File.read!(path)

  defp read_tail_lines(path, n) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.take(-n)
    |> Enum.join("\n")
  rescue
    _ -> "(unable to read tail lines)"
  end
end
