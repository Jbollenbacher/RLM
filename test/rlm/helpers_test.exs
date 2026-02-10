defmodule RLM.HelpersTest do
  use ExUnit.Case

  describe "latest_user_message/1" do
    test "returns the most recent user message from transcript" do
      context = """
      [RLM_User]
      first

      [RLM_Assistant]
      ok

      [RLM_User]
      second
      """

      assert {:ok, "second"} = RLM.Helpers.latest_user_message(context)
    end

    test "returns error when no chat markers are present" do
      context = "[User]\nthis is a document, not a transcript"
      assert {:error, _reason} = RLM.Helpers.latest_user_message(context)
    end
  end
end
