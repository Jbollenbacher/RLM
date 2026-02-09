defmodule RLM.RecursionTest do
  use ExUnit.Case

  # These tests involve recursive LLM calls and can take a while
  @moduletag timeout: 600_000

  describe "spec test 7: sub-LLM delegation" do
    test "summarizes a 100K document using lm_query" do
      # Generate a 100K document with distinct sections
      sections =
        for i <- 1..20 do
          "Section #{i}: " <> String.duplicate("This is content for section #{i}. ", 100)
        end

      context = Enum.join(sections, "\n\n")
      assert byte_size(context) > 50_000

      result =
        RLM.run(
          context,
          "Summarize this document. It contains multiple sections. Use lm_query to delegate summarization of chunks.",
          config: RLM.Config.load(max_iterations: 15, max_depth: 3)
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
          "How many characters is the input? Count using byte_size(context) and report the number.",
          config: RLM.Config.load(max_iterations: 5)
        )

      assert {:ok, answer} = result
      # The model should report a number over 1M
      assert answer =~ "1"
    end
  end
end
