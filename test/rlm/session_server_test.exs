defmodule RLM.SessionServerTest do
  use ExUnit.Case
  alias RLM.Session
  @moduletag :integration
  @moduletag :capture_log
  test "starts a session and maintains state across calls" do
    {:ok, session_id} = RLM.start_session("You are a memory test assistant.", [])
    on_exit(fn -> RLM.stop_session(session_id) end)

    # First ask
    {:ok, response1} =
      RLM.run("", "Remember the word 'Pineapple'. Just reply with 'OK'.", session_id: session_id)

    assert response1 =~ "OK"
    # Second ask - verify memory
    {:ok, response2} = RLM.run("", "What word did I ask you to remember?", session_id: session_id)
    assert response2 =~ "Pineapple"
    # Verify state via get_state
    assert {:ok, %Session{} = session} = RLM.get_session_state(session_id)
    assert is_binary(session.id)
    # System + Principal + Agent + Principal + Agent
    assert length(session.history) >= 5
  end
end
