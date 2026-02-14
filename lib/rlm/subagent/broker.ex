defmodule RLM.Subagent.Broker do
  @moduledoc "Async subagent job broker keyed by parent agent and child agent id."

  use GenServer

  @default_max_jobs_per_parent 2_000

  @type parent_id :: String.t()
  @type child_id :: String.t()

  @type poll_state ::
          %{state: :running}
          | %{
              state: :ok | :error | :cancelled,
              payload: term(),
              assessment_required: boolean(),
              assessment_recorded: boolean(),
              assessment: map() | nil,
              pending_surveys: [map()],
              answered_surveys: [map()]
            }

  @type push_update :: %{
          child_agent_id: child_id(),
          state: :ok | :error | :cancelled,
          payload: term(),
          assessment_required: boolean(),
          assessment_recorded: boolean(),
          assessment: map() | nil,
          pending_surveys: [map()],
          answered_surveys: [map()],
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
          assessment_missing_emitted: boolean(),
          completion_notified: boolean(),
          assessment_prompt_pending: boolean(),
          surveys: map(),
          survey_requested_notified: boolean()
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

    call_if_running(fn ->
      GenServer.call(
        @name,
        {:dispatch, parent_id, child_id, text, lm_opts, lm_query_fn, timeout_ms,
         assessment_sampled}
      )
    end)
  end

  @spec poll(parent_id(), child_id()) :: {:ok, poll_state()} | {:error, String.t()}
  def poll(parent_id, child_id) when is_binary(parent_id) and is_binary(child_id) do
    call_if_running(fn -> GenServer.call(@name, {:poll, parent_id, child_id}) end)
  end

  @spec cancel(parent_id(), child_id()) :: {:ok, poll_state()} | {:error, String.t()}
  def cancel(parent_id, child_id) when is_binary(parent_id) and is_binary(child_id) do
    call_if_running(fn -> GenServer.call(@name, {:cancel, parent_id, child_id}) end)
  end

  @spec answer_survey(parent_id(), child_id(), String.t(), term(), String.t()) ::
          {:ok, poll_state()} | {:error, String.t()}
  def answer_survey(parent_id, child_id, survey_id, response, reason \\ "")
      when is_binary(parent_id) and is_binary(child_id) and is_binary(survey_id) and
             is_binary(reason) do
    call_if_running(fn ->
      GenServer.call(@name, {:answer_survey, parent_id, child_id, survey_id, response, reason})
    end)
  end

  @spec pending_assessments(parent_id()) :: [map()]
  def pending_assessments(parent_id) when is_binary(parent_id) do
    call_if_running(fn -> GenServer.call(@name, {:pending_assessments, parent_id}) end, [])
  end

  @spec drain_pending_assessments(parent_id()) :: [map()]
  def drain_pending_assessments(parent_id) when is_binary(parent_id) do
    call_if_running(fn -> GenServer.call(@name, {:drain_pending_assessments, parent_id}) end, [])
  end

  @spec drain_updates(parent_id()) :: [push_update()]
  def drain_updates(parent_id) when is_binary(parent_id) do
    call_if_running(fn -> GenServer.call(@name, {:drain_updates, parent_id}) end, [])
  end

  @spec cancel_all(parent_id()) :: :ok
  def cancel_all(parent_id) when is_binary(parent_id) do
    cast_if_running(fn -> GenServer.cast(@name, {:cancel_all, parent_id}) end)
  end

  @impl true
  def init(opts) do
    max_jobs_per_parent =
      Keyword.get(
        opts,
        :max_jobs_per_parent,
        Application.get_env(
          :rlm,
          :subagent_broker_max_jobs_per_parent,
          @default_max_jobs_per_parent
        )
      )

    {:ok, %{jobs: %{}, by_parent: %{}, max_jobs_per_parent: max_jobs_per_parent}}
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
          assessment_missing_emitted: false,
          completion_notified: false,
          assessment_prompt_pending: false,
          surveys: initial_surveys(),
          survey_requested_notified: false
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

  def handle_call(
        {:answer_survey, parent_id, child_id, survey_id, response, reason},
        _from,
        state
      ) do
    key = {parent_id, child_id}

    case Map.get(state.jobs, key) do
      nil ->
        {:reply, {:error, "Unknown lm_query id: #{child_id}"}, state}

      %{status: :running} ->
        {:reply,
         {:error,
          "Cannot answer survey for lm_query id `#{child_id}` while subagent is still running. Wait for termination via poll_lm_query/await_lm_query/cancel_lm_query first."},
         state}

      job ->
        with {surveys, _survey} <- ensure_job_survey(job, survey_id),
             {:ok, surveys, _answered_survey} <-
               RLM.Survey.answer(surveys, survey_id, response, reason) do
          now = System.system_time(:millisecond)
          compat_assessment = compat_assessment_from_surveys(surveys)

          job = %{
            job
            | surveys: surveys,
              assessment: compat_assessment,
              assessment_prompt_pending: required_survey_pending?(surveys),
              updated_at: now
          }

          state = put_job(state, key, job)
          {:reply, {:ok, to_poll_state(job)}, state}
        else
          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:pending_assessments, parent_id}, _from, state) do
    pending =
      state
      |> parent_job_entries(parent_id)
      |> Enum.map(&elem(&1, 1))
      |> Enum.filter(&required_subagent_survey_pending?/1)
      |> Enum.map(&pending_required_survey_summary/1)

    {:reply, pending, state}
  end

  def handle_call({:drain_pending_assessments, parent_id}, _from, state) do
    pending =
      state
      |> parent_job_entries(parent_id)
      |> Enum.filter(fn {_key, job} ->
        required_subagent_survey_pending?(job) and
          not job.assessment_missing_emitted
      end)

    state =
      Enum.reduce(pending, state, fn {key, job}, acc ->
        now = System.system_time(:millisecond)
        updated = %{job | assessment_missing_emitted: true, updated_at: now}
        put_job(acc, key, updated)
      end)

    response = Enum.map(pending, fn {_key, job} -> pending_required_survey_summary(job) end)

    {:reply, response, state}
  end

  def handle_call({:drain_updates, parent_id}, _from, state) do
    {state, updates} =
      state
      |> parent_job_entries(parent_id)
      |> Enum.reduce({state, []}, fn {key, job}, {acc_state, acc_updates} ->
        if job.status == :running do
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

            {put_job(acc_state, key, updated_job), [update | acc_updates]}
          else
            {acc_state, acc_updates}
          end
        end
      end)

    updates =
      updates
      |> Enum.reverse()
      |> Enum.sort_by(&{Map.get(&1, :child_agent_id), Map.get(&1, :state)})

    {:reply, updates, state}
  end

  @impl true
  def handle_cast({:cancel_all, parent_id}, state) do
    state =
      state
      |> parent_job_entries(parent_id)
      |> Enum.reduce(state, fn {key, _job}, acc ->
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
    candidate = %{job | status: status, payload: payload}
    surveys = refresh_job_surveys(candidate)
    assessment_prompt_pending = required_survey_pending?(surveys)
    compat_assessment = compat_assessment_from_surveys(surveys)

    survey_requested_notified =
      maybe_emit_survey_requested(
        candidate.parent_id,
        candidate.child_id,
        surveys,
        candidate.polled,
        candidate.survey_requested_notified
      )

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
        assessment_prompt_pending: assessment_prompt_pending,
        assessment: compat_assessment,
        surveys: surveys,
        survey_requested_notified: survey_requested_notified,
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

    state = %{
      state
      | jobs: Map.put(state.jobs, key, job),
        by_parent: Map.put(state.by_parent, parent_id, child_set)
    }

    prune_parent_jobs(state, parent_id)
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
    candidate = %{job | polled: true}
    surveys = refresh_job_surveys(candidate)
    assessment_prompt_pending = required_survey_pending?(surveys)
    compat_assessment = compat_assessment_from_surveys(surveys)

    survey_requested_notified =
      maybe_emit_survey_requested(
        candidate.parent_id,
        candidate.child_id,
        surveys,
        true,
        candidate.survey_requested_notified
      )

    now = System.system_time(:millisecond)

    updated =
      %{
        candidate
        | polled: true,
          assessment_prompt_pending: assessment_prompt_pending,
          assessment: compat_assessment,
          surveys: surveys,
          survey_requested_notified: survey_requested_notified,
          updated_at: now
      }

    {put_job(state, key, updated), updated}
  end

  defp to_poll_state(%{status: :running}) do
    %{state: :running}
  end

  defp to_poll_state(job) do
    survey_snapshot = survey_snapshot(job)
    payload = terminal_job_payload(job, survey_snapshot)

    Map.put(payload, :state, job.status)
  end

  defp normalize_assessment(nil), do: nil

  defp normalize_assessment(assessment) do
    %{
      verdict: Map.get(assessment, :verdict),
      reason: Map.get(assessment, :reason),
      ts: Map.get(assessment, :ts)
    }
  end

  defp prune_parent_jobs(state, parent_id) do
    child_ids =
      state.by_parent
      |> Map.get(parent_id, MapSet.new())
      |> MapSet.to_list()

    overflow = length(child_ids) - state.max_jobs_per_parent

    if overflow <= 0 do
      state
    else
      evict_ids =
        child_ids
        |> Enum.map(fn child_id ->
          {child_id, Map.get(state.jobs, {parent_id, child_id})}
        end)
        |> Enum.reject(fn {_child_id, job} -> is_nil(job) end)
        |> Enum.filter(fn {_child_id, job} -> evictable_job?(job) end)
        |> Enum.sort_by(fn {_child_id, job} -> {job.updated_at || 0, job.inserted_at || 0} end)
        |> Enum.take(overflow)
        |> Enum.map(&elem(&1, 0))

      Enum.reduce(evict_ids, state, fn child_id, acc ->
        delete_job(acc, parent_id, child_id)
      end)
    end
  end

  defp delete_job(state, parent_id, child_id) do
    key = {parent_id, child_id}
    jobs = Map.delete(state.jobs, key)

    by_parent =
      state.by_parent
      |> Map.get(parent_id, MapSet.new())
      |> MapSet.delete(child_id)
      |> case do
        set ->
          if MapSet.size(set) == 0 do
            Map.delete(state.by_parent, parent_id)
          else
            Map.put(state.by_parent, parent_id, set)
          end
      end

    %{state | jobs: jobs, by_parent: by_parent}
  end

  defp evictable_job?(job) do
    job.status in [:ok, :error, :cancelled] and
      job.completion_notified and
      not required_survey_pending?(refresh_job_surveys(job))
  end

  defp build_push_update(job, opts) do
    survey_snapshot = survey_snapshot(job)
    payload = terminal_job_payload(job, survey_snapshot)

    Map.merge(payload, %{
      child_agent_id: job.child_id,
      state: job.status,
      completion_update: Keyword.get(opts, :completion_update, false),
      assessment_update: Keyword.get(opts, :assessment_update, false)
    })
  end

  defp initial_surveys do
    RLM.Survey.init_state()
    |> RLM.Survey.ensure_subagent_usefulness(false)
  end

  defp refresh_job_surveys(job) do
    required = job.assessment_sampled and job.polled and job.status in [:ok, :error, :cancelled]
    job.surveys |> ensure_job_surveys_present() |> RLM.Survey.ensure_subagent_usefulness(required)
  end

  defp ensure_job_surveys_present(nil), do: initial_surveys()
  defp ensure_job_surveys_present(surveys) when is_map(surveys), do: surveys

  defp required_survey_pending?(surveys) do
    surveys
    |> RLM.Survey.pending_required()
    |> Enum.any?()
  end

  defp required_subagent_survey_pending?(job) do
    surveys = refresh_job_surveys(job)
    required_subagent_survey_pending_from_surveys?(surveys)
  end

  defp required_subagent_survey_pending_from_surveys?(surveys) when is_map(surveys) do
    Enum.any?(RLM.Survey.pending_required(surveys), fn survey ->
      Map.get(survey, :id) == RLM.Survey.subagent_usefulness_id()
    end)
  end

  defp survey_snapshot(job) do
    surveys = refresh_job_surveys(job)

    %{
      pending_surveys: serialize_surveys(RLM.Survey.pending_all(surveys)),
      answered_surveys: serialize_surveys(RLM.Survey.answered_all(surveys)),
      assessment_required: required_subagent_survey_pending_from_surveys?(surveys)
    }
  end

  defp terminal_job_payload(job, survey_snapshot) do
    %{
      payload: job.payload,
      assessment_required: survey_snapshot.assessment_required,
      assessment_recorded: not is_nil(job.assessment),
      assessment: normalize_assessment(job.assessment),
      pending_surveys: survey_snapshot.pending_surveys,
      answered_surveys: survey_snapshot.answered_surveys
    }
  end

  defp serialize_surveys(surveys) when is_list(surveys) do
    Enum.map(surveys, fn survey ->
      %{
        id: Map.get(survey, :id),
        scope: Map.get(survey, :scope),
        question: Map.get(survey, :question),
        required: Map.get(survey, :required, false),
        status: Map.get(survey, :status),
        response: Map.get(survey, :response),
        reason: get_in(survey, [:metadata, :reason])
      }
    end)
  end

  defp ensure_job_survey(job, survey_id) do
    surveys =
      job
      |> Map.get(:surveys, %{})
      |> ensure_job_surveys_present()

    RLM.Survey.ensure_survey(surveys, survey_definition(job, survey_id))
  end

  # Compatibility projection for existing poll/update payload fields.
  defp compat_assessment_from_surveys(surveys) do
    case Map.get(surveys, RLM.Survey.subagent_usefulness_id()) do
      %{response: verdict, metadata: metadata} when verdict in [:satisfied, :dissatisfied] ->
        %{
          verdict: verdict,
          reason: to_string(Map.get(metadata, :reason, "")),
          ts: System.system_time(:millisecond)
        }

      _ ->
        nil
    end
  end

  defp maybe_emit_survey_requested(parent_id, child_id, surveys, true, false) do
    case Map.get(surveys, RLM.Survey.subagent_usefulness_id()) do
      %{required: true} = survey ->
        RLM.Observability.survey_requested(parent_id, survey.id, %{
          child_agent_id: child_id,
          required: true,
          question: survey.question,
          scope: survey.scope
        })

        true

      _ ->
        false
    end
  end

  defp maybe_emit_survey_requested(_parent_id, _child_id, _surveys, _polled, notified),
    do: notified

  defp parent_job_entries(state, parent_id) do
    state.by_parent
    |> Map.get(parent_id, MapSet.new())
    |> Enum.map(fn child_id ->
      key = {parent_id, child_id}
      {key, Map.get(state.jobs, key)}
    end)
    |> Enum.reject(fn {_key, job} -> is_nil(job) end)
  end

  defp pending_required_survey_summary(job) do
    %{child_agent_id: job.child_id, status: job.status}
  end

  defp survey_definition(job, survey_id) do
    if survey_id == RLM.Survey.subagent_usefulness_id() do
      required = job.assessment_sampled and job.polled and job.status in [:ok, :error, :cancelled]

      %{
        id: RLM.Survey.subagent_usefulness_id(),
        scope: :child,
        question: "Rate subagent usefulness",
        required: required,
        response_schema: :verdict
      }
    else
      %{
        id: survey_id,
        scope: :child,
        question: "Survey response",
        required: false,
        response_schema: nil,
        metadata: %{}
      }
    end
  end

  defp call_if_running(fun, fallback \\ {:error, "Subagent broker is not running"}) do
    if Process.whereis(@name), do: fun.(), else: fallback
  end

  defp cast_if_running(fun) do
    if Process.whereis(@name), do: fun.(), else: :ok
  end
end
