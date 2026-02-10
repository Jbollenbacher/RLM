defmodule RLM.Observability.Telemetry do
  @moduledoc false

  alias RLM.Observability.Tracker

  @handler_id "rlm-observability"

  @events [
    [:rlm, :agent, :start],
    [:rlm, :agent, :end],
    [:rlm, :iteration, :start],
    [:rlm, :iteration, :stop],
    [:rlm, :llm, :start],
    [:rlm, :llm, :stop],
    [:rlm, :eval, :start],
    [:rlm, :eval, :stop],
    [:rlm, :compaction],
    [:rlm, :lm_query]
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
  end

  def handle_event([:rlm, :agent, :end], _measurements, metadata, _config) do
    Tracker.end_agent(metadata.agent_id, metadata.status, Map.drop(metadata, [:agent_id, :status]))
  end

  def handle_event([:rlm, :iteration, :start], _measurements, metadata, _config) do
    Tracker.record_event(metadata.agent_id, :iteration_start, Map.drop(metadata, [:agent_id]))
  end

  def handle_event([:rlm, :iteration, :stop], measurements, metadata, _config) do
    payload =
      metadata
      |> Map.drop([:agent_id])
      |> Map.merge(measurements)

    Tracker.record_event(metadata.agent_id, :iteration, payload)
  end

  def handle_event([:rlm, :llm, :stop], measurements, metadata, _config) do
    payload =
      metadata
      |> Map.drop([:agent_id])
      |> Map.merge(measurements)

    Tracker.record_event(metadata.agent_id, :llm, payload)
  end

  def handle_event([:rlm, :eval, :stop], measurements, metadata, _config) do
    payload =
      metadata
      |> Map.drop([:agent_id])
      |> Map.merge(measurements)

    Tracker.record_event(metadata.agent_id, :eval, payload)
  end

  def handle_event([:rlm, :compaction], _measurements, metadata, _config) do
    Tracker.record_event(metadata.agent_id, :compaction, Map.drop(metadata, [:agent_id]))
  end

  def handle_event([:rlm, :lm_query], _measurements, metadata, _config) do
    Tracker.record_event(metadata.agent_id, :lm_query, Map.drop(metadata, [:agent_id]))
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok
end
