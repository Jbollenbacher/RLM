defmodule Mix.Tasks.Rlm.Bench.Optimize do
  use Mix.Task

  alias RLM.Bench.Optimizer
  alias RLM.Bench.Paths

  @shortdoc "Autonomous prompt-only optimization loop using assessment objective"

  @impl true
  def run(args) do
    {opts, _positional, invalid} =
      OptionParser.parse(args,
        strict: [
          tasks: :string,
          base_variant: :string,
          profile: :string,
          cycles: :integer,
          quiet_runs: :boolean,
          loud_runs: :boolean,
          stream_logs: :boolean,
          inspect_logs: :boolean,
          no_inspect_logs: :boolean
        ]
      )

    RLM.Bench.CLI.raise_on_invalid_flags!(invalid)
    Mix.Task.run("app.start")

    tasks_path = Keyword.get(opts, :tasks, Paths.default_pool_path())

    base_variant_path =
      Keyword.get(
        opts,
        :base_variant,
        Path.join([Paths.bench_root(), "variants", "champion_v1.md"])
      )

    quiet_runs = RLM.Bench.CLI.resolve_bool_flag(opts, :quiet_runs, :loud_runs)
    inspect_logs = RLM.Bench.CLI.resolve_bool_flag(opts, :inspect_logs, :no_inspect_logs)

    case Optimizer.run(
           tasks_path: tasks_path,
           base_variant_path: base_variant_path,
           profile_path: Keyword.get(opts, :profile, Paths.default_profile_path()),
           cycles: Keyword.get(opts, :cycles, 6),
           quiet_runs: quiet_runs,
           stream_logs: Keyword.get(opts, :stream_logs, false),
           inspect_logs: inspect_logs
         ) do
      {:ok, result} ->
        Mix.shell().info(
          "Optimize complete: session_id=#{result.session_id} summary=#{result.summary_path} promoted_cycles=#{result.summary.promoted_cycles}/#{result.summary.total_cycles}"
        )

      {:error, reason} ->
        Mix.raise(inspect(reason))
    end
  end

end
