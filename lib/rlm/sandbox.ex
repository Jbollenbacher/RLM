defmodule RLM.Sandbox do
  defdelegate chunks(string, size), to: RLM.Helpers
  defdelegate grep(pattern, string), to: RLM.Helpers
  defdelegate preview(term, n \\ 500), to: RLM.Helpers

  def list_bindings do
    Process.get(:rlm_bindings_info, [])
  end

  def lm_query(text, opts) do
    case Process.get(:rlm_lm_query_fn) do
      nil -> {:error, "lm_query not available"}
      fun -> fun.(text, opts)
    end
  end
end
