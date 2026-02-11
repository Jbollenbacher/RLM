defmodule RLM.Sessions do
  @moduledoc "Start and manage long-lived RLM sessions by ID."

  @registry RLM.SessionRegistry
  @supervisor RLM.SessionSupervisor

  @spec start(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def start(context, opts \\ []) when is_binary(context) do
    with :ok <- ensure_started() do
      id = Keyword.get(opts, :session_id, RLM.Helpers.unique_id("session"))
      opts = opts |> Keyword.put(:session_id, id) |> Keyword.put(:name, via(id))

      case DynamicSupervisor.start_child(@supervisor, {RLM.SessionServer, {context, opts}}) do
        {:ok, _pid} -> {:ok, id}
        {:error, {:already_started, _pid}} -> {:ok, id}
        {:error, {:already_present, _pid}} -> {:ok, id}
        {:error, _} = error -> error
      end
    end
  end

  @spec ask(String.t(), String.t(), timeout()) :: {:ok, String.t()} | {:error, String.t()}
  def ask(session_id, message, timeout \\ :infinity)
      when is_binary(session_id) and is_binary(message) do
    case lookup_pid(session_id) do
      {:ok, pid} -> RLM.SessionServer.ask(pid, message, timeout)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec get_state(String.t(), timeout()) :: {:ok, RLM.Session.t()} | {:error, String.t()}
  def get_state(session_id, timeout \\ 5_000) when is_binary(session_id) do
    case lookup_pid(session_id) do
      {:ok, pid} -> {:ok, RLM.SessionServer.get_state(pid, timeout)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec stop(String.t()) :: :ok | {:error, String.t()}
  def stop(session_id) when is_binary(session_id) do
    case lookup_pid(session_id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(@supervisor, pid)
        RLM.Observability.emit([:rlm, :agent, :end], %{}, %{agent_id: session_id, status: :done})
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec list() :: [String.t()]
  def list do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  defp lookup_pid(session_id) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, "Session not found: #{session_id}"}
    end
  end

  defp via(session_id), do: {:via, Registry, {@registry, session_id}}

  defp ensure_started do
    case Application.ensure_all_started(:rlm) do
      {:ok, _} -> :ok
      {:error, {app, reason}} -> {:error, "Failed to start #{app}: #{inspect(reason)}"}
    end
  end
end
