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
end
