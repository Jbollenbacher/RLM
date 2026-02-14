defmodule RLM.SampleRate do
  @moduledoc false

  @default 0.25

  @spec normalize(term()) :: float()
  def normalize(rate) when is_float(rate), do: clamp(rate)
  def normalize(rate) when is_integer(rate), do: clamp(rate * 1.0)

  def normalize(rate) when is_binary(rate) do
    case Float.parse(rate) do
      {parsed, _} -> clamp(parsed)
      _ -> @default
    end
  end

  def normalize(_), do: @default

  defp clamp(rate) when rate < 0.0, do: 0.0
  defp clamp(rate) when rate > 1.0, do: 1.0
  defp clamp(rate), do: rate
end
