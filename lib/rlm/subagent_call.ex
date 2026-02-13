defmodule RLM.Subagent.Call do
  @moduledoc "Supervised wrapper for subagent calls used by lm_query bridge handling."

  @watcher_poll_attempts 20
  @watcher_poll_interval_ms 10

  @type result ::
          {:ok, term()}
          | {:error, term()}
          | {:error_raise, String.t()}

  @spec execute((String.t(), keyword() -> any()), String.t(), keyword(), keyword()) :: result()
  def execute(lm_query_fn, text, lm_opts, opts \\ [])
      when is_function(lm_query_fn, 2) and is_binary(text) and is_list(lm_opts) and is_list(opts) do
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)
    child_agent_id = Keyword.get(opts, :child_agent_id, RLM.Helpers.unique_id("agent"))
    parent = self()
    result_ref = make_ref()
    lm_opts = Keyword.put(lm_opts, :child_agent_id, child_agent_id)

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        result = lm_query_fn.(text, lm_opts)
        send(parent, {:subagent_result, result_ref, result})
      end)

    receive do
      {:subagent_result, ^result_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        normalize_result(result)

      {:DOWN, ^monitor_ref, :process, ^pid, :normal} ->
        receive do
          {:subagent_result, ^result_ref, result} ->
            normalize_result(result)
        after
          5 ->
            {:error, "Subagent finished without producing a result"}
        end

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        crash_result(child_agent_id, reason)
    after
      timeout_ms ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
            timeout_result(child_agent_id, timeout_ms, reason)
        after
          50 ->
            timeout_result(child_agent_id, timeout_ms, :timeout)
        end
    end
  end

  defp normalize_result({:ok, payload}), do: {:ok, payload}
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result(other), do: {:error, "Invalid lm_query return: #{inspect(other)}"}

  defp crash_result(child_agent_id, reason) do
    case watcher_pid_down_reason(child_agent_id) do
      {:ok, watcher_reason} ->
        {:error_raise, "Subagent crashed before returning a result (watcher): #{watcher_reason}"}

      :error ->
        {:error, "Subagent process crashed before returning a result: #{inspect(reason)}"}
    end
  end

  defp timeout_result(child_agent_id, timeout_ms, reason) do
    case watcher_pid_down_reason(child_agent_id) do
      {:ok, watcher_reason} ->
        {:error_raise, "Subagent crashed before returning a result (watcher): #{watcher_reason}"}

      :error ->
        {:error, "lm_query timed out after #{timeout_ms}ms (reason: #{inspect(reason)})"}
    end
  end

  defp watcher_pid_down_reason(child_agent_id, attempts \\ @watcher_poll_attempts)
  defp watcher_pid_down_reason(_child_agent_id, attempts) when attempts <= 0, do: :error

  defp watcher_pid_down_reason(child_agent_id, attempts) do
    case latest_pid_down_event(child_agent_id) do
      {:ok, reason} ->
        {:ok, reason}

      :error ->
        Process.sleep(@watcher_poll_interval_ms)
        watcher_pid_down_reason(child_agent_id, attempts - 1)
    end
  end

  defp latest_pid_down_event(child_agent_id) do
    if Process.whereis(RLM.Observability.Store) do
      event =
        RLM.Observability.Store.list_events(
          agent_id: child_agent_id,
          since_ts: 0,
          since_id: 0,
          limit: 200
        )
        |> Enum.reverse()
        |> Enum.find(fn evt ->
          evt.type == :agent_end and Map.get(evt.payload, :source) == :pid_down
        end)

      case event do
        nil -> :error
        %{payload: payload} -> {:ok, to_string(Map.get(payload, :reason, "unknown"))}
      end
    else
      :error
    end
  end
end
