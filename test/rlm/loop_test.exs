defmodule RLM.LoopTest do
  use ExUnit.Case

  @moduletag timeout: 300_000

  describe "spec test 3: basic loop" do
    test "answers 'What is 2 + 2?' correctly" do
      result = RLM.run("unused", "What is 2 + 2?")
      assert {:ok, answer} = result
      assert answer =~ "4"
    end
  end

  describe "spec test 4: context access" do
    test "finds a secret token in 50K chars" do
      # Build a 50K string with SECRET_42 on its own line among random lines
      lines = for i <- 1..500, do: "line #{i}: #{String.duplicate("abcdefghij", 10)}"
      insert_at = :rand.uniform(400)

      lines = List.insert_at(lines, insert_at, "TOKEN: SECRET_42")
      context = Enum.join(lines, "\n")
      assert byte_size(context) > 50_000

      result = RLM.run(context, "Find the secret token embedded in the input. It starts with SECRET_.")
      assert {:ok, answer} = result
      assert answer =~ "SECRET_42"
    end
  end

  describe "spec test 5: truncation" do
    test "truncation works in the loop" do
      result =
        RLM.run(
          "unused",
          "Print the string 'x' repeated 10000 times using IO.puts, then set final_answer to {:ok, \"done\"}.",
          config: RLM.Config.load(max_iterations: 5)
        )

      assert {:ok, _answer} = result
    end
  end

  describe "spec test 6: error recovery" do
    test "model recovers from an error" do
      result =
        RLM.run(
          "unused",
          "Write code that will cause a runtime error (e.g. 1/0 or raise \"test error\"). After observing the error, set final_answer = {:ok, \"recovered\"}. Do these in separate iterations — first cause the error, then recover.",
          config: RLM.Config.load(max_iterations: 10)
        )

      assert {:ok, answer} = result
      assert answer =~ "recover"
    end
  end

  describe "context compaction" do
    test "compacts history when token estimate exceeds threshold" do
      config =
        RLM.Config.load(
          context_window_tokens_large: 100,
          context_window_tokens_small: 100,
          truncation_head: 5,
          truncation_tail: 5
        )

      history = [
        %{role: :system, content: "sys"},
        %{role: :user, content: String.duplicate("a", 400)}
      ]

      bindings = [context: "x"]

      {new_history, new_bindings} =
        RLM.Loop.maybe_compact(history, bindings, config.model_large, config)

      assert length(new_history) == 2
      assert Enum.at(new_history, 1).content =~ "[Context Window Compacted]"
      assert Keyword.get(new_bindings, :compacted_history) =~ "Role: user"
    end

    test "appends to existing compacted_history on subsequent compaction" do
      config =
        RLM.Config.load(
          context_window_tokens_large: 100,
          context_window_tokens_small: 100,
          truncation_head: 5,
          truncation_tail: 5
        )

      history_a = [
        %{role: :system, content: "sys"},
        %{role: :user, content: String.duplicate("a", 400)}
      ]

      history_b = [
        %{role: :system, content: "sys"},
        %{role: :user, content: String.duplicate("b", 400)}
      ]

      bindings = [context: "x"]

      {_history_a, bindings_a} =
        RLM.Loop.maybe_compact(history_a, bindings, config.model_large, config)

      {_history_b, bindings_b} =
        RLM.Loop.maybe_compact(history_b, bindings_a, config.model_large, config)

      combined = Keyword.get(bindings_b, :compacted_history)
      assert combined =~ "---"
      assert combined =~ String.duplicate("a", 20)
      assert combined =~ String.duplicate("b", 20)
    end
  end
end
