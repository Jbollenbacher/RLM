defmodule RLM.Prompt do
  @system_prompt_text File.read!(Path.join(:code.priv_dir(:rlm), "system_prompt.md"))

  @spec system_prompt() :: String.t()
  def system_prompt, do: @system_prompt_text

  @spec initial_user_message(String.t(), keyword()) :: String.t()
  def initial_user_message(context, opts \\ []) do
    size = byte_size(context)
    line_count = context |> String.split("\n") |> length()
    {preview_label, preview_text} =
      case RLM.Helpers.latest_user_message(context) do
        {:ok, message} ->
          {"Latest user message preview (head+tail 500 chars):",
           RLM.Truncate.truncate(message, head: 250, tail: 250)}

        {:error, _reason} ->
          {"Context preview (head+tail 500 chars):",
           RLM.Truncate.truncate(context, head: 250, tail: 250)}
      end
    workspace_available = Keyword.get(opts, :workspace_available, false)
    workspace_read_only = Keyword.get(opts, :workspace_read_only, false)

    workspace_note =
      if workspace_available do
        if workspace_read_only do
          "Workspace access: read-only. Use ls() and read_file() with relative paths.\n"
        else
          "Workspace access: enabled. Use ls(), read_file(), and edit_file() with relative paths (no workspace/ prefix).\n"
        end
      else
        ""
      end

    """
    Input: #{size} bytes, #{line_count} lines.
    #{preview_label}
    #{preview_text}

    #{workspace_note}\
    """
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
      [] -> "[No output]"
      _ -> Enum.join(parts, "\n\n")
    end
  end
end
