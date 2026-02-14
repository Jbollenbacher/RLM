defmodule RLM.Bench.Logs do
  @moduledoc false

  alias RLM.Bench.Paths

  def tail(run_id, task_id, lines \\ 120) do
    log_path = Path.join([Paths.runs_dir(), run_id, "task_logs", "#{task_id}.log"])

    with {:ok, body} <- File.read(log_path) do
      tail = body |> String.split("\n") |> Enum.take(-max(lines, 1)) |> Enum.join("\n")
      {:ok, %{log_path: log_path, tail: tail}}
    else
      {:error, reason} ->
        {:error, "Could not read #{log_path}: #{inspect(reason)}"}
    end
  end
end
