defmodule RLM.PromptTest do
  use ExUnit.Case

  describe "user prompt builders" do
    test "followup_user_message omits system instruction block" do
      context =
        "[RLM_Principal]\nHello world!\n\n[RLM_Agent]\nHi\n\n[RLM_Principal]\nWhats in the workspace?"

      output = RLM.Prompt.followup_user_message(context)

      assert output =~ "[PRINCIPAL]\nWhats in the workspace?"
      refute output =~ "[SYSTEM]"
      refute output =~ "final_answer"
    end
  end

  describe "format_eval_output/4" do
    test "adds truncation note for large binary results" do
      result = String.duplicate("x", 600)
      output = RLM.Prompt.format_eval_output("", "", :ok, result)

      assert output =~ "(600 bytes, truncated)"
    end

    test "omits truncation note for small binary results" do
      result = "hello"
      output = RLM.Prompt.format_eval_output("", "", :ok, result)

      refute output =~ "truncated"
    end

    test "adds actionable rollback hint on eval errors" do
      output = RLM.Prompt.format_eval_output("Traceback...", "", :error, nil)

      assert output =~ "Bindings unchanged"
      assert output =~ "Variables assigned in this failed step were not persisted"
      assert output =~ "Use list_bindings()"
    end

    test "adds undefined-name hint when NameError is detected" do
      stdout = """
      Traceback (most recent call last):
        File \"<string>\", line 317, in <module>
      NameError: name 'major_sections' is not defined
      """

      output = RLM.Prompt.format_eval_output(stdout, "", :error, nil)

      assert output =~ "`major_sections` is undefined"
      assert output =~ "\"major_sections\" in globals()"
    end
  end

  describe "check-in nudges" do
    test "dispatch assessment check-in nudge enforces assessment-only step" do
      output = RLM.Prompt.dispatch_assessment_checkin_nudge()

      assert output =~ "respond with exactly one Python code block"
      assert output =~ "assess_dispatch(\"satisfied\""
      assert output =~ "Do not call `lm_query`, `await_lm_query`, or `poll_lm_query`"
      assert output =~ "Do not set `final_answer` again"
    end

    test "subagent assessment check-in nudge enforces assessment-only step" do
      output = RLM.Prompt.subagent_assessment_checkin_nudge(["agent_1"])

      assert output =~ "respond with exactly one Python code block"
      assert output =~ "assess_lm_query(child_agent_id"
      assert output =~ "Use the exact `child_agent_id` values listed below as literal arguments"
      assert output =~ "agent_1: assess_lm_query(\"agent_1\""
      assert output =~ "Do not call `lm_query`, `await_lm_query`, or `poll_lm_query`"
      assert output =~ "Do not set `final_answer` again"
    end

    test "generic survey check-in nudge includes answer_survey guidance" do
      output = RLM.Prompt.survey_checkin_nudge(["dispatch_quality"])

      assert output =~ "answer_survey(survey_id, response, reason=\"...\")"
      assert output =~ "Pending survey_id values: dispatch_quality"
    end
  end
end
