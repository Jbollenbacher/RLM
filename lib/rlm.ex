defmodule RLM do
  @moduledoc "Recursive Language Model — public API."

  def run(context, query, opts \\ []) do
    RLM.Loop.run(Keyword.merge(opts, context: context, query: query))
  end
end
