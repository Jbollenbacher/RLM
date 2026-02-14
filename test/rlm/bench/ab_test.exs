defmodule RLM.Bench.ABTest do
  use ExUnit.Case, async: true

  alias RLM.Bench.AB

  test "promotes variant B when objective improves and thresholds pass" do
    a = %{
      "objective" => 0.40,
      "delegation_coverage" => 0.6,
      "task_completion_rate" => 0.9,
      "failed_count" => 1,
      "overall_satisfied_rate" => 0.67,
      "assessment_volume" => 100,
      "run_id" => "a"
    }

    b = %{
      "objective" => 0.46,
      "delegation_coverage" => 0.62,
      "task_completion_rate" => 0.92,
      "failed_count" => 1,
      "overall_satisfied_rate" => 0.74,
      "assessment_volume" => 120,
      "run_id" => "b"
    }

    report = AB.decide(a, b, %{})
    assert report.decision == "promote"
    assert report.deltas.task_completion_rate > 0
  end

  test "rejects B when assessment volume is too low" do
    a = %{
      "objective" => 0.40,
      "delegation_coverage" => 0.6,
      "task_completion_rate" => 0.9,
      "failed_count" => 1,
      "overall_satisfied_rate" => 0.67,
      "assessment_volume" => 100,
      "run_id" => "a"
    }

    b = %{
      "objective" => 0.60,
      "delegation_coverage" => 0.8,
      "task_completion_rate" => 0.7,
      "failed_count" => 3,
      "overall_satisfied_rate" => 0.80,
      "assessment_volume" => 10,
      "run_id" => "b"
    }

    report = AB.decide(a, b, %{})
    assert report.decision == "reject"
    assert report.run_b.failed_count > report.run_a.failed_count
  end
end
