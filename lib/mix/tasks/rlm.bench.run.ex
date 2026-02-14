defmodule Mix.Tasks.Rlm.Bench.Run do
  use Mix.Task

  alias RLM.Bench.Paths
  alias RLM.Bench.Runner

  @shortdoc "Run benchmark task batch and compute assessment metrics"

  @impl true
  def run(args) do
    {opts, _positional, invalid} =
      OptionParser.parse(args,
        strict: [
          tasks: :string,
          variant: :string,
          limit: :integer,
          seed: :integer,
          quiet: :boolean,
          loud: :boolean,
          stream_logs: :boolean,
          export_debug: :boolean,
          export_normal: :boolean,
          sample_rate: :float,
          failure_tail_lines: :integer,
          progress_every: :integer,
          run_id: :string,
          log_dir: :string
        ]
      )

    RLM.Bench.CLI.raise_on_invalid_flags!(invalid)
    Mix.Task.run("app.start")

    tasks_path = Keyword.get(opts, :tasks, Paths.default_pool_path())
    quiet = RLM.Bench.CLI.resolve_bool_flag(opts, :quiet, :loud)

    run_opts = [
      tasks_path: tasks_path,
      variant_path: Keyword.get(opts, :variant),
      limit: Keyword.get(opts, :limit),
      seed: Keyword.get(opts, :seed),
      quiet: quiet,
      stream_logs: Keyword.get(opts, :stream_logs, false),
      export_debug: RLM.Bench.CLI.resolve_bool_flag(opts, :export_debug, :export_normal),
      sample_rate: Keyword.get(opts, :sample_rate, 1.0),
      failure_tail_lines: Keyword.get(opts, :failure_tail_lines, 80),
      progress_every: Keyword.get(opts, :progress_every, 5),
      run_id: Keyword.get(opts, :run_id),
      log_dir: Keyword.get(opts, :log_dir)
    ]

    {:ok, result} = Runner.run(run_opts)

    Mix.shell().info(
      "Run complete: run_id=#{result.run_id} summary=#{result.summary_path} objective=#{Float.round(result.summary.objective, 4)}"
    )
  end

end
