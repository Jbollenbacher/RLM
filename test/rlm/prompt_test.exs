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
  end
end
