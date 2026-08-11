defmodule OptimalSystemAgent.Agent.RunLeaseCrossProcessTest do
  @moduledoc """
  Regression tests for the cross-process run-ownership defect.

  ## The defect

  `~/.osa/agent-runs` is machine-global, but every `osa` invocation is its own
  BEAM with its own `RunStore` ETS table and its own `SessionRegistry`.
  `application.ex` calls `FleetResumer.resume_on_boot/0` at every boot, which
  decides which runs are dead using `Registry.lookup(SessionRegistry, agent_id)`
  — a probe that can only see the local node. Another live process's run
  therefore ALWAYS reads as dead, so a second `osa` invocation would

    * re-dispatch it (`qualifying_orphans/2`) => duplicate execution, and
    * mark it `:cancelled` + append a RECONCILE record
      (`reconcile_stale_running/1`) => the first process's healthy work killed.

  The cancellation half was not even gated by `:fleet_resume_on_boot`: the
  `if enabled` in `resume_on_boot/1` closes before the reconcile.

  ## What is asserted

  Two independent "processes" are simulated by two distinct lease identities
  plus two distinct liveness views (process B's registry, like a real second
  BEAM's, reports A's run as dead). The headline test asserts B neither cancels
  nor re-dispatches A's in-flight run. These tests FAIL on the pre-lease code:
  there, B's registry probe is the only authority and it says "dead".

  Everything is deterministic — leases are compared by claim/expiry, never by
  waiting on a heartbeat, and the heartbeat is driven by hand
  (`RunStore.heartbeat_tick/0`).
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.FleetResumer
  alias OptimalSystemAgent.Agent.RunStore

  # The local ownership index. Clearing it is precisely what makes this process
  # look like a freshly booted BEAM, which owns nothing yet.
  @lease_owners :"Elixir.OptimalSystemAgent.Agent.RunStore.LeaseOwners"

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_run_lease_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    prev_dir = Application.get_env(:optimal_system_agent, :agent_runs_dir)
    prev_identity = Application.get_env(:optimal_system_agent, :run_lease_identity)
    prev_ttl = Application.get_env(:optimal_system_agent, :run_lease_ttl_ms)
    prev_abort = Application.get_env(:optimal_system_agent, :run_lease_abort_fun)

    Application.put_env(:optimal_system_agent, :agent_runs_dir, tmp)
    # Never call the real Fleet.stop_node/1 from these tests.
    Application.put_env(:optimal_system_agent, :run_lease_abort_fun, fn _ -> :ok end)

    :ets.delete_all_objects(RunStore)
    clear_local_ownership()

    on_exit(fn ->
      restore(:agent_runs_dir, prev_dir)
      restore(:run_lease_identity, prev_identity)
      restore(:run_lease_ttl_ms, prev_ttl)
      restore(:run_lease_abort_fun, prev_abort)
      :ets.delete_all_objects(RunStore)
      clear_local_ownership()
      File.rm_rf(tmp)
    end)

    # Both simulated processes report the REAL os pid/start time, so the
    # belt-and-braces OS liveness check sees a genuinely live owner. Only the
    # owner_id (and hence the lease claim) differs.
    real = real_identity()

    %{
      process_a: %{real | owner_id: "osa-process-a"},
      process_b: %{real | owner_id: "osa-process-b"},
      dir: tmp
    }
  end

  # ── the headline regression ────────────────────────────────────────────────

  describe "a second osa invocation and another process's in-flight run" do
    test "neither cancels nor re-dispatches it", ctx do
      # ---- process A: starts a run and keeps it in flight.
      as_process(ctx.process_a, fn ->
        RunStore.start_run(%{
          agent_id: "a-live-run",
          parent_session_id: "a-parent",
          role: "agent",
          task: "long running work",
          posture: :autonomous
        })
      end)

      assert %{status: :running} = RunStore.get("a-live-run")
      assert File.exists?(Path.join(ctx.dir, "a-live-run.md.lease.json"))

      # ---- process B boots. Its ETS index is seeded from the machine-global
      # runs dir with A's still-:running row, and it owns nothing locally.
      # (This is exactly the state `rehydrate/0` reaches — see the rehydrate
      # test below — reproduced directly so the assertion does not depend on
      # transcript parsing.)
      a_row = RunStore.get("a-live-run")
      clear_local_ownership()
      :ets.insert(RunStore, {"a-live-run", a_row})

      test_pid = self()

      summary =
        as_process(ctx.process_b, fn ->
          FleetResumer.resume_on_boot(
            enabled: true,
            # B's SessionRegistry is a different BEAM's: A's live loop is not in
            # it, so the node-local probe says "dead". This is the whole trap.
            alive_fun: fn _ -> false end,
            posture_fun: fn _ -> true end,
            resume_fun: fn id, _msg ->
              send(test_pid, {:resumed, id})
              {:ok, id}
            end
          )
        end)

      # Consequence A — duplicate execution — must not happen.
      refute_received {:resumed, "a-live-run"}
      assert summary.resumed == []
      assert "a-live-run" in summary.skipped

      # Consequence B — cancellation — must not happen.
      assert "a-live-run" not in summary.reconciled
      assert %{status: :running} = RunStore.get("a-live-run")

      # ...and no RECONCILE record was appended to A's transcript.
      {:ok, transcript} = RunStore.transcript("a-live-run")
      refute transcript =~ "RECONCILE"
    end

    test "the cancellation half is blocked even with fleet-resume disabled", ctx do
      # `:fleet_resume_on_boot` has never gated the reconcile (the `if enabled`
      # closes before it), so disabling fleet-resume must not be what protects
      # another process's run — the lease must.
      as_process(ctx.process_a, fn ->
        RunStore.start_run(%{
          agent_id: "a-live-run",
          parent_session_id: "a-parent",
          role: "agent",
          task: "t",
          posture: :autonomous
        })
      end)

      a_row = RunStore.get("a-live-run")
      clear_local_ownership()
      :ets.insert(RunStore, {"a-live-run", a_row})

      summary =
        as_process(ctx.process_b, fn ->
          FleetResumer.resume_on_boot(enabled: false, alive_fun: fn _ -> false end)
        end)

      assert summary.enabled == false
      assert summary.reconciled == []
      assert %{status: :running} = RunStore.get("a-live-run")
    end

    test "process B still reconciles a genuine ghost it can claim", ctx do
      # The fix must not make reconciliation a no-op: a run with no live owner
      # (here, no lease at all — a legacy row) is still cleaned up.
      RunStore.start_run(%{
        agent_id: "ghost",
        parent_session_id: "p",
        role: "agent",
        task: "t"
      })

      File.rm(Path.join(ctx.dir, "ghost.md.lease.json"))
      clear_local_ownership()

      summary =
        as_process(ctx.process_b, fn ->
          FleetResumer.resume_on_boot(enabled: false, alive_fun: fn _ -> false end)
        end)

      assert "ghost" in summary.reconciled
      assert %{status: :cancelled} = RunStore.get("ghost")
    end

    test "an expired lease from a dead owner is reclaimed and reconciled", ctx do
      # Owner died uncleanly: the lease was deliberately NOT released, so it must
      # expire before anyone else may touch the run.
      dead_owner = %{ctx.process_a | owner_id: "dead-owner", os_pid: 2_147_483_646, os_start: 1}

      as_process(dead_owner, fn ->
        RunStore.start_run(%{
          agent_id: "crashed",
          parent_session_id: "p",
          role: "agent",
          task: "t"
        })
      end)

      clear_local_ownership()

      # Before expiry: untouchable, even though the pid is bogus/dead — expiry is
      # the primary signal and the OS check may only VETO a steal, never force one.
      as_process(ctx.process_b, fn ->
        assert {:held, _} = RunStore.lease_state("crashed")
        refute RunStore.lease_claimable?("crashed")
      end)

      # After expiry: claimable. Time is advanced by rewriting the recorded
      # heartbeat into the past — deterministic, never sleep-based.
      age_lease(ctx.dir, "crashed")

      summary =
        as_process(ctx.process_b, fn ->
          assert {:expired, _} = RunStore.lease_state("crashed")
          FleetResumer.resume_on_boot(enabled: false, alive_fun: fn _ -> false end)
        end)

      assert "crashed" in summary.reconciled
      assert %{status: :cancelled} = RunStore.get("crashed")
    end
  end

  # ── lease mechanics ────────────────────────────────────────────────────────

  describe "claim_lease/1" do
    test "is exclusive: only one of two processes wins a fresh run", ctx do
      assert {:ok, _} = as_process(ctx.process_a, fn -> RunStore.claim_lease("r") end)

      assert {:error, {:held_by, lease}} =
               as_process(ctx.process_b, fn -> RunStore.claim_lease("r") end)

      assert lease["owner_id"] == "osa-process-a"
    end

    test "re-claiming our own lease succeeds (idempotent re-affirmation)", ctx do
      as_process(ctx.process_a, fn ->
        assert {:ok, _} = RunStore.claim_lease("r")
        assert {:ok, _} = RunStore.claim_lease("r")
        assert RunStore.owns_lease?("r")
      end)
    end

    test "a live owner keeps the lease even past expiry (OS check vetoes the steal)", ctx do
      # process_a records the REAL os pid + start time, so it is demonstrably
      # alive. Expiry alone must not be enough to steal from it.
      as_process(ctx.process_a, fn -> RunStore.claim_lease("r") end)
      age_lease(ctx.dir, "r")

      as_process(ctx.process_b, fn ->
        assert {:held, _} = RunStore.lease_state("r")
        assert {:error, {:held_by, _}} = RunStore.claim_lease("r")
      end)
    end

    test "a recycled pid does not read as alive", ctx do
      # Same pid as a live process, but a different recorded start time: the
      # process at that pid today is NOT the one that took the lease.
      real = real_identity()
      recycled = %{real | owner_id: "recycled", os_start: (real.os_start || 0) + 999_999}

      as_process(recycled, fn -> RunStore.claim_lease("r") end)
      clear_local_ownership()
      age_lease(ctx.dir, "r")

      as_process(ctx.process_b, fn ->
        assert {:expired, _} = RunStore.lease_state("r")
        assert {:ok, _} = RunStore.claim_lease("r")
      end)
    end
  end

  describe "release semantics" do
    test "a clean completion releases the lease", ctx do
      as_process(ctx.process_a, fn ->
        RunStore.start_run(%{agent_id: "r", parent_session_id: "p", role: "agent", task: "t"})
        assert RunStore.owns_lease?("r")
        RunStore.complete("r", %{agent_id: "r", status: :completed})
      end)

      refute File.exists?(Path.join(ctx.dir, "r.md.lease.json"))
      assert {:ok, _} = as_process(ctx.process_b, fn -> RunStore.claim_lease("r") end)
    end

    test "an unclean exit leaves the lease behind to expire, not released", ctx do
      as_process(ctx.process_a, fn ->
        RunStore.start_run(%{agent_id: "r", parent_session_id: "p", role: "agent", task: "t"})
      end)

      # Simulate a hard kill: the owner simply stops existing. Nothing cleans up.
      clear_local_ownership()

      assert File.exists?(Path.join(ctx.dir, "r.md.lease.json")),
             "an unclean shutdown must NOT clear the lease — a self-clearing lease " <>
               "lets a second process race a half-dead worker"

      as_process(ctx.process_b, fn ->
        assert {:held, _} = RunStore.lease_state("r")
      end)
    end

    test "another process cannot release a lease it does not hold", ctx do
      as_process(ctx.process_a, fn -> RunStore.claim_lease("r") end)
      as_process(ctx.process_b, fn -> RunStore.release_lease("r") end)

      assert File.exists?(Path.join(ctx.dir, "r.md.lease.json"))
    end
  end

  describe "heartbeat" do
    test "renews our lease so it never expires while we live", ctx do
      as_process(ctx.process_a, fn ->
        Application.put_env(:optimal_system_agent, :run_lease_ttl_ms, 50)
        RunStore.claim_lease("r")
        Process.sleep(60)
        assert {:mine, _} = RunStore.lease_state("r")

        # Drive the heartbeat by hand — no sleeping on a timer.
        assert :ok = RunStore.heartbeat_tick()
        assert :ok = RunStore.renew_lease("r")
      end)
    end

    test "losing ownership mid-flight aborts the run instead of leaving it unowned", ctx do
      test_pid = self()

      Application.put_env(:optimal_system_agent, :run_lease_abort_fun, fn id ->
        send(test_pid, {:aborted, id})
        :ok
      end)

      as_process(ctx.process_a, fn ->
        RunStore.start_run(%{agent_id: "r", parent_session_id: "p", role: "agent", task: "t"})
      end)

      # Process B takes the run over (as it legitimately could after expiry).
      as_process(ctx.process_b, fn ->
        File.write!(
          Path.join(ctx.dir, "r.md.lease.json"),
          Jason.encode!(%{
            "agent_id" => "r",
            "owner_id" => "osa-process-b",
            "host" => ctx.process_b.host,
            "os_pid" => ctx.process_b.os_pid,
            "os_start" => ctx.process_b.os_start,
            "claimed_at" => System.system_time(:millisecond),
            "renewed_at" => System.system_time(:millisecond),
            "ttl_ms" => 60_000
          })
        )
      end)

      # A's next heartbeat discovers the loss.
      as_process(ctx.process_a, fn ->
        assert {:error, :lost} = RunStore.renew_lease("r")
        RunStore.heartbeat_tick()
      end)

      assert_received {:aborted, "r"}
      assert %{status: :cancelled} = RunStore.get("r")
    end
  end

  # ── rehydrate accuracy ─────────────────────────────────────────────────────

  describe "rehydrate/0 across processes" do
    test "a run held by another live process rehydrates as :running, not :failed", ctx do
      as_process(ctx.process_a, fn ->
        RunStore.start_run(%{
          agent_id: "a-live-run",
          parent_session_id: "a-parent",
          role: "agent",
          task: "t",
          posture: :autonomous
        })

        RunStore.save_messages("a-live-run", [%{role: "user", content: "hi"}], %{
          agent_id: "a-live-run",
          parent_session_id: "a-parent",
          posture: :autonomous
        })
      end)

      # Fresh BEAM: empty index, owns nothing.
      :ets.delete_all_objects(RunStore)
      clear_local_ownership()

      as_process(ctx.process_b, fn -> RunStore.rehydrate() end)

      # The transcript has no STOP record. Without the lease this is indistinguishable
      # from a crashed run and was recorded as :failed — mislabelling another
      # process's healthy work as dead.
      assert %{status: :running, completed_at: nil} = RunStore.get("a-live-run")
    end

    test "a run with no live owner still rehydrates as :failed", ctx do
      RunStore.start_run(%{agent_id: "orphan", parent_session_id: "p", role: "agent", task: "t"})
      File.rm(Path.join(ctx.dir, "orphan.md.lease.json"))

      :ets.delete_all_objects(RunStore)
      clear_local_ownership()

      as_process(ctx.process_b, fn -> RunStore.rehydrate() end)

      assert %{status: :failed} = RunStore.get("orphan")
    end
  end

  # ── fleet accounting ───────────────────────────────────────────────────────

  describe "all_running_local/0" do
    test "excludes runs owned by another live process but keeps lease-less rows", ctx do
      as_process(ctx.process_a, fn ->
        RunStore.start_run(%{agent_id: "a-run", parent_session_id: "p", role: "agent", task: "t"})
      end)

      a_row = RunStore.get("a-run")
      clear_local_ownership()
      :ets.insert(RunStore, {"a-run", a_row})

      # A legacy row with no lease file at all must keep counting locally.
      RunStore.start_run(%{agent_id: "legacy", parent_session_id: "p", role: "agent", task: "t"})
      File.rm(Path.join(ctx.dir, "legacy.md.lease.json"))

      ids =
        as_process(ctx.process_b, fn ->
          RunStore.all_running_local() |> Enum.map(& &1.agent_id)
        end)

      refute "a-run" in ids
      assert "legacy" in ids

      # ...and the machine-global view still sees both.
      assert "a-run" in (RunStore.all_running() |> Enum.map(& &1.agent_id))
    end
  end

  # ── atomic .messages.etf write ─────────────────────────────────────────────

  describe "save_messages/3 atomicity" do
    test "publishes via rename and leaves no temp files behind", ctx do
      RunStore.save_messages("r", [%{role: "user", content: "one"}], %{v: 1})

      assert {:ok, [%{content: "one"}], %{v: 1}} = RunStore.load_messages("r")

      assert ctx.dir
             |> File.ls!()
             |> Enum.filter(&String.contains?(&1, ".tmp.")) == []
    end

    test "a failed write never truncates the only copy of the resume context", ctx do
      RunStore.save_messages("r", [%{role: "user", content: "good"}], %{v: 1})
      path = Path.join(ctx.dir, "r.md.messages.etf")
      before = File.read!(path)

      # Make the publish step fail after the temp file is written, the way ENOSPC
      # or a crash mid-write would: an in-place File.write/2 would have already
      # truncated the file at this point.
      File.chmod!(ctx.dir, 0o500)

      try do
        RunStore.save_messages("r", [%{role: "user", content: "new"}], %{v: 2})
      after
        File.chmod!(ctx.dir, 0o700)
      end

      assert File.read!(path) == before
      assert {:ok, [%{content: "good"}], %{v: 1}} = RunStore.load_messages("r")
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  # Run `fun` under a given lease identity — the stand-in for "a different osa
  # process". Combined with clearing the local ownership table (a fresh BEAM owns
  # nothing) and an `alive_fun` that cannot see the other node's registry, this
  # reproduces the cross-process situation inside one test VM.
  defp as_process(identity, fun) do
    prev = Application.get_env(:optimal_system_agent, :run_lease_identity)
    Application.put_env(:optimal_system_agent, :run_lease_identity, identity)

    try do
      fun.()
    after
      restore(:run_lease_identity, prev)
    end
  end

  defp real_identity do
    prev = Application.get_env(:optimal_system_agent, :run_lease_identity)
    Application.delete_env(:optimal_system_agent, :run_lease_identity)

    try do
      RunStore.lease_identity()
    after
      restore(:run_lease_identity, prev)
    end
  end

  # Advance time past the lease's own recorded TTL by backdating its heartbeat.
  # The TTL is written INTO the lease at claim time (so a lease means the same
  # thing to every reader, whatever their config), which is why lowering the
  # app-env TTL afterwards does not expire an existing lease.
  defp age_lease(dir, agent_id) do
    path = Path.join(dir, "#{agent_id}.md.lease.json")
    lease = path |> File.read!() |> Jason.decode!()
    stale = lease["renewed_at"] - lease["ttl_ms"] - 1_000
    File.write!(path, Jason.encode!(Map.put(lease, "renewed_at", stale)))
    :ok
  end

  defp clear_local_ownership do
    case :ets.whereis(@lease_owners) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(@lease_owners)
    end

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, value), do: Application.put_env(:optimal_system_agent, key, value)
end
