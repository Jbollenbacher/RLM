defmodule RLM do
  @moduledoc "Recursive Language Model — public API."

  def run(context, query, opts \\ []) do
    session = RLM.Session.start(context, opts)
    {result, _session} = RLM.Session.ask(session, query)
    result
  end
end
