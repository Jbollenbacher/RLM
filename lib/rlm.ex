defmodule RLM do
  @moduledoc "Recursive Language Model — public API."

  def run(context, query, opts \\ []) do
    agent_id =
      Keyword.get(
        opts,
        :agent_id,
        Keyword.get(opts, :session_id, RLM.Helpers.unique_id("agent"))
      )

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
