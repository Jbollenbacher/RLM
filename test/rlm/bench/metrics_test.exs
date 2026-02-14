defmodule RLM.Bench.MetricsTest do
  use ExUnit.Case, async: true

  alias RLM.Bench.Metrics

  test "extracts delegation and assessment metrics from survey events" do
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
                type: "survey_answered",
                payload: %{
                  survey_id: "subagent_usefulness",
                  response: "satisfied",
                  reason: "good",
                  scope: "child"
                }
              }
            },
            %{
              kind: "event",
              event: %{
                type: "survey_answered",
                payload: %{
                  survey_id: "dispatch_quality",
                  response: "dissatisfied",
                  reason: "unclear dispatch",
                  scope: "agent"
                }
              }
            },
            %{
              kind: "event",
              event: %{
                type: "survey_missing",
                payload: %{survey_id: "dispatch_quality", status: "ok", scope: "agent"}
              }
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
          survey_events_observed: 2,
          warnings: [],
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
          survey_events_observed: 0,
          warnings: ["no survey events observed; objective defaults to 0.0"],
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
    assert summary.tasks_with_no_survey_events == 1
    assert "no survey events observed; objective defaults to 0.0" in summary.warnings
    assert summary.objective > 0
    assert summary.reasons.counts.timeout_or_runtime_issue == 1
  end

  test "flags exports with no survey events" do
    export = %{format: "rlm_agent_log_v1", agent_tree: [%{agent: %{id: "agent_1"}, timeline: []}]}
    path = Path.join(System.tmp_dir!(), "export_#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(export))

    assert {:ok, metrics} = Metrics.from_export(path, 0)
    assert metrics.survey_events_observed == 0
    assert metrics.warnings == ["no survey events observed; objective defaults to 0.0"]
  end
end
