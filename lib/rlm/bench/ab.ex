defmodule RLM.Bench.AB do
  @moduledoc false

  alias RLM.Bench.Paths
  alias RLM.Bench.Util

  @default_thresholds %{
    min_assessment_volume: 40,
    max_coverage_drop: 0.02,
    min_objective_delta: 0.03
  }

  def compare(summary_a_path, summary_b_path, opts \\ []) do
    with {:ok, a} <- read_summary(summary_a_path),
         {:ok, b} <- read_summary(summary_b_path) do
      thresholds = Map.merge(@default_thresholds, Map.get(opts, :thresholds, %{}))
      report = build_report(a, b, thresholds)

      ab_id =
        "ab_#{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601() |> String.replace(":", "-")}_#{System.unique_integer([:positive])}"

      out_dir = Paths.ensure_dir!(Path.join(Paths.ab_dir(), ab_id))
      report_path = Path.join(out_dir, "report.json")
      summary_path = Path.join(out_dir, "report.md")

      File.write!(report_path, Jason.encode!(report, pretty: true))
      File.write!(summary_path, report_markdown(report))

      {:ok,
       %{
         ab_id: ab_id,
         out_dir: out_dir,
         report_path: report_path,
         summary_path: summary_path,
         report: report
       }}
    end
  end

  def decide(a_summary, b_summary, thresholds \\ %{}) do
    thresholds = Map.merge(@default_thresholds, thresholds)
    build_report(a_summary, b_summary, thresholds)
  end

  defp read_summary(path) do
    with {:ok, body} <- File.read(path),
         {:ok, summary} <- Jason.decode(body) do
      {:ok, summary}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, "Invalid summary JSON #{path}: #{Exception.message(error)}"}

      {:error, reason} ->
        {:error, "Failed to read summary #{path}: #{inspect(reason)}"}
    end
  end

  defp build_report(a, b, thresholds) do
    objective_a = Util.get_number(a, "objective")
    objective_b = Util.get_number(b, "objective")
    objective_delta = objective_b - objective_a

    coverage_a = Util.get_number(a, "delegation_coverage")
    coverage_b = Util.get_number(b, "delegation_coverage")
    coverage_delta = coverage_b - coverage_a

    assessment_volume_b = trunc(Util.get_number(b, "assessment_volume"))

    decision =
      cond do
        assessment_volume_b < thresholds.min_assessment_volume ->
          "reject"

        coverage_delta < -thresholds.max_coverage_drop ->
          "reject"

        objective_delta >= thresholds.min_objective_delta ->
          "promote"

        true ->
          "keep_a"
      end

    %{
      decision: decision,
      thresholds: thresholds,
      run_a: %{
        run_id: Map.get(a, "run_id"),
        objective: objective_a,
        delegation_coverage: coverage_a,
        assessment_volume: trunc(Util.get_number(a, "assessment_volume")),
        task_completion_rate: Util.get_number(a, "task_completion_rate"),
        failed_count: trunc(Util.get_number(a, "failed_count")),
        overall_satisfied_rate: Util.get_number(a, "overall_satisfied_rate"),
        reasons: Map.get(a, "reasons", %{})
      },
      run_b: %{
        run_id: Map.get(b, "run_id"),
        objective: objective_b,
        delegation_coverage: coverage_b,
        assessment_volume: assessment_volume_b,
        task_completion_rate: Util.get_number(b, "task_completion_rate"),
        failed_count: trunc(Util.get_number(b, "failed_count")),
        overall_satisfied_rate: Util.get_number(b, "overall_satisfied_rate"),
        reasons: Map.get(b, "reasons", %{})
      },
      deltas: %{
        objective: objective_delta,
        delegation_coverage: coverage_delta,
        task_completion_rate: Util.get_number(b, "task_completion_rate") - Util.get_number(a, "task_completion_rate"),
        overall_satisfied_rate:
          Util.get_number(b, "overall_satisfied_rate") - Util.get_number(a, "overall_satisfied_rate")
      },
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  defp report_markdown(report) do
    [
      "# A/B Report",
      "",
      "- Decision: **#{report.decision}**",
      "- Objective delta (B-A): #{Float.round(report.deltas.objective, 4)}",
      "- Coverage delta (B-A): #{Float.round(report.deltas.delegation_coverage, 4)}",
      "- Completion-rate delta (B-A): #{Float.round(report.deltas.task_completion_rate, 4)}",
      "- Satisfied-rate delta (B-A): #{Float.round(report.deltas.overall_satisfied_rate, 4)}",
      "",
      "## Run A",
      "- run_id: #{report.run_a.run_id}",
      "- objective: #{Float.round(report.run_a.objective, 4)}",
      "- delegation_coverage: #{Float.round(report.run_a.delegation_coverage, 4)}",
      "- task_completion_rate: #{Float.round(report.run_a.task_completion_rate, 4)}",
      "- failed_count: #{report.run_a.failed_count}",
      "- assessment_volume: #{report.run_a.assessment_volume}",
      "",
      "## Run B",
      "- run_id: #{report.run_b.run_id}",
      "- objective: #{Float.round(report.run_b.objective, 4)}",
      "- delegation_coverage: #{Float.round(report.run_b.delegation_coverage, 4)}",
      "- task_completion_rate: #{Float.round(report.run_b.task_completion_rate, 4)}",
      "- failed_count: #{report.run_b.failed_count}",
      "- assessment_volume: #{report.run_b.assessment_volume}",
      ""
    ]
    |> Enum.join("\n")
  end

end
