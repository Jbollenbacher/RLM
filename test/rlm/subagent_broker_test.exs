defmodule RLM.SubagentBrokerTest do
  use ExUnit.Case

  test "dispatch returns child id and job eventually completes" do
    parent_id = "parent_#{System.unique_integer([:positive, :monotonic])}"

    lm_query_fn = fn _text, _opts ->
      Process.sleep(50)
      {:ok, "done"}
    end

    assert {:ok, child_id} =
             RLM.Subagent.Broker.dispatch(
               parent_id,
               "task",
               [model_size: :small],
               lm_query_fn,
               timeout_ms: 1_000
             )

    assert is_binary(child_id)

    assert_eventually(fn ->
      case RLM.Subagent.Broker.poll(parent_id, child_id) do
        {:ok, %{state: :ok, payload: "done"}} -> true
        _ -> false
      end
    end)
  end

  test "cancel marks running jobs as cancelled" do
    parent_id = "parent_#{System.unique_integer([:positive, :monotonic])}"

    lm_query_fn = fn _text, _opts ->
      Process.sleep(5_000)
      {:ok, "never"}
    end

    assert {:ok, child_id} =
             RLM.Subagent.Broker.dispatch(
               parent_id,
               "task",
               [model_size: :small],
               lm_query_fn,
               timeout_ms: 10_000
             )

    assert {:ok, %{state: :cancelled, payload: "Subagent cancelled by parent"}} =
             RLM.Subagent.Broker.cancel(parent_id, child_id)

    assert {:ok, %{state: :cancelled, payload: "Subagent cancelled by parent"}} =
             RLM.Subagent.Broker.poll(parent_id, child_id)
  end

  test "cancel_all removes jobs for parent" do
    parent_id = "parent_#{System.unique_integer([:positive, :monotonic])}"

    lm_query_fn = fn _text, _opts ->
      Process.sleep(5_000)
      {:ok, "never"}
    end

    assert {:ok, _child_1} =
             RLM.Subagent.Broker.dispatch(
               parent_id,
               "task-1",
               [model_size: :small],
               lm_query_fn,
               timeout_ms: 10_000
             )

    assert {:ok, child_2} =
             RLM.Subagent.Broker.dispatch(
               parent_id,
               "task-2",
               [model_size: :small],
               lm_query_fn,
               timeout_ms: 10_000
             )

    assert :ok = RLM.Subagent.Broker.cancel_all(parent_id)

    assert_eventually(fn ->
      match?({:error, _}, RLM.Subagent.Broker.poll(parent_id, child_2))
    end)
  end

  test "assessment is required only for sampled and polled terminal jobs" do
    parent_id = "parent_#{System.unique_integer([:positive, :monotonic])}"

    lm_query_fn = fn _text, _opts ->
      {:ok, "done"}
    end

    assert {:ok, child_id} =
             RLM.Subagent.Broker.dispatch(
               parent_id,
               "task",
               [model_size: :small],
               lm_query_fn,
               timeout_ms: 1_000,
               assessment_sampled: true
             )

    assert_eventually(fn ->
      match?({:ok, %{state: :ok}}, RLM.Subagent.Broker.poll(parent_id, child_id))
    end)

    assert [%{child_agent_id: ^child_id}] = RLM.Subagent.Broker.pending_assessments(parent_id)

    assert {:ok, %{assessment: %{verdict: :satisfied, reason: "useful"}}} =
             RLM.Subagent.Broker.assess(parent_id, child_id, :satisfied, "useful")

    assert [] == RLM.Subagent.Broker.pending_assessments(parent_id)
  end

  test "assess fails while job is running" do
    parent_id = "parent_#{System.unique_integer([:positive, :monotonic])}"

    lm_query_fn = fn _text, _opts ->
      Process.sleep(200)
      {:ok, "done"}
    end

    assert {:ok, child_id} =
             RLM.Subagent.Broker.dispatch(
               parent_id,
               "task",
               [model_size: :small],
               lm_query_fn,
               timeout_ms: 1_000,
               assessment_sampled: true
             )

    assert {:error, reason} =
             RLM.Subagent.Broker.assess(parent_id, child_id, :dissatisfied, "too early")

    assert reason =~ "still running"
  end

  test "drain_updates returns terminal completion updates once" do
    parent_id = "parent_#{System.unique_integer([:positive, :monotonic])}"

    lm_query_fn = fn _text, _opts ->
      {:ok, "done"}
    end

    assert {:ok, child_id} =
             RLM.Subagent.Broker.dispatch(
               parent_id,
               "task",
               [model_size: :small],
               lm_query_fn,
               timeout_ms: 1_000
             )

    assert_eventually(fn ->
      case RLM.Subagent.Broker.drain_updates(parent_id) do
        [%{child_agent_id: ^child_id, state: :ok, completion_update: true}] -> true
        _ -> false
      end
    end)

    assert [] == RLM.Subagent.Broker.drain_updates(parent_id)
  end

  test "drain_updates sends an assessment reminder update after terminal poll" do
    parent_id = "parent_#{System.unique_integer([:positive, :monotonic])}"

    lm_query_fn = fn _text, _opts ->
      {:ok, "done"}
    end

    assert {:ok, child_id} =
             RLM.Subagent.Broker.dispatch(
               parent_id,
               "task",
               [model_size: :small],
               lm_query_fn,
               timeout_ms: 1_000,
               assessment_sampled: true
             )

    assert_eventually(fn ->
      case RLM.Subagent.Broker.drain_updates(parent_id) do
        [%{child_agent_id: ^child_id, completion_update: true, assessment_required: false}] ->
          true

        _ ->
          false
      end
    end)

    assert {:ok, %{state: :ok, assessment_required: true}} =
             RLM.Subagent.Broker.poll(parent_id, child_id)

    assert [
             %{
               child_agent_id: ^child_id,
               completion_update: false,
               assessment_update: true,
               assessment_required: true
             }
           ] = RLM.Subagent.Broker.drain_updates(parent_id)
  end

  test "drain_pending_assessments returns sampled missing assessments once" do
    parent_id = "parent_#{System.unique_integer([:positive, :monotonic])}"

    lm_query_fn = fn _text, _opts ->
      {:ok, "done"}
    end

    assert {:ok, child_id} =
             RLM.Subagent.Broker.dispatch(
               parent_id,
               "task",
               [model_size: :small],
               lm_query_fn,
               timeout_ms: 1_000,
               assessment_sampled: true
             )

    assert_eventually(fn ->
      match?(
        {:ok, %{state: :ok, assessment_required: true}},
        RLM.Subagent.Broker.poll(parent_id, child_id)
      )
    end)

    assert [%{child_agent_id: ^child_id, status: :ok}] =
             RLM.Subagent.Broker.drain_pending_assessments(parent_id)

    assert [] == RLM.Subagent.Broker.drain_pending_assessments(parent_id)
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
