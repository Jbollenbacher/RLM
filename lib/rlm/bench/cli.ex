defmodule RLM.Bench.CLI do
  @moduledoc false

  @spec raise_on_invalid_flags!(list()) :: :ok
  def raise_on_invalid_flags!([]), do: :ok

  def raise_on_invalid_flags!(invalid) do
    invalid_list =
      invalid
      |> Enum.map(fn
        {flag, _value} -> to_string(flag)
        flag -> to_string(flag)
      end)
      |> Enum.join(", ")

    Mix.raise("Unknown or invalid options: #{invalid_list}")
  end

  @spec resolve_bool_flag(keyword(), atom(), atom(), boolean()) :: boolean()
  def resolve_bool_flag(opts, positive_key, negative_key, default \\ true) do
    cond do
      Keyword.get(opts, negative_key, false) -> !default
      Keyword.has_key?(opts, positive_key) -> Keyword.get(opts, positive_key)
      true -> default
    end
  end
end
