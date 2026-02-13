defmodule RLM.Subagent.Broker do
  @moduledoc "Async subagent job broker keyed by parent agent and child agent id."

  use GenServer

  @type parent_id :: String.t()
  @type child_id :: String.t()

  @type poll_state ::
          %{state: :running}
          | %{state: :ok, payload: term()}
          | %{state: :error, payload: term()}
          | %{state: :cancelled, payload: term()}

  @type job :: %{
          parent_id: parent_id(),
          child_id: child_id(),
          status: :running | :ok | :error | :cancelled,
          payload: term() | nil,
          worker_pid: pid() | nil,
          monitor_ref: reference() | nil,
          timeout_ref: reference() | nil,
          timeout_ms: pos_integer(),
          inserted_at: integer(),
          updated_at: integer()
        }

  @name __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @spec dispatch(parent_id(), String.t(), keyword(), function(), keyword()) ::
          {:ok, child_id()} | {:error, String.t()}
  def dispatch(parent_id, text, lm_opts, lm_query_fn, opts \\ [])
      when is_binary(parent_id) and is_binary(text) and is_list(lm_opts) and is_function(lm_query_fn, 2) do
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)
    child_id = Keyword.get(lm_opts, :child_agent_id, RLM.Helpers.unique_id("agent"))
    lm_opts = Keyword.put(lm_opts, :child_agent_id, child_id)

    case Process.whereis(@name) do
      nil ->
        {:error, "Subagent broker is not running"}

      _ ->
        GenServer.call(@name, {:dispatch, parent_id, child_id, text, lm_opts, lm_query_fn, timeout_ms})
    end
  end

  @spec poll(parent_id(), child_id()) :: {:ok, poll_state()} | {:error, String.t()}
  def poll(parent_id, child_id) when is_binary(parent_id) and is_binary(child_id) do
    case Process.whereis(@name) do
      nil -> {:error, "Subagent broker is not running"}
      _ -> GenServer.call(@name, {:poll, parent_id, child_id})
    end
  end

  @spec cancel(parent_id(), child_id()) :: {:ok, poll_state()} | {:error, String.t()}
  def cancel(parent_id, child_id) when is_binary(parent_id) and is_binary(child_id) do
    case Process.whereis(@name) do
      nil -> {:error, "Subagent broker is not running"}
      _ -> GenServer.call(@name, {:cancel, parent_id, child_id})
    end
  end

  @spec cancel_all(parent_id()) :: :ok
  def cancel_all(parent_id) when is_binary(parent_id) do
    case Process.whereis(@name) do
      nil -> :ok
      _ -> GenServer.cast(@name, {:cancel_all, parent_id})
    end
  end

  @impl true
  def init(_opts) do
    {:ok, %{jobs: %{}, by_parent: %{}}}
  end

  @impl true
  def handle_call(
        {:dispatch, parent_id, child_id, text, lm_opts, lm_query_fn, timeout_ms},
        _from,
        state
      ) do
    key = {parent_id, child_id}

    case Map.get(state.jobs, key) do
      nil ->
        now = System.system_time(:millisecond)

        {worker_pid, monitor_ref} =
          spawn_monitor(fn ->
            result =
              try do
                lm_query_fn.(text, lm_opts)
              rescue
                exception ->
                  {:error, Exception.format(:error, exception, __STACKTRACE__)}
              catch
                kind, reason ->
                  {:error, Exception.format(kind, reason, __STACKTRACE__)}
              end

            send(@name, {:job_result, key, result})
          end)

        timeout_ref = Process.send_after(self(), {:job_timeout, key}, timeout_ms)

        job = %{
          parent_id: parent_id,
          child_id: child_id,
          status: :running,
          payload: nil,
          worker_pid: worker_pid,
          monitor_ref: monitor_ref,
          timeout_ref: timeout_ref,
          timeout_ms: timeout_ms,
          inserted_at: now,
          updated_at: now
        }

        state = put_job(state, key, job)
        {:reply, {:ok, child_id}, state}

      _existing ->
        {:reply, {:error, "Subagent id already exists: #{child_id}"}, state}
    end
  end

  def handle_call({:poll, parent_id, child_id}, _from, state) do
    key = {parent_id, child_id}

    reply =
      case Map.get(state.jobs, key) do
        nil ->
          {:error, "Unknown lm_query id: #{child_id}"}

        %{status: :running} ->
          {:ok, %{state: :running}}

        %{status: :ok, payload: payload} ->
          {:ok, %{state: :ok, payload: payload}}

        %{status: :error, payload: payload} ->
          {:ok, %{state: :error, payload: payload}}

        %{status: :cancelled, payload: payload} ->
          {:ok, %{state: :cancelled, payload: payload}}
      end

    {:reply, reply, state}
  end

  def handle_call({:cancel, parent_id, child_id}, _from, state) do
    key = {parent_id, child_id}

    case Map.get(state.jobs, key) do
      nil ->
        {:reply, {:error, "Unknown lm_query id: #{child_id}"}, state}

      %{status: :running} = job ->
        state = cancel_job(state, key, job, "Subagent cancelled by parent")
        {:reply, {:ok, %{state: :cancelled, payload: "Subagent cancelled by parent"}}, state}

      %{status: :ok, payload: payload} ->
        {:reply, {:ok, %{state: :ok, payload: payload}}, state}

      %{status: :error, payload: payload} ->
        {:reply, {:ok, %{state: :error, payload: payload}}, state}

      %{status: :cancelled, payload: payload} ->
        {:reply, {:ok, %{state: :cancelled, payload: payload}}, state}
    end
  end

  @impl true
  def handle_cast({:cancel_all, parent_id}, state) do
    child_ids = state.by_parent |> Map.get(parent_id, MapSet.new()) |> MapSet.to_list()

    state =
      Enum.reduce(child_ids, state, fn child_id, acc ->
        key = {parent_id, child_id}

        case Map.get(acc.jobs, key) do
          %{status: :running} = job ->
            cancel_job(acc, key, job, "Parent agent ended")

          _ ->
            acc
        end
      end)
      |> delete_parent(parent_id)

    {:noreply, state}
  end

  @impl true
  def handle_info({:job_result, key, result}, state) do
    case Map.get(state.jobs, key) do
      %{status: :running} = job ->
        state = finalize_job(state, key, job, normalize_result(result))
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:job_timeout, key}, state) do
    case Map.get(state.jobs, key) do
      %{status: :running, timeout_ms: timeout_ms} = job ->
        state =
          cancel_job(state, key, job, "lm_query timed out after #{timeout_ms}ms", :error)

        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    key =
      Enum.find_value(state.jobs, fn {key, job} ->
        if job.monitor_ref == ref, do: key, else: nil
      end)

    if key do
      case Map.get(state.jobs, key) do
        %{status: :running} = job ->
          state =
            finalize_job(
              state,
              key,
              job,
              {:error, "Subagent process crashed before returning a result: #{inspect(reason)}"}
            )

          {:noreply, state}

        _ ->
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  defp normalize_result({:ok, payload}), do: {:ok, payload}
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result(other), do: {:error, "Invalid lm_query return: #{inspect(other)}"}

  defp finalize_job(state, key, job, {:ok, payload}) do
    finalize_job(state, key, job, :ok, payload)
  end

  defp finalize_job(state, key, job, {:error, payload}) do
    finalize_job(state, key, job, :error, payload)
  end

  defp finalize_job(state, key, job, status, payload) do
    cancel_timeout(job.timeout_ref)
    demonitor_job(job.monitor_ref)

    updated =
      job
      |> Map.put(:status, status)
      |> Map.put(:payload, payload)
      |> Map.put(:worker_pid, nil)
      |> Map.put(:monitor_ref, nil)
      |> Map.put(:timeout_ref, nil)
      |> Map.put(:updated_at, System.system_time(:millisecond))

    put_job(state, key, updated)
  end

  defp cancel_job(state, key, job, payload, status \\ :cancelled) do
    if is_pid(job.worker_pid) and Process.alive?(job.worker_pid) do
      Process.exit(job.worker_pid, :kill)
    end

    finalize_job(state, key, job, status, payload)
  end

  defp put_job(state, {parent_id, child_id} = key, job) do
    by_parent =
      Map.update(state.by_parent, parent_id, MapSet.new([child_id]), fn ids ->
        MapSet.put(ids, child_id)
      end)

    %{state | jobs: Map.put(state.jobs, key, job), by_parent: by_parent}
  end

  defp delete_parent(state, parent_id) do
    child_ids = state.by_parent |> Map.get(parent_id, MapSet.new()) |> MapSet.to_list()

    jobs =
      Enum.reduce(child_ids, state.jobs, fn child_id, acc ->
        Map.delete(acc, {parent_id, child_id})
      end)

    %{state | jobs: jobs, by_parent: Map.delete(state.by_parent, parent_id)}
  end

  defp cancel_timeout(nil), do: :ok

  defp cancel_timeout(ref) when is_reference(ref) do
    _ = Process.cancel_timer(ref)
    :ok
  end

  defp demonitor_job(nil), do: :ok

  defp demonitor_job(ref) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    :ok
  end
end
