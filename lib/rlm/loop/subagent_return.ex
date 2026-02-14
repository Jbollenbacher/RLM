defmodule RLM.Loop.SubagentReturn do
  @moduledoc false

  @spec maybe_inject([map()], RLM.Config.t(), String.t() | nil) :: [map()]
  def maybe_inject(history, _config, nil), do: history

  def maybe_inject(history, config, agent_id) do
    case RLM.Subagent.Broker.drain_updates(agent_id) do
      [] ->
        history

      updates ->
        message = subagent_return_message(updates, config)
        history ++ [%{role: :user, content: message}]
    end
  end

  defp subagent_return_message(updates, config) do
    body =
      updates
      |> Enum.map_join("\n\n---\n\n", fn update ->
        id = Map.get(update, :child_agent_id)
        status = Map.get(update, :state)
        preview = preview_subagent_payload(Map.get(update, :payload), config)

        completion_note =
          if Map.get(update, :completion_update), do: "completion update", else: nil

        survey_note =
          cond do
            Map.get(update, :assessment_required) and not Map.get(update, :assessment_recorded) ->
              "survey required: call answer_child_survey(\"#{id}\", \"subagent_usefulness\", \"satisfied\"|\"dissatisfied\", reason=\"...\") (or assess_lm_query for compatibility)"

            Map.get(update, :assessment_update) ->
              "survey reminder: this update now requires a subagent_usefulness response after polling"

            true ->
              nil
          end

        [
          "child_agent_id: #{id}",
          "status: #{status}",
          "preview:",
          preview,
          completion_note,
          survey_note
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")
      end)

    "[SUBAGENT_RETURN]\n" <> body
  end

  defp preview_subagent_payload(payload, config) do
    text =
      if is_binary(payload) do
        payload
      else
        inspect(payload, pretty: true, limit: 20, printable_limit: 4000)
      end

    RLM.Truncate.truncate(text,
      head: min(400, config.truncation_head),
      tail: min(400, config.truncation_tail)
    )
  end
end
