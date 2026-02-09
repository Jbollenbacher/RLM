defmodule RLM.PromptTest do
  use ExUnit.Case

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
