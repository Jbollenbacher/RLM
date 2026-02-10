defmodule RLM.Observability.Tracker do
  @moduledoc "Public API for tracking agents, events, and context snapshots."

  alias RLM.Observability.Store

  @spec start_agent(String.t(), String.t() | nil, String.t(), non_neg_integer()) :: :ok
  def start_agent(agent_id, parent_id, model, depth) do
    agent = %{
      id: agent_id,
      parent_id: parent_id,
      depth: depth,
      model: model,
      status: :running
    }

    Store.put_agent(agent)
    record_event(agent_id, :agent_start, %{parent_id: parent_id, model: model, depth: depth})
  end

  @spec end_agent(String.t(), :done | :error | :running, map()) :: :ok
  def end_agent(agent_id, status, payload \\ %{}) do
    Store.update_agent(agent_id, %{status: status})
    record_event(agent_id, :agent_end, Map.put(payload, :status, status))
  end

  @spec record_event(String.t(), atom(), map()) :: :ok
  def record_event(agent_id, type, payload \\ %{}) do
    event = RLM.Observability.Event.new(agent_id, type, payload)
    Store.add_event(Map.from_struct(event))
  end

  @spec snapshot_context(String.t(), non_neg_integer(), [map()], RLM.Config.t(), keyword()) :: :ok
  def snapshot_context(agent_id, iteration, history, config, opts \\ []) do
    transcript = serialize_history(history)
    {transcript, truncated_bytes} = maybe_truncate(transcript, config.obs_max_context_window_chars)
    context_window_size_chars = String.length(transcript)
    preview = RLM.Truncate.truncate(transcript, head: config.truncation_head, tail: config.truncation_tail)

    snapshot = %{
      agent_id: agent_id,
      iteration: iteration,
      context_window_size_chars: context_window_size_chars,
      preview: preview,
      transcript: transcript,
      truncated_bytes: truncated_bytes,
      compacted?: Keyword.get(opts, :compacted?, false)
    }

    Store.add_snapshot(snapshot)
  end

  defp serialize_history(history) do
    Enum.map_join(history, "\n\n---\n\n", fn %{role: role, content: content} ->
      role = role |> to_string() |> String.upcase()
      "[#{role}]\n#{to_string(content)}"
    end)
  end

  defp maybe_truncate(transcript, max_chars) when is_integer(max_chars) and max_chars > 0 do
    if String.length(transcript) > max_chars do
      truncated = String.slice(transcript, -max_chars, max_chars)
      truncated_bytes = String.length(transcript) - max_chars
      marker = "... [truncated #{truncated_bytes} chars] ...\n"
      {marker <> truncated, truncated_bytes}
    else
      {transcript, 0}
    end
  end

  defp maybe_truncate(transcript, _), do: {transcript, 0}
end
