defmodule RLM.SessionServer do
  @moduledoc """
  A GenServer that manages the lifecycle of an `RLM.Session`.
  This allows for long-lived, stateful sessions that can be tracked via PID or ID.
  """
  use GenServer, restart: :temporary

  alias RLM.Session

  defstruct [:session]

  @type t :: %__MODULE__{session: Session.t()}

  # Client API
  @doc "Starts a new session server."
  def start_link({context, opts}) when is_binary(context) and is_list(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, {context, opts}, name: name)
  end

  def start_link(context, opts) when is_binary(context) and is_list(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, {context, opts}, name: name)
  end

  @doc "Sends a query to the session and waits for the response."
  def ask(pid, message, timeout \\ :infinity) do
    GenServer.call(pid, {:ask, message}, timeout)
  end

  @doc "Returns the current state of the session."
  def get_state(pid, timeout \\ 5_000) do
    GenServer.call(pid, :get_state, timeout)
  end

  # Server Callbacks
  @impl true
  def init({context, opts}) do
    session_opts = Keyword.drop(opts, [:name])
    session = Session.start(context, session_opts)
    {:ok, %__MODULE__{session: session}}
  end

  @impl true
  def handle_call({:ask, message}, _from, %__MODULE__{} = state) do
    {result, new_session} = Session.ask(state.session, message)
    {:reply, result, %{state | session: new_session}}
  end

  @impl true
  def handle_call(:get_state, _from, %__MODULE__{} = state) do
    {:reply, state.session, state}
  end

  @impl true
  def terminate(reason, %__MODULE__{session: session}) do
    status = if reason in [:normal, :shutdown], do: :done, else: :error
    RLM.Observability.emit([:rlm, :agent, :end], %{}, %{agent_id: session.id, status: status})
    :ok
  end
end
