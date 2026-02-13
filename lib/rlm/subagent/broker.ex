defmodule RLM.Subagent.Broker do
  @moduledoc "Async subagent job broker keyed by parent agent and child agent id."

  use GenServer

  @type parent_id :: String.t()
  @type child_id :: String.t()

  @type poll_state ::
          %{state: :running}
          | %{
              state: :ok | :error | :cancelled,
              payload: term(),
              assessment_required: boolean(),
              assessment_recorded: boolean(),
              assessment: map() | nil
            }

  @type assessment_verdict :: :satisfied | :dissatisfied

  @type push_update :: %{
          child_agent_id: child_id(),
          state: :ok | :error | :cancelled,
          payload: term(),
          assessment_required: boolean(),
          assessment_recorded: boolean(),
          assessment: map() | nil,
          completion_update: boolean(),
          assessment_update: boolean()
        }

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
          updated_at: integer(),
          assessment_sampled: boolean(),
          polled: boolean(),
          assessment: map() | nil,
          completion_notified: boolean(),
          assessment_prompt_pending: boolean()
        }

  @name __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @spec dispatch(parent_id(), String.t(), keyword(), function(), keyword()) ::
          {:ok, child_id()} | {:error, String.t()}
  def dispatch(parent_id, text, lm_opts, lm_query_fn, opts \\ [])
      when is_binary(parent_id) and is_binary(text) and is_list(lm_opts) and
             is_function(lm_query_fn, 2) do
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)
    child_id = Keyword.get(lm_opts, :child_agent_id, RLM.Helpers.unique_id("agent"))
    lm_opts = Keyword.put(lm_opts, :child_agent_id, child_id)
    assessment_sampled = Keyword.get(opts, :assessment_sampled, false)

    case Process.whereis(@name) do
      nil ->
        {:error, "Subagent broker is not running"}

      _ ->
        GenServer.call(
          @name,
          {:dispatch, parent_id, child_id, text, lm_opts, lm_query_fn, timeout_ms,
           assessment_sampled}
        )
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

  @spec assess(parent_id(), child_id(), assessment_verdict(), String.t()) ::
          {:ok, poll_state()} | {:error, String.t()}
  def assess(parent_id, child_id, verdict, reason \\ "")
      when is_binary(parent_id) and is_binary(child_id) and
             verdict in [:satisfied, :dissatisfied] and is_binary(reason) do
    case Process.whereis(@name) do
      nil -> {:error, "Subagent broker is not running"}
      _ -> GenServer.call(@name, {:assess, parent_id, child_id, verdict, reason})
    end
  end

  @spec pending_assessments(parent_id()) :: [map()]
  def pending_assessments(parent_id) when is_binary(parent_id) do
    case Process.whereis(@name) do
      nil -> []
      _ -> GenServer.call(@name, {:pending_assessments, parent_id})
    end
  end

  @spec drain_updates(parent_id()) :: [push_update()]
  def drain_updates(parent_id) when is_binary(parent_id) do
    case Process.whereis(@name) do
      nil -> []
      _ -> GenServer.call(@name, {:drain_updates, parent_id})
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
        {:dispatch, parent_id, child_id, text, lm_opts, lm_query_fn, timeout_ms,
         assessment_sampled},
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
          updated_at: now,
          assessment_sampled: assessment_sampled,
          polled: false,
          assessment: nil,
          completion_notified: false,
          assessment_prompt_pending: false
        }

        state = put_job(state, key, job)
        {:reply, {:ok, child_id}, state}

      _existing ->
        {:reply, {:error, "Subagent id already exists: #{child_id}"}, state}
    end
  end

  def handle_call({:poll, parent_id, child_id}, _from, state) do
    key = {parent_id, child_id}

    case Map.get(state.jobs, key) do
      nil ->
        {:reply, {:error, "Unknown lm_query id: #{child_id}"}, state}

      job ->
        {state, job} = mark_polled(state, key, job)
        {:reply, {:ok, to_poll_state(job)}, state}
    end
  end

  def handle_call({:cancel, parent_id, child_id}, _from, state) do
    key = {parent_id, child_id}

    case Map.get(state.jobs, key) do
      nil ->
        {:reply, {:error, "Unknown lm_query id: #{child_id}"}, state}

      %{status: :running} = job ->
        {state, job} = mark_polled(state, key, job)
        state = cancel_job(state, key, job, "Subagent cancelled by parent")
        {:reply, {:ok, to_poll_state(Map.fetch!(state.jobs, key))}, state}

      job ->
        {state, job} = mark_polled(state, key, job)
        {:reply, {:ok, to_poll_state(job)}, state}
    end
  end

  def handle_call({:assess, parent_id, child_id, verdict, reason}, _from, state) do
    key = {parent_id, child_id}

    case Map.get(state.jobs, key) do
      nil ->
        {:reply, {:error, "Unknown lm_query id: #{child_id}"}, state}

      %{status: :running} ->
        {:reply,
         {:error,
          "Cannot assess lm_query id `#{child_id}` while subagent is still running. Wait for termination via poll_lm_query/await_lm_query/cancel_lm_query first."},
         state}

      job ->
        now = System.system_time(:millisecond)

        assessment = %{
          verdict: verdict,
          reason: reason,
          ts: now
        }

        job = %{job | assessment: assessment, assessment_prompt_pending: false, updated_at: now}
        state = put_job(state, key, job)
        {:reply, {:ok, to_poll_state(job)}, state}
    end
  end

  def handle_call({:pending_assessments, parent_id}, _from, state) do
    pending =
      state.by_parent
      |> Map.get(parent_id, MapSet.new())
      |> MapSet.to_list()
      |> Enum.map(fn child_id ->
        key = {parent_id, child_id}
        Map.get(state.jobs, key)
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&(assessment_required?(&1) and is_nil(&1.assessment)))
      |> Enum.map(fn job ->
        %{
          child_agent_id: job.child_id,
          status: job.status
        }
      end)

    {:reply, pending, state}
  end

  def handle_call({:drain_updates, parent_id}, _from, state) do
    child_ids =
      state.by_parent
      |> Map.get(parent_id, MapSet.new())
      |> MapSet.to_list()

    {state, updates} =
      Enum.reduce(child_ids, {state, []}, fn child_id, {acc_state, acc_updates} ->
        key = {parent_id, child_id}
        job = Map.get(acc_state.jobs, key)

        if is_nil(job) or job.status == :running do
          {acc_state, acc_updates}
        else
          completion_update = not Map.get(job, :completion_notified, false)
          assessment_update = Map.get(job, :assessment_prompt_pending, false)

          if completion_update or assessment_update do
            update =
              build_push_update(
                job,
                completion_update: completion_update,
                assessment_update: assessment_update
              )

            now = System.system_time(:millisecond)

            updated_job = %{
              job
              | completion_notified: true,
                assessment_prompt_pending: false,
                updated_at: now
            }

            {put_job(acc_state, key, updated_job), acc_updates ++ [update]}
          else
            {acc_state, acc_updates}
          end
        end
      end)

    updates = Enum.sort_by(updates, &{Map.get(&1, :child_agent_id), Map.get(&1, :state)})
    {:reply, updates, state}
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

  defp finalize_job(state, key, job, status, payload)
       when status in [:ok, :error, :cancelled] do
    now = System.system_time(:millisecond)
    timeout_ref = Map.get(job, :timeout_ref)
    if is_reference(timeout_ref), do: Process.cancel_timer(timeout_ref)
    monitor_ref = Map.get(job, :monitor_ref)
    if is_reference(monitor_ref), do: Process.demonitor(monitor_ref, [:flush])

    updated = %{
      job
      | status: status,
        payload: payload,
        worker_pid: nil,
        monitor_ref: nil,
        timeout_ref: nil,
        completion_notified: false,
        assessment_prompt_pending:
          assessment_required?(%{job | status: status, payload: payload}),
        updated_at: now
    }

    put_job(state, key, updated)
  end

  defp cancel_job(state, key, job, payload, status \\ :cancelled)
       when status in [:cancelled, :error] do
    if is_pid(job.worker_pid) and Process.alive?(job.worker_pid),
      do: Process.exit(job.worker_pid, :kill)

    finalize_job(state, key, job, status, payload)
  end

  defp put_job(state, {parent_id, child_id} = key, job) do
    child_set =
      state.by_parent
      |> Map.get(parent_id, MapSet.new())
      |> MapSet.put(child_id)

    %{
      state
      | jobs: Map.put(state.jobs, key, job),
        by_parent: Map.put(state.by_parent, parent_id, child_set)
    }
  end

  defp delete_parent(state, parent_id) do
    child_set = Map.get(state.by_parent, parent_id, MapSet.new())

    jobs =
      Enum.reduce(child_set, state.jobs, fn child_id, acc ->
        Map.delete(acc, {parent_id, child_id})
      end)

    %{state | jobs: jobs, by_parent: Map.delete(state.by_parent, parent_id)}
  end

  defp mark_polled(state, _key, %{polled: true} = job), do: {state, job}

  defp mark_polled(state, key, job) do
    now = System.system_time(:millisecond)

    updated =
      %{
        job
        | polled: true,
          assessment_prompt_pending: assessment_required?(%{job | polled: true}),
          updated_at: now
      }

    {put_job(state, key, updated), updated}
  end

  defp to_poll_state(%{status: :running}) do
    %{state: :running}
  end

  defp to_poll_state(job) do
    %{
      state: job.status,
      payload: job.payload,
      assessment_required: assessment_required?(job),
      assessment_recorded: not is_nil(job.assessment),
      assessment: normalize_assessment(job.assessment)
    }
  end

  defp normalize_assessment(nil), do: nil

  defp normalize_assessment(assessment) do
    %{
      verdict: Map.get(assessment, :verdict),
      reason: Map.get(assessment, :reason),
      ts: Map.get(assessment, :ts)
    }
  end

  defp assessment_required?(job) do
    job.assessment_sampled and job.polled and job.status in [:ok, :error, :cancelled]
  end

  defp build_push_update(job, opts) do
    %{
      child_agent_id: job.child_id,
      state: job.status,
      payload: job.payload,
      assessment_required: assessment_required?(job),
      assessment_recorded: not is_nil(job.assessment),
      assessment: normalize_assessment(job.assessment),
      completion_update: Keyword.get(opts, :completion_update, false),
      assessment_update: Keyword.get(opts, :assessment_update, false)
    }
  end
end
