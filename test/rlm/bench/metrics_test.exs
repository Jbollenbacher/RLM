defmodule RLM.Bench.MetricsTest do
  use ExUnit.Case, async: true

  alias RLM.Bench.Metrics

  test "extracts delegation and assessment metrics from export" do
    export = %{
      format: "rlm_agent_log_v1",
      agent_tree: [
        %{
          agent: %{id: "agent_1"},
          timeline: [
            %{kind: "event", event: %{type: "lm_query", payload: %{child_agent_id: "agent_2"}}},
            %{
              kind: "event",
              event: %{
                type: "subagent_assessment",
                payload: %{verdict: "satisfied", reason: "good"}
              }
            },
            %{
              kind: "event",
              event: %{
                type: "dispatch_assessment",
                payload: %{verdict: "dissatisfied", reason: "unclear dispatch"}
              }
            },
            %{
              kind: "event",
              event: %{type: "dispatch_assessment_missing", payload: %{status: "ok"}}
            }
          ]
        }
      ]
    }

    path = Path.join(System.tmp_dir!(), "export_#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(export))

    assert {:ok, metrics} = Metrics.from_export(path, 1)
    assert metrics.dispatch_count == 1
    assert metrics.delegation_requirement_met == true
    assert metrics.subagent_satisfied == 1
    assert metrics.dispatch_dissatisfied == 1
    assert metrics.dispatch_missing == 1
    assert length(metrics.reasons) == 2
  end

  test "summarizes results to objective metrics" do
    results = [
      %{
        status: :ok,
        metrics: %{
          delegation_requirement_met: true,
          dispatch_satisfied: 1,
          dispatch_dissatisfied: 0,
          dispatch_missing: 0,
          subagent_satisfied: 1,
          subagent_dissatisfied: 0,
          subagent_missing: 0,
          reasons: []
        }
      },
      %{
        status: :error,
        metrics: %{
          delegation_requirement_met: false,
          dispatch_satisfied: 0,
          dispatch_dissatisfied: 1,
          dispatch_missing: 0,
          subagent_satisfied: 0,
          subagent_dissatisfied: 0,
          subagent_missing: 1,
          reasons: ["timed out"]
        }
      }
    ]

    summary = Metrics.summarize_results(results)
    assert summary.task_count == 2
    assert summary.completed_count == 1
    assert summary.failed_count == 1
    assert summary.task_completion_rate == 0.5
    assert summary.delegation_coverage == 0.5
    assert summary.assessment_volume == 4
    assert summary.objective > 0
    assert summary.reasons.counts.timeout_or_runtime_issue == 1
  end
end
