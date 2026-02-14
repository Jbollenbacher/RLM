defmodule RLM.Bench.InspectorTest do
  use ExUnit.Case, async: true

  alias RLM.Bench.Inspector

  test "inspects weak run and emits investigation artifacts" do
    dir = Path.join(System.tmp_dir!(), "bench_inspect_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    log_path = Path.join(dir, "task.log")
    export_path = Path.join(dir, "task_export.json")

    File.write!(
      log_path,
      "[RLM] no code block found\n[RLM] Max iterations reached\nTraceback: NameError\n"
    )

    export = %{
      format: "rlm_agent_log_v1",
      agent_tree: [
        %{
          agent: %{id: "a1"},
          timeline: [
            %{kind: "event", event: %{type: "llm", payload: %{status: "ok"}}},
            %{kind: "event", event: %{type: "eval", payload: %{status: "error"}}}
          ]
        }
      ]
    }

    File.write!(export_path, Jason.encode!(export))

    run = %{
      run_dir: dir,
      summary: %{
        run_id: "run_x",
        objective: 0.2,
        overall_satisfied_rate: 0.4,
        delegation_coverage: 0.3,
        failed_count: 1
      },
      results: [
        %{
          task_id: "task_1",
          status: :error,
          log_path: log_path,
          export_path: export_path,
          metrics: %{
            dispatch_missing: 1,
            subagent_missing: 1,
            dispatch_dissatisfied: 0,
            subagent_dissatisfied: 0
          }
        }
      ]
    }

    out = Inspector.inspect_run(run, limit: 1, tail_lines: 30)

    assert out.enabled == true
    assert File.exists?(out.path)
    assert Enum.any?(out.investigated_tasks, &(&1.task_id == "task_1"))
    assert Map.get(out.signal_counts, :task_error, 0) >= 1
    assert is_list(out.recommendations)
  end
end
