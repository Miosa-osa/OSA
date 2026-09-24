defmodule OptimalSystemAgent.Agent.Loop.SendNowReachesModelTest do
  @moduledoc """
  Item 2 correctness guarantee: a message the user sends mid-turn ALWAYS reaches
  the model.

  Queued messages must never be ignored. Here we
  prove the property directly against the real loop: a message queued while the
  model is generating is folded into history and is present on the NEXT
  generation the model sees — as a `user`-role turn carrying the user's own words
  (item / operator scope: minimal framing, no imperatives).
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ReactLoop
  alias OptimalSystemAgent.Agent.Loop.SendNow
  alias OptimalSystemAgent.Agent.Loop.Steer
  alias OptimalSystemAgent.Test.MockProvider

  @midturn "REDIRECT: switch to the billing bug"

  setup do
    prev_provider = Application.get_env(:optimal_system_agent, :default_provider)
    prev_max_iter = Application.get_env(:optimal_system_agent, :max_iterations)
    Application.put_env(:optimal_system_agent, :default_provider, :mock)
    Application.put_env(:optimal_system_agent, :max_iterations, 12)

    on_exit(fn ->
      restore(:default_provider, prev_provider)
      restore(:max_iterations, prev_max_iter)
      Application.delete_env(:optimal_system_agent, :mock_provider_after_call_once)
      Application.delete_env(:optimal_system_agent, :mock_provider_final_text)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, value), do: Application.put_env(:optimal_system_agent, key, value)

  defp base_state(sid) do
    Map.from_struct(%OptimalSystemAgent.Agent.Loop{
      session_id: sid,
      provider: :mock,
      model: "mock-model-1.0",
      iteration: 0,
      auto_continues: 0,
      overflow_retries: 0,
      messages: [%{role: "user", content: "start the original task"}],
      tools: [],
      permission_mode: :ask,
      permission_tier: :full,
      working_dir: File.cwd!()
    })
  end

  test "a message sent mid-turn (send-now) reaches the model on the next generation" do
    sid = "send-now-reach-#{System.unique_integer([:positive])}"
    on_exit(fn -> SendNow.clear(sid) end)
    on_exit(fn -> Steer.drain(sid) end)

    # The mock's FIRST generation returns a tool_call; WHILE it generates, the
    # user sends a message via send-now (the exact production path the TUI uses).
    Application.put_env(:optimal_system_agent, :mock_provider_after_call_once, fn ->
      SendNow.request(sid, [@midturn])
    end)

    {_response, state} = ReactLoop.run(base_state(sid))

    # The message reached the model: it is in the conversation history, as a
    # user turn carrying the user's verbatim text.
    steer_msg =
      Enum.find(state.messages, fn m ->
        (m[:role] == "user" or m["role"] == "user") and
          is_binary(m[:content] || m["content"]) and
          String.contains?(m[:content] || m["content"], @midturn)
      end)

    assert steer_msg, "the mid-turn message never reached the model's conversation history"

    content = steer_msg[:content] || steer_msg["content"]

    # Minimal framing (operator scope): the user's words plus only the neutral
    # marker — no imperatives, no "URGENT", no plan-dropping directive.
    assert content =~ Steer.marker()
    refute String.downcase(content) =~ "urgent"
    refute String.downcase(content) =~ "do not finish"

    # The queue was fully consumed — no double injection, nothing stranded.
    assert Steer.count(sid) == 0
    refute SendNow.flagged?(sid)
  end
end
