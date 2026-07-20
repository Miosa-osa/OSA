defmodule OptimalSystemAgent.Agent.Loop.MessageHandlerTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.MessageHandler

  setup do
    original = Application.get_env(:optimal_system_agent, :computer_use_enabled)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:optimal_system_agent, :computer_use_enabled)
      else
        Application.put_env(:optimal_system_agent, :computer_use_enabled, original)
      end
    end)

    :ok
  end

  test "visual screen requests force an observation directive when computer use is enabled" do
    Application.put_env(:optimal_system_agent, :computer_use_enabled, true)

    messages =
      MessageHandler.build_messages("what do you see on the screen", %{
        turn_count: 0,
        permission_tier: :full
      })

    assert [
             %{role: "system", content: directive},
             %{role: "user", content: "what do you see on the screen"}
           ] = messages

    assert directive =~ "Do not guess"
    assert directive =~ "computer_use"
    assert directive =~ "`snapshot`"
    assert directive =~ "answer the user normally"
    assert directive =~ "concrete failure"
  end

  test "visual observation detection is signal based, not tied to one exact phrase" do
    Application.put_env(:optimal_system_agent, :computer_use_enabled, true)

    messages =
      MessageHandler.build_messages("can you inspect this terminal here", %{
        turn_count: 0,
        permission_tier: :full
      })

    assert [%{role: "system", content: directive}, %{role: "user"}] = messages
    assert directive =~ "computer_use"
  end

  test "visual screen requests do not add the directive when computer use is disabled" do
    Application.put_env(:optimal_system_agent, :computer_use_enabled, false)

    assert [%{role: "user", content: "what do you see on the screen"}] =
             MessageHandler.build_messages("what do you see on the screen", %{
               turn_count: 0,
               permission_tier: :full
             })
  end

  # --- systematic-debugging directive ---------------------------------------

  defp dsid,
    do: "mh-dbg-" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false))

  defp debugging_directive?(messages) do
    Enum.any?(messages, fn
      %{role: "system", content: c} when is_binary(c) -> c =~ "ROOT CAUSE"
      _ -> false
    end)
  end

  test "a bug report injects a one-shot systematic-debugging directive" do
    messages =
      MessageHandler.build_messages("fix the crash: TypeError: undefined is not a function", %{
        turn_count: 1,
        permission_tier: :full,
        session_id: dsid()
      })

    directive =
      Enum.find_value(messages, fn
        %{role: "system", content: c} when is_binary(c) -> if c =~ "ROOT CAUSE", do: c
        _ -> nil
      end)

    assert is_binary(directive)
    assert directive =~ "REPRODUCE"
    assert directive =~ "do NOT symptom-patch"
    assert directive =~ "ROOT CAUSE"
    assert directive =~ "REGRESSION TEST"
    assert directive =~ "VERIFY"

    # The genuine user message is still present and last.
    assert %{role: "user", content: "fix the crash: TypeError: undefined is not a function"} =
             List.last(messages)
  end

  test "a normal feature request injects NO debugging directive (zero added tokens)" do
    messages =
      MessageHandler.build_messages("add a dark mode toggle to settings", %{
        turn_count: 1,
        permission_tier: :full,
        session_id: dsid()
      })

    refute debugging_directive?(messages)
  end

  test "the debugging directive fires at most once per session (dedup)" do
    sid = dsid()
    state = %{turn_count: 1, permission_tier: :full, session_id: sid}

    first = MessageHandler.build_messages("the app is broken and keeps crashing", state)
    second = MessageHandler.build_messages("still broken, throws an exception", state)

    assert debugging_directive?(first)
    refute debugging_directive?(second)
  end
end
