defmodule RLM.Loop.EvalFeedback do
  @moduledoc false

  @spec evaluate_code(String.t(), keyword(), RLM.Config.t(), String.t() | nil, non_neg_integer()) ::
          {:ok | :error, String.t(), String.t(), any(), keyword()}
  def evaluate_code(code, bindings, config, agent_id, iteration) do
    case RLM.Eval.eval(code, bindings,
           timeout: config.eval_timeout,
           lm_query_timeout: config.lm_query_timeout,
           subagent_assessment_sample_rate: config.subagent_assessment_sample_rate,
           agent_id: agent_id,
           iteration: iteration
         ) do
      {:ok, stdout, stderr, result, new_bindings} ->
        {:ok, stdout, stderr, result, new_bindings}

      {:error, stdout, stderr, original_bindings} ->
        {:error, stdout, stderr, nil, original_bindings}
    end
  end

  @spec apply(
          [map()],
          keyword(),
          :ok | :error,
          any(),
          String.t(),
          String.t(),
          RLM.Config.t()
        ) :: {[map()], keyword()}
  def apply(history, bindings, status, result, full_stdout, full_stderr, config) do
    truncated_stdout =
      RLM.Truncate.truncate(full_stdout,
        head: config.truncation_head,
        tail: config.truncation_tail
      )

    truncated_stderr =
      RLM.Truncate.truncate(full_stderr,
        head: config.truncation_head,
        tail: config.truncation_tail
      )

    final_answer_value = Keyword.get(bindings, :final_answer)

    suppress_result? =
      status == :ok and final_answer_value != nil and result == final_answer_value

    result_for_output = if suppress_result?, do: nil, else: result

    feedback =
      RLM.Prompt.format_eval_output(truncated_stdout, truncated_stderr, status, result_for_output)

    history =
      if suppress_result? and truncated_stdout == "" and truncated_stderr == "" do
        history
      else
        history ++ [%{role: :user, content: feedback}]
      end

    bindings =
      bindings
      |> Keyword.put(:last_stdout, full_stdout)
      |> Keyword.put(:last_stderr, full_stderr)
      |> Keyword.put(:last_result, result)

    {history, bindings}
  end
end
