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
end
