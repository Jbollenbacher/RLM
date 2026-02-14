defmodule RLM.Observability.Telemetry do
  @moduledoc false

  alias RLM.Observability.Tracker

  @handler_id "rlm-observability"

  @events [
    [:rlm, :agent, :start],
    [:rlm, :agent, :end],
    [:rlm, :agent, :status],
    [:rlm, :iteration, :stop],
    [:rlm, :llm, :start],
    [:rlm, :llm, :stop],
    [:rlm, :eval, :start],
    [:rlm, :eval, :stop],
    [:rlm, :compaction],
    [:rlm, :lm_query],
    [:rlm, :subagent_assessment],
    [:rlm, :subagent_assessment, :missing],
    [:rlm, :dispatch_assessment],
    [:rlm, :dispatch_assessment, :missing]
  ]

  def attach do
    case :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, %{}) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  def detach do
    :telemetry.detach(@handler_id)
  end

  def handle_event([:rlm, :agent, :start], _measurements, metadata, _config) do
    Tracker.start_agent(metadata.agent_id, metadata.parent_id, metadata.model, metadata.depth)
    maybe_watch_agent_owner(metadata.agent_id, metadata.owner_pid)
  end

  def handle_event([:rlm, :agent, :end], _measurements, metadata, _config) do
    emit_missing_subagent_assessments(metadata.agent_id)

    Tracker.end_agent(
      metadata.agent_id,
      metadata.status,
      Map.drop(metadata, [:agent_id, :status])
    )

    RLM.Observability.AgentWatcher.unwatch(metadata.agent_id)
    RLM.Subagent.Broker.cancel_all(metadata.agent_id)
  end

  def handle_event([:rlm, :agent, :status], _measurements, metadata, _config) do
    if metadata.status in [:done, :error] do
      emit_missing_subagent_assessments(metadata.agent_id)
    end

    Tracker.set_agent_status(
      metadata.agent_id,
      metadata.status,
      Map.drop(metadata, [:agent_id, :status])
    )
  end

  def handle_event([:rlm, :iteration, :stop], measurements, metadata, _config) do
    record_with_measurements(metadata, :iteration, measurements)
  end

  def handle_event([:rlm, :llm, :stop], measurements, metadata, _config) do
    record_with_measurements(metadata, :llm, measurements)
  end

  def handle_event([:rlm, :eval, :stop], measurements, metadata, _config) do
    record_with_measurements(metadata, :eval, measurements)
  end

  def handle_event([:rlm, :compaction], _measurements, metadata, _config) do
    record_metadata(metadata, :compaction)
  end

  def handle_event([:rlm, :lm_query], _measurements, metadata, _config) do
    record_metadata(metadata, :lm_query)
  end

  def handle_event([:rlm, :subagent_assessment], _measurements, metadata, _config) do
    record_metadata(metadata, :subagent_assessment)
  end

  def handle_event([:rlm, :subagent_assessment, :missing], _measurements, metadata, _config) do
    record_metadata(metadata, :subagent_assessment_missing)
  end

  def handle_event([:rlm, :dispatch_assessment], _measurements, metadata, _config) do
    record_metadata(metadata, :dispatch_assessment)
  end

  def handle_event([:rlm, :dispatch_assessment, :missing], _measurements, metadata, _config) do
    record_metadata(metadata, :dispatch_assessment_missing)
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  defp maybe_watch_agent_owner(agent_id, owner_pid) when is_pid(owner_pid) do
    RLM.Observability.AgentWatcher.watch(agent_id, owner_pid)
  end

  defp maybe_watch_agent_owner(_agent_id, _owner_pid), do: :ok

  defp record_with_measurements(metadata, type, measurements) do
    payload =
      metadata
      |> Map.drop([:agent_id])
      |> Map.merge(measurements)

    Tracker.record_event(metadata.agent_id, type, payload)
  end

  defp record_metadata(metadata, type) do
    Tracker.record_event(metadata.agent_id, type, Map.drop(metadata, [:agent_id]))
  end

  defp emit_missing_subagent_assessments(agent_id) do
    RLM.Subagent.Broker.drain_pending_assessments(agent_id)
    |> Enum.each(fn pending ->
      RLM.Observability.subagent_assessment_missing(
        agent_id,
        pending.child_agent_id,
        pending.status
      )
    end)
  end
end
