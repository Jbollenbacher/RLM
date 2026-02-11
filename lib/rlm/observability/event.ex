defmodule RLM.Observability.Event do
  @moduledoc "Event schema and helpers for observability."

  @enforce_keys [:agent_id, :type]
  defstruct [:id, :agent_id, :type, :ts, :payload]

  @spec new(String.t(), atom(), map()) :: %__MODULE__{}
  def new(agent_id, type, payload \\ %{}) do
    %__MODULE__{
      agent_id: agent_id,
      type: type,
      payload: payload
    }
  end
end
