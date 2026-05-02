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
  end

  test "visual screen requests do not add the directive when computer use is disabled" do
    Application.put_env(:optimal_system_agent, :computer_use_enabled, false)

    assert [%{role: "user", content: "what do you see on the screen"}] =
             MessageHandler.build_messages("what do you see on the screen", %{
               turn_count: 0,
               permission_tier: :full
             })
  end
end
