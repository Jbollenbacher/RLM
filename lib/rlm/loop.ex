defmodule RLM.Loop do
  require Logger

  @spec run(keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(opts) do
    config = Keyword.get_lazy(opts, :config, fn -> RLM.Config.load() end)
    context = Keyword.fetch!(opts, :context)
    query = Keyword.fetch!(opts, :query)
    model = Keyword.get(opts, :model, config.model_large)
    depth = Keyword.get(opts, :depth, 0)

    Logger.info("[RLM] depth=#{depth} context_size=#{byte_size(context)} query=#{String.slice(query, 0, 100)}")

    lm_query_fn = build_lm_query(config, depth)

    initial_bindings = [
      context: context,
      lm_query: lm_query_fn,
      final_answer: nil,
      last_stdout: "",
      last_stderr: "",
      last_result: nil
    ]

    system_msg = %{role: :system, content: RLM.Prompt.system_prompt()}
    user_msg = %{role: :user, content: RLM.Prompt.initial_user_message(context, query)}
    initial_history = [system_msg, user_msg]

    iterate(initial_history, initial_bindings, model, config, depth, 0)
  end

  defp iterate(history, bindings, model, config, depth, iteration) do
    if iteration >= config.max_iterations do
      {:error, "Max iterations (#{config.max_iterations}) reached without final_answer"}
    else
      Logger.info("[RLM] depth=#{depth} iteration=#{iteration}")

      case RLM.LLM.chat(history, model, config) do
        {:ok, response} ->
          handle_response(response, history, bindings, model, config, depth, iteration)

        {:error, reason} ->
          {:error, "LLM call failed at depth=#{depth} iteration=#{iteration}: #{reason}"}
      end
    end
  end

  defp handle_response(response, history, bindings, model, config, depth, iteration) do
    case RLM.LLM.extract_code(response) do
      {:ok, code} ->
        Logger.debug("[RLM] depth=#{depth} iteration=#{iteration} code=#{String.slice(code, 0, 200)}")

        # Add assistant message to history
        history = history ++ [%{role: :assistant, content: response}]

        # Eval
        {status, full_stdout, result, new_bindings} =
          case RLM.Eval.eval(code, bindings, timeout: config.eval_timeout) do
            {:ok, stdout, result, new_b} -> {:ok, stdout, result, new_b}
            {:error, stdout, old_b} -> {:error, stdout, nil, old_b}
          end

        full_stderr = ""

        # Truncate stdout for history
        truncated_stdout =
          RLM.Truncate.truncate(full_stdout,
            head: config.truncation_head,
            tail: config.truncation_tail
          )

        # Build feedback message
        feedback = RLM.Prompt.format_eval_output(truncated_stdout, full_stderr, status, result)
        history = history ++ [%{role: :user, content: feedback}]

        # Update history bindings
        new_bindings =
          new_bindings
          |> Keyword.put(:last_stdout, full_stdout)
          |> Keyword.put(:last_stderr, full_stderr)
          |> Keyword.put(:last_result, result)

        # Check for final_answer
        case Keyword.get(new_bindings, :final_answer) do
          {:ok, answer} ->
            Logger.info("[RLM] depth=#{depth} completed with answer at iteration=#{iteration}")
            {:ok, to_string(answer)}

          {:error, reason} ->
            {:error, to_string(reason)}

          nil ->
            iterate(history, new_bindings, model, config, depth, iteration + 1)

          other when other != nil ->
            Logger.info("[RLM] depth=#{depth} completed with raw answer at iteration=#{iteration}")
            {:ok, to_string(other)}
        end

      {:error, :no_code_block} ->
        # LLM didn't produce code — nudge it
        Logger.warning("[RLM] depth=#{depth} iteration=#{iteration} no code block found")

        history =
          history ++
            [
              %{role: :assistant, content: response},
              %{role: :user, content: "[No code block found. Please respond with an ```elixir code block.]"}
            ]

        iterate(history, bindings, model, config, depth, iteration + 1)
    end
  end

  defp build_lm_query(config, depth) do
    fn text, opts ->
      model_size = Keyword.fetch!(opts, :model_size)
      model = if model_size == :large, do: config.model_large, else: config.model_small

      if depth >= config.max_depth do
        {:error, "Maximum recursion depth (#{config.max_depth}) exceeded"}
      else
        RLM.Loop.run(
          context: text,
          query: text,
          model: model,
          config: config,
          depth: depth + 1
        )
      end
    end
  end
end
