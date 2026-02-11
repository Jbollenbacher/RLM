defmodule RLM.Sandbox do
  defdelegate chunks(string, size), to: RLM.Helpers
  defdelegate grep(pattern, string), to: RLM.Helpers
  defdelegate preview(term, n \\ 500), to: RLM.Helpers
  defdelegate latest_principal_message(context), to: RLM.Helpers

  @deprecated "Use latest_principal_message/1"
  def latest_user_message(context), do: RLM.Helpers.latest_principal_message(context)

  def ls(path \\ ".") do
    case Process.get(:rlm_workspace_root) do
      nil -> {:error, "workspace_root not set"}
      root -> RLM.Helpers.ls(root, path)
    end
  end

  def read_file(path, max_bytes \\ nil) do
    case Process.get(:rlm_workspace_root) do
      nil -> {:error, "workspace_root not set"}
      root -> RLM.Helpers.read_file(root, path, max_bytes)
    end
  end

  def edit_file(path, patch) do
    case Process.get(:rlm_workspace_root) do
      nil ->
        {:error, "workspace_root not set"}

      root ->
        if Process.get(:rlm_workspace_read_only, false) do
          {:error, "Workspace is read-only"}
        else
          RLM.Helpers.edit_file(root, path, patch)
        end
    end
  end

  def create_file(path, content) do
    case Process.get(:rlm_workspace_root) do
      nil ->
        {:error, "workspace_root not set"}

      root ->
        if Process.get(:rlm_workspace_read_only, false) do
          {:error, "Workspace is read-only"}
        else
          RLM.Helpers.create_file(root, path, content)
        end
    end
  end


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
