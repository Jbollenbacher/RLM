defmodule RLM.Helpers do
  @spec unique_id(String.t()) :: String.t()
  def unique_id(prefix) when is_binary(prefix) and prefix != "" do
    "#{prefix}_#{System.unique_integer([:positive, :monotonic])}"
  end

  def unique_id(_prefix), do: "id_#{System.unique_integer([:positive, :monotonic])}"

  @chat_principal_marker "[RLM_Principal]"
  @chat_agent_marker "[RLM_Agent]"

  @spec chat_marker(:principal | :agent | :user | :assistant) :: String.t()
  def chat_marker(:principal), do: @chat_principal_marker
  def chat_marker(:agent), do: @chat_agent_marker
  def chat_marker(:user), do: @chat_principal_marker
  def chat_marker(:assistant), do: @chat_agent_marker

  @spec latest_principal_message(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def latest_principal_message(context) when is_binary(context) do
    pattern = ~r/^\[RLM_Principal\]\n(.*?)(?=^\[RLM_(?:Principal|Agent)\]|\z)/ms

    case Regex.scan(pattern, context) do
      [] ->
        {:error, "No chat entries found in context"}

      matches ->
        message =
          matches
          |> List.last()
          |> Enum.at(1)
          |> String.trim()

        {:ok, message}
    end
  end

  @spec format_value(term()) :: String.t()
  def format_value(value) when is_binary(value), do: value

  def format_value(value),
    do: inspect(value, pretty: true, limit: :infinity, printable_limit: :infinity)
end
