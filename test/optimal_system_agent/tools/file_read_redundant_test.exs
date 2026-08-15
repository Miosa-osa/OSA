defmodule OptimalSystemAgent.Tools.FileReadRedundantTest do
  @moduledoc """
  Redundant-read suppression (diagnosis item A2).

  Measured motivation: the `schemelike-metacircular-eval` head-to-head run made
  **59 `file_read` calls against one path with byte-identical arguments**, each
  re-injecting the whole of a growing file. Input cost is quadratic in turns once
  the transcript dominates the static prefix, so that is the largest single cost
  driver in the artefacts.

  The load-bearing half of these tests is not "does it suppress" — it is
  **"does it refuse to suppress"**. Every case below that asserts real content
  comes back is guarding against a change that would silently starve the model
  of its working context, which shows up as a lower solve rate rather than as an
  error.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Builtins.FileEdit.Handler, as: FileEdit
  alias OptimalSystemAgent.Tools.Builtins.FileRead.Handler, as: FileRead
  alias OptimalSystemAgent.Tools.Builtins.FileWrite.Handler, as: FileWrite
  alias OptimalSystemAgent.Tools.FileState
  alias OptimalSystemAgent.Tools.UseContext

  @unchanged "is UNCHANGED since you last read it"

  setup do
    FileState.reset()
    sid = "fr-redundant-#{System.unique_integer([:positive])}"
    ctx = %UseContext{session_id: sid, permission_tier: :full}
    path = Path.join(System.tmp_dir!(), "osa_fr_#{System.unique_integer([:positive])}.txt")
    on_exit(fn -> File.rm(path) end)
    {:ok, ctx: ctx, sid: sid, path: path}
  end

  defp read(path, ctx, extra \\ %{}),
    do: FileRead.execute(Map.merge(%{"path" => path}, extra), ctx)

  # file_edit / file_write answer with a 3-tuple (result + structured metadata
  # for the diff renderer); only the :ok matters here.
  defp ok!(result) do
    assert :ok == elem(result, 0)
    result
  end

  # Suppression is declined for files smaller than the notice itself (there
  # would be nothing to save), so a fixture that wants to exercise suppression
  # has to be bigger than that. Pad with filler that no assertion looks at.
  defp write_now(path, content), do: File.write!(path, content <> filler())

  # Lines wide enough that a 10-line window exceeds the notice's own size, so
  # the range tests exercise range logic rather than the size guard.
  defp wide_lines(range) do
    Enum.map_join(range, "", fn i -> "line#{i} " <> String.duplicate("x", 60) <> "\n" end)
  end

  defp filler do
    "\n" <> String.duplicate("# filler line that no assertion inspects\n", 20)
  end

  describe "suppression: the repeat that costs tokens and returns nothing new" do
    test "a second identical whole-file read returns a marker, not the bytes",
         %{ctx: ctx, path: path} do
      write_now(path, "alpha\nbeta\ngamma\n")

      assert {:ok, first} = read(path, ctx)
      assert first =~ "alpha"
      assert first =~ "gamma"

      assert {:ok, second} = read(path, ctx)
      refute second =~ "alpha"
      assert second =~ @unchanged
      assert second =~ path
    end

    test "it keeps returning the marker, and says so, rather than oscillating",
         %{ctx: ctx, path: path} do
      write_now(path, "alpha\nbeta\n")
      assert {:ok, _} = read(path, ctx)

      for _ <- 1..5 do
        assert {:ok, out} = read(path, ctx)
        assert out =~ @unchanged
        # The message must tell the model that retrying is not a way out, or the
        # marker becomes the new loop.
        assert out =~ "Re-reading returns this notice"
      end
    end

    test "the file still counts as read, so the marker does not break edit gating",
         %{ctx: ctx, path: path} do
      write_now(path, "alpha\nbeta\n")
      assert {:ok, _} = read(path, ctx)
      assert {:ok, marker} = read(path, ctx)
      assert marker =~ @unchanged

      # Read-before-edit enforcement must still pass after a suppressed read.
      ok!(
        FileEdit.execute(%{"path" => path, "old_string" => "beta", "new_string" => "BETA"}, ctx)
      )

      assert File.read!(path) =~ "alpha\nBETA\n"
    end

    test "an identical offset/limit window is suppressed", %{ctx: ctx, path: path} do
      # The window must itself be bigger than the notice, or suppressing it
      # would cost more than it saves — see the wide_lines/0 note.
      write_now(path, wide_lines(1..40))

      assert {:ok, first} = read(path, ctx, %{"offset" => 10, "limit" => 10})
      assert first =~ "line10"

      assert {:ok, second} = read(path, ctx, %{"offset" => 10, "limit" => 10})
      assert second =~ @unchanged
      refute second =~ "line10"
    end
  end

  describe "the exemption: read -> edit -> verify must never be suppressed" do
    test "a read after an edit returns the real, updated content",
         %{ctx: ctx, path: path} do
      write_now(path, "alpha\nbeta\ngamma\n")

      assert {:ok, _} = read(path, ctx)

      ok!(
        FileEdit.execute(%{"path" => path, "old_string" => "beta", "new_string" => "BETA"}, ctx)
      )

      assert {:ok, after_edit} = read(path, ctx)
      refute after_edit =~ @unchanged
      assert after_edit =~ "BETA"
    end

    test "the full read -> edit -> read -> edit -> read cycle is never suppressed",
         %{ctx: ctx, path: path} do
      write_now(path, "l1\nl2\nl3\nl4\n")

      for {old, new} <- [{"l1", "L1"}, {"l2", "L2"}, {"l3", "L3"}] do
        assert {:ok, body} = read(path, ctx)

        refute body =~ @unchanged,
               "a read that follows an edit must return content, not a marker"

        ok!(FileEdit.execute(%{"path" => path, "old_string" => old, "new_string" => new}, ctx))
      end

      assert {:ok, final} = read(path, ctx)
      refute final =~ @unchanged
      assert final =~ "L1"
      assert final =~ "L3"
    end

    test "a read after file_write returns real content", %{ctx: ctx, path: path} do
      write_now(path, "old\n")
      assert {:ok, _} = read(path, ctx)

      ok!(FileWrite.execute(%{"path" => path, "content" => "brand new\n"}, ctx))

      assert {:ok, body} = read(path, ctx)
      refute body =~ @unchanged
      assert body =~ "brand new"
    end

    test "an out-of-band change (another process) returns real content",
         %{ctx: ctx, path: path} do
      write_now(path, "alpha\nbeta\n")
      assert {:ok, _} = read(path, ctx)

      # A linter, the user, or a shell_execute — nothing went through FileState.
      write_now(path, "alpha\nbeta\ndelta\n")

      assert {:ok, body} = read(path, ctx)
      refute body =~ @unchanged
      assert body =~ "delta"
    end

    test "a same-size in-place change is caught by the content hash, not mtime",
         %{ctx: ctx, path: path} do
      write_now(path, "aaaa\nbbbb\n")
      assert {:ok, _} = read(path, ctx)

      # Same byte count. If suppression relied on {mtime, size} alone this could
      # slip through inside one mtime granule and hand the model stale bytes.
      File.write!(path, "aaaa\ncccc\n")

      assert {:ok, body} = read(path, ctx)
      refute body =~ @unchanged
      assert body =~ "cccc"
    end
  end

  describe "range subtraction: overlapping windows return the REMAINDER" do
    # These tests used to assert the opposite — that any window which was not
    # byte-identical came back in full. That was measured to address 0.8% of the
    # read payload (19 calls, 20 KB of 2.63 MB across 118 transcripts) while
    # overlapping windows and whole-file re-reads were 31.5%. The remedy is a
    # subtraction, not a verdict, so the expectations below changed with it.
    setup %{path: path} do
      write_now(path, wide_lines(1..60))
      :ok
    end

    test "a windowed read is answered with only the part not already held",
         %{ctx: ctx, path: path} do
      assert {:ok, first} = read(path, ctx, %{"offset" => 10, "limit" => 20})
      assert first =~ "line15"

      # 1..40 overlaps 10..29 (held). Expect lines 1-9 and 30-40 back, and the
      # omission named rather than silently dropped.
      assert {:ok, second} = read(path, ctx, %{"offset" => 1, "limit" => 40})

      assert second =~ "line5", "the part it does not hold must come back"
      assert second =~ "line35", "the part after the hole must come back too"
      refute second =~ "line15 ", "the held part must not be sent twice"

      assert second =~ "omitted", "a subtraction the model cannot see is a truncation"
      assert second =~ "10-29", "the omission must name the exact lines"
    end

    test "the result says which lines it is showing, so a hole is never a mystery",
         %{ctx: ctx, path: path} do
      assert {:ok, _} = read(path, ctx, %{"offset" => 20, "limit" => 20})
      assert {:ok, out} = read(path, ctx, %{"offset" => 1, "limit" => 60})

      # Header: what is here, what is not, and why leaving it out is safe.
      assert out =~ "showing lines"
      assert out =~ "already read them this session"
      assert out =~ "not a truncation"
      # And the undo, so withholding is never a dead end.
      assert out =~ "resend: true"
    end

    test "delivered lines keep their real file line numbers across the hole",
         %{ctx: ctx, path: path} do
      assert {:ok, _} = read(path, ctx, %{"offset" => 20, "limit" => 20})
      assert {:ok, out} = read(path, ctx, %{"offset" => 1, "limit" => 60})

      # Line 40 sits immediately after the omitted 20-39 span; its number must
      # still be 40, or reassembling the file from the transcript is guesswork.
      assert out =~ ~r/^\s+40\| line40/m
      assert out =~ ~r/^\s+19\| line19/m
    end

    test "a window wholly contained in one already read returns the notice",
         %{ctx: ctx, path: path} do
      assert {:ok, _} = read(path, ctx, %{"offset" => 10, "limit" => 20})

      # Nothing new to send. Big enough that the notice is cheaper than the
      # bytes — the small case is covered separately below.
      assert {:ok, inner} = read(path, ctx, %{"offset" => 12, "limit" => 10})
      assert inner =~ @unchanged
      refute inner =~ "line12 "
    end

    test "a whole-file re-read after a windowed read returns the complement",
         %{ctx: ctx, path: path} do
      assert {:ok, _} = read(path, ctx, %{"offset" => 20, "limit" => 20})

      assert {:ok, whole} = read(path, ctx)
      assert whole =~ "line1", "the lines before the hole"
      assert whole =~ "line50", "the lines after the hole"
      refute whole =~ "line25 ", "the held span is not re-sent"
      assert whole =~ "20-39"
    end

    test "a disjoint window is untouched — subtraction is not suppression",
         %{ctx: ctx, path: path} do
      assert {:ok, _} = read(path, ctx, %{"offset" => 1, "limit" => 10})

      assert {:ok, c} = read(path, ctx, %{"offset" => 45, "limit" => 10})
      refute c =~ @unchanged
      refute c =~ "omitted"
      assert c =~ "line45"
    end

    test "a subtraction too small to pay for its own explanation is declined",
         %{ctx: ctx, path: path} do
      assert {:ok, _} = read(path, ctx, %{"offset" => 20, "limit" => 2})

      # Two lines held (~140 bytes) against a ~340-byte header plus markers.
      # Omitting them would GROW the result, so the window comes back whole.
      assert {:ok, out} = read(path, ctx, %{"offset" => 18, "limit" => 8})
      refute out =~ "omitted"
      assert out =~ "line20"
    end

    test "resend: true defeats subtraction and returns everything asked for",
         %{ctx: ctx, path: path} do
      assert {:ok, _} = read(path, ctx, %{"offset" => 10, "limit" => 20})

      assert {:ok, out} =
               read(path, ctx, %{"offset" => 1, "limit" => 40, "resend" => true})

      assert out =~ "line15", "the held span comes back on demand"
      refute out =~ "omitted"
    end

    test "resend: true also defeats the byte-identical notice",
         %{ctx: ctx, path: path} do
      assert {:ok, _} = read(path, ctx, %{"offset" => 10, "limit" => 20})
      assert {:ok, notice} = read(path, ctx, %{"offset" => 10, "limit" => 20})
      assert notice =~ @unchanged

      assert {:ok, out} =
               read(path, ctx, %{"offset" => 10, "limit" => 20, "resend" => true})

      refute out =~ @unchanged
      assert out =~ "line15"
    end

    test "an edit drops every held span, so the verify-read is complete",
         %{ctx: ctx, path: path} do
      assert {:ok, _} = read(path, ctx, %{"offset" => 1, "limit" => 30})

      ok!(
        FileEdit.execute(
          %{"path" => path, "old_string" => "line5 ", "new_string" => "LINE5 "},
          ctx
        )
      )

      assert {:ok, out} = read(path, ctx)
      refute out =~ "omitted", "after a write the model holds a delta, not the file"
      assert out =~ "LINE5"
      assert out =~ "line29"
    end

    test "an out-of-band change drops every held span too", %{ctx: ctx, path: path} do
      assert {:ok, _} = read(path, ctx, %{"offset" => 1, "limit" => 30})

      # A linter or the user — nothing went through FileState.
      write_now(path, wide_lines(1..60) <> "tail marker\n")

      assert {:ok, out} = read(path, ctx)
      refute out =~ "omitted"
      assert out =~ "line10"
      assert out =~ "tail marker"
    end

    test "a compaction drops every held span", %{ctx: ctx, path: path, sid: sid} do
      assert {:ok, _} = read(path, ctx, %{"offset" => 1, "limit" => 30})

      OptimalSystemAgent.Agent.CompactionEvents.completed(sid, tokens_before: 10, tokens_after: 5)

      assert {:ok, out} = read(path, ctx)
      refute out =~ "omitted"
      assert out =~ "line10"
    end

    test "the EOF and continuation stamps survive subtraction unchanged",
         %{ctx: ctx, path: path} do
      assert {:ok, _} = read(path, ctx, %{"offset" => 20, "limit" => 20})

      assert {:ok, out} = read(path, ctx, %{"offset" => 1, "limit" => 45})
      # The stamp describes the WINDOW, not the delivered subset: subtraction
      # changes which lines are rendered, never where the window sat.
      assert out =~ "Use offset=46 to continue"

      assert {:ok, tail} = read(path, ctx, %{"offset" => 75, "limit" => 40})
      assert tail =~ "End of file"
    end
  end

  describe "compaction invalidates suppression" do
    test "after a compaction the next read returns real content again",
         %{ctx: ctx, path: path, sid: sid} do
      write_now(path, "alpha\nbeta\n")

      assert {:ok, _} = read(path, ctx)
      assert {:ok, marker} = read(path, ctx)
      assert marker =~ @unchanged

      # The earlier read may have been summarised out of the transcript.
      OptimalSystemAgent.Agent.CompactionEvents.completed(sid, tokens_before: 10, tokens_after: 5)

      assert {:ok, body} = read(path, ctx)
      refute body =~ @unchanged
      assert body =~ "alpha"
    end

    test "and re-establishes suppression from the post-compaction read onward",
         %{ctx: ctx, path: path, sid: sid} do
      write_now(path, "alpha\nbeta\n")
      assert {:ok, _} = read(path, ctx)
      OptimalSystemAgent.Agent.CompactionEvents.completed(sid, tokens_before: 10, tokens_after: 5)

      assert {:ok, refreshed} = read(path, ctx)
      refute refreshed =~ @unchanged

      assert {:ok, marker} = read(path, ctx)
      assert marker =~ @unchanged
    end
  end

  describe "isolation and safety" do
    test "suppression is per-session — a second session gets real content",
         %{ctx: ctx, path: path} do
      write_now(path, "alpha\nbeta\n")
      assert {:ok, _} = read(path, ctx)
      assert {:ok, marker} = read(path, ctx)
      assert marker =~ @unchanged

      other = %UseContext{session_id: "other-#{System.unique_integer([:positive])}"}
      assert {:ok, body} = read(path, other, %{})
      refute body =~ @unchanged
      assert body =~ "alpha"
    end

    test "exempt sessions (nil / \"test\") are never suppressed", %{path: path} do
      write_now(path, "alpha\nbeta\n")
      ctx = %UseContext{session_id: nil}

      assert {:ok, a} = read(path, ctx)
      assert {:ok, b} = read(path, ctx)
      refute a =~ @unchanged
      refute b =~ @unchanged
      assert b =~ "alpha"
    end

    test "a file too small to be worth suppressing always returns real content" do
      # The notice replaces the bytes, so substituting it for a file smaller than
      # itself would COST tokens. Measured before this guard: a 732-byte read was
      # replaced by a 607-byte notice.
      sid = "small-#{System.unique_integer([:positive])}"
      ctx = %UseContext{session_id: sid, permission_tier: :full}
      path = Path.join(System.tmp_dir!(), "osa_small_#{System.unique_integer([:positive])}.txt")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, "tiny\n")

      assert {:ok, a} = read(path, ctx)
      assert {:ok, b} = read(path, ctx)
      refute a =~ @unchanged
      refute b =~ @unchanged
      assert b =~ "tiny"
    end

    test "a file deleted after being read reports the real error, not a marker",
         %{ctx: ctx, path: path} do
      write_now(path, "alpha\n")
      assert {:ok, _} = read(path, ctx)
      File.rm!(path)

      assert {:error, msg} = read(path, ctx)
      refute msg =~ @unchanged
      assert msg =~ "does not exist"
    end

    test "the ETS ledger survives the tool executing in a separate process",
         %{ctx: ctx, path: path} do
      # The process dictionary does NOT cross a Task boundary; the read ledger
      # must, or suppression silently never fires in the real loop (where tools
      # run under Task.async). This asserts the storage choice, not the policy.
      write_now(path, "alpha\nbeta\n")

      assert {:ok, first} =
               Task.async(fn -> read(path, ctx) end) |> Task.await(5_000)

      assert first =~ "alpha"

      assert {:ok, second} =
               Task.async(fn -> read(path, ctx) end) |> Task.await(5_000)

      assert second =~ @unchanged
    end
  end
end
