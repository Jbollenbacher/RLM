defmodule RLM.Prompt do
  @how_to_respond_note """
  [SYSTEM]
  You can only communicate with the Principal by setting `final_answer` in a ```python``` code block. Proceed according to the system prompt.
  """
  @no_code_nudge """
  [REPL][AGENT]
  [No executable Python code block found. Respond with exactly one fenced block in this format:
  ```python
  # your code
  ```
  Do not use XML/HTML tags (e.g. <python>), tool-call wrappers, or multiple code blocks.
  Do not use print() to answer the Principal; set `final_answer` instead.]
  """
  @invalid_final_answer_nudge """
  [REPL][AGENT]
  [Invalid final_answer format. Set `final_answer` directly for success (e.g. `final_answer = "done"`), or use `final_answer = fail("reason")` for failure.]
  """
  @invalid_dispatch_assessment_nudge """
  [REPL][AGENT]
  [assess_dispatch(...) is only processed in the same step where you set `final_answer`. Re-run this in your final commit block.]
  """
  @dispatch_assessment_checkin_nudge """
  [REPL][AGENT]
  [Dispatch quality assessment is required for this sampled run.
  Your final answer has been staged and will be returned automatically.
  In this turn, respond with exactly one Python code block that only records the assessment:
  ```python
  assess_dispatch("satisfied", reason="clear and specific rationale")
  ```
  Any response without executable Python code will be treated as a failed check-in.
  Do not call `lm_query`, `await_lm_query`, or `poll_lm_query`.
  Do not set `final_answer` again.
  Do not redo prior work.]
  """
  @subagent_assessment_checkin_nudge_prefix """
  [REPL][AGENT]
  [Subagent assessments are required before finalizing.
  Your final answer has been staged and will be returned automatically.
  In this turn, respond with exactly one Python code block and only record missing assessments with:
  `assess_lm_query(child_agent_id, "satisfied"|"dissatisfied", reason="...")`.
  Use the exact `child_agent_id` values listed below as literal arguments.
  Do not rely on alias variables that may have been reassigned after retries.
  Any response without executable Python code will be treated as a failed check-in.
  Do not call `lm_query`, `await_lm_query`, or `poll_lm_query`.
  Do not set `final_answer` again.
  Do not redo prior work.
  """
  @survey_checkin_nudge_prefix """
  [REPL][AGENT]
  [Required surveys are pending before finalization.
  Your final answer has been staged and will be returned automatically.
  In this turn, respond with exactly one Python code block and only answer pending surveys with:
  `answer_survey(survey_id, response, reason="...")`.
  Do not call `lm_query`, `await_lm_query`, or `poll_lm_query`.
  Do not set `final_answer` again.
  Do not redo prior work.
  """

  @default_system_prompt_path Path.join(:code.priv_dir(:rlm), "system_prompt.md")

  @spec system_prompt() :: String.t()
  def system_prompt, do: File.read!(@default_system_prompt_path)

  @spec system_prompt(RLM.Config.t() | map() | nil) :: String.t()
  def system_prompt(nil), do: system_prompt()

  def system_prompt(config) do
    case Map.get(config, :system_prompt_path) do
      path when is_binary(path) and path != "" -> File.read!(path)
      _ -> system_prompt()
    end
  end

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
        do:
          parts ++
            [
              "[Execution failed. Bindings unchanged. Variables assigned in this failed step were not persisted.]"
            ] ++ error_recovery_hints(stdout, stderr),
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

  @spec no_code_nudge() :: String.t()
  def no_code_nudge, do: @no_code_nudge

  @spec invalid_final_answer_nudge() :: String.t()
  def invalid_final_answer_nudge, do: @invalid_final_answer_nudge

  @spec invalid_dispatch_assessment_nudge() :: String.t()
  def invalid_dispatch_assessment_nudge, do: @invalid_dispatch_assessment_nudge

  @spec dispatch_assessment_checkin_nudge() :: String.t()
  def dispatch_assessment_checkin_nudge, do: @dispatch_assessment_checkin_nudge

  @spec subagent_assessment_checkin_nudge([String.t()]) :: String.t()
  def subagent_assessment_checkin_nudge(child_ids) when is_list(child_ids) do
    pending_ids = child_ids |> Enum.map(&to_string/1) |> Enum.uniq()
    pending = if pending_ids == [], do: "(none captured)", else: Enum.join(pending_ids, ", ")

    examples =
      if pending_ids == [] do
        ""
      else
        "\nUse one call per pending child:\n" <>
          Enum.map_join(
            pending_ids,
            "\n",
            &"  - #{&1}: assess_lm_query(\"#{&1}\", \"satisfied\"|\"dissatisfied\", reason=\"...\")"
          )
      end

    @subagent_assessment_checkin_nudge_prefix <>
      "\nPending child_agent_id values: " <> pending <> examples <> "]"
  end

  @spec survey_checkin_nudge([String.t()]) :: String.t()
  def survey_checkin_nudge(survey_ids) when is_list(survey_ids) do
    pending =
      survey_ids
      |> Enum.map(&to_string/1)
      |> Enum.uniq()
      |> Enum.join(", ")

    @survey_checkin_nudge_prefix <>
      "\nPending survey_id values: " <>
      if(pending == "", do: "(none captured)", else: pending) <> "]"
  end

  @spec compaction_addendum(String.t()) :: String.t()
  def compaction_addendum(preview) do
    """
    [REPL][AGENT]
    [Context Window Compacted]

    Your previous conversation history has been compacted to free context space.
    The full history is available in the variable `compacted_history`.
    Use Python string operations (slicing, split, regex) and `grep(pattern, compacted_history)` to search it.
    All other bindings (context, variables you defined, etc.) are preserved unchanged.

    Preview of compacted history:
    #{preview}

    Continue working on your task. Use list_bindings() to see your current state.
    """
  end

  defp error_recovery_hints(stdout, stderr) do
    combined = [stdout, stderr] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\n")

    hints =
      [
        "[Recovery hint] Use list_bindings() before reusing intermediates after a failed step.",
        undefined_name_hint(combined)
      ]

    Enum.reject(hints, &is_nil/1)
  end

  defp undefined_name_hint(text) do
    case Regex.run(~r/NameError:\s+name ['"]([^'"]+)['"] is not defined/, text,
           capture: :all_but_first
         ) do
      [name] ->
        "[Recovery hint] `#{name}` is undefined. Recompute it in this step or guard with `\"#{name}\" in globals()`."

      _ ->
        nil
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
        "[SYSTEM]\nWorkspace access is read-only. Use helper functions ls() and read_file() in ```python code blocks.\n\n"
      else
        "[SYSTEM]\nWorkspace access is read-write. Use helper functions ls(), read_file(), edit_file(), and create_file() ```python code blocks.\n\n"
      end
    else
      ""
    end
  end
end
