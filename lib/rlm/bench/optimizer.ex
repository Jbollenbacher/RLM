defmodule RLM.Bench.Optimizer do
  @moduledoc false

  alias RLM.Bench.AB
  alias RLM.Bench.Inspector
  alias RLM.Bench.Paths
  alias RLM.Bench.Profile
  alias RLM.Bench.Runner
  alias RLM.Bench.Util

  def run(opts \\ []) do
    tasks_path = Keyword.fetch!(opts, :tasks_path)
    base_variant_path = Keyword.fetch!(opts, :base_variant_path)
    cycles = Keyword.get(opts, :cycles, 6)

    profile_path = Keyword.get(opts, :profile_path, Paths.default_profile_path())

    with {:ok, profile} <- Profile.load(profile_path) do
      session_id = Util.timestamp_id("opt")

      session_dir = Paths.ensure_dir!(Path.join(Paths.optimize_dir(), session_id))
      variants_dir = Paths.ensure_dir!(Path.join(session_dir, "variants"))
      cycles_dir = Paths.ensure_dir!(Path.join(session_dir, "cycles"))

      champion_path = Path.join(variants_dir, "champion.md")
      File.cp!(base_variant_path, champion_path)

      batch_size = Profile.get(profile, ["run_defaults", "batch_size"], 12)

      quiet_runs =
        Keyword.get(opts, :quiet_runs, Profile.get(profile, ["run_defaults", "quiet"], true))

      stream_logs = Keyword.get(opts, :stream_logs, false)
      sample_rate = Profile.get(profile, ["run_defaults", "sample_rate"], 1.0)
      failure_tail_lines = Profile.get(profile, ["run_defaults", "failure_tail_lines"], 80)
      max_log_inspections = Profile.get(profile, ["run_defaults", "max_log_inspections"], 3)
      inspection_tail_lines = Profile.get(profile, ["run_defaults", "inspection_tail_lines"], 120)
      inspect_logs? = Keyword.get(opts, :inspect_logs, true)
      thresholds = Profile.get(profile, ["ab_thresholds"], %{})

      state = %{
        champion_path: champion_path,
        promoted_cycles: 0,
        last_report: nil,
        cycle_reports: []
      }

      final_state =
        Enum.reduce(1..cycles, state, fn cycle, acc ->
          run_cycle(
            session_id,
            cycle,
            acc,
            tasks_path,
            batch_size,
            quiet_runs,
            stream_logs,
            sample_rate,
            failure_tail_lines,
            max_log_inspections,
            inspection_tail_lines,
            inspect_logs?,
            thresholds,
            variants_dir,
            cycles_dir
          )
        end)

      summary = %{
        session_id: session_id,
        tasks_path: tasks_path,
        base_variant_path: base_variant_path,
        final_champion_path: final_state.champion_path,
        promoted_cycles: final_state.promoted_cycles,
        total_cycles: cycles,
        cycle_reports: Enum.reverse(final_state.cycle_reports),
        generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      }

      summary_path = Path.join(session_dir, "summary.json")
      File.write!(summary_path, Jason.encode!(summary, pretty: true))

      {:ok,
       %{
         session_id: session_id,
         session_dir: session_dir,
         summary_path: summary_path,
         summary: summary
       }}
    end
  end

  defp run_cycle(
         session_id,
         cycle,
         state,
         tasks_path,
         batch_size,
         quiet_runs,
         stream_logs,
         sample_rate,
         failure_tail_lines,
         max_log_inspections,
         inspection_tail_lines,
         inspect_logs?,
         thresholds,
         variants_dir,
         cycles_dir
       ) do
    IO.puts("[bench.optimize] cycle=#{cycle} running champion")

    {:ok, run_a} =
      Runner.run(
        tasks_path: tasks_path,
        variant_path: state.champion_path,
        limit: batch_size,
        quiet: quiet_runs,
        stream_logs: stream_logs,
        sample_rate: sample_rate,
        failure_tail_lines: failure_tail_lines,
        export_debug: true,
        run_id: run_id_for_cycle(session_id, cycle, :a)
      )

    inspection =
      if inspect_logs? do
        Inspector.inspect_run(run_a,
          limit: max_log_inspections,
          tail_lines: inspection_tail_lines
        )
      else
        %{
          enabled: false,
          investigated_tasks: [],
          signal_counts: %{},
          recommendations: [],
          path: nil
        }
      end

    champion_body = File.read!(state.champion_path)
    candidate_body = mutate_prompt(champion_body, run_a.summary, cycle, inspection)
    candidate_path = Path.join(variants_dir, "cycle_#{cycle}_candidate.md")
    File.write!(candidate_path, candidate_body)

    IO.puts("[bench.optimize] cycle=#{cycle} running candidate")

    {:ok, run_b} =
      Runner.run(
        tasks_path: tasks_path,
        variant_path: candidate_path,
        limit: batch_size,
        quiet: quiet_runs,
        stream_logs: stream_logs,
        sample_rate: sample_rate,
        failure_tail_lines: failure_tail_lines,
        export_debug: true,
        run_id: run_id_for_cycle(session_id, cycle, :b)
      )

    report =
      AB.decide(Util.stringify_keys(run_a.summary), Util.stringify_keys(run_b.summary), thresholds)

    promote? = report.decision == "promote"

    if promote? do
      File.cp!(candidate_path, state.champion_path)
    end

    cycle_record = %{
      cycle: cycle,
      run_a_summary_path: run_a.summary_path,
      run_b_summary_path: run_b.summary_path,
      candidate_path: candidate_path,
      decision: report.decision,
      objective_delta: report.deltas.objective,
      coverage_delta: report.deltas.delegation_coverage,
      satisfied_delta: report.deltas.overall_satisfied_rate,
      inspection_path: inspection.path,
      inspected_tasks: Enum.map(inspection.investigated_tasks, & &1.task_id)
    }

    cycle_report_path = Path.join(cycles_dir, "cycle_#{cycle}.json")

    File.write!(
      cycle_report_path,
      Jason.encode!(%{record: cycle_record, ab_report: report, inspection: inspection},
        pretty: true
      )
    )

    IO.puts(
      "[bench.optimize] cycle=#{cycle} decision=#{report.decision} objective_delta=#{Float.round(report.deltas.objective, 4)}"
    )

    %{
      state
      | promoted_cycles: if(promote?, do: state.promoted_cycles + 1, else: state.promoted_cycles),
        last_report: report,
        cycle_reports: [cycle_record | state.cycle_reports]
    }
  end

  @doc false
  def run_id_for_cycle(session_id, cycle, variant)
      when is_binary(session_id) and is_integer(cycle) and cycle > 0 do
    "#{session_id}_cycle#{cycle}_#{normalize_variant(variant)}"
  end

  defp mutate_prompt(prompt, run_summary, cycle, inspection) do
    counts = get_in(run_summary, [:reasons, :counts]) || %{}
    top_bucket = top_bucket(counts)
    primary_nudge = nudge_for_bucket(top_bucket)
    inspection_nudges = Map.get(inspection, :recommendations, [])
    completion_rate = Util.get_number(run_summary, :task_completion_rate, 1.0)
    failed_count = trunc(Util.get_number(run_summary, :failed_count, 0.0))
    completion_nudge = completion_nudge(completion_rate, failed_count)

    patch =
      [
        "",
        "---",
        "",
        "## Benchmark Optimization Patch (Cycle #{cycle})",
        "",
        "Observed issue bucket: #{top_bucket}",
        "",
        primary_nudge,
        "",
        "Completion signal:",
        format_completion_nudge(completion_nudge),
        "",
        "Execution hygiene:",
        "- When running benchmarks with `--stream-logs`, redirect output to a temp logfile and inspect with bounded `tail` windows.",
        "- Avoid flooding interactive context with full raw stream output; summarize only relevant failure snippets and reasons.",
        "",
        "Investigation-informed refinements:",
        format_inspection_nudges(inspection_nudges),
        ""
      ]
      |> Enum.join("\n")

    prompt <> patch
  end

  defp top_bucket(counts) when is_map(counts) do
    case Enum.max_by(counts, fn {_k, v} -> v end, fn -> {:other, 0} end) do
      {bucket, _count} -> bucket
      _ -> :other
    end
  end

  defp nudge_for_bucket(bucket) when bucket in ["unclear_dispatch", :unclear_dispatch] do
    "Before each `lm_query`, include objective, expected output shape, and success/failure criteria."
  end

  defp nudge_for_bucket(bucket) when bucket in ["insufficient_context", :insufficient_context] do
    "When delegating, include enough surrounding evidence and constraints so the child can finish without missing context."
  end

  defp nudge_for_bucket(bucket)
       when bucket in ["wrong_or_incomplete_output", :wrong_or_incomplete_output] do
    "Require child responses to include verifiable bullets and reject low-confidence outputs via `assess_lm_query(..., \"dissatisfied\", reason=...)`."
  end

  defp nudge_for_bucket(bucket)
       when bucket in ["format_or_contract_issue", :format_or_contract_issue] do
    "In final commit steps, always set `final_answer` and include required assessment calls in the same code block."
  end

  defp nudge_for_bucket(bucket)
       when bucket in ["timeout_or_runtime_issue", :timeout_or_runtime_issue] do
    "Prefer smaller delegated chunks and incremental synthesis to reduce timeout risk."
  end

  defp nudge_for_bucket(_bucket) do
    "Use delegation intentionally: narrow tasks, explicit output schema, and explicit usefulness assessment reasons."
  end

  defp completion_nudge(completion_rate, failed_count)
       when completion_rate < 0.8 or failed_count >= 2 do
    "Increase completion discipline: use smaller integration steps, check progress every turn, and commit `final_answer` promptly once minimum evidence is sufficient."
  end

  defp completion_nudge(completion_rate, failed_count)
       when completion_rate < 0.95 or failed_count >= 1 do
    "Guard against run-level failure: explicitly track unresolved blockers and ensure each loop moves toward a concrete final commit."
  end

  defp completion_nudge(_completion_rate, _failed_count), do: nil

  defp format_completion_nudge(nil),
    do: "- Completion rate healthy; no extra completion-specific patch."

  defp format_completion_nudge(nudge), do: "- " <> nudge

  defp format_inspection_nudges([]), do: "- No additional investigation recommendations."

  defp format_inspection_nudges(nudges) do
    nudges
    |> Enum.map(&"- #{&1}")
    |> Enum.join("\n")
  end

  defp normalize_variant(:a), do: "a"
  defp normalize_variant(:b), do: "b"
  defp normalize_variant(value), do: value |> to_string() |> String.trim()
end
