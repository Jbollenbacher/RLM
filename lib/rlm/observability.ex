defmodule RLM.Observability do
  @moduledoc "Optional observability hooks and embedded UI."

  @enabled_key {__MODULE__, :enabled}

  @spec start(keyword()) :: :ok | {:error, term()}
  def start(opts \\ []) do
    with :ok <- start_supervisor(opts),
         :ok <- RLM.Observability.Telemetry.attach() do
      :persistent_term.put(@enabled_key, true)
      :ok
    end
  end

  @spec enabled?() :: boolean()
  def enabled? do
    :persistent_term.get(@enabled_key, false)
  end

  @spec emit([atom()], map(), map()) :: :ok
  def emit(event, measurements, metadata) do
    if enabled?() do
      :telemetry.execute(event, measurements, metadata)
    end

    :ok
  end

  @spec span(atom(), map(), (-> term()), (term() -> atom())) :: term()
  def span(event, metadata, fun, status_fun \\ &default_status/1)
      when is_function(fun, 0) and is_function(status_fun, 1) do
    if enabled?() and Map.get(metadata, :agent_id) do
      start_time = System.monotonic_time()
      emit([:rlm, event, :start], %{system_time: System.system_time(:millisecond)}, metadata)
      result = fun.()

      duration_ms =
        System.monotonic_time()
        |> Kernel.-(start_time)
        |> System.convert_time_unit(:native, :millisecond)

      emit(
        [:rlm, event, :stop],
        %{duration_ms: duration_ms},
        Map.put(metadata, :status, status_fun.(result))
      )

      result
    else
      fun.()
    end
  end

  defp default_status({:ok, _}), do: :ok
  defp default_status(_), do: :error

  @spec iteration_start(String.t(), non_neg_integer()) :: integer()
  def iteration_start(_agent_id, _iteration) do
    System.monotonic_time()
  end

  @spec iteration_stop(String.t(), non_neg_integer(), atom(), integer()) :: :ok
  def iteration_stop(agent_id, iteration, status, start_time) do
    if enabled?() and agent_id do
      duration_ms =
        System.monotonic_time()
        |> Kernel.-(start_time)
        |> System.convert_time_unit(:native, :millisecond)

      emit([:rlm, :iteration, :stop], %{duration_ms: duration_ms}, %{
        agent_id: agent_id,
        iteration: iteration,
        status: status
      })
    end

    :ok
  end

  @spec compaction(String.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: :ok
  def compaction(agent_id, before_tokens, after_tokens, preview_chars) do
    if enabled?() and agent_id do
      emit([:rlm, :compaction], %{}, %{
        agent_id: agent_id,
        before_tokens: before_tokens,
        after_tokens: after_tokens,
        preview_chars: preview_chars
      })
    end

    :ok
  end

  @spec child_query(String.t(), String.t(), atom(), non_neg_integer(), keyword()) :: :ok
  def child_query(parent_agent_id, child_agent_id, model_size, text_bytes, opts \\ []) do
    payload =
      %{
        agent_id: parent_agent_id,
        child_agent_id: child_agent_id,
        model_size: model_size,
        text_bytes: text_bytes,
        assessment_sampled: Keyword.get(opts, :assessment_sampled, false)
      }
      |> maybe_put_opt(opts, :text_chars)
      |> maybe_put_opt(opts, :query_preview)

    emit([:rlm, :lm_query], %{}, payload)
  end

  @spec subagent_usefulness_answer(String.t(), String.t(), atom(), String.t()) :: :ok
  def subagent_usefulness_answer(parent_agent_id, child_agent_id, verdict, reason) do
    survey_answered(
      parent_agent_id,
      RLM.Survey.subagent_usefulness_id(),
      verdict,
      %{
        child_agent_id: child_agent_id,
        reason: reason,
        scope: :child
      }
    )
  end

  @spec subagent_usefulness_missing(String.t(), String.t(), atom()) :: :ok
  def subagent_usefulness_missing(parent_agent_id, child_agent_id, status) do
    survey_missing(
      parent_agent_id,
      RLM.Survey.subagent_usefulness_id(),
      %{
        child_agent_id: child_agent_id,
        status: status,
        scope: :child
      }
    )
  end

  @spec dispatch_quality_answer(String.t(), String.t(), atom(), String.t()) :: :ok
  def dispatch_quality_answer(parent_agent_id, child_agent_id, verdict, reason) do
    with_child_agent(child_agent_id, fn ->
      survey_answered(
        child_agent_id,
        RLM.Survey.dispatch_quality_id(),
        verdict,
        %{
          child_agent_id: child_agent_id,
          parent_agent_id: parent_agent_id,
          reason: reason,
          scope: :agent
        }
      )
    end)
  end

  @spec dispatch_quality_missing(String.t(), String.t(), atom()) :: :ok
  def dispatch_quality_missing(parent_agent_id, child_agent_id, status) do
    with_child_agent(child_agent_id, fn ->
      survey_missing(
        child_agent_id,
        RLM.Survey.dispatch_quality_id(),
        %{
          child_agent_id: child_agent_id,
          parent_agent_id: parent_agent_id,
          status: status,
          scope: :agent
        }
      )
    end)
  end

  @spec subagent_assessment(String.t(), String.t(), atom(), String.t()) :: :ok
  def subagent_assessment(parent_agent_id, child_agent_id, verdict, reason) do
    subagent_usefulness_answer(parent_agent_id, child_agent_id, verdict, reason)
  end

  @spec subagent_assessment_missing(String.t(), String.t(), atom()) :: :ok
  def subagent_assessment_missing(parent_agent_id, child_agent_id, status) do
    subagent_usefulness_missing(parent_agent_id, child_agent_id, status)
  end

  @spec dispatch_assessment(String.t(), String.t(), atom(), String.t()) :: :ok
  def dispatch_assessment(parent_agent_id, child_agent_id, verdict, reason) do
    dispatch_quality_answer(parent_agent_id, child_agent_id, verdict, reason)
  end

  @spec dispatch_assessment_missing(String.t(), String.t(), atom()) :: :ok
  def dispatch_assessment_missing(parent_agent_id, child_agent_id, status) do
    dispatch_quality_missing(parent_agent_id, child_agent_id, status)
  end

  @spec survey_requested(String.t(), String.t(), map()) :: :ok
  def survey_requested(agent_id, survey_id, payload \\ %{})
      when is_binary(agent_id) and is_binary(survey_id) and is_map(payload) do
    emit(
      [:rlm, :survey, :requested],
      %{},
      Map.merge(payload, %{agent_id: agent_id, survey_id: survey_id})
    )
  end

  @spec survey_answered(String.t(), String.t(), term(), map()) :: :ok
  def survey_answered(agent_id, survey_id, response, payload \\ %{})
      when is_binary(agent_id) and is_binary(survey_id) and is_map(payload) do
    emit(
      [:rlm, :survey, :answered],
      %{},
      Map.merge(payload, %{agent_id: agent_id, survey_id: survey_id, response: response})
    )
  end

  @spec survey_missing(String.t(), String.t(), map()) :: :ok
  def survey_missing(agent_id, survey_id, payload \\ %{})
      when is_binary(agent_id) and is_binary(survey_id) and is_map(payload) do
    emit(
      [:rlm, :survey, :missing],
      %{},
      Map.merge(payload, %{agent_id: agent_id, survey_id: survey_id})
    )
  end

  @spec local_survey_answers(String.t() | nil, String.t() | nil, boolean(), map()) :: :ok
  def local_survey_answers(
        agent_id,
        parent_agent_id,
        dispatch_assessment_required,
        survey_answers
      ) do
    dispatch_survey_id = RLM.Survey.dispatch_quality_id()
    parent_present? = is_binary(parent_agent_id) and parent_agent_id != ""

    # Required dispatch_quality answers are emitted at finalization so scoring
    # sees one canonical event per sampled child.
    if is_binary(agent_id) and is_map(survey_answers) do
      Enum.each(survey_answers, fn {survey_id, value} ->
        survey_id = to_string(survey_id)

        defer_dispatch_emit? =
          survey_id == dispatch_survey_id and dispatch_assessment_required and parent_present?

        if not defer_dispatch_emit? do
          response =
            normalize_survey_answer_response(
              survey_id,
              Map.get(value, :response, Map.get(value, "response"))
            )

          payload =
            %{
              scope: :agent,
              reason: value |> Map.get(:reason, Map.get(value, "reason", "")) |> to_string()
            }
            |> maybe_attach_dispatch_metadata(
              survey_id,
              dispatch_survey_id,
              parent_agent_id,
              agent_id
            )

          survey_answered(agent_id, survey_id, response, payload)
        end
      end)
    end

    :ok
  end

  @spec snapshot_context(String.t(), non_neg_integer(), [map()], RLM.Config.t(), keyword()) :: :ok
  def snapshot_context(agent_id, iteration, history, config, opts \\ []) do
    if enabled?() do
      RLM.Observability.Tracker.snapshot_context(agent_id, iteration, history, config, opts)
    end

    :ok
  end

  defp with_child_agent(child_agent_id, fun)
       when is_binary(child_agent_id) and child_agent_id != "" do
    fun.()
  end

  defp with_child_agent(_child_agent_id, _fun), do: :ok

  defp maybe_attach_dispatch_metadata(
         payload,
         survey_id,
         dispatch_survey_id,
         parent_agent_id,
         child_agent_id
       ) do
    if survey_id == dispatch_survey_id and is_binary(parent_agent_id) and parent_agent_id != "" do
      Map.merge(payload, %{parent_agent_id: parent_agent_id, child_agent_id: child_agent_id})
    else
      payload
    end
  end

  defp normalize_survey_answer_response(survey_id, response) do
    if survey_id in [RLM.Survey.dispatch_quality_id(), RLM.Survey.subagent_usefulness_id()] do
      case RLM.Survey.parse_verdict(response) do
        {:ok, verdict} -> verdict
        :error -> response
      end
    else
      response
    end
  end

  defp start_supervisor(opts) do
    case Process.whereis(RLM.Observability.Supervisor) do
      nil ->
        case RLM.Observability.Supervisor.start_link(opts) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _pid ->
        :ok
    end
  end

  defp maybe_put_opt(payload, opts, key) do
    case Keyword.get(opts, key) do
      nil -> payload
      value -> Map.put(payload, key, value)
    end
  end
end
