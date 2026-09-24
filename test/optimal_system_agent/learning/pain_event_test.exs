defmodule OptimalSystemAgent.Learning.PainEventTest do
  @moduledoc """
  Unit tests for `OptimalSystemAgent.Learning.PainEvent` — the sanitizing
  constructor every pain signal must pass through before it is buffered,
  mirrored to the event bus, or ever considered for a durable lesson.
  """

  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Learning.PainEvent

  describe "new/4" do
    test "builds a struct with the given kind, session, detail and a timestamp" do
      event = PainEvent.new(:repeated_probe, "sess-1", "shell_execute repeated 3x")

      assert %PainEvent{} = event
      assert event.kind == :repeated_probe
      assert event.session_id == "sess-1"
      assert event.detail == "shell_execute repeated 3x"
      assert %DateTime{} = event.at
      assert event.metadata == %{}
    end

    test "carries through arbitrary metadata" do
      event = PainEvent.new(:command_fix, "sess-1", "retried", %{attempts: 2})
      assert event.metadata == %{attempts: 2}
    end

    test "unknown kinds fall back to :other rather than raising" do
      event = PainEvent.new(:not_a_real_kind, "sess-1", "detail")
      assert event.kind == :other
    end

    test "kinds/0 lists exactly the fixed vocabulary" do
      assert PainEvent.kinds() == [
               :repeated_probe,
               :reverification_loop,
               :command_fix,
               :wrong_checkout,
               :slow_search,
               :user_correction,
               :other
             ]
    end
  end

  describe "sanitize/1 — secret redaction" do
    test "redacts a bearer token" do
      out = PainEvent.sanitize("failed with header Bearer sk-abcdefghijklmnopqrstuvwxyz1234")
      refute out =~ "sk-abcdefghijklmnopqrstuvwxyz1234"
      assert out =~ "[redacted]"
    end

    test "redacts an api_key=... assignment" do
      out = PainEvent.sanitize("curl failed, api_key=abcdef123456 was rejected")
      refute out =~ "abcdef123456"
      assert out =~ "[redacted]"
    end

    test "redacts a long base64-looking blob" do
      blob = String.duplicate("A", 60)
      out = PainEvent.sanitize("token dump: #{blob}")
      refute out =~ blob
    end

    test "redacts an AWS-shaped access key id" do
      out = PainEvent.sanitize("AKIAABCDEFGHIJKLMNOP leaked in logs")
      refute out =~ "AKIAABCDEFGHIJKLMNOP"
    end
  end

  describe "sanitize/1 — file/diff content collapse" do
    test "collapses a multi-line diff dump to a short synopsis" do
      dump = """
      diff --git a/lib/foo.ex b/lib/foo.ex
      --- a/lib/foo.ex
      +++ b/lib/foo.ex
      @@ -1,3 +1,3 @@
      -old line
      +new line
      """

      out = PainEvent.sanitize(dump)
      refute out =~ "old line"
      refute out =~ "new line"
      assert out =~ "omitted"
    end

    test "collapses any long multi-line blob even without diff markers" do
      long_text = Enum.map_join(1..20, "\n", &"line #{&1} of file content")
      out = PainEvent.sanitize(long_text)
      refute out =~ "line 1 of file content"
      assert out =~ "omitted"
    end

    test "leaves a short, single-line detail untouched (besides trimming)" do
      out = PainEvent.sanitize("shell_execute took 9000ms")
      assert out == "shell_execute took 9000ms"
    end
  end

  describe "sanitize/1 — length cap and whitespace" do
    test "truncates very long text to the cap" do
      out = PainEvent.sanitize(String.duplicate("x", 5_000))
      assert String.length(out) <= 200
    end

    test "collapses internal whitespace runs" do
      out = PainEvent.sanitize("a    b\t\tc")
      assert out == "a b c"
    end

    test "non-binary input is inspected then sanitized rather than raising" do
      out = PainEvent.sanitize(%{reason: :boom})
      assert is_binary(out)
    end
  end
end
