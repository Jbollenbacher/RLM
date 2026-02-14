defmodule RLM.TestSupport do
  @moduledoc false

  def ensure_runtime_supervisors do
    unless Process.whereis(RLM.AgentLimiter) do
      ExUnit.Callbacks.start_supervised!(RLM.AgentLimiter)
    end

    unless Process.whereis(RLM.Finch) do
      ExUnit.Callbacks.start_supervised!({Finch, name: RLM.Finch})
    end
  end

  def free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  def assert_eventually(fun, attempts \\ 60, sleep_ms \\ 20)
      when is_function(fun, 0) and attempts >= 0 and sleep_ms >= 0 do
    do_assert_eventually(fun, attempts, sleep_ms)
  end

  defp do_assert_eventually(fun, attempts, sleep_ms) do
    if fun.() do
      :ok
    else
      if attempts == 0 do
        ExUnit.Assertions.flunk("condition did not become true in time")
      else
        Process.sleep(sleep_ms)
        do_assert_eventually(fun, attempts - 1, sleep_ms)
      end
    end
  end
end

defmodule RLM.TestSupport.LLMPlug do
  @moduledoc false

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    responder = Keyword.fetch!(opts, :responder)

    case {conn.method, conn.request_path} do
      {"POST", "/chat/completions"} ->
        {:ok, raw_body, conn} = read_body(conn)
        content = responder.(raw_body)
        body = Jason.encode!(%{choices: [%{message: %{content: to_string(content)}}]})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      _ ->
        send_resp(conn, 404, "Not found")
    end
  end
end

run_integration? = System.get_env("RLM_RUN_INTEGRATION") in ["1", "true", "TRUE"]

ExUnit.start(exclude: if(run_integration?, do: [], else: [:integration]))
