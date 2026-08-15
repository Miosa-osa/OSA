defmodule OptimalSystemAgent.Runtime.SessionTeardownTest do
  @moduledoc """
  A session's per-session state must actually die with the session.

  Seven per-session cleanup functions existed, were tested, and had ZERO
  production callers — so every session that ever ran left its ETS slice behind
  for the life of the daemon. These tests assert the bound end-to-end: run N
  sessions, stop them, and assert the per-session tables come back to where they
  started.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Context.WorldState
  alias OptimalSystemAgent.Agent.CoordinatorMode
  alias OptimalSystemAgent.Agent.Loop.GoalTracker
  alias OptimalSystemAgent.Agent.Loop.PermissionBroker
  alias OptimalSystemAgent.Agent.Loop.VerificationEvidence
  alias OptimalSystemAgent.Agent.Safety.Guardian
  alias OptimalSystemAgent.Runtime.SessionManager
  alias OptimalSystemAgent.Runtime.SessionTeardown
  alias OptimalSystemAgent.Tools.Registry.SkillTouch

  @per_session_tables [
    :osa_world_state_ledger
  ]

  defp sid, do: "teardown-#{System.unique_integer([:positive])}"

  # {content, priority, label} — the shape Context.gather_dynamic_blocks/1 emits.
  defp blk(label, content), do: {content, 1, label}

  # Dirty every slice of per-session state we expect teardown to release.
  defp dirty(session_id) do
    label = WorldState.managed_labels() |> hd()
    WorldState.assemble(session_id, [blk(label, "a good deal of pinned payload text")], [])
    Guardian.reset(session_id)
    GoalTracker.reset(session_id)
    VerificationEvidence.reset(session_id)
    SkillTouch.reset(session_id)
    CoordinatorMode.clear(session_id)
    PermissionBroker.clear_session(session_id)
    :ok
  end

  defp table_size(t) do
    case :ets.info(t, :size) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  describe "wiring — the failure mode was a cleanup nobody called" do
    test "every step in the teardown list actually runs" do
      s = sid()
      dirty(s)

      ran = SessionTeardown.run(s)
      expected = SessionTeardown.steps() |> Enum.map(fn {name, _} -> name end)

      assert Enum.sort(ran) == Enum.sort(expected)
      # Seven original zero-caller cleanups + `:compactor_summary` (the
      # session-scoped compaction summary, added when that summary stopped
      # being a global that leaked across sessions) + `:side_spend`.
      #
      # `:side_spend` is the staged-but-unabsorbed compaction spend that
      # `Loop.Accounting` now keeps for summarizer calls made off the Loop
      # process. It is per-session state with a lifetime, so it belongs in this
      # list for exactly the reason the other eight do: left behind, a later
      # session that reused the id would absorb — and be billed for — spend it
      # never made. This count is the whole point of the test, so it is asserted
      # rather than derived; bump it deliberately when a cleanup is added.
      # `:ask_user_mode` is the sticky `/ask-user` choice. It joined for the
      # same reason: left behind, a recycled session id would inherit a
      # stranger's "on" and could block on a question its operator never
      # enabled — the exact failure the toggle exists to remove.
      # `:attendance` is the session's channel + attendance override
      # (`Agent.Attendance`). It joined for the same reason as `:ask_user_mode`
      # and in the same direction: left behind, a recycled session id would
      # inherit a stranger's "someone is watching", which is what lets an
      # unattended run park on a prompt nobody can answer.
      assert length(expected) == 11, "every per-session cleanup must be wired in"
      assert :compactor_summary in expected
      assert :side_spend in expected
      assert :ask_user_mode in expected
      assert :attendance in expected
    end

    test "the WorldState ledger is covered — it pins rendered payload text" do
      s = sid()

      WorldState.assemble(
        s,
        [blk(hd(WorldState.managed_labels()), "payload the ledger would otherwise pin")],
        []
      )

      assert :ets.lookup(:osa_world_state_ledger, s) != []

      SessionTeardown.run(s)

      assert :ets.lookup(:osa_world_state_ledger, s) == [],
             "the world-state ledger row must not outlive its session"
    end

    test "is idempotent and safe on an unknown or nil session" do
      assert SessionTeardown.run(nil) == []
      assert SessionTeardown.run(:not_a_binary) == []

      s = sid()
      # 11 steps — see the count assertion above for why `:side_spend`,
      # `:ask_user_mode` and `:attendance` joined.
      assert length(SessionTeardown.run(s)) == 11
      assert length(SessionTeardown.run(s)) == 11
    end
  end

  describe "the bound — state does not survive its session" do
    test "200 sessions leave the per-session tables where they started" do
      Enum.each(1..3, fn _ -> dirty(sid()) end)
      baseline = Enum.map(@per_session_tables, &{&1, table_size(&1)})

      sessions = Enum.map(1..200, fn _ -> sid() end)
      Enum.each(sessions, &dirty/1)

      # Every session leaves a row while it lives...
      assert table_size(:osa_world_state_ledger) >= 200

      Enum.each(sessions, &SessionTeardown.run/1)

      Enum.each(baseline, fn {t, before} ->
        assert table_size(t) <= before,
               "#{t} grew across 200 stopped sessions (#{table_size(t)} vs #{before})"
      end)
    end

    test "tearing one session down leaves another session's state alone" do
      keep = sid()
      drop = sid()
      dirty(keep)
      dirty(drop)

      SessionTeardown.run(drop)

      assert :ets.lookup(:osa_world_state_ledger, keep) != []
      assert :ets.lookup(:osa_world_state_ledger, drop) == []
    end
  end

  describe "reached from the real stop path" do
    test "SessionManager.stop_session/1 tears the session's state down" do
      s = sid()
      :ok = SessionManager.ensure_loop(s, user_id: "u", working_dir: File.cwd!())
      dirty(s)

      assert :ets.lookup(:osa_world_state_ledger, s) != []

      SessionManager.stop_session(s)

      assert :ets.lookup(:osa_world_state_ledger, s) == [],
             "stopping a session must release its per-session state"
    end

    test "untrack_session/1 alone is enough (the single teardown path)" do
      s = sid()
      dirty(s)
      assert :ets.lookup(:osa_world_state_ledger, s) != []

      SessionManager.untrack_session(s)
      assert :ets.lookup(:osa_world_state_ledger, s) == []
    end
  end

  describe "durable resume artifacts are deliberately NOT torn down" do
    test "teardown does not touch offloaded tool results or rewind checkpoints" do
      names = SessionTeardown.steps() |> Enum.map(fn {n, _} -> n end)

      refute :tool_result_storage in names
      refute :rewind_checkpoints in names
      refute :session_persistence in names
    end
  end
end
