defmodule OptimalSystemAgent.Agent.DefenseContextTest do
  use ExUnit.Case, async: true
  alias OptimalSystemAgent.Agent.DefenseContext

  test "malformed message collections do not break context assembly" do
    for messages <- [nil, %{}, "incident response"],
        do: assert(DefenseContext.block(%{messages: messages}) == nil)
  end

  test "defense requests expose the lab and defense skill routing" do
    for phrase <- ["simulate an attack and fix it", "cyber defence", "SIEM tuning"] do
      assert DefenseContext.block(%{messages: [%{role: :user, content: phrase}]}) =~
               "cyber_defense"
    end
  end

  test "tool output and assistant text do not activate defense guidance" do
    assert DefenseContext.block(%{
             messages: [
               %{role: :tool, content: "incident response"},
               %{role: :assistant, content: "attack simulation"},
               %{role: :user, content: "make a calendar"}
             ]
           }) == nil
  end

  test "handles serialized multimodal messages and expires old requests" do
    assert DefenseContext.block(%{
             messages: [
               %{
                 "role" => "user",
                 "content" => [%{"type" => "text", "text" => "endpoint hardening"}]
               }
             ]
           }) =~ "endpoint-hardening"

    messages =
      Enum.map(
        ["attack simulation", "hello", "calendar", "add a date"],
        &%{role: :user, content: &1}
      )

    assert DefenseContext.block(%{messages: messages}) == nil
  end
end
