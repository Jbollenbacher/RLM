defmodule Mix.Tasks.Rlm.Bench.Logs do
  use Mix.Task

  alias RLM.Bench.Logs

  @shortdoc "Show tail of a saved benchmark task logfile"

  @impl true
  def run(args) do
    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        strict: [run_id: :string, task: :string, tail: :integer]
      )

    run_id = Keyword.get(opts, :run_id) || Mix.raise("--run-id is required")
    task_id = Keyword.get(opts, :task) || Mix.raise("--task is required")
    tail = Keyword.get(opts, :tail, 120)

    case Logs.tail(run_id, task_id, tail) do
      {:ok, out} ->
        Mix.shell().info("log_path=#{out.log_path}")
        IO.puts(out.tail)

      {:error, reason} ->
        Mix.raise(reason)
    end
  end
end
