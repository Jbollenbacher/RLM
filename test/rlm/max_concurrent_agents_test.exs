defmodule RLM.MaxConcurrentAgentsTest do
  use ExUnit.Case

  @moduletag timeout: 60_000

  import RLM.TestSupport,
    only: [ensure_runtime_supervisors: 0, free_port: 0]

  test "lm_query returns max-concurrency error when limit is 1" do
    ensure_runtime_supervisors()

    port = free_port()

    start_supervised!(
      {Bandit,
       plug: {RLM.TestSupport.LLMPlug, responder: fake_llm_responder()},
       scheme: :http,
       port: port,
       ip: {127, 0, 0, 1}}
    )

    config =
      RLM.Config.load(
        api_base_url: "http://127.0.0.1:#{port}",
        api_key: "test",
        max_concurrent_agents: 1,
        max_iterations: 3,
        max_depth: 2
      )

    assert {:error, reason} =
             RLM.run("", "Call a subagent using lm_query.", config: config)

    assert reason =~ "Max concurrent agents (1) reached"
  end

  defp fake_llm_responder do
    fn _raw_body ->
      """
      ```python
      try:
          job_id = lm_query("subagent task", model_size="small")
          final_answer = await_lm_query(job_id, timeout_ms=5_000)
      except Exception as exc:
          final_answer = fail(str(exc))
      ```
      """
    end
  end
end
