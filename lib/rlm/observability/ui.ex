defmodule RLM.Observability.UI do
  @moduledoc false

  @priv_dir :code.priv_dir(:rlm)
  @html_path Path.join(@priv_dir, "observability_ui.html")
  @js_glob Path.join([@priv_dir, "observability_ui", "*.js"])
  @js_placeholder "/*__RLM_OBSERVABILITY_APP_JS__*/"
  @js_bundle @js_glob
             |> Path.wildcard()
             |> Enum.sort()
             |> Enum.map_join("\n\n", &File.read!/1)

  @html File.read!(@html_path)
        |> String.replace(@js_placeholder, @js_bundle)

  def html, do: @html
end
