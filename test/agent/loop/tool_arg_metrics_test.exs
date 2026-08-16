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

  describe "assertion_lines/1" do
    test "recovers the propositions a test file asserted, which the log did not carry" do
      # Verbatim shape of `model-extraction-relu-logits`'s own test, the case
      # docs/research/failure-taxonomy.md §2.1 could only describe in prose
      # because the event log stored the path and not the content. Its test
      # measured precision; the verifier measures recall. That is visible here
      # and is visible nowhere in the artefacts of that run.
      content = """
      import numpy as np

      def test_stolen_rows_are_real_neurons():
          stolen = np.load('/app/stolen_A1.npy')
          matched = count_matches(stolen, A1)
          assert matched == stolen.shape[0], f"{matched}/{stolen.shape[0]} stolen rows matched"
      """

      assert [line] = ToolArgMetrics.assertion_lines(%{"path" => "t.py", "content" => content})
      assert line =~ "matched == stolen.shape[0]"
      # Indentation collapsed so the same assertion at two nesting depths
      # compares equal across trials.
      refute String.starts_with?(line, " ")
    end

    test "reads a file_edit's new_string, not only a whole-file write" do
      args = %{
        "path" => "/app/tests/test_x.py",
        "old_string" => "pass",
        "new_string" => "    assert out == expected"
      }

      assert ToolArgMetrics.assertion_lines(args) == ["assert out == expected"]
    end

    test "covers the assertion forms of the languages this corpus writes tests in" do
      content = """
      EXPECT_EQ(rc, 0);
      expect(result).toBe(42);
      assert_eq!(lhs, rhs);
      if got != want { t.Fatalf("got %v want %v", got, want) }
      require.NoError(t, err)
      """

      assert length(ToolArgMetrics.assertion_lines(args_for(content))) == 5
    end

    test "nil, not [], when the write carried no assertion" do
      assert ToolArgMetrics.assertion_lines(args_for("def main():\n    return 0\n")) == nil
    end

    test "does not match a word that merely contains an assertion verb" do
      # `reassert_all` and prose containing "expected" are the two false
      # positives a bare substring match produces on real source.
      content = "reassert_all(state)\n# the expected output is described above\n"
      assert ToolArgMetrics.assertion_lines(args_for(content)) == nil
    end

    test "leaves every non-write tool call untouched" do
      assert ToolArgMetrics.assertion_lines(%{"command" => "pytest -q && assert_something"}) ==
               nil

      assert ToolArgMetrics.assertion_lines(%{"path" => "/app/t.py"}) == nil
      assert ToolArgMetrics.assertion_lines(nil) == nil
    end

    test "bounds what a single write can put on the event" do
      content = String.duplicate("assert x == #{String.duplicate("y", 400)}\n", 50)
      lines = ToolArgMetrics.assertion_lines(args_for(content))

      assert length(lines) == 12
      assert Enum.all?(lines, &(String.length(&1) <= 240))
    end
  end

  defp args_for(content), do: %{"path" => "/app/tests/test_x.py", "content" => content}
end

defmodule OptimalSystemAgent.Agent.Loop.ToolArgMetricsKillSwitchTest do
  @moduledoc """
  Separate, `async: false`: the kill switch is read from the OS environment,
  which is process-global, so exercising it inside the async module above could
  silence assertion capture underneath any test running beside it.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ToolArgMetrics

  test "OSA_ASSERTION_CAPTURE=0 removes it" do
    args = %{"path" => "/app/tests/test_x.py", "content" => "assert 1 == 1\n"}
    assert ToolArgMetrics.assertion_lines(args) == ["assert 1 == 1"]

    System.put_env("OSA_ASSERTION_CAPTURE", "0")
    on_exit(fn -> System.delete_env("OSA_ASSERTION_CAPTURE") end)

    assert ToolArgMetrics.assertion_lines(args) == nil
  end
end
