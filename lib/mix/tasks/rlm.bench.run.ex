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

    raise_on_invalid_flags!(invalid)
    Mix.Task.run("app.start")

    tasks_path = Keyword.get(opts, :tasks, Paths.default_pool_path())
    quiet = quiet_value(opts)

    run_opts = [
      tasks_path: tasks_path,
      variant_path: Keyword.get(opts, :variant),
      limit: Keyword.get(opts, :limit),
      seed: Keyword.get(opts, :seed),
      quiet: quiet,
      stream_logs: Keyword.get(opts, :stream_logs, false),
      export_debug: export_debug_value(opts),
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

  defp raise_on_invalid_flags!([]), do: :ok

  defp raise_on_invalid_flags!(invalid) do
    invalid_list =
      invalid
      |> Enum.map(&format_invalid_option/1)
      |> Enum.join(", ")

    Mix.raise("Unknown or invalid options: #{invalid_list}")
  end

  defp format_invalid_option({flag, _value}), do: to_string(flag)
  defp format_invalid_option(flag), do: to_string(flag)

  defp quiet_value(opts) do
    cond do
      Keyword.get(opts, :loud, false) -> false
      Keyword.has_key?(opts, :quiet) -> Keyword.get(opts, :quiet)
      true -> true
    end
  end

  defp export_debug_value(opts) do
    cond do
      Keyword.get(opts, :export_normal, false) -> false
      Keyword.has_key?(opts, :export_debug) -> Keyword.get(opts, :export_debug)
      true -> true
    end
  end
end
