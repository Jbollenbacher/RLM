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

  @spec subagent_assessment(String.t(), String.t(), atom(), String.t()) :: :ok
  def subagent_assessment(parent_agent_id, child_agent_id, verdict, reason) do
    emit([:rlm, :subagent_assessment], %{}, %{
      agent_id: parent_agent_id,
      child_agent_id: child_agent_id,
      verdict: verdict,
      reason: reason
    })
  end

  @spec subagent_assessment_missing(String.t(), String.t(), atom()) :: :ok
  def subagent_assessment_missing(parent_agent_id, child_agent_id, status) do
    emit([:rlm, :subagent_assessment, :missing], %{}, %{
      agent_id: parent_agent_id,
      child_agent_id: child_agent_id,
      status: status
    })
  end

  @spec snapshot_context(String.t(), non_neg_integer(), [map()], RLM.Config.t(), keyword()) :: :ok
  def snapshot_context(agent_id, iteration, history, config, opts \\ []) do
    if enabled?() do
      RLM.Observability.Tracker.snapshot_context(agent_id, iteration, history, config, opts)
    end

    :ok
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
