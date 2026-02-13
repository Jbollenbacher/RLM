defmodule RLM.MaxConcurrentAgentsTest do
  use ExUnit.Case

  @moduletag timeout: 60_000

  defmodule FakeLLMPlug do
    use Plug.Router
    import Plug.Conn

    plug(:match)
    plug(:dispatch)

    post "/chat/completions" do
      response = """
      ```python
      try:
          job_id = lm_query("subagent task", model_size="small")
          final_answer = await_lm_query(job_id, timeout_ms=5_000)
      except Exception as exc:
          final_answer = fail(str(exc))
      ```
      """

      body = Jason.encode!(%{choices: [%{message: %{content: response}}]})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    end

    match _ do
      send_resp(conn, 404, "Not found")
    end
  end

  test "lm_query returns max-concurrency error when limit is 1" do
    unless Process.whereis(RLM.AgentLimiter) do
      start_supervised!(RLM.AgentLimiter)
    end

    unless Process.whereis(RLM.Finch) do
      start_supervised!({Finch, name: RLM.Finch})
    end

    port = free_port()

    start_supervised!({Bandit, plug: FakeLLMPlug, scheme: :http, port: port, ip: {127, 0, 0, 1}})

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

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
