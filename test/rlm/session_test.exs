defmodule RLM.SessionTest do
  use ExUnit.Case

  @moduletag :integration
  @moduletag :capture_log

  test "maintains state across calls in a direct session" do
    session = RLM.Session.start("You are a memory test assistant.")

    {:ok, response1, session} =
      case RLM.Session.ask(session, "Remember the word 'Pineapple'. Just reply with 'OK'.") do
        {{:ok, response}, next_session} -> {:ok, response, next_session}
        {{:error, reason}, _next_session} -> flunk("Unexpected error on first ask: #{reason}")
      end

    assert response1 =~ "OK"

    {:ok, response2, session} =
      case RLM.Session.ask(session, "What word did I ask you to remember?") do
        {{:ok, response}, next_session} -> {:ok, response, next_session}
        {{:error, reason}, _next_session} -> flunk("Unexpected error on second ask: #{reason}")
      end

    assert response2 =~ "Pineapple"
    assert is_binary(session.id)
    assert length(session.history) >= 5
  end
end
