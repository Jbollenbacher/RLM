defmodule RLM.Session do
  @moduledoc "Multi-turn session API for RLM."

  defstruct [:id, :history, :bindings, :model, :config, :depth]

  @type t :: %__MODULE__{
          id: String.t(),
          history: [map()],
          bindings: keyword(),
          model: String.t(),
          config: RLM.Config.t(),
          depth: non_neg_integer()
        }

  @spec start(String.t(), keyword()) :: t()
  def start(context, opts \\ []) do
    id = Keyword.get(opts, :session_id, RLM.Helpers.unique_id("session"))
    parent_agent_id = Keyword.get(opts, :parent_agent_id)
    config = Keyword.get_lazy(opts, :config, fn -> RLM.Config.load() end)
    model = Keyword.get(opts, :model, config.model_large)
    depth = Keyword.get(opts, :depth, 0)
    workspace_root = Keyword.get(opts, :workspace_root)
    workspace_read_only = Keyword.get(opts, :workspace_read_only, false)

    lm_query_fn = RLM.Loop.build_lm_query(config, depth, workspace_root, workspace_read_only, id)

    bindings = [
      context: context,
      lm_query: lm_query_fn,
      workspace_root: workspace_root,
      workspace_read_only: workspace_read_only,
      final_answer: nil,
      last_stdout: "",
      last_stderr: "",
      last_result: nil
    ]

    history = [%{role: :system, content: RLM.Prompt.system_prompt()}]

    RLM.Observability.emit([:rlm, :agent, :start], %{system_time: System.system_time(:millisecond)}, %{
      agent_id: id,
      parent_id: parent_agent_id,
      model: model,
      depth: depth
    })

    %__MODULE__{
      id: id,
      history: history,
      bindings: bindings,
      model: model,
      config: config,
      depth: depth
    }
  end

  @spec ask(t(), String.t()) :: {{:ok, String.t()} | {:error, String.t()}, t()}
  def ask(%__MODULE__{} = session, message) do
    case RLM.AgentLimiter.with_slot(session.config.max_concurrent_agents, fn ->
           history = session.history
           bindings = session.bindings

           updated_context = append_turn(Keyword.fetch!(bindings, :context), "Principal", message)
           bindings = Keyword.put(bindings, :context, updated_context)

           user_message = build_prompt_message(history, updated_context, bindings)
           history = history ++ [%{role: :user, content: user_message}]
           bindings = Keyword.put(bindings, :final_answer, nil)

           {result, new_history, new_bindings} =
             RLM.Loop.run_turn(
               history,
               bindings,
               session.model,
               session.config,
               session.depth,
               session.id
             )

           updated_context = append_agent_to_context(updated_context, result)

           new_bindings =
             new_bindings
             |> Keyword.put(:context, updated_context)
             |> Keyword.put(:final_answer, nil)

           new_session = %__MODULE__{session | history: new_history, bindings: new_bindings}
           {result, new_session}
         end) do
      {:error, reason} ->
        {{:error, reason}, session}

      other ->
        other
    end
  end

  defp build_prompt_message(history, context, bindings) do
    if length(history) == 1 do
      workspace_available = Keyword.get(bindings, :workspace_root) != nil
      workspace_read_only = Keyword.get(bindings, :workspace_read_only, false)

      RLM.Prompt.initial_user_message(context,
        workspace_available: workspace_available,
        workspace_read_only: workspace_read_only
      )
    else
      RLM.Prompt.initial_user_message(context)
    end
  end

  defp append_turn(context, role, message) do
    prefix = if context == "", do: "", else: "\n\n"
    marker =
      case role do
        "Principal" -> RLM.Helpers.chat_marker(:principal)
        "Agent" -> RLM.Helpers.chat_marker(:agent)
        other -> "[RLM_#{other}]"
      end

    context <> prefix <> marker <> "\n" <> message
  end

  defp append_agent_to_context(context, {:ok, answer}),
    do: append_turn(context, "Agent", format_message(answer))

  defp append_agent_to_context(context, {:error, reason}),
    do: append_turn(context, "Agent", "Error: #{format_message(reason)}")

  defp format_message(message) when is_binary(message), do: message

  defp format_message(message),
    do: inspect(message, pretty: true, limit: :infinity, printable_limit: :infinity)
end
