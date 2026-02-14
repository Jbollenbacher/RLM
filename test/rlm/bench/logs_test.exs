defmodule RLM.Bench.LogsTest do
  use ExUnit.Case, async: false

  alias RLM.Bench.Logs
  alias RLM.Bench.Paths

  test "tail reads default task log path" do
    run_id = "logs_default_#{System.unique_integer([:positive, :monotonic])}"
    run_dir = Path.join(Paths.runs_dir(), run_id)
    task_logs_dir = Path.join(run_dir, "task_logs")
    task_id = "task_default"
    log_path = Path.join(task_logs_dir, "#{task_id}.log")

    File.mkdir_p!(task_logs_dir)
    on_exit(fn -> File.rm_rf(run_dir) end)
    File.write!(log_path, "line1\nline2\nline3\n")

    assert {:ok, out} = Logs.tail(run_id, task_id, 2)
    assert out.log_path == log_path
    assert out.tail == "line2\nline3"
  end

  test "tail resolves custom log_dir path from results.jsonl" do
    unique = System.unique_integer([:positive, :monotonic])
    run_id = "logs_custom_#{unique}"
    run_dir = Path.join(Paths.runs_dir(), run_id)
    task_id = "task_custom"
    custom_log_dir = Path.join(System.tmp_dir!(), "rlm_custom_logs_#{unique}")
    custom_log_path = Path.join(custom_log_dir, "#{task_id}.log")
    results_path = Path.join(run_dir, "results.jsonl")

    File.mkdir_p!(run_dir)
    File.mkdir_p!(custom_log_dir)

    on_exit(fn ->
      File.rm_rf(run_dir)
      File.rm_rf(custom_log_dir)
    end)

    File.write!(custom_log_path, "alpha\nbeta\ngamma\n")

    results_row = %{
      "task_id" => task_id,
      "log_path" => custom_log_path
    }

    File.write!(results_path, Jason.encode!(results_row) <> "\n")

    assert {:ok, out} = Logs.tail(run_id, task_id, 1)
    assert out.log_path == custom_log_path
    assert out.tail == "gamma"
  end
end
