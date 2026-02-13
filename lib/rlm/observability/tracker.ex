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
    persist_status(agent_id, status, :agent_end, payload)
  end

  @spec set_agent_status(String.t(), :done | :error | :running, map()) :: :ok
  def set_agent_status(agent_id, status, payload \\ %{}) do
    persist_status(agent_id, status, :agent_status, payload)
  end

  @spec record_event(String.t(), atom(), map()) :: :ok
  def record_event(agent_id, type, payload \\ %{}) do
    event = RLM.Observability.Event.new(agent_id, type, payload)
    Store.add_event(Map.from_struct(event))
  end

  @spec snapshot_context(String.t(), non_neg_integer(), [map()], RLM.Config.t(), keyword()) :: :ok
  def snapshot_context(agent_id, iteration, history, config, opts \\ []) do
    transcript = serialize_history(history)

    {transcript, truncated_bytes} =
      maybe_truncate(transcript, config.obs_max_context_window_chars)

    context_window_size_chars = String.length(transcript)

    preview =
      RLM.Truncate.truncate(transcript,
        head: config.truncation_head,
        tail: config.truncation_tail
      )

    history_without_system =
      Enum.reject(history, fn %{role: role} -> role == :system end)

    transcript_without_system =
      history_without_system
      |> serialize_history()
      |> maybe_truncate(config.obs_max_context_window_chars)
      |> elem(0)

    snapshot = %{
      agent_id: agent_id,
      iteration: iteration,
      context_window_size_chars: context_window_size_chars,
      preview: preview,
      transcript: transcript,
      transcript_without_system: transcript_without_system,
      truncated_bytes: truncated_bytes,
      compacted?: Keyword.get(opts, :compacted?, false)
    }

    Store.add_snapshot(snapshot)
  end

  defp serialize_history(history) do
    Enum.map_join(history, "\n\n", fn %{role: role, content: content} ->
      {label, cleaned} = label_message(role, to_string(content))
      "[#{label}]\n#{cleaned}"
    end)
  end

  defp label_message(:user, content) do
    cond do
      String.starts_with?(content, "[REPL][AGENT]") ->
        {"REPL", strip_tag(content, "[REPL][AGENT]")}

      String.starts_with?(content, "[SYSTEM]") ->
        {"SYSTEM", strip_tag(content, "[SYSTEM]")}

      String.starts_with?(content, "[PRINCIPAL]") ->
        {"PRINCIPAL", strip_tag(content, "[PRINCIPAL]")}

      true ->
        {"PRINCIPAL", content}
    end
  end

  defp label_message(:assistant, content) do
    cleaned =
      if String.starts_with?(content, "[AGENT]") do
        strip_tag(content, "[AGENT]")
      else
        content
      end

    {"AGENT", cleaned}
  end

  defp label_message(role, content), do: {role |> to_string() |> String.upcase(), content}

  defp strip_tag(content, tag) do
    content
    |> String.trim_leading(tag)
    |> String.trim_leading()
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

  defp persist_status(agent_id, status, event_type, payload) do
    Store.update_agent(agent_id, %{status: status})
    record_event(agent_id, event_type, Map.put(payload, :status, status))
  end
end
