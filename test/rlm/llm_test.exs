defmodule RLM.LLMTest do
  use ExUnit.Case

  describe "extract_code/1" do
    test "extracts elixir code blocks" do
      response = """
      ```elixir
      IO.puts(\"hi\")
      ```
      """

      assert {:ok, code} = RLM.LLM.extract_code(response)
      assert code == "IO.puts(\"hi\")"
    end

    test "accepts capitalized Elixir and trailing whitespace" do
      response = "```Elixir  \r\nx = 1\n```"

      assert {:ok, code} = RLM.LLM.extract_code(response)
      assert code == "x = 1"
    end

    test "returns the last elixir code block when multiple are present" do
      response = """
      ```elixir
      first = 1
      ```

      ```elixir
      second = 2
      ```
      """

      assert {:ok, code} = RLM.LLM.extract_code(response)
      assert code == "second = 2"
    end

    test "returns no_code_block for non-binary input" do
      assert {:error, :no_code_block} = RLM.LLM.extract_code(nil)
    end
  end
end
