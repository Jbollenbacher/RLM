defmodule RLM.FinalAnswerContractTest do
  use ExUnit.Case

  @moduletag timeout: 60_000

  defmodule RawFinalAnswerPlug do
    use Plug.Router
    import Plug.Conn

    plug(:match)
    plug(:dispatch)

    post "/chat/completions" do
      response = """
      ```python
      final_answer = "raw text"
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

  defmodule AlwaysNoCodePlug do
    use Plug.Router
    import Plug.Conn

    plug(:match)
    plug(:dispatch)

    post "/chat/completions" do
      body =
        Jason.encode!(%{choices: [%{message: %{content: "I will answer in plain text only."}}]})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    end

    match _ do
      send_resp(conn, 404, "Not found")
    end
  end

  test "raw final_answer values are treated as successful answers" do
    ensure_runtime_supervisors()
    port = free_port()

    start_supervised!(
      {Bandit, plug: RawFinalAnswerPlug, scheme: :http, port: port, ip: {127, 0, 0, 1}}
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
      {Bandit, plug: AlwaysNoCodePlug, scheme: :http, port: port, ip: {127, 0, 0, 1}}
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

  defp ensure_runtime_supervisors do
    unless Process.whereis(RLM.AgentLimiter) do
      start_supervised!(RLM.AgentLimiter)
    end

    unless Process.whereis(RLM.Finch) do
      start_supervised!({Finch, name: RLM.Finch})
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
