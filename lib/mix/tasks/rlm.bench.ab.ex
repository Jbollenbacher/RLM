defmodule Mix.Tasks.Rlm.Bench.Ab do
  use Mix.Task

  alias RLM.Bench.AB
  alias RLM.Bench.Paths

  @shortdoc "Compare two benchmark runs using assessment-driven objective"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        strict: [
          run_a: :string,
          run_b: :string,
          summary_a: :string,
          summary_b: :string,
          min_assessment_volume: :integer,
          max_coverage_drop: :float,
          min_objective_delta: :float
        ]
      )

    summary_a = resolve_summary_path(opts, :summary_a, :run_a)
    summary_b = resolve_summary_path(opts, :summary_b, :run_b)

    thresholds =
      %{}
      |> maybe_put(:min_assessment_volume, Keyword.get(opts, :min_assessment_volume))
      |> maybe_put(:max_coverage_drop, Keyword.get(opts, :max_coverage_drop))
      |> maybe_put(:min_objective_delta, Keyword.get(opts, :min_objective_delta))

    case AB.compare(summary_a, summary_b, thresholds: thresholds) do
      {:ok, out} ->
        Mix.shell().info(
          "AB decision=#{out.report.decision} report=#{out.report_path} summary=#{out.summary_path}"
        )

      {:error, reason} ->
        Mix.raise(reason)
    end
  end

  defp resolve_summary_path(opts, summary_key, run_key) do
    case Keyword.get(opts, summary_key) do
      nil ->
        case Keyword.get(opts, run_key) do
          nil -> Mix.raise("Provide --#{summary_key} or --#{run_key}")
          run_id -> Path.join([Paths.runs_dir(), run_id, "summary.json"])
        end

      path ->
        path
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
