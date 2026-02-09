defmodule RLM.Truncate do
  @spec truncate(String.t(), keyword()) :: String.t()
  def truncate(text, opts \\ []) do
    head = Keyword.get(opts, :head, 4000)
    tail = Keyword.get(opts, :tail, 4000)
    len = String.length(text)

    if len <= head + tail do
      text
    else
      omitted = len - head - tail

      String.slice(text, 0, head) <>
        "\n... [truncated #{omitted} chars] ...\n" <>
        String.slice(text, len - tail, tail)
    end
  end
end
