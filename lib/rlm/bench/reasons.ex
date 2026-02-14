defmodule RLM.Bench.Reasons do
  @moduledoc false

  @buckets [
    :unclear_dispatch,
    :insufficient_context,
    :wrong_or_incomplete_output,
    :format_or_contract_issue,
    :timeout_or_runtime_issue,
    :other
  ]

  def categorize(reason) when is_binary(reason) do
    normalized = reason |> String.downcase() |> String.trim()

    cond do
      normalized == "" ->
        :other

      Regex.match?(~r/unclear|ambiguous|not clear|underspecified|vague|scope/, normalized) ->
        :unclear_dispatch

      Regex.match?(
        ~r/missing context|missing information|insufficient context|not enough context|lacked context/,
        normalized
      ) ->
        :insufficient_context

      Regex.match?(
        ~r/incorrect|wrong|incomplete|hallucinat|did not answer|not useful|low quality|malformed/,
        normalized
      ) ->
        :wrong_or_incomplete_output

      Regex.match?(
        ~r/format|contract|final_answer|assessment|survey|invalid|schema|parse|code block/,
        normalized
      ) ->
        :format_or_contract_issue

      Regex.match?(
        ~r/timeout|timed out|crash|exception|runtime|error|max iterations|cancelled/,
        normalized
      ) ->
        :timeout_or_runtime_issue

      true ->
        :other
    end
  end

  def summarize(reasons) when is_list(reasons) do
    grouped = Enum.group_by(reasons, fn reason -> categorize(reason) end)

    counts =
      Enum.into(@buckets, %{}, fn bucket ->
        {bucket, grouped |> Map.get(bucket, []) |> length()}
      end)

    top_examples =
      grouped
      |> Enum.map(fn {bucket, items} -> {bucket, Enum.at(items, 0)} end)
      |> Enum.into(%{})

    %{
      counts: counts,
      top_examples: top_examples
    }
  end
end
