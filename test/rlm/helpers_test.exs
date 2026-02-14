defmodule RLM.HelpersTest do
  use ExUnit.Case

  describe "latest_principal_message/1" do
    test "returns the most recent principal message from transcript" do
      context = """
      [RLM_Principal]
      first

      [RLM_Agent]
      ok

      [RLM_Principal]
      second
      """

      assert {:ok, "second"} = RLM.Helpers.latest_principal_message(context)
    end

    test "returns error when no chat markers are present" do
      context = "[User]\nthis is a document, not a transcript"
      assert {:error, _reason} = RLM.Helpers.latest_principal_message(context)
    end
  end

  describe "timestamped_filename/2" do
    test "builds a timestamped filename with extension" do
      filename = RLM.Helpers.timestamped_filename("rlm_agent_logs")

      assert String.starts_with?(filename, "rlm_agent_logs_")
      assert String.ends_with?(filename, ".json")
      assert filename =~ ~r/^rlm_agent_logs_[0-9T:\-+Z]+\.json$/
    end
  end
end
