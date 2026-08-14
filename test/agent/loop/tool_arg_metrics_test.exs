defmodule OptimalSystemAgent.Agent.Loop.ToolArgMetricsTest do
  @moduledoc """
  These tests are the regression guard for a measurement defect, not for a
  feature. `ToolHint.summarize/1` is a display string; for a while it was also
  the only argument-shaped field on the `:tool_call` event, and two published
  competitor comparisons were computed from it. Each test below pins the
  specific way the hint lied, by asserting that the metric does NOT agree with
  it.
  """

  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Loop.ToolArgMetrics
  alias OptimalSystemAgent.Agent.Loop.ToolHint

  describe "arg_bytes/1" do
    test "measures the whole shell command where the display hint stops at 60 characters" do
      # The shape that produced "OSA's median tool-call argument is 62 bytes":
      # a heredoc writing a real file, of the kind codex was credited with and
      # OSA was said never to emit.
      body = String.duplicate("(define (f x) (* x x))\n", 340)
      command = "cat > /app/eval.scm << 'EOF'\n" <> body <> "EOF"
      args = %{"command" => command}

      assert byte_size(ToolHint.summarize(args)) == 60
      assert ToolArgMetrics.arg_bytes(args) > 7_000
    end

    test "counts file_write content, which the display hint drops entirely" do
      args = %{"path" => "eval.scm", "content" => String.duplicate("x", 7_838)}

      # The hint is the bare path: eight bytes standing in for a 7 KB write.
      assert ToolHint.summarize(args) == "eval.scm"
      assert ToolArgMetrics.arg_bytes(args) > 7_838
    end

    test "handles the shapes that reach the telemetry path without raising" do
      assert ToolArgMetrics.arg_bytes(%{}) == 2
      assert ToolArgMetrics.arg_bytes(nil) == 0
      assert ToolArgMetrics.arg_bytes("raw string") == 10
      # A term Jason cannot encode must still yield a positive, non-misleading
      # size rather than crashing the emit or reporting zero work.
      assert ToolArgMetrics.arg_bytes(%{"pid" => self()}) > 0
    end
  end

  describe "arg_hash/1" do
    test "separates reads of different offset windows that the hint collapses" do
      # This is the exact false positive behind "59 byte-identical file_read
      # calls": the hint keeps only the path, so 49 distinct slices of one
      # growing file were counted as 49 repeats of a single call.
      a = %{"path" => "/app/eval.scm", "offset" => 1, "limit" => 200}
      b = %{"path" => "/app/eval.scm", "offset" => 201, "limit" => 200}

      assert ToolHint.summarize(a) == ToolHint.summarize(b)
      refute ToolArgMetrics.arg_hash(a) == ToolArgMetrics.arg_hash(b)
    end

    test "separates shell commands that share their first 60 characters" do
      prefix = String.duplicate("a", 60)
      a = %{"command" => prefix <> " && make test"}
      b = %{"command" => prefix <> " && make lint"}

      assert ToolHint.summarize(a) == ToolHint.summarize(b)
      refute ToolArgMetrics.arg_hash(a) == ToolArgMetrics.arg_hash(b)
    end

    test "genuinely identical calls hash identically regardless of key order" do
      a = %{"path" => "/app/x.ex", "offset" => 1, "limit" => 50}
      b = %{"limit" => 50, "path" => "/app/x.ex", "offset" => 1}

      assert ToolArgMetrics.arg_hash(a) == ToolArgMetrics.arg_hash(b)
    end

    test "atom and string keys for the same call agree" do
      assert ToolArgMetrics.arg_hash(%{"path" => "/a"}) ==
               ToolArgMetrics.arg_hash(%{path: "/a"})
    end

    test "nested edit lists are compared by content, not by ordering accident" do
      edits = [%{"path" => "/a", "old_string" => "x", "new_string" => "y"}]
      a = %{"edits" => edits}
      b = %{"edits" => [%{"new_string" => "y", "old_string" => "x", "path" => "/a"}]}

      assert ToolArgMetrics.arg_hash(a) == ToolArgMetrics.arg_hash(b)
    end

    test "returns a stable fixed-width identity" do
      hash = ToolArgMetrics.arg_hash(%{"path" => "/a"})
      assert String.length(hash) == 32
      assert hash =~ ~r/\A[0-9a-f]{32}\z/
      assert hash == ToolArgMetrics.arg_hash(%{"path" => "/a"})
    end
  end
end
