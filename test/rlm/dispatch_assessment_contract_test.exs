defmodule RLM.DispatchAssessmentContractTest do
  use ExUnit.Case

  import RLM.TestSupport,
    only: [
      assert_eventually: 1,
      ensure_runtime_supervisors: 0,
      free_port: 0
    ]

  @moduletag timeout: 60_000

  setup do
    ensure_runtime_supervisors()

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

  test "subagent dispatch assessment is recorded when provided in final step" do
    port = start_llm_server!(dispatch_assessment_final_responder())
    config = test_config(port, max_iterations: 2)

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

    events = events_for(child_id)

    event =
      Enum.find(events, fn evt ->
        evt.type == :dispatch_assessment and get_in(evt, [:payload, :child_agent_id]) == child_id
      end)

    assert event
    assert get_in(event, [:payload, :verdict]) == :satisfied
    assert get_in(event, [:payload, :parent_agent_id]) == parent_id

    parent_events = events_for(parent_id)
    refute Enum.any?(parent_events, fn evt -> evt.type == :dispatch_assessment end)
  end

  test "assess_dispatch is not processed when no final_answer is committed" do
    port = start_llm_server!(dispatch_assessment_no_final_responder())
    config = test_config(port, max_iterations: 1)

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

    events = events_for(parent_id)

    refute Enum.any?(events, fn evt ->
             evt.type in [:dispatch_assessment, :dispatch_assessment_missing] and
               get_in(evt, [:payload, :child_agent_id]) == child_id
           end)

    child_events = events_for(child_id)

    refute Enum.any?(child_events, fn evt ->
             evt.type in [:dispatch_assessment, :dispatch_assessment_missing]
           end)
  end

  test "sampled subagent finalization uses one-turn check-in and records dispatch assessment" do
    port = start_llm_server!(dispatch_assessment_missing_responder())
    config = test_config(port, max_iterations: 3)

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

    events = events_for(child_id)

    assert Enum.any?(events, fn evt ->
             evt.type == :dispatch_assessment and
               get_in(evt, [:payload, :child_agent_id]) == child_id and
               get_in(evt, [:payload, :parent_agent_id]) == parent_id and
               get_in(evt, [:payload, :verdict]) == :satisfied
           end)

    refute Enum.any?(events, fn evt ->
             evt.type == :dispatch_assessment_missing and
               get_in(evt, [:payload, :child_agent_id]) == child_id
           end)

    parent_events = events_for(parent_id)
    refute Enum.any?(parent_events, fn evt -> evt.type in [:dispatch_assessment, :dispatch_assessment_missing] end)
  end

  test "sampled subagent finalization falls back after one check-in turn when assessment remains missing" do
    port = start_llm_server!(dispatch_assessment_still_missing_responder())
    config = test_config(port, max_iterations: 2)

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

    events = events_for(child_id)

    assert Enum.any?(events, fn evt ->
             evt.type == :dispatch_assessment_missing and
               get_in(evt, [:payload, :child_agent_id]) == child_id
           end)

    refute Enum.any?(events, fn evt ->
             evt.type == :dispatch_assessment and
               get_in(evt, [:payload, :child_agent_id]) == child_id
           end)

    parent_events = events_for(parent_id)
    refute Enum.any?(parent_events, fn evt -> evt.type in [:dispatch_assessment, :dispatch_assessment_missing] end)
  end

  test "unsampled subagent finalization remains unchanged without check-in gating" do
    port = start_llm_server!(dispatch_assessment_still_missing_responder())
    config = test_config(port, max_iterations: 1)

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

    events = events_for(parent_id)

    refute Enum.any?(events, fn evt ->
             evt.type in [:dispatch_assessment, :dispatch_assessment_missing] and
               get_in(evt, [:payload, :child_agent_id]) == child_id
           end)

    child_events = events_for(child_id)

    refute Enum.any?(child_events, fn evt ->
             evt.type in [:dispatch_assessment, :dispatch_assessment_missing]
           end)
  end

  test "sampled subagent assessment check-in records assess_lm_query before finalization" do
    port = start_llm_server!(subagent_checkin_recorded_responder())
    config =
      test_config(port,
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

    events = events_for(parent_id)

    assert Enum.any?(events, fn evt -> evt.type == :subagent_assessment end)

    refute Enum.any?(events, fn evt -> evt.type == :subagent_assessment_missing end)
  end

  test "sampled subagent assessment check-in falls back to missing after one retry" do
    port = start_llm_server!(subagent_checkin_missing_responder())
    config =
      test_config(port,
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

    events = events_for(parent_id)

    assert Enum.any?(events, fn evt -> evt.type == :subagent_assessment_missing end)
  end

  test "agent_status done emits subagent_assessment_missing once for sampled pending assessments" do
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

    events = events_for(parent_id)

    missing_count =
      events
      |> Enum.filter(fn evt ->
        evt.type == :subagent_assessment_missing and
          get_in(evt, [:payload, :child_agent_id]) == child_id
      end)
      |> length()

    assert missing_count == 1
  end

  defp dispatch_assessment_final_responder do
    fn _raw_body ->
      """
      ```python
      assess_dispatch("satisfied", reason="clear and well-scoped dispatch")
      final_answer = "done"
      ```
      """
    end
  end

  defp dispatch_assessment_no_final_responder do
    fn _raw_body ->
      """
      ```python
      assess_dispatch("dissatisfied", reason="testing non-final step")
      x = 1
      ```
      """
    end
  end

  defp dispatch_assessment_missing_responder do
    fn raw_body ->
      if String.contains?(raw_body, "Dispatch quality assessment is required") do
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
    end
  end

  defp dispatch_assessment_still_missing_responder do
    fn raw_body ->
      if String.contains?(raw_body, "Dispatch quality assessment is required") do
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
    end
  end

  defp subagent_checkin_recorded_responder do
    fn raw_body ->
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
    end
  end

  defp subagent_checkin_missing_responder do
    fn raw_body ->
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
    end
  end

  defp start_llm_server!(responder) do
    port = free_port()

    start_supervised!(
      {Bandit,
       plug: {RLM.TestSupport.LLMPlug, responder: responder},
       scheme: :http,
       port: port,
       ip: {127, 0, 0, 1}}
    )

    port
  end

  defp test_config(port, overrides) do
    RLM.Config.load(
      Keyword.merge(
        [
          api_base_url: "http://127.0.0.1:#{port}",
          api_key: "test"
        ],
        overrides
      )
    )
  end

  defp events_for(agent_id) do
    RLM.Observability.Store.list_events(
      agent_id: agent_id,
      since_ts: 0,
      since_id: 0,
      limit: 500
    )
  end
end
