defmodule RLM.Bench.ReasonsTest do
  use ExUnit.Case, async: true

  alias RLM.Bench.Reasons

  test "categorizes common reason buckets" do
    assert Reasons.categorize("Dispatch was ambiguous and scope unclear") == :unclear_dispatch
    assert Reasons.categorize("Not enough context provided") == :insufficient_context
    assert Reasons.categorize("Output was incomplete and wrong") == :wrong_or_incomplete_output
    assert Reasons.categorize("Invalid final_answer format") == :format_or_contract_issue
    assert Reasons.categorize("Subagent timed out") == :timeout_or_runtime_issue
  end

  test "summarizes bucket counts" do
    summary =
      Reasons.summarize([
        "Dispatch unclear",
        "Not enough context",
        "assessment missing (status=ok)",
        "timed out"
      ])

    assert summary.counts.unclear_dispatch == 1
    assert summary.counts.insufficient_context == 1
    assert summary.counts.timeout_or_runtime_issue == 1
    assert summary.counts.format_or_contract_issue == 1
    assert summary.counts.other == 0
  end
end
