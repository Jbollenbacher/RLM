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

    raise_on_invalid_flags!(invalid)
    Mix.Task.run("app.start")

    tasks_path = Keyword.get(opts, :tasks, Paths.default_pool_path())

    base_variant_path =
      Keyword.get(
        opts,
        :base_variant,
        Path.join([Paths.bench_root(), "variants", "champion_v1.md"])
      )

    quiet_runs =
      cond do
        Keyword.get(opts, :loud_runs, false) -> false
        Keyword.has_key?(opts, :quiet_runs) -> Keyword.get(opts, :quiet_runs)
        true -> true
      end

    inspect_logs =
      cond do
        Keyword.get(opts, :no_inspect_logs, false) -> false
        Keyword.has_key?(opts, :inspect_logs) -> Keyword.get(opts, :inspect_logs)
        true -> true
      end

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
end
