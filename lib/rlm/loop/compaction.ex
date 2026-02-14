defmodule RLM.Loop.Compaction do
  @moduledoc false

  require Logger

  @spec maybe_compact([map()], keyword(), String.t(), RLM.Config.t(), String.t() | nil) ::
          {[map()], keyword()}
  def maybe_compact(history, bindings, model, config, agent_id \\ nil) do
    estimated_tokens = estimate_tokens(history)
    threshold = trunc(context_window_tokens_for_model(config, model) * 0.8)

    if estimated_tokens > threshold and length(history) > 1 do
      [system_msg | rest] = history
      serialized = serialize_history(rest)

      existing = Keyword.get(bindings, :compacted_history, "")

      combined =
        if existing == "" do
          serialized
        else
          existing <> "\n\n---\n\n" <> serialized
        end

      new_bindings = Keyword.put(bindings, :compacted_history, combined)

      preview =
        RLM.Truncate.truncate(combined,
          head: config.truncation_head,
          tail: config.truncation_tail
        )

      addendum = RLM.Prompt.compaction_addendum(preview)
      new_history = [system_msg, %{role: :user, content: addendum}]

      Logger.info(
        "[RLM] Compacted history: #{estimated_tokens} tokens -> #{estimate_tokens(new_history)} tokens"
      )

      RLM.Observability.compaction(
        agent_id,
        estimated_tokens,
        estimate_tokens(new_history),
        String.length(preview)
      )

      {new_history, new_bindings}
    else
      {history, bindings}
    end
  end

  defp estimate_tokens(history) do
    total_chars =
      Enum.reduce(history, 0, fn msg, acc ->
        content = Map.get(msg, :content, "")
        acc + String.length(to_string(content))
      end)

    div(total_chars, 4)
  end

  defp context_window_tokens_for_model(config, model) do
    if config.model_large == config.model_small do
      max(config.context_window_tokens_large, config.context_window_tokens_small)
    else
      cond do
        model == config.model_large -> config.context_window_tokens_large
        model == config.model_small -> config.context_window_tokens_small
        true -> config.context_window_tokens_large
      end
    end
  end

  defp serialize_history(messages) do
    Enum.map_join(messages, "\n\n---\n\n", fn msg ->
      role = Map.get(msg, :role, "unknown")
      content = Map.get(msg, :content, "")
      "Role: #{role}\n#{to_string(content)}"
    end)
  end
end
