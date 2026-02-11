defmodule RLM do
  @moduledoc "Recursive Language Model — public API."

  @spec start_session(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def start_session(context, opts \\ []) do
    RLM.Sessions.start(context, opts)
  end

  @spec stop_session(String.t()) :: :ok | {:error, String.t()}
  def stop_session(session_id) do
    RLM.Sessions.stop(session_id)
  end

  @spec get_session_state(String.t()) :: {:ok, RLM.Session.t()} | {:error, String.t()}
  def get_session_state(session_id) do
    RLM.Sessions.get_state(session_id)
  end

  def run(context, query, opts \\ []) do
    case {Keyword.get(opts, :session_id), Keyword.get(opts, :session_pid)} do
      {session_id, _} when is_binary(session_id) ->
        RLM.Sessions.ask(session_id, query)

      {_, pid} when is_pid(pid) ->
        RLM.SessionServer.ask(pid, query)

      _ ->
        agent_id = Keyword.get(opts, :agent_id, RLM.Helpers.unique_id("agent"))
        parent_agent_id = Keyword.get(opts, :parent_agent_id)

        session =
          RLM.Session.start(
            context,
            Keyword.merge(opts,
              session_id: agent_id,
              parent_agent_id: parent_agent_id
            )
          )

        {result, _session} = RLM.Session.ask(session, query)
        status = if match?({:ok, _}, result), do: :done, else: :error

        RLM.Observability.emit([:rlm, :agent, :end], %{}, %{agent_id: agent_id, status: status})
        result
    end
  end
end
