defmodule OptimalSystemAgent.Agent.Loop.DoomLoop.IdenticalCallWindowedTest do
  @moduledoc """
  The windowed-repeat rule (diagnosis item A1), and its replay against the real
  bench artefacts.

  ## What this rule is for

  The original detector only saw *consecutive* identical calls, so any repeat
  with something interleaved was invisible to it — `doom_loop_halt` fired 0
  times in 0 of 52 runs. The windowed rule counts occurrences anywhere inside a
  20-call window.

  ## What it must not do

  Most of this file is negative. A detector that halts a working agent converts
  solves into failures, and the diagnosis is explicit that "fewer turns with
  fewer solves is not a win". The two shapes that must never trip it:

    * `read -> edit -> read` and `test -> fix -> test`, where the repeat returns
      something *different* — that is progress, not a loop.
    * polling and waiting, where the repeat returns the same *nothing* — that is
      the correct way to wait on background work.

  The replay section drives the real detector over the recorded call sequences
  of three real runs, including the one the diagnosis was built on and a solved
  174-call run that must be left alone.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Loop.DoomLoop.IdenticalCall

  @fixtures Path.join([__DIR__, "..", "..", "..", "..", "support", "fixtures"])
            |> Path.expand()
            |> Path.join("doom_loop_replay.exs")

  # ── Harness ───────────────────────────────────────────────────────────

  defp state, do: %{session_id: "windowed-test", messages: []}

  # Feed one call + its result through the detector.
  defp step(state, name, args, result) do
    tc = %{name: name, arguments: args}
    IdenticalCall.check([{tc, {"", result}}], [tc], state)
  end

  # Feed a list of `{name, args, result}` and report where it first nudged and
  # first halted, as 1-based call indices. `halt` is `{index, rule}` so the
  # replays can tell the windowed rule apart from the consecutive one.
  defp run(calls) do
    {_state, nudge, halt, _i} =
      Enum.reduce(calls, {state(), nil, nil, 0}, fn
        _call, {st, n, h, i} when not is_nil(h) ->
          {st, n, h, i}

        {name, args, result}, {st, n, h, i} ->
          i = i + 1
          before = escalations(st)

          case step(st, name, args, result) do
            {:ok, st2} ->
              n2 = if is_nil(n) and escalations(st2) > before, do: i, else: n
              {st2, n2, h, i}

            {:halt, msg, st2} ->
              {st2, n, {i, rule(msg)}, i}
          end
      end)

    {nudge, halt}
  end

  # The windowed rule names its window in the halt message; the consecutive rule
  # says "in a row".
  defp rule(msg) do
    cond do
      msg =~ "within the last" -> :windowed
      msg =~ "in a row" -> :consecutive
      true -> :unknown
    end
  end

  defp halt_index(nil), do: nil
  defp halt_index({i, _rule}), do: i

  defp windowed_halt(nil), do: nil
  defp windowed_halt({i, :windowed}), do: i
  defp windowed_halt({_i, _other}), do: nil

  defp escalations(st), do: Map.get(st, :graded_escalation_count, 0)

  # Put a unique call between each entry, so the consecutive-streak rule (which
  # is not what these tests are about) can never fire and the windowed rule is
  # observed in isolation.
  defp interleave(calls, offset \\ 0) do
    calls
    |> Enum.with_index(offset)
    |> Enum.flat_map(fn {call, i} ->
      [call, {"shell_execute", %{"command" => "sep#{i}"}, "sep-out-#{i}"}]
    end)
  end

  # ── The loop it was built to see ──────────────────────────────────────

  describe "windowed detection sees repeats the consecutive rule cannot" do
    test "the same call returning the same bytes, interleaved with other work, halts" do
      # Interleaving is what made this invisible before: the streak never
      # exceeds 1, so only a windowed counter can see it.
      calls =
        Enum.flat_map(1..6, fn i ->
          [
            {"file_read", %{"path" => "/a"}, "SAME BYTES"},
            {"shell_execute", %{"command" => "echo #{i}"}, "#{i}"}
          ]
        end)

      {nudge, halt} = run(calls)

      assert nudge, "a repeat that carries no information should nudge before halting"
      assert halt, "five identical results in a 20-call window should halt"
      # 5 qualifying reads at call indices 1,3,5,7,9 -> halt on the 5th.
      assert halt_index(halt) == 9
      assert nudge == 5
    end

    test "it does not fire when the interleaving pushes repeats outside the window" do
      # Same 5 reads, but spread over more than 20 calls: only ~3 are ever in
      # the window at once, so it must not reach the halt threshold.
      calls =
        Enum.flat_map(1..5, fn i ->
          [{"file_read", %{"path" => "/a"}, "SAME BYTES"}] ++
            Enum.map(1..8, fn j -> {"shell_execute", %{"command" => "c#{i}#{j}"}, "#{i}#{j}"} end)
        end)

      {_nudge, halt} = run(calls)
      refute halt, "repeats spread beyond the window are not a loop"
    end
  end

  # ── The exemption: differing results are progress ─────────────────────

  describe "the exemption: a repeat that returns something different is progress" do
    test "read -> edit -> read never accumulates, however long it runs" do
      # The exact shape of the runaway: identical read arguments every time, an
      # edit between each pair, and a file that is different after each edit.
      calls =
        Enum.flat_map(1..20, fn i ->
          [
            {"file_read", %{"path" => "/eval.scm"}, "file contents version #{i}"},
            {"file_edit", %{"path" => "/eval.scm", "old" => "x#{i}"}, "edited #{i}"}
          ]
        end)

      {nudge, halt} = run(calls)

      refute halt, "read -> edit -> verify must never be halted"
      refute nudge, "and must not even be nudged — it is correct behaviour"
    end

    test "test -> fix -> test never accumulates" do
      # The shell analogue. A stat-based exemption would not have covered this
      # at all, which is why the change signature is the result.
      calls =
        Enum.flat_map(1..15, fn i ->
          [
            {"shell_execute", %{"command" => "pytest"}, "#{i} failed"},
            {"file_edit", %{"path" => "/x.py"}, "edited #{i}"}
          ]
        end)

      {_nudge, halt} = run(calls)
      refute halt
    end

    test "a differing result partitions the window rather than merely skipping" do
      # The discriminator: OLD x3, one NEW, OLD x3 — interleaved with unique
      # shell calls so the consecutive rule cannot fire and only the windowed
      # rule is under test.
      #
      #   * partitioning  -> the trailing OLDs count 3, scanning stops at NEW.
      #   * merely skipping -> the NEW is stepped over and all 6 OLDs count, 6 >= 5,
      #     and a legitimate change would be halted.
      calls =
        interleave(List.duplicate({"file_read", %{"path" => "/a"}, "OLD"}, 3)) ++
          interleave([{"file_read", %{"path" => "/a"}, "NEW"}], 100) ++
          interleave(List.duplicate({"file_read", %{"path" => "/a"}, "OLD"}, 3), 200)

      {_nudge, halt} = run(calls)

      refute windowed_halt(halt),
             "a differing result must restart counting, not just be stepped over"
    end

    test "a repeat resumes counting after the change, and can still halt" do
      # Same structure, but the post-change run is long enough to be a real
      # loop on its own. The exemption must not become an amnesty.
      calls =
        interleave(List.duplicate({"file_read", %{"path" => "/a"}, "OLD"}, 2)) ++
          interleave(List.duplicate({"file_read", %{"path" => "/a"}, "NEW"}, 5), 100)

      {_nudge, halt} = run(calls)
      assert windowed_halt(halt), "a genuine loop after a change must still be caught"
    end
  end

  # ── The exemption: waiting ────────────────────────────────────────────

  describe "waiting is not looping" do
    test "polling a background job with bash_output never fires" do
      calls = List.duplicate({"bash_output", %{"id" => "bg_1"}, "still running"}, 12)
      {nudge, halt} = run(calls)
      refute halt
      refute nudge
    end

    test "a command that returns nothing never fires, however often repeated" do
      # `shell_execute "sleep 90"` 8x in a real run. An empty result carries no
      # information to compare, so two of them are not "the same answer".
      calls = List.duplicate({"shell_execute", %{"command" => "sleep 90"}, ""}, 12)
      {nudge, halt} = run(calls)
      refute halt
      refute nudge
    end

    test "whitespace-only results are treated as empty" do
      calls = List.duplicate({"shell_execute", %{"command" => "sleep 5"}, "\n  \n"}, 12)
      {_nudge, halt} = run(calls)
      refute halt
    end

    test "an empty result neither counts nor partitions" do
      # Empties interleaved among real repeats must not rescue a genuine loop by
      # accidentally partitioning it.
      calls =
        Enum.flat_map(1..6, fn _ ->
          [
            {"file_grep", %{"pattern" => "x"}, "match at line 1"},
            {"shell_execute", %{"command" => "sleep 1"}, ""}
          ]
        end)

      {_nudge, halt} = run(calls)
      assert halt, "an inert empty result must not disguise a real loop"
    end
  end

  describe "the consecutive rule still works" do
    test "back-to-back identical calls halt as before" do
      calls = List.duplicate({"dir_list", %{"path" => "."}, "a\nb\n"}, 6)
      {_nudge, halt} = run(calls)
      assert halt
    end

    test "with no results supplied, only the consecutive rule can fire" do
      st = state()
      tc = %{name: "file_read", arguments: %{"path" => "/a"}}

      # Interleaved, so the consecutive rule cannot see it, and no results means
      # the windowed rule declines to guess.
      other = %{name: "shell_execute", arguments: %{"command" => "x"}}

      result =
        Enum.reduce_while(1..20, st, fn _i, acc ->
          {:ok, acc} = IdenticalCall.check([], [tc], acc)

          case IdenticalCall.check([], [other], acc) do
            {:ok, acc} -> {:cont, acc}
            {:halt, _, acc} -> {:halt, {:halted, acc}}
          end
        end)

      refute match?({:halted, _}, result),
             "without result bytes the windowed rule must not guess"
    end
  end

  # ── Replay against the real artefacts ─────────────────────────────────

  describe "replay: recorded bench runs" do
    setup do
      {fixtures, _} = Code.eval_file(@fixtures)
      {:ok, fixtures: fixtures}
    end

    # ## What this replay can and cannot show
    #
    # The recorded `args` field in `osa-events.jsonl` is **not** the tool's
    # arguments — it is `ToolHint.summarize/1`, the one-line TUI display hint,
    # hard-clipped to 60 characters (`agent/loop/tool_hint.ex`). In the
    # `schemelike` run all 134 `shell_execute` args are <= 60 chars with 127 of
    # them at exactly 60, cut mid-path; `file_read` args carry only the path,
    # with `offset`/`limit` dropped entirely.
    #
    # So the replay can only ever make distinct calls look IDENTICAL, never the
    # reverse. That makes it:
    #
    #   * a valid UPPER BOUND on firing — if it does not fire here, it cannot
    #     fire on the real arguments, which is exactly what the safety
    #     assertions below need; and
    #   * useless for the args-only consecutive rule, which the clipping alone
    #     can trip. `windowed_halt/1` therefore selects halts by rule.
    #
    # The windowed rule additionally requires byte-identical RESULTS, which is
    # recorded faithfully, so clipping collisions are largely filtered out.

    defp replay(entries) do
      entries
      |> Enum.map(fn {name, args, rhash, empty?} ->
        # Preserve the recorded identity relations exactly: same args string ->
        # same arguments map, same digest -> same result. An empty result is
        # replayed as empty so the waiting exemption is exercised for real.
        {name, %{"a" => args}, if(empty?, do: "", else: rhash)}
      end)
      |> run()
    end

    test "schemelike (277 calls, UNSOLVED) — the run the diagnosis was built on",
         %{fixtures: f} do
      {_nudge, halt} = replay(f.schemelike)

      # The corrected reading of this run. The diagnosis counted 152 "exact
      # duplicate" calls here, including "59 file_read of the same file with
      # byte-identical arguments" — but that was computed from the clipped
      # display field. Recovering the true windows from the results shows the 59
      # reads span **49 distinct offset windows**, and NONE of them returned
      # bytes identical to a previous read. Requiring the result to match as
      # well drops the duplicate count from 152 to 26 (9.4%), of which the
      # largest cluster — 15 identical `cp … && <test>` calls — returned EMPTY
      # output, i.e. silent commands, not a loop.
      #
      # So there is no qualifying loop in the worst run in the corpus, and the
      # detector correctly declines to halt it. Halting here would mean acting
      # on a logging artefact.
      refute windowed_halt(halt),
             "no qualifying loop exists once results are compared; " <>
               "halting would be acting on a logging artefact"
    end

    test "train-fasttext (66 calls) — the polling run that must not be halted",
         %{fixtures: f} do
      {_nudge, halt} = replay(f.train_fasttext)

      # 8x `sleep 90` and 6x `bash_output`, all returning "". Without the
      # waiting exemptions this run halts at call 39 — mid-wait, on a training
      # job, which guarantees failure. This is the assertion that stopped the
      # first design from shipping.
      refute windowed_halt(halt), "waiting on a background training job is not a loop"
    end

    test "path-tracing (174 calls, SOLVED) — the long healthy run",
         %{fixtures: f} do
      {_nudge, halt} = replay(f.path_tracing)

      # Solved at 174 calls. Any interference converts a solve into a fail,
      # which is the outcome the diagnosis warns against most clearly.
      refute windowed_halt(halt)
    end

    test "across all three runs the windowed rule fires zero halts",
         %{fixtures: f} do
      # The honest summary of this change's measured yield. Replayed over the
      # full 52-run corpus (of which these three are the extremes), the windowed
      # rule produces 0 halts and 4 nudges, and halts 0 solved runs. It is a
      # backstop against a pathology this corpus does not contain, bought at a
      # measured cost of zero — NOT a turn-reduction lever.
      for key <- [:schemelike, :train_fasttext, :path_tracing] do
        {_nudge, halt} = replay(Map.fetch!(f, key))
        refute windowed_halt(halt), "windowed rule must not halt #{key}"
      end
    end
  end
end
