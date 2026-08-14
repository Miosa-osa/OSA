defmodule OptimalSystemAgent.Providers.CompatSystemShapeTest do
  @moduledoc """
  Anthropic and Gemini reject a `system` message that follows assistant text:

      messages.N: role 'system' must follow a 'user' message or an assistant
      message ending in a server tool result

  `Providers.Anthropic.split_system/2` has always demoted non-leading system
  messages for the NATIVE path. `OpenAICompatProvider` had no equivalent, so an
  Anthropic or Gemini model reached through OpenRouter — or any other
  OpenAI-compatible gateway — still received the invalid shape and returned a
  hard 400.

  Measured under real benchmark conditions AFTER nine emitter sites were fixed:
  `claude-opus-5` via OpenRouter still returned `messages.65: role 'system'
  must follow...`, role tail `[…assistant, tool, assistant, system]`. Fixing
  emitters one at a time cannot close this — one missed site anywhere
  reintroduces it — so the guard lives at the wire, where every message passes
  exactly once.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.OpenAICompatProvider, as: Compat

  test "a leading system run is preserved" do
    msgs = [
      %{"role" => "system", "content" => "you are OSA"},
      %{"role" => "system", "content" => "more prompt"},
      %{"role" => "user", "content" => "hi"}
    ]

    assert Compat.demote_non_leading_system(msgs) == msgs
  end

  test "a system message after assistant text is demoted" do
    msgs = [
      %{"role" => "system", "content" => "prompt"},
      %{"role" => "user", "content" => "fix it"},
      %{"role" => "assistant", "content" => "done"},
      %{"role" => "system", "content" => "verify your work"}
    ]

    assert [_, _, _, %{"role" => "user", "content" => "verify your work"}] =
             Compat.demote_non_leading_system(msgs)
  end

  test "the exact shape that produced the 400 is corrected" do
    # role tail as captured on the wire: assistant, tool, assistant, system
    msgs = [
      %{"role" => "system", "content" => "prompt"},
      %{"role" => "user", "content" => "task"},
      %{"role" => "assistant", "content" => "thinking"},
      %{"role" => "tool", "content" => "result"},
      %{"role" => "assistant", "content" => "answer"},
      %{"role" => "system", "content" => "steer"}
    ]

    out = Compat.demote_non_leading_system(msgs)
    roles = Enum.map(out, & &1["role"])

    assert roles == ~w(system user assistant tool assistant user)

    refute Enum.any?(Enum.drop(out, 1), &(&1["role"] == "system")),
           "no system message may survive past the leading run"
  end

  test "atom-keyed messages are handled too" do
    msgs = [
      %{role: "user", content: "x"},
      %{role: "system", content: "steer"}
    ]

    assert [_, %{role: "user"}] = Compat.demote_non_leading_system(msgs)
  end

  test "a non-list is returned untouched rather than raising" do
    assert Compat.demote_non_leading_system(nil) == nil
    assert Compat.demote_non_leading_system("oops") == "oops"
  end
end
