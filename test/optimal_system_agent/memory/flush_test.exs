defmodule OptimalSystemAgent.Memory.FlushTest do
  @moduledoc """
  Pre-compaction memory flush.

  The harvest/threshold/latch halves are pure and run async. The persistence
  half touches the shared `Memory.Store` singleton, so it is split into an
  `async: false` module at the bottom of this file.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Loop.CompactionThresholds
  alias OptimalSystemAgent.Memory.Flush

  defp msg(role, content), do: %{role: role, content: content}

  describe "flush_at/1 sits strictly inside the pre-compaction band" do
    test "below compact_at and at or above warn_at, for every realistic window" do
      for window <- [128_000, 200_000, 1_000_000] do
        flush_at = Flush.flush_at(window)

        assert flush_at < CompactionThresholds.compact_at(window),
               "flush must fire BEFORE compaction for a #{window} window"

        assert flush_at >= CompactionThresholds.warn_at(window),
               "flush must not fire before the context-low warning band (#{window})"
      end
    end

    test "a tiny window still yields an ordered, positive threshold" do
      flush_at = Flush.flush_at(8_000)
      assert flush_at > 0
      assert flush_at < CompactionThresholds.compact_at(8_000)
    end
  end

  describe "should_flush?/2" do
    test "false below the band, true inside it, false at/after compaction" do
      window = 200_000
      flush_at = Flush.flush_at(window)
      compact_at = CompactionThresholds.compact_at(window)

      refute Flush.should_flush?(%{last_input_tokens: flush_at - 1, session_id: sid()}, window)
      assert Flush.should_flush?(%{last_input_tokens: flush_at, session_id: sid()}, window)
      refute Flush.should_flush?(%{last_input_tokens: compact_at, session_id: sid()}, window)
    end

    test "false once the cycle has already flushed" do
      window = 200_000
      state = %{last_input_tokens: Flush.flush_at(window), session_id: sid()}

      assert Flush.should_flush?(state, window)
      assert :ok = Flush.begin(state.session_id)
      refute Flush.should_flush?(state, window)

      :ok = Flush.reset_cycle(state.session_id)
      assert Flush.should_flush?(state, window)
    end

    test "false for a nonsense context window" do
      refute Flush.should_flush?(%{last_input_tokens: 999_999}, 0)
      refute Flush.should_flush?(%{last_input_tokens: 999_999}, nil)
    end
  end

  describe "the once-per-cycle latch" do
    test "begin/1 succeeds exactly once until reset_cycle/1" do
      s = sid()

      assert :ok = Flush.begin(s)
      assert {:error, :already_flushed} = Flush.begin(s)
      assert {:error, :already_flushed} = Flush.begin(s)

      assert :ok = Flush.reset_cycle(s)
      assert :ok = Flush.begin(s)
    end

    test "is keyed per session — one session's flush never latches another's" do
      a = sid()
      b = sid()

      assert :ok = Flush.begin(a)
      assert :ok = Flush.begin(b)
      assert {:error, :already_flushed} = Flush.begin(a)
    end
  end

  describe "harvest/1 — what counts as hard-won knowledge" do
    test "captures root causes, fixes, decisions and constraints" do
      messages = [
        msg("assistant", "The root cause was a stale symlink in ~/.local/bin shadowing the build."),
        msg("assistant", "The fix was to pin the resolver to the workspace root before compiling."),
        msg("user", "We decided to keep the SQLite bridge synchronous for now, despite the stall risk."),
        msg("assistant", "That command only works if the gateway is already bound to port 18789.")
      ]

      harvested = Flush.harvest(messages)
      contents = Enum.map(harvested, & &1.content)

      assert length(harvested) == 4
      assert Enum.any?(contents, &(&1 =~ "stale symlink"))
      assert Enum.any?(contents, &(&1 =~ "pin the resolver"))
      assert Enum.any?(contents, &(&1 =~ "SQLite bridge synchronous"))
      assert Enum.any?(contents, &(&1 =~ "port 18789"))
    end

    test "assigns the category the phrasing implies" do
      by_category =
        [
          msg("assistant", "The root cause was an unflushed write buffer in the session store."),
          msg("assistant", "We decided to route every provider call through the registry facade."),
          msg("assistant", "The migration must not be run while the replica is still catching up.")
        ]
        |> Flush.harvest()
        |> Map.new(&{&1.category, &1.content})

      assert Map.has_key?(by_category, :lesson)
      assert Map.has_key?(by_category, :decision)
      assert Map.has_key?(by_category, :context)
    end

    test "ignores narration, progress updates and tool noise" do
      messages = [
        msg("assistant", "Let me read the file and see what is going on in there."),
        msg("assistant", "I will now run the test suite to check the current state."),
        msg("assistant", "Reading lib/app/auth.ex now, then I will look at the router."),
        msg("assistant", "Okay."),
        msg("user", "thanks, keep going")
      ]

      assert Flush.harvest(messages) == []
    end

    test "ignores system messages and compact boundaries" do
      messages = [
        msg("system", "The root cause was something the summarizer wrote, not the session."),
        msg("assistant", "[Compact boundary] The root cause was described in the summary above.")
      ]

      assert Flush.harvest(messages) == []
    end

    test "rejects fragments and paragraph dumps" do
      messages = [
        msg("assistant", "The fix was x."),
        msg("assistant", "The root cause was " <> String.duplicate("very long detail ", 40))
      ]

      assert Flush.harvest(messages) == []
    end

    test "collapses near-duplicate findings within one batch" do
      messages = [
        msg("assistant", "The root cause was a stale symlink shadowing the compiled binary."),
        msg("assistant", "The root cause was a stale symlink shadowing the compiled binary here.")
      ]

      assert length(Flush.harvest(messages)) == 1
    end

    test "reads text blocks out of structured content" do
      messages = [
        %{
          role: "assistant",
          content: [
            %{type: :text, text: "The root cause was a missing index on the sessions table."},
            %{type: :image, data: "..."}
          ]
        }
      ]

      assert [%{content: content}] = Flush.harvest(messages)
      assert content =~ "missing index"
    end

    test "is total — never raises on malformed input" do
      assert Flush.harvest([]) == []
      assert Flush.harvest(nil) == []
      assert Flush.harvest([%{}, %{role: "assistant"}, %{role: "assistant", content: 42}]) == []
    end
  end

  describe "flush_message/1 (the optional LLM-driven variant)" do
    test "is a marked synthetic user turn that names the tool and the stakes" do
      m = Flush.flush_message()

      assert m.role == "user"
      assert m.synthetic == true
      assert m.metadata.memory_flush == true
      assert m.content =~ "memory_save"
      assert m.content =~ "FUTURE session"
      assert m.content =~ "about to be compacted"
    end

    test "states the remaining budget when the caller knows it" do
      assert Flush.flush_message(remaining_tokens: 9_000).content =~ "9000 tokens"
    end
  end

  describe "hook_contract/0" do
    test "documents both call sites the loop owner must add" do
      contract = Flush.hook_contract()

      assert contract.before_compaction.call =~ "should_flush?"
      assert contract.before_compaction.call =~ "Memory.Flush.run"
      assert contract.after_compaction.call =~ "reset_cycle"
      assert contract.after_compaction.where =~ "compact/3"
    end
  end

  defp sid, do: "flush-test-#{System.unique_integer([:positive])}"
end

defmodule OptimalSystemAgent.Memory.FlushPersistenceTest do
  @moduledoc """
  The half that writes. `Memory.Store` is a shared singleton, so: async: false.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Memory
  alias OptimalSystemAgent.Memory.Flush

  defp msg(role, content), do: %{role: role, content: content}
  defp sid, do: "flush-persist-#{System.unique_integer([:positive])}"

  test "run/2 persists harvested notes and reports what it did" do
    anchor = "zorbulax#{System.unique_integer([:positive])}"

    messages = [
      msg("assistant", "The root cause was the #{anchor} resolver returning a stale build path.")
    ]

    assert {:ok, report} = Flush.run(messages, session_id: sid())

    assert report.candidates == 1
    assert report.saved == 1
    assert report.duplicates == 0

    assert {:ok, recalled} = Memory.recall(anchor, limit: 5)
    assert Enum.any?(recalled, &(to_string(&1.content) =~ anchor))
  end

  test "the latch makes run/2 idempotent within a compaction cycle" do
    session = sid()

    messages = [
      msg(
        "assistant",
        "The root cause was the quixotrode#{System.unique_integer([:positive])} cache never expiring."
      )
    ]

    assert {:ok, %{saved: 1}} = Flush.run(messages, session_id: session)
    assert {:skipped, :already_flushed} = Flush.run(messages, session_id: session)

    :ok = Flush.reset_cycle(session)
    # New cycle: it runs again, but the dedupe gate stops the SAME fact from
    # being written twice. Latch and dedupe are independent defences.
    assert {:ok, %{saved: 0, duplicates: 1}} = Flush.run(messages, session_id: session)
  end

  test ":force bypasses the latch for manual invocation" do
    session = sid()
    assert :ok = Flush.begin(session)

    assert {:skipped, :already_flushed} = Flush.run([], session_id: session)
    assert {:ok, _} = Flush.run([], session_id: session, force: true)
  end

  test "already_remembered?/1 gates on substance, not on exact text" do
    anchor = "flibberwock#{System.unique_integer([:positive])}"
    fact = "The root cause was the #{anchor} pool leaking connections on timeout."

    refute Flush.already_remembered?(fact)

    {:ok, _} = Memory.save(fact, category: :lesson, source: :agent, tags: ["flush-test"])

    assert Flush.already_remembered?(fact)
    # A restatement of the same fact is also caught.
    assert Flush.already_remembered?(
             "Root cause: the #{anchor} pool leaking connections on timeout."
           )

    # An unrelated fact is not.
    refute Flush.already_remembered?(
             "The fix was to rebuild the #{anchor} index after every migration run instead."
           )
  end

  test ":limit caps how much one flush writes" do
    tag = "capcheck#{System.unique_integer([:positive])}"

    # Deliberately unrelated facts — the batch deduper must not collapse them,
    # so the only thing capping the batch is `:limit`.
    facts = [
      "The root cause was the #{tag} websocket handler dropping its reply frame.",
      "We decided to keep #{tag} migrations reversible by writing an explicit down block.",
      "The #{tag} exporter only works if the collector endpoint is reachable over TLS.",
      "The fix was to rebuild the #{tag} search index after every schema change."
    ]

    assert length(Flush.harvest(Enum.map(facts, &msg("assistant", &1)))) == 4

    assert {:ok, report} =
             Flush.run(Enum.map(facts, &msg("assistant", &1)), session_id: sid(), limit: 2)

    assert report.candidates == 2
    assert report.saved <= 2
  end
end
