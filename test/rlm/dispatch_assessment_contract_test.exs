defmodule RLM.DispatchAssessmentContractTest do
  use ExUnit.Case

  @moduletag timeout: 60_000

  setup do
    start_supervised!(
      {RLM.Observability.Store,
       [max_events_per_agent: 500, max_context_snapshots_per_agent: 50, max_agents: 100]}
    )

    :ok = RLM.Observability.Telemetry.attach()
    :persistent_term.put({RLM.Observability, :enabled}, true)

    on_exit(fn ->
      RLM.Observability.Telemetry.detach()
      :persistent_term.put({RLM.Observability, :enabled}, false)
    end)

    :ok
  end

  defmodule DispatchAssessmentFinalPlug do
    use Plug.Router
    import Plug.Conn

    plug(:match)
    plug(:dispatch)

    post "/chat/completions" do
      response = """
      ```python
      assess_dispatch("satisfied", reason="clear and well-scoped dispatch")
      final_answer = "done"
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

  defmodule DispatchAssessmentNoFinalPlug do
    use Plug.Router
    import Plug.Conn

    plug(:match)
    plug(:dispatch)

    post "/chat/completions" do
      response = """
      ```python
      assess_dispatch("dissatisfied", reason="testing non-final step")
      x = 1
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

  defmodule DispatchAssessmentMissingPlug do
    use Plug.Router
    import Plug.Conn

    plug(:match)
    plug(:dispatch)

    post "/chat/completions" do
      {:ok, raw_body, conn} = read_body(conn)
      checkin_turn? = String.contains?(raw_body, "Dispatch quality assessment is required")

      response =
        if checkin_turn? do
          """
          ```python
          assess_dispatch("satisfied", reason="check-in provided assessment")
          final_answer = "replacement-answer"
          ```
          """
        else
          """
          ```python
          final_answer = "staged-answer"
          ```
          """
        end

      body = Jason.encode!(%{choices: [%{message: %{content: response}}]})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    end

    match _ do
      send_resp(conn, 404, "Not found")
    end
  end

  defmodule DispatchAssessmentStillMissingPlug do
    use Plug.Router
    import Plug.Conn

    plug(:match)
    plug(:dispatch)

    post "/chat/completions" do
      {:ok, raw_body, conn} = read_body(conn)
      checkin_turn? = String.contains?(raw_body, "Dispatch quality assessment is required")

      response =
        if checkin_turn? do
          """
          ```python
          final_answer = "replacement-without-assessment"
          ```
          """
        else
          """
          ```python
          final_answer = "staged-answer"
          ```
          """
        end

      body = Jason.encode!(%{choices: [%{message: %{content: response}}]})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    end

    match _ do
      send_resp(conn, 404, "Not found")
    end
  end

  defmodule SubagentAssessmentCheckinRecordedPlug do
    use Plug.Router
    import Plug.Conn

    plug(:match)
    plug(:dispatch)

    post "/chat/completions" do
      {:ok, raw_body, conn} = read_body(conn)

      response =
        cond do
          String.contains?(raw_body, "Subagent assessments are required before finalizing") ->
            """
            ```python
            assess_lm_query(job, "satisfied", reason="subagent result was useful")
            ```
            """

          String.contains?(raw_body, "child mission") ->
            """
            ```python
            final_answer = "child result"
            ```
            """

          true ->
            """
            ```python
            job = lm_query("child mission", model_size="small")
            result = await_lm_query(job, timeout_ms=5_000)
            final_answer = result
            ```
            """
        end

      body = Jason.encode!(%{choices: [%{message: %{content: response}}]})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    end

    match _ do
      send_resp(conn, 404, "Not found")
    end
  end

  defmodule SubagentAssessmentCheckinMissingPlug do
    use Plug.Router
    import Plug.Conn

    plug(:match)
    plug(:dispatch)

    post "/chat/completions" do
      {:ok, raw_body, conn} = read_body(conn)

      response =
        cond do
          String.contains?(raw_body, "Subagent assessments are required before finalizing") ->
            """
            ```python
            # skip assessment intentionally during check-in turn
            x = 1
            ```
            """

          String.contains?(raw_body, "child mission") ->
            """
            ```python
            final_answer = "child result"
            ```
            """

          true ->
            """
            ```python
            job = lm_query("child mission", model_size="small")
            result = await_lm_query(job, timeout_ms=5_000)
            final_answer = result
            ```
            """
        end

      body = Jason.encode!(%{choices: [%{message: %{content: response}}]})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    end

    match _ do
      send_resp(conn, 404, "Not found")
    end
  end

  test "subagent dispatch assessment is recorded when provided in final step" do
    ensure_runtime_supervisors()
    port = free_port()

    start_supervised!(
      {Bandit, plug: DispatchAssessmentFinalPlug, scheme: :http, port: port, ip: {127, 0, 0, 1}}
    )

    config =
      RLM.Config.load(
        api_base_url: "http://127.0.0.1:#{port}",
        api_key: "test",
        max_iterations: 2
      )

    parent_id = "agent_parent_#{System.unique_integer([:positive])}"
    child_id = "agent_child_#{System.unique_integer([:positive])}"

    assert {:ok, "done"} =
             RLM.run(
               "",
               "Finish the task.",
               config: config,
               parent_agent_id: parent_id,
               dispatch_assessment_required: true,
               agent_id: child_id
             )

    events =
      RLM.Observability.Store.list_events(
        agent_id: parent_id,
        since_ts: 0,
        since_id: 0,
        limit: 500
      )

    event =
      Enum.find(events, fn evt ->
        evt.type == :dispatch_assessment and get_in(evt, [:payload, :child_agent_id]) == child_id
      end)

    assert event
    assert get_in(event, [:payload, :verdict]) == :satisfied

    child_events =
      RLM.Observability.Store.list_events(
        agent_id: child_id,
        since_ts: 0,
        since_id: 0,
        limit: 500
      )

    assert Enum.any?(child_events, fn evt ->
             evt.type == :dispatch_assessment and
               get_in(evt, [:payload, :parent_agent_id]) == parent_id
           end)
  end

  test "assess_dispatch is not processed when no final_answer is committed" do
    ensure_runtime_supervisors()
    port = free_port()

    start_supervised!(
      {Bandit, plug: DispatchAssessmentNoFinalPlug, scheme: :http, port: port, ip: {127, 0, 0, 1}}
    )

    config =
      RLM.Config.load(
        api_base_url: "http://127.0.0.1:#{port}",
        api_key: "test",
        max_iterations: 1
      )

    parent_id = "agent_parent_#{System.unique_integer([:positive])}"
    child_id = "agent_child_#{System.unique_integer([:positive])}"

    assert {:error, reason} =
             RLM.run(
               "",
               "Finish the task.",
               config: config,
               parent_agent_id: parent_id,
               agent_id: child_id
             )

    assert reason =~ "Max iterations"

    events =
      RLM.Observability.Store.list_events(
        agent_id: parent_id,
        since_ts: 0,
        since_id: 0,
        limit: 500
      )

    refute Enum.any?(events, fn evt ->
             evt.type in [:dispatch_assessment, :dispatch_assessment_missing] and
               get_in(evt, [:payload, :child_agent_id]) == child_id
           end)
  end

  test "sampled subagent finalization uses one-turn check-in and records dispatch assessment" do
    ensure_runtime_supervisors()
    port = free_port()

    start_supervised!(
      {Bandit, plug: DispatchAssessmentMissingPlug, scheme: :http, port: port, ip: {127, 0, 0, 1}}
    )

    config =
      RLM.Config.load(
        api_base_url: "http://127.0.0.1:#{port}",
        api_key: "test",
        max_iterations: 3
      )

    parent_id = "agent_parent_#{System.unique_integer([:positive])}"
    child_id = "agent_child_#{System.unique_integer([:positive])}"

    assert {:ok, "staged-answer"} =
             RLM.run(
               "",
               "Finish the task.",
               config: config,
               parent_agent_id: parent_id,
               dispatch_assessment_required: true,
               agent_id: child_id
             )

    events =
      RLM.Observability.Store.list_events(
        agent_id: parent_id,
        since_ts: 0,
        since_id: 0,
        limit: 500
      )

    assert Enum.any?(events, fn evt ->
             evt.type == :dispatch_assessment and
               get_in(evt, [:payload, :child_agent_id]) == child_id and
               get_in(evt, [:payload, :verdict]) == :satisfied
           end)

    refute Enum.any?(events, fn evt ->
             evt.type == :dispatch_assessment_missing and
               get_in(evt, [:payload, :child_agent_id]) == child_id
           end)
  end

  test "sampled subagent finalization falls back after one check-in turn when assessment remains missing" do
    ensure_runtime_supervisors()
    port = free_port()

    start_supervised!(
      {Bandit,
       plug: DispatchAssessmentStillMissingPlug, scheme: :http, port: port, ip: {127, 0, 0, 1}}
    )

    config =
      RLM.Config.load(
        api_base_url: "http://127.0.0.1:#{port}",
        api_key: "test",
        max_iterations: 2
      )

    parent_id = "agent_parent_#{System.unique_integer([:positive])}"
    child_id = "agent_child_#{System.unique_integer([:positive])}"

    assert {:ok, "staged-answer"} =
             RLM.run(
               "",
               "Finish the task.",
               config: config,
               parent_agent_id: parent_id,
               dispatch_assessment_required: true,
               agent_id: child_id
             )

    events =
      RLM.Observability.Store.list_events(
        agent_id: parent_id,
        since_ts: 0,
        since_id: 0,
        limit: 500
      )

    assert Enum.any?(events, fn evt ->
             evt.type == :dispatch_assessment_missing and
               get_in(evt, [:payload, :child_agent_id]) == child_id
           end)

    refute Enum.any?(events, fn evt ->
             evt.type == :dispatch_assessment and
               get_in(evt, [:payload, :child_agent_id]) == child_id
           end)
  end

  test "unsampled subagent finalization remains unchanged without check-in gating" do
    ensure_runtime_supervisors()
    port = free_port()

    start_supervised!(
      {Bandit,
       plug: DispatchAssessmentStillMissingPlug, scheme: :http, port: port, ip: {127, 0, 0, 1}}
    )

    config =
      RLM.Config.load(
        api_base_url: "http://127.0.0.1:#{port}",
        api_key: "test",
        max_iterations: 1
      )

    parent_id = "agent_parent_#{System.unique_integer([:positive])}"
    child_id = "agent_child_#{System.unique_integer([:positive])}"

    assert {:ok, "staged-answer"} =
             RLM.run(
               "",
               "Finish the task.",
               config: config,
               parent_agent_id: parent_id,
               dispatch_assessment_required: false,
               agent_id: child_id
             )

    events =
      RLM.Observability.Store.list_events(
        agent_id: parent_id,
        since_ts: 0,
        since_id: 0,
        limit: 500
      )

    refute Enum.any?(events, fn evt ->
             evt.type in [:dispatch_assessment, :dispatch_assessment_missing] and
               get_in(evt, [:payload, :child_agent_id]) == child_id
           end)
  end

  test "sampled subagent assessment check-in records assess_lm_query before finalization" do
    ensure_runtime_supervisors()
    port = free_port()

    start_supervised!(
      {Bandit,
       plug: SubagentAssessmentCheckinRecordedPlug, scheme: :http, port: port, ip: {127, 0, 0, 1}}
    )

    config =
      RLM.Config.load(
        api_base_url: "http://127.0.0.1:#{port}",
        api_key: "test",
        subagent_assessment_sample_rate: 1.0,
        max_iterations: 4
      )

    parent_id = "agent_parent_#{System.unique_integer([:positive])}"

    assert {:ok, "child result"} =
             RLM.run(
               "",
               "Dispatch one child and return its result.",
               config: config,
               agent_id: parent_id
             )

    events =
      RLM.Observability.Store.list_events(
        agent_id: parent_id,
        since_ts: 0,
        since_id: 0,
        limit: 500
      )

    assert Enum.any?(events, fn evt -> evt.type == :subagent_assessment end)

    refute Enum.any?(events, fn evt -> evt.type == :subagent_assessment_missing end)
  end

  test "sampled subagent assessment check-in falls back to missing after one retry" do
    ensure_runtime_supervisors()
    port = free_port()

    start_supervised!(
      {Bandit,
       plug: SubagentAssessmentCheckinMissingPlug, scheme: :http, port: port, ip: {127, 0, 0, 1}}
    )

    config =
      RLM.Config.load(
        api_base_url: "http://127.0.0.1:#{port}",
        api_key: "test",
        subagent_assessment_sample_rate: 1.0,
        max_iterations: 4
      )

    parent_id = "agent_parent_#{System.unique_integer([:positive])}"

    assert {:ok, "child result"} =
             RLM.run(
               "",
               "Dispatch one child and return its result.",
               config: config,
               agent_id: parent_id
             )

    events =
      RLM.Observability.Store.list_events(
        agent_id: parent_id,
        since_ts: 0,
        since_id: 0,
        limit: 500
      )

    assert Enum.any?(events, fn evt -> evt.type == :subagent_assessment_missing end)
  end

  test "agent_status done emits subagent_assessment_missing once for sampled pending assessments" do
    ensure_runtime_supervisors()

    parent_id = "agent_parent_#{System.unique_integer([:positive])}"

    assert {:ok, child_id} =
             RLM.Subagent.Broker.dispatch(
               parent_id,
               "task",
               [model_size: :small],
               fn _text, _opts -> {:ok, "done"} end,
               timeout_ms: 1_000,
               assessment_sampled: true
             )

    assert_eventually(fn ->
      match?(
        {:ok, %{state: :ok, assessment_required: true}},
        RLM.Subagent.Broker.poll(parent_id, child_id)
      )
    end)

    RLM.Observability.emit([:rlm, :agent, :status], %{}, %{agent_id: parent_id, status: :done})
    RLM.Observability.emit([:rlm, :agent, :status], %{}, %{agent_id: parent_id, status: :done})

    events =
      RLM.Observability.Store.list_events(
        agent_id: parent_id,
        since_ts: 0,
        since_id: 0,
        limit: 500
      )

    missing_count =
      events
      |> Enum.filter(fn evt ->
        evt.type == :subagent_assessment_missing and
          get_in(evt, [:payload, :child_agent_id]) == child_id
      end)
      |> length()

    assert missing_count == 1
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

  defp assert_eventually(fun, attempts \\ 60)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true in time")
end
