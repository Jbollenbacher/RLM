defmodule RLM.Prompt do
  @system_prompt_text File.read!(Path.join(:code.priv_dir(:rlm), "system_prompt.md"))
  @how_to_respond_note """
  [SYSTEM]
  You can only communicate with the Principal by setting `final_answer` in a ```python``` code block. Proceed according to the system prompt.
  """

  @spec system_prompt() :: String.t()
  def system_prompt, do: @system_prompt_text

  @spec system_prompt(keyword()) :: String.t()
  def system_prompt(_opts), do: @system_prompt_text

  @spec initial_user_message(String.t(), keyword()) :: String.t()
  def initial_user_message(context, opts \\ []) do
    "#{workspace_note(opts)}[PRINCIPAL]\n#{principal_preview(context)}\n\n#{@how_to_respond_note}"
  end

  @spec followup_user_message(String.t()) :: String.t()
  def followup_user_message(context) do
    "[PRINCIPAL]\n#{principal_preview(context)}"
  end

  @spec format_eval_output(String.t(), String.t(), :ok | :error, any()) :: String.t()
  def format_eval_output(stdout, stderr, status, result \\ nil) do
    parts = []
    parts = if stdout != "", do: parts ++ ["stdout:\n#{stdout}"], else: parts
    parts = if stderr != "", do: parts ++ ["stderr:\n#{stderr}"], else: parts

    parts =
      if status == :error,
        do: parts ++ ["[Execution failed. Bindings unchanged.]"],
        else: parts

    # Show the return value like iex does — truncated to keep it compact
    parts =
      if status == :ok and result != nil do
        result_preview = inspect(result, limit: 20, printable_limit: 200)
        result_preview = String.slice(result_preview, 0, 500)

        truncation_note =
          if is_binary(result) and byte_size(result) > 500 do
            " (#{byte_size(result)} bytes, truncated)"
          else
            ""
          end

        parts ++ ["=> #{result_preview}#{truncation_note}"]
      else
        parts
      end

    case parts do
      [] -> "[REPL][AGENT]\n[No output]"
      _ -> "[REPL][AGENT]\n" <> Enum.join(parts, "\n\n")
    end
  end

  defp principal_preview(context) do
    case RLM.Helpers.latest_principal_message(context) do
      {:ok, message} -> RLM.Truncate.truncate(message, head: 250, tail: 250)
      {:error, _reason} -> RLM.Truncate.truncate(context, head: 250, tail: 250)
    end
  end

  defp workspace_note(opts) do
    if Keyword.get(opts, :workspace_available, false) do
      if Keyword.get(opts, :workspace_read_only, false) do
        "[SYSTEM]\nWorkspace access is read-only. Use ls() and read_file() with relative paths.\n\n"
      else
        "[SYSTEM]\nWorkspace access is read-write. Use ls(), read_file(), edit_file(), and create_file() with relative paths.\n\n"
      end
    else
      ""
    end
  end
end
