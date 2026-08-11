defmodule OptimalSystemAgent.Providers.ThinkStreamParserTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.ThinkStreamParser, as: P
  alias OptimalSystemAgent.Utils.Text

  # Drive a list of chunks through the streaming parser exactly as the SSE loop
  # does, then flush. Returns {visible, thinking}.
  defp run(chunks) do
    {vis, think, state} =
      Enum.reduce(chunks, {"", "", P.new()}, fn chunk, {v, t, s} ->
        {dv, dt, s2} = P.feed(s, chunk)
        {v <> dv, t <> dt, s2}
      end)

    {fv, ft, _} = P.flush(state)
    {vis <> fv, think <> ft}
  end

  describe "inline <think> stripping" do
    test "strips a complete inline think block from a single chunk" do
      {visible, thinking} =
        run(["Let me plan.<think>fire parallel shell commands</think>Oh that's fun."])

      assert visible == "Let me plan.Oh that's fun."
      assert thinking == "fire parallel shell commands"
      refute visible =~ "<think>"
      refute visible =~ "</think>"
    end

    test "routes reasoning to thinking and never leaks the closing tag (real glm format)" do
      # The exact on-screen leak from the bug report — glm streams the opening
      # <think>, reasons, then </think>, then the answer.
      {visible, thinking} =
        run([
          "<think>build a beautiful HTML dashboard. Let me fire off a bunch of parallel shell commands to gather real data.</think>Oh that's a fun one"
        ])

      assert visible == "Oh that's a fun one"
      refute visible =~ "</think>"
      refute visible =~ "<think>"
      assert thinking =~ "parallel shell commands"
    end

    test "a stray closing tag (no matching open) is stripped, never shown literally" do
      # Defensive path: even if the opening tag never arrived, the literal
      # </think> must not leak into the visible answer.
      {visible, _thinking} = run(["some text</think>more"])
      refute visible =~ "</think>"
      assert visible == "some textmore"
    end
  end

  describe "tags split across chunks" do
    test "an opening tag split across chunks is never shown then rewritten" do
      {visible, thinking} = run(["hello <", "thi", "nk>secret</think> world"])
      assert visible == "hello  world"
      assert thinking == "secret"
      refute visible =~ "<"
    end

    test "a closing tag split across chunks is handled" do
      {visible, thinking} = run(["<think>rea", "soning</th", "ink>answer"])
      assert visible == "answer"
      assert thinking == "reasoning"
    end

    test "a lone '<' tail is buffered, not emitted, until it resolves to plain text" do
      # After "<" we hold; the next chunk reveals it is NOT a think tag.
      {visible, thinking} = run(["a <", "b > c"])
      assert visible == "a <b > c"
      assert thinking == ""
    end
  end

  describe "unclosed leading think block" do
    test "an unclosed <think> routes all following text to thinking" do
      {visible, thinking} = run(["<think>still reasoning, never closed"])
      assert visible == ""
      assert thinking == "still reasoning, never closed"
    end

    test "unclosed block that closes in a later chunk splits correctly" do
      {visible, thinking} =
        run(["<think>reasoning here", " still reasoning</think>", "the answer"])

      assert visible == "the answer"
      assert thinking == "reasoning here still reasoning"
    end
  end

  describe "variants and false positives" do
    test "handles <thinking> and <reason> variants" do
      {v1, t1} = run(["a<thinking>x</thinking>b"])
      assert v1 == "ab" and t1 == "x"

      {v2, t2} = run(["a<reason>y</reason>b"])
      assert v2 == "ab" and t2 == "y"
    end

    test "non-think tags are preserved in the visible output" do
      {visible, thinking} = run(["use <div> and <span> tags"])
      assert visible == "use <div> and <span> tags"
      assert thinking == ""
    end

    test "a tag-lookalike that is not a think tag is not swallowed" do
      {visible, thinking} = run(["<thinker> is a person"])
      assert visible == "<thinker> is a person"
      assert thinking == ""
    end
  end

  describe "no inline tags (native reasoning path untouched)" do
    test "plain content passes through unchanged as visible" do
      {visible, thinking} = run(["just", " a normal ", "answer"])
      assert visible == "just a normal answer"
      assert thinking == ""
    end
  end

  describe "persisted transcript stripping (strip_thinking_tokens)" do
    test "strips closed variants and unclosed leading tags" do
      assert Text.strip_thinking_tokens("a<think>r</think>b") == "ab"
      assert Text.strip_thinking_tokens("a<thinking>r</thinking>b") == "ab"
      assert Text.strip_thinking_tokens("a<reason>r</reason>b") == "ab"
      # Unclosed leading block → everything from the tag onward is dropped.
      assert Text.strip_thinking_tokens("visible then <think>runaway reasoning") == "visible then"
    end
  end
end
