defmodule RLM.Bench.Logs do
  @moduledoc false

  alias RLM.Bench.Paths

  def tail(run_id, task_id, lines \\ 120) do
    with {:ok, log_path} <- resolve_log_path(run_id, task_id),
         {:ok, body} <- File.read(log_path) do
      tail = RLM.Bench.Util.tail_lines(body, max(lines, 1))

      {:ok, %{log_path: log_path, tail: tail}}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "Could not read log output: #{inspect(reason)}"}
    end
  end

  defp resolve_log_path(run_id, task_id) do
    default_path = Path.join([Paths.runs_dir(), run_id, "task_logs", "#{task_id}.log"])

    if File.exists?(default_path) do
      {:ok, default_path}
    else
      resolve_log_path_from_results(run_id, task_id, default_path)
    end
  end

  defp resolve_log_path_from_results(run_id, task_id, default_path) do
    run_dir = Path.join(Paths.runs_dir(), run_id)
    results_path = Path.join(run_dir, "results.jsonl")

    with {:ok, rows} <- read_results(results_path),
         {:ok, log_path} <- find_task_log_path(rows, task_id),
         true <- is_binary(log_path) and String.trim(log_path) != "" do
      {:ok, log_path}
    else
      false ->
        {:error, "Task #{task_id} has no log_path in #{results_path}"}

      {:error, reason} ->
        {:error,
         "Could not resolve log path for task #{task_id}. Checked #{default_path} and #{results_path}: #{reason}"}
    end
  end

  defp read_results(path) do
    with {:ok, body} <- File.read(path) do
      rows =
        body
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      {:ok, rows}
    else
      {:error, reason} ->
        {:error, "Could not read #{path}: #{inspect(reason)}"}
    end
  rescue
    error in Jason.DecodeError ->
      {:error, "Invalid JSONL in #{path}: #{Exception.message(error)}"}
  end

  defp find_task_log_path(rows, task_id) when is_list(rows) do
    case Enum.find(rows, fn row -> Map.get(row, "task_id") == task_id end) do
      %{"log_path" => log_path} -> {:ok, log_path}
      %{} -> {:error, "task entry found but missing log_path"}
      nil -> {:error, "task entry not found"}
    end
  end
end
