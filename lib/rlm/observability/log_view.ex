defmodule RLM.Observability.LogView do
  @moduledoc false

  @normal_event_types MapSet.new([
                        :agent_start,
                        :agent_end,
                        :agent_status,
                        :llm,
                        :eval,
                        :lm_query,
                        :subagent_assessment,
                        :subagent_assessment_missing,
                        :compaction,
                        :principal_interrupt
                      ])

  @spec normalize(boolean()) :: :normal | :debug
  def normalize(true), do: :debug
  def normalize(false), do: :normal

  @spec filter_events([map()], :normal | :debug) :: [map()]
  def filter_events(events, :debug), do: events

  def filter_events(events, :normal) do
    Enum.filter(events, &keep_event?(&1, :normal))
  end

  @spec keep_event?(map(), :normal | :debug) :: boolean()
  def keep_event?(_event, :debug), do: true

  def keep_event?(event, :normal) do
    case Map.get(event, :type) do
      :iteration -> iteration_problem?(event)
      type -> MapSet.member?(@normal_event_types, type)
    end
  end

  defp iteration_problem?(event) do
    status = get_in(event, [:payload, :status])
    status not in [:ok, "ok"]
  end
end
