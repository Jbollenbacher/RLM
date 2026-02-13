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
