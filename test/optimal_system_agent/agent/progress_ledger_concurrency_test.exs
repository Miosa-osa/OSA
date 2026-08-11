defmodule OptimalSystemAgent.Agent.ProgressLedgerConcurrencyTest do
  @moduledoc """
  The progress ledger is the coherence anchor recovered after compaction, so it
  must not lose entries and must not lie about having written a goal.

  Two defects covered here:

    * `set_goal/2` was read → `Regex.replace/3` → `atomic_write/2` with no lock,
      racing `append_entry/2`'s raw append. The write was atomic; the
      read-modify-write was not, so any entry landing in the window was
      overwritten out of existence.
    * `Regex.replace/3` returns content UNCHANGED on zero matches. When the
      scaffold drifted so the `## Goal` anchor no longer matched, `set_goal/2`
      wrote the file back verbatim and STILL returned `{:ok, body}`, still
      emitted `:goal_set`, and still captured a founding Task Brief for a goal
      the ledger never contained.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.ProgressLedger

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_ledger_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev = Application.get_env(:optimal_system_agent, :config_dir)
    Application.put_env(:optimal_system_agent, :config_dir, tmp)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:optimal_system_agent, :config_dir, prev),
        else: Application.delete_env(:optimal_system_agent, :config_dir)

      File.rm_rf(tmp)
    end)

    {:ok, session: "sess-#{System.unique_integer([:positive])}"}
  end

  test "concurrent appends are never swallowed by a concurrent set_goal", %{session: session} do
    assert {:ok, _} = ProgressLedger.set_goal(session, "initial goal")

    appends = 40

    tasks =
      for i <- 1..appends do
        Task.async(fn ->
          # Interleave goal rewrites with appends from many processes at once.
          if rem(i, 4) == 0, do: ProgressLedger.set_goal(session, "goal rev #{i}")
          ProgressLedger.append_entry(session, "entry-#{i}")
        end)
      end

    Enum.each(tasks, &Task.await(&1, 15_000))

    {:ok, contents} = ProgressLedger.read(session)

    missing =
      for i <- 1..appends,
          not String.contains?(contents, "entry-#{i}"),
          do: i

    assert missing == [], "lost ledger entries: #{inspect(missing)}"
  end

  test "set_goal reports failure when the Goal section anchor is gone", %{session: session} do
    assert {:ok, _} = ProgressLedger.set_goal(session, "real goal")

    # Simulate scaffold drift: the "## Goal" heading is renamed, so the section
    # regex no longer matches anything.
    path = ProgressLedger.path(session)
    {:ok, contents} = File.read(path)
    File.write!(path, String.replace(contents, "## Goal", "## Objective"))

    assert {:error, :goal_section_missing} = ProgressLedger.set_goal(session, "new goal")

    # And the file is untouched — no silent half-write.
    {:ok, after_contents} = File.read(path)
    refute String.contains?(after_contents, "new goal")
  end

  test "a normal set_goal still replaces the goal body", %{session: session} do
    assert {:ok, "first"} = ProgressLedger.set_goal(session, "first")
    assert {:ok, "second"} = ProgressLedger.set_goal(session, "second")

    {:ok, contents} = ProgressLedger.read(session)
    assert String.contains?(contents, "second")
    refute String.contains?(contents, "first")
  end
end
