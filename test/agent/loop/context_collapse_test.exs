defmodule OptimalSystemAgent.Agent.Loop.ContextCollapseTest do
  @moduledoc """
  Reproduces the audit-item-3 gap: `collapse/2` only ever withholds TOOL
  results, and the compactor's hot-zone selection deliberately preserves the
  single most-recent turn VERBATIM no matter how large it is — so a latest
  USER message that is, on its own, bigger than the model's context window
  survives every recovery attempt unchanged and the turn fails as a context
  overflow forever.

  `trim_oversized_latest_message/3` is the last-resort fix: keep a head+tail
  excerpt inline, write the untouched original to disk, and say so in the
  message so the model can retrieve the omitted middle with `file_read`.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ContextCollapse
  alias OptimalSystemAgent.Agent.Loop.ToolResultStorage

  defp sid, do: "ctxcollapse-#{System.unique_integer([:positive])}"

  # Vastly larger than half of even a generous window regardless of the
  # token-estimation heuristic's exact constants.
  defp huge_text, do: String.duplicate("word ", 40_000)

  describe "trim_oversized_latest_message/3 — no oversized user message to trim" do
    test "a small latest user message returns :error (nothing to do)" do
      messages = [%{role: "user", content: "hello there"}]
      assert ContextCollapse.trim_oversized_latest_message(messages, 200_000, sid()) == :error
    end

    test "no user message at all returns :error" do
      messages = [
        %{role: "assistant", content: "an answer with no preceding user turn on record"}
      ]

      assert ContextCollapse.trim_oversized_latest_message(messages, 2_000, sid()) == :error
    end

    test "a huge SCAFFOLD interrupt marker is never the trim target" do
      messages = [
        %{role: "user", content: "a normal-sized real request"},
        %{role: "user", content: huge_text(), scaffold: true}
      ]

      # The only candidate is the small, non-scaffold user message — not
      # oversized against a generous window, so still :error.
      assert ContextCollapse.trim_oversized_latest_message(messages, 200_000, sid()) == :error
    end
  end

  describe "trim_oversized_latest_message/3 — the latest user message alone blows the budget" do
    setup do
      session = sid()
      on_exit(fn -> ToolResultStorage.cleanup(session) end)
      {:ok, session: session}
    end

    test "trims to a head+tail excerpt and persists the full text to disk", %{session: session} do
      text = huge_text()
      messages = [%{role: "user", content: text}]

      # A small explicit window (bare integer, the raw shape) so the huge
      # text is unambiguously more than half of it.
      assert {:ok, [trimmed]} =
               ContextCollapse.trim_oversized_latest_message(messages, 2_000, session)

      assert trimmed.role == "user"
      assert trimmed.content != text
      assert trimmed.content =~ "larger than half the model's context window"
      assert trimmed.content =~ "word word word"
      assert trimmed.content =~ "file_read"

      # The full, untouched original must be recoverable — not just implied.
      [path] = Regex.run(~r/saved to (\S+\.txt)/, trimmed.content, capture: :all_but_first)
      assert File.read!(path) == text
    end

    test "accepts the {:ok, n} context-window shape ContextWindow.resolve/1 returns", %{
      session: session
    } do
      messages = [%{role: "user", content: huge_text()}]

      assert {:ok, [trimmed]} =
               ContextCollapse.trim_oversized_latest_message(messages, {:ok, 2_000}, session)

      assert trimmed.content =~ "larger than half"
    end

    test "an :unknown context window falls back to a real ceiling instead of crashing", %{
      session: session
    } do
      # The fallback ceiling is a real, generous window (200k tokens) — needs
      # a text well past `huge_text/0` to unambiguously clear half of it too,
      # so this exercises the SAME fallback path a genuinely unresolvable
      # session window would hit, rather than silently passing through.
      messages = [%{role: "user", content: String.duplicate("word ", 250_000)}]

      assert {:ok, [trimmed]} =
               ContextCollapse.trim_oversized_latest_message(messages, :unknown, session)

      assert trimmed.content =~ "larger than half"
    end

    test "only the LATEST user message is touched — earlier history and later turns are untouched",
         %{session: session} do
      tc = %{id: "tc_1", name: "read_file", arguments: %{}}

      messages = [
        %{role: "user", content: "first, normal-sized request"},
        %{role: "assistant", content: "", tool_calls: [tc]},
        %{role: "tool", tool_call_id: "tc_1", content: "file contents"},
        %{role: "assistant", content: "here is what I found"},
        %{role: "user", content: huge_text()}
      ]

      assert {:ok, trimmed_messages} =
               ContextCollapse.trim_oversized_latest_message(messages, 2_000, session)

      assert length(trimmed_messages) == length(messages)
      # Order preserved; every message except the last is byte-for-byte
      # unchanged.
      assert Enum.take(trimmed_messages, 4) == Enum.take(messages, 4)
      assert List.last(trimmed_messages).content =~ "larger than half"
    end
  end
end
