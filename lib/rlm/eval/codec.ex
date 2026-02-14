defmodule RLM.Eval.Codec do
  @moduledoc false

  def json_term(value)
      when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
      do: value

  def json_term(value) when is_atom(value), do: Atom.to_string(value)
  def json_term(value) when is_list(value), do: Enum.map(value, &json_term/1)

  def json_term(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&json_term/1)

  def json_term(value) when is_map(value) do
    Enum.into(value, %{}, fn {k, v} ->
      {to_string(k), json_term(v)}
    end)
  end

  def json_term(value), do: inspect(value)

  def decode_term(nil), do: nil

  def decode_term(term) do
    Pythonx.decode(term)
  rescue
    _ -> term
  end

  def normalize_final_answer(nil), do: nil
  def normalize_final_answer({:ok, _answer} = answer), do: answer
  def normalize_final_answer({:error, _reason} = answer), do: answer
  def normalize_final_answer({"ok", answer}), do: {:ok, answer}
  def normalize_final_answer({"error", reason}), do: {:error, reason}
  def normalize_final_answer([status, payload]), do: normalize_final_answer({status, payload})

  def normalize_final_answer(%{"status" => status, "payload" => payload}) do
    normalize_status_payload(status, payload)
  end

  def normalize_final_answer(%{status: status, payload: payload}) do
    normalize_status_payload(status, payload)
  end

  def normalize_final_answer(%{"ok" => answer}), do: {:ok, answer}
  def normalize_final_answer(%{ok: answer}), do: {:ok, answer}
  def normalize_final_answer(%{"error" => reason}), do: {:error, reason}
  def normalize_final_answer(%{error: reason}), do: {:error, reason}

  # Pythonic default: assigning any non-nil value to final_answer means success.
  def normalize_final_answer(other), do: {:ok, other}

  def normalize_survey_answers(value) do
    value
    |> RLM.Survey.normalize_answers()
  end

  def decode_captured_output(python_globals) when is_map(python_globals) do
    stdout = python_globals |> Map.get("_rlm_stdout_buffer") |> decode_output_chunks()
    stderr = python_globals |> Map.get("_rlm_stderr_buffer") |> decode_output_chunks()
    {stdout, stderr}
  end

  def format_python_exception(error) do
    error
    |> Exception.message()
    |> String.replace_prefix("Python exception raised\n\n", "")
    |> String.replace(~r/^ {8}/m, "")
    |> String.trim_trailing()
  end

  defp normalize_status_payload(status, payload) when status in ["ok", :ok], do: {:ok, payload}

  defp normalize_status_payload(status, payload) when status in ["error", :error],
    do: {:error, payload}

  defp normalize_status_payload(status, payload),
    do: {:invalid, %{status: status, payload: payload}}

  defp decode_output_chunks(nil), do: ""

  defp decode_output_chunks(chunks) do
    chunks
    |> decode_term()
    |> normalize_output_chunks()
  end

  defp normalize_output_chunks(chunks) when is_list(chunks) do
    Enum.map_join(chunks, "", &chunk_to_string/1)
  end

  defp normalize_output_chunks(other), do: chunk_to_string(other)

  defp chunk_to_string(chunk) when is_binary(chunk), do: chunk

  defp chunk_to_string(chunk) when is_list(chunk) do
    chunk
    |> List.to_string()
  rescue
    _ -> inspect(chunk)
  end

  defp chunk_to_string(chunk) do
    to_string(chunk)
  rescue
    _ -> inspect(chunk)
  end
end
