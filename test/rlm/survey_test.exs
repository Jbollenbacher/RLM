defmodule RLM.SurveyTest do
  use ExUnit.Case, async: true

  test "required pending and answered transitions" do
    state =
      RLM.Survey.init_state()
      |> RLM.Survey.ensure_dispatch_quality(true)

    assert [%{id: "dispatch_quality"}] = RLM.Survey.pending_required(state)

    assert {:ok, state, survey} =
             RLM.Survey.answer(state, "dispatch_quality", "satisfied", "clear dispatch")

    assert survey.response == :satisfied
    assert [] == RLM.Survey.pending_required(state)
    assert [%{id: "dispatch_quality"}] = RLM.Survey.answered_all(state)
  end

  test "verdict validation rejects invalid values" do
    {state, _survey} =
      RLM.Survey.ensure_survey(RLM.Survey.init_state(), %{
        id: "q1",
        required: true,
        response_schema: :verdict
      })

    assert {:error, reason} = RLM.Survey.answer(state, "q1", "maybe", "")
    assert reason =~ "Invalid survey response"
  end

  test "answer is last-write-wins" do
    {state, _survey} =
      RLM.Survey.ensure_survey(RLM.Survey.init_state(), %{
        id: "q1",
        required: false
      })

    assert {:ok, state, _survey} = RLM.Survey.answer(state, "q1", "first", "")
    assert {:ok, _updated_state, survey} = RLM.Survey.answer(state, "q1", "second", "")
    assert survey.response == "second"
  end

  test "mark_missing persists across ensure_survey refreshes" do
    state =
      RLM.Survey.init_state()
      |> RLM.Survey.ensure_dispatch_quality(true)
      |> RLM.Survey.mark_missing("dispatch_quality")

    assert state["dispatch_quality"].status == :missing

    refreshed = RLM.Survey.ensure_dispatch_quality(state, true)
    assert refreshed["dispatch_quality"].status == :missing
  end

  test "unknown string scope defaults to agent without atom conversion" do
    {state, survey} =
      RLM.Survey.ensure_survey(RLM.Survey.init_state(), %{
        id: "q_scope",
        scope: "not_a_real_scope"
      })

    assert survey.scope == :agent
    assert state["q_scope"].scope == :agent
  end

  test "clear_response resets answer and status to pending" do
    state =
      RLM.Survey.init_state()
      |> RLM.Survey.ensure_dispatch_quality(true)

    {:ok, state, _survey} = RLM.Survey.answer(state, "dispatch_quality", "satisfied", "good")
    assert state["dispatch_quality"].status == :answered

    cleared = RLM.Survey.clear_response(state, "dispatch_quality")
    assert cleared["dispatch_quality"].response == nil
    assert cleared["dispatch_quality"].status == :pending
    assert cleared["dispatch_quality"].answered_at == nil
  end

  test "clear_response on nonexistent survey is a no-op" do
    state = RLM.Survey.init_state()
    assert state == RLM.Survey.clear_response(state, "nonexistent")
  end

  test "merge_answers applies multiple answers at once" do
    state =
      RLM.Survey.init_state()
      |> RLM.Survey.ensure_dispatch_quality(true)

    answers = %{
      "dispatch_quality" => %{response: "satisfied", reason: "good"},
      "custom_q" => %{response: "yes", reason: ""}
    }

    merged = RLM.Survey.merge_answers(state, answers)
    assert merged["dispatch_quality"].response == :satisfied
    assert merged["custom_q"].response == "yes"
    assert merged["custom_q"].status == :answered
  end

  test "merge_answers skips invalid verdicts for schema-validated surveys" do
    state =
      RLM.Survey.init_state()
      |> RLM.Survey.ensure_dispatch_quality(true)

    answers = %{"dispatch_quality" => %{response: "maybe", reason: ""}}
    merged = RLM.Survey.merge_answers(state, answers)
    assert merged["dispatch_quality"].status == :pending
  end

  test "dispatch_assessment extracts verdict and reason from survey state" do
    state =
      RLM.Survey.init_state()
      |> RLM.Survey.ensure_dispatch_quality(true)

    assert RLM.Survey.dispatch_assessment(state) == nil

    {:ok, state, _survey} = RLM.Survey.answer(state, "dispatch_quality", "dissatisfied", "unclear")
    assert RLM.Survey.dispatch_assessment(state) == %{verdict: :dissatisfied, reason: "unclear"}
  end

  test "normalize_answers handles mixed atom and string keys" do
    raw = %{
      "q1" => %{"response" => "yes", "reason" => "ok"},
      q2: %{response: "no", reason: "nope"}
    }

    normalized = RLM.Survey.normalize_answers(raw)
    assert normalized["q1"] == %{response: "yes", reason: "ok"}
    assert normalized["q2"] == %{response: "no", reason: "nope"}
  end

  test "normalize_answers returns empty map for non-map input" do
    assert RLM.Survey.normalize_answers(nil) == %{}
    assert RLM.Survey.normalize_answers("bad") == %{}
  end

  test "parse_verdict accepts atoms and case-insensitive strings" do
    assert {:ok, :satisfied} = RLM.Survey.parse_verdict(:satisfied)
    assert {:ok, :dissatisfied} = RLM.Survey.parse_verdict(:dissatisfied)
    assert {:ok, :satisfied} = RLM.Survey.parse_verdict("Satisfied")
    assert {:ok, :dissatisfied} = RLM.Survey.parse_verdict("  DISSATISFIED  ")
    assert :error = RLM.Survey.parse_verdict("maybe")
    assert :error = RLM.Survey.parse_verdict(42)
  end
end
