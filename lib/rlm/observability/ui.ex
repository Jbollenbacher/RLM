defmodule RLM.Observability.UI do
  @moduledoc false

  @html File.read!(Path.join(:code.priv_dir(:rlm), "observability_ui.html"))

  def html, do: @html
end
