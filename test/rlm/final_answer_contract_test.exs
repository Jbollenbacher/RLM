defmodule RLM.FinalAnswerContractTest do
  use ExUnit.Case

  @moduletag timeout: 60_000

  import RLM.TestSupport,
    only: [ensure_runtime_supervisors: 0, free_port: 0]

  test "raw final_answer values are treated as successful answers" do
    ensure_runtime_supervisors()
    port = free_port()

    start_supervised!(
      {Bandit,
       plug: {RLM.TestSupport.LLMPlug, responder: raw_final_answer_responder()},
       scheme: :http,
       port: port,
       ip: {127, 0, 0, 1}}
    )

    config =
      RLM.Config.load(
        api_base_url: "http://127.0.0.1:#{port}",
        api_key: "test",
        max_iterations: 4
      )

    assert {:ok, "raw text"} = RLM.run("", "Finish the task", config: config)
  end

  test "repeated no-code responses fail the turn" do
    ensure_runtime_supervisors()
    port = free_port()

    start_supervised!(
      {Bandit,
       plug: {RLM.TestSupport.LLMPlug, responder: always_no_code_responder()},
       scheme: :http,
       port: port,
       ip: {127, 0, 0, 1}}
    )

    config =
      RLM.Config.load(
        api_base_url: "http://127.0.0.1:#{port}",
        api_key: "test",
        max_iterations: 4
      )

    assert {:error, reason} = RLM.run("", "Finish the task", config: config)
    assert reason =~ "No code block found after retry"
  end

  defp raw_final_answer_responder do
    fn _raw_body ->
      """
      ```python
      final_answer = "raw text"
      ```
      """
    end
  end

  defp always_no_code_responder, do: fn _raw_body -> "I will answer in plain text only." end
end
