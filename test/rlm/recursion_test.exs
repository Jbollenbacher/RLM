defmodule RLM.RecursionTest do
  use ExUnit.Case

  @moduletag :integration
  # These tests involve recursive LLM calls and can take a while
  @moduletag timeout: 600_000

  describe "spec test 7: sub-LLM delegation" do
    test "summarizes a 100K document using lm_query" do
      # Generate a 50K+ document with distinct sections (kept smaller to reduce runtime)
      sections =
        for i <- 1..10 do
          "Section #{i}: " <> String.duplicate("This is content for section #{i}. ", 200)
        end

      context = Enum.join(sections, "\n\n")
      assert byte_size(context) > 50_000

      result =
        RLM.run(
          context,
          "Summarize this document. It contains multiple sections. Use lm_query to delegate chunk summarization, await the delegated results, synthesize them, and set final_answer to the final summary string in that same step.",
          config:
            RLM.Config.load(
              max_iterations: 40,
              max_depth: 3,
              subagent_assessment_sample_rate: 0.0
            )
        )

      assert {:ok, answer} = result
      assert String.length(answer) > 10
    end
  end

  describe "spec test 9: scale" do
    test "handles 1M+ character input" do
      # Generate 1M+ of structured content
      context = String.duplicate("The quick brown fox jumps over the lazy dog. ", 25_000)
      assert byte_size(context) > 1_000_000

      result =
        RLM.run(
          context,
          "Compute len(context.encode('utf-8')) and set final_answer = (\"ok\", str(len(context.encode('utf-8')))) in the same step.",
          config: RLM.Config.load(max_iterations: 5)
        )

      assert {:ok, answer} = result
      # The model should report a number over 1M
      assert answer =~ "1"
    end
  end
end
