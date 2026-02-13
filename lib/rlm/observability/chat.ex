defmodule RLM.Observability.Chat do
  @moduledoc "Single-session chat backend for the embedded web UI."

  use GenServer

  alias RLM.Session
  alias RLM.Observability.Tracker

  @name __MODULE__
  @interrupt_note "[PRINCIPAL] Principal interrupted the previous generation."
  @interrupt_reply "[Interrupted] Generation stopped by principal."

  @type message :: %{
          id: pos_integer(),
          role: :user | :assistant,
          content: String.t(),
          ts: non_neg_integer()
        }

  @type running :: %{
          pid: pid(),
          monitor_ref: reference(),
          task_ref: reference(),
          started_at: non_neg_integer()
        }

  defstruct [:session, :ask_fn, :running, messages: [], next_message_id: 1]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @spec available?() :: boolean()
  def available? do
    Process.whereis(@name) != nil
  end

  @spec ask(String.t(), timeout()) :: {:ok, map()} | {:error, String.t()}
  def ask(message, timeout \\ 5_000) when is_binary(message) do
    if available?() do
      GenServer.call(@name, {:ask, message}, timeout)
    else
      {:error, "Web chat is not enabled"}
    end
  end

  @spec stop(timeout()) :: {:ok, map()} | {:error, String.t()}
  def stop(timeout \\ 5_000) do
    if available?() do
      GenServer.call(@name, :stop, timeout)
    else
      {:error, "Web chat is not enabled"}
    end
  end

  @spec state(timeout()) :: {:ok, map()} | {:error, String.t()}
  def state(timeout \\ 5_000) do
    if available?() do
      GenServer.call(@name, :state, timeout)
    else
      {:error, "Web chat is not enabled"}
    end
  end

  @impl true
  def init(opts) do
    context = Keyword.get(opts, :context, "")
    workspace_root = Keyword.get(opts, :workspace_root)
    workspace_read_only = Keyword.get(opts, :workspace_read_only, false)
    ask_fn = Keyword.get(opts, :ask_fn, &Session.ask/2)

    session =
      Session.start(context,
        workspace_root: workspace_root,
        workspace_read_only: workspace_read_only
      )

    {:ok, %__MODULE__{session: session, ask_fn: ask_fn}}
  end

  @impl true
  def handle_call({:ask, message}, _from, state) do
    content = String.trim(message)

    cond do
      content == "" ->
        {:reply, {:error, "Message cannot be empty"}, state}

      state.running != nil ->
        {:reply, {:error, "Generation already in progress"}, state}

      true ->
        {user_message, state} = append_message(state, :user, content)
        running = start_generation(state.ask_fn, state.session, content)
        emit_agent_status(state.session.id, :running)

        response = %{
          status: "accepted",
          session_id: state.session.id,
          user: user_message
        }

        {:reply, {:ok, response}, %{state | running: running}}
    end
  end

  def handle_call(:stop, _from, state) do
    case state.running do
      nil ->
        {:reply, {:ok, %{stopped: false, reason: "No generation in progress"}}, state}

      running ->
        Process.exit(running.pid, :kill)
        Process.demonitor(running.monitor_ref, [:flush])

        session = Session.principal_interrupt(state.session, @interrupt_note)

        {assistant_message, state} =
          append_message(%{state | running: nil, session: session}, :assistant, @interrupt_reply)

        emit_agent_status(session.id, :error, %{source: :web})
        Tracker.record_event(session.id, :principal_interrupt, %{source: :web})

        {:reply, {:ok, %{stopped: true, message: assistant_message}}, state}
    end
  end

  def handle_call(:state, _from, state) do
    payload = %{
      session_id: state.session.id,
      messages: state.messages,
      busy: state.running != nil
    }

    {:reply, {:ok, payload}, state}
  end

  @impl true
  def handle_info({:chat_result, task_ref, {result, session}}, state) do
    case state.running do
      %{task_ref: ^task_ref} = running ->
        Process.demonitor(running.monitor_ref, [:flush])
        state = %{state | running: nil, session: session}
        state = apply_result_message(state, result)
        emit_agent_status(session.id, result_status(result))
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:chat_result, _task_ref, _other_result}, state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, reason}, state) do
    case state.running do
      %{monitor_ref: ^monitor_ref} ->
        if reason == :normal do
          {:noreply, state}
        else
          error_text = "Error: generation failed (#{inspect(reason)})"
          state = %{state | running: nil}
          {_, state} = append_message(state, :assistant, error_text)
          emit_agent_status(state.session.id, :error, %{source: :chat_down, reason: inspect(reason)})
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  defp start_generation(ask_fn, session, content) do
    parent = self()
    task_ref = make_ref()

    pid =
      spawn(fn ->
        result =
          try do
            ask_fn.(session, content)
          rescue
            exception -> {{:error, Exception.message(exception)}, session}
          catch
            kind, reason -> {{:error, "#{kind}: #{inspect(reason)}"}, session}
          end

        send(parent, {:chat_result, task_ref, result})
      end)

    %{
      pid: pid,
      monitor_ref: Process.monitor(pid),
      task_ref: task_ref,
      started_at: System.system_time(:millisecond)
    }
  end

  defp apply_result_message(state, {:ok, answer}) do
    {_, state} = append_message(state, :assistant, answer)
    state
  end

  defp apply_result_message(state, {:error, reason}) do
    text = "Error: #{to_string(reason)}"
    {_, state} = append_message(state, :assistant, text)
    state
  end

  defp result_status({:ok, _answer}), do: :done
  defp result_status({:error, _reason}), do: :error

  defp emit_agent_status(agent_id, status, payload \\ %{}) do
    metadata =
      payload
      |> Map.put(:agent_id, agent_id)
      |> Map.put(:status, status)

    RLM.Observability.emit([:rlm, :agent, :status], %{}, metadata)
  end

  defp append_message(state, role, content) do
    message = %{
      id: state.next_message_id,
      role: role,
      content: normalize(content),
      ts: System.system_time(:millisecond)
    }

    next_state = %{
      state
      | messages: state.messages ++ [message],
        next_message_id: state.next_message_id + 1
    }

    {message, next_state}
  end

  defp normalize(content) when is_binary(content), do: content

  defp normalize(content),
    do: inspect(content, pretty: true, limit: :infinity, printable_limit: :infinity)
end
