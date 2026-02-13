defmodule RLM.LLMTest do
  use ExUnit.Case

  describe "extract_code/1" do
    test "extracts python code blocks" do
      response = """
      ```python
      print("hi")
      ```
      """

      assert {:ok, code} = RLM.LLM.extract_code(response)
      assert code == "print(\"hi\")"
    end

    test "accepts capitalized Python and trailing whitespace" do
      response = "```Python  \r\nx = 1\n```"

      assert {:ok, code} = RLM.LLM.extract_code(response)
      assert code == "x = 1"
    end

    test "returns the last python code block when multiple are present" do
      response = """
      ```python
      first = 1
      ```

      ```python
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
