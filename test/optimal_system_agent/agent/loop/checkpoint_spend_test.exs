defmodule OptimalSystemAgent.Agent.Loop.CheckpointSpendTest do
  @moduledoc """
  Audit gap C2 — the cost/budget accumulator must survive a crash.

  Before this fix the spend totals lived only in Loop in-memory state and were
  in NO checkpoint, so a crash reset `session_cost_usd` to 0.0 and a
  `max_budget_usd` cap was defeated (a $48-of-$50 run resumed at $0). These
  tests assert:

    * `Checkpoint.checkpoint_state/1` persists the spend accumulators +
      `started_at`, and `restore_checkpoint/1` reads them back.
    * The durable between-turn spend sidecar (`SessionPersistence`) carries spend
      across a CLEAN turn boundary (where the checkpoint is cleared).
    * A restored NON-zero spend makes `Loop.Limits.budget_exceeded?/1` fire, so
      the cap is honored post-resume.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.Checkpoint
  alias OptimalSystemAgent.Agent.Loop.Limits
  alias OptimalSystemAgent.Agent.SessionPersistence

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_spend_#{System.unique_integer([:positive])}")
    crash = Path.join(tmp, "checkpoints")
    home = Path.join(tmp, "home")
    File.mkdir_p!(crash)
    File.mkdir_p!(home)

    prev_crash = Application.get_env(:optimal_system_agent, :checkpoint_dir)
    prev_home = Application.get_env(:optimal_system_agent, :config_dir)
    Application.put_env(:optimal_system_agent, :checkpoint_dir, crash)
    Application.put_env(:optimal_system_agent, :config_dir, home)

    on_exit(fn ->
      restore_env(:checkpoint_dir, prev_crash)
      restore_env(:config_dir, prev_home)
      File.rm_rf(tmp)
    end)

    {:ok, session: "spend_#{System.unique_integer([:positive])}"}
  end

  defp restore_env(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore_env(key, val), do: Application.put_env(:optimal_system_agent, key, val)

  defp state(session, overrides) do
    Map.merge(
      %{
        session_id: session,
        messages: [%{role: "user", content: "hello"}],
        iteration: 4,
        plan_mode: false,
        turn_count: 2,
        session_cost_usd: 48.25,
        session_input_tokens: 1_200,
        session_output_tokens: 800,
        session_cache_creation_tokens: 100,
        session_cache_read_tokens: 50,
        started_at: ~U[2026-07-19 00:00:00Z]
      },
      overrides
    )
  end

  # Read the sidecar as it literally sits on disk. `load_spend/1` cannot be used
  # for these assertions: it FILLS IN a missing `tree_cost_usd` from `cost_usd`,
  # which is exactly the absence under test.
  defp raw_sidecar(session) do
    Application.get_env(:optimal_system_agent, :config_dir)
    |> Path.join("sessions")
    |> Path.join("#{session}.spend.json")
    |> File.read!()
    |> Jason.decode!()
  end

  describe "the spend sidecar has ONE shape, whichever writer wrote it last" do
    # The defect: `save_spend/2` overwrites the file, and there were two writers
    # with two payload shapes — the turn-boundary save (full) and Checkpoint's
    # per-tool-cycle mirror (token counters only). Whichever ran last decided
    # the file's shape. Because a turn's final LLM round-trip makes no tool
    # call, the mid-turn checkpoint was usually last, so the published sidecar
    # lost `tree_cost_usd` AND lagged the true token count by one round-trip.
    # Measured on the 8-task cost probe: 5 of 8 trials, ~1.1% of input tokens
    # missing, always in the direction that makes OSA look cheaper.
    test "a Checkpoint write carries the tree figures, not just the counters",
         %{session: session} do
      Checkpoint.checkpoint_state(state(session, %{}))

      raw = raw_sidecar(session)

      assert Map.has_key?(raw, "tree_cost_usd")
      assert Map.has_key?(raw, "tree_cost_complete")
      # Node-local `cost_usd` must stay node-local: `tree_spend/1` sums THAT
      # field across descendants, so a tree total there double-counts.
      assert raw["cost_usd"] == 48.25
    end

    test "a Checkpoint write after a full turn-boundary save does not erase the tree figures",
         %{session: session} do
      st = state(session, %{})

      :ok = SessionPersistence.save_from_state(session, st)
      assert Map.has_key?(raw_sidecar(session), "tree_cost_usd")

      # The write that used to clobber it.
      Checkpoint.checkpoint_state(st)

      assert Map.has_key?(raw_sidecar(session), "tree_cost_usd")
    end

    test "flush_spend/2 writes the same shape and the later figures win",
         %{session: session} do
      Checkpoint.checkpoint_state(state(session, %{}))

      # The final LLM round-trip of the turn: more spend, no tool call, so no
      # further checkpoint. This is the flush the loop now performs at turn end.
      :ok =
        SessionPersistence.flush_spend(
          session,
          state(session, %{session_cost_usd: 49.75, session_input_tokens: 1_500})
        )

      raw = raw_sidecar(session)
      assert Map.has_key?(raw, "tree_cost_usd")
      assert raw["cost_usd"] == 49.75
      assert raw["input_tokens"] == 1_500

      loaded = SessionPersistence.load_spend(session)
      assert loaded.input_tokens == 1_500
      assert loaded.complete
    end

    test "flush_spend/2 never raises on a nil session or a non-map state" do
      assert {:error, :invalid_args} = SessionPersistence.flush_spend(nil, %{})
      assert {:error, :invalid_args} = SessionPersistence.flush_spend("s", :not_a_map)
    end
  end

  describe "checkpoint round-trips the spend accumulators + started_at" do
    test "restore_checkpoint returns the persisted spend and started_at", %{session: session} do
      Checkpoint.checkpoint_state(state(session, %{}))

      restored = Checkpoint.restore_checkpoint(session)

      assert restored.session_cost_usd == 48.25
      assert restored.session_input_tokens == 1_200
      assert restored.session_output_tokens == 800
      assert restored.session_cache_creation_tokens == 100
      assert restored.session_cache_read_tokens == 50
      assert restored.started_at == "2026-07-19T00:00:00Z"
      # Non-spend fields still restore as before.
      assert restored.iteration == 4
      assert restored.turn_count == 2
    end

    test "a pre-C2 checkpoint (no spend keys) restores to zero, not a crash", %{session: session} do
      # Simulate an old checkpoint written before this feature.
      path = Checkpoint.checkpoint_path(session)
      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        Jason.encode!(%{
          "session_id" => session,
          "messages" => [],
          "iteration" => 1,
          "turn_count" => 1
        })
      )

      restored = Checkpoint.restore_checkpoint(session)
      assert restored.session_cost_usd == 0.0
      assert restored.session_input_tokens == 0
      assert restored.started_at == nil
    end
  end

  describe "budget cap (max_budget_usd) survives a crash (audit gap D2 restore half)" do
    test "checkpoint persists max_budget_usd and restore reads it back", %{session: session} do
      Checkpoint.checkpoint_state(state(session, %{max_budget_usd: 50.0}))

      restored = Checkpoint.restore_checkpoint(session)
      assert restored.max_budget_usd == 50.0
    end

    test "a pre-D2 checkpoint (no cap key) restores max_budget_usd as nil", %{session: session} do
      path = Checkpoint.checkpoint_path(session)
      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        Jason.encode!(%{"session_id" => session, "messages" => [], "iteration" => 1})
      )

      restored = Checkpoint.restore_checkpoint(session)
      assert restored.max_budget_usd == nil
    end

    test "an uncapped run (nil cap) round-trips as nil, not a coerced default", %{
      session: session
    } do
      Checkpoint.checkpoint_state(state(session, %{max_budget_usd: nil}))
      restored = Checkpoint.restore_checkpoint(session)
      assert restored.max_budget_usd == nil
    end

    test "restored cap + restored spend trips budget_exceeded? (loop.init precedence)", %{
      session: session
    } do
      # A $50 run that spent $48 crashes; on resume the cap must come from the
      # checkpoint (app-env default is nil = uncapped), then one more turn trips it.
      Checkpoint.checkpoint_state(state(session, %{session_cost_usd: 48.0, max_budget_usd: 50.0}))

      restored = Checkpoint.restore_checkpoint(session)

      # Mirror loop.ex init precedence: restored cap wins over opts→app env.
      resumed_cap = restored.max_budget_usd || nil
      assert resumed_cap == 50.0

      refute Limits.budget_exceeded?(%{max_budget_usd: resumed_cap, session_cost_usd: 48.0})
      assert Limits.budget_exceeded?(%{max_budget_usd: resumed_cap, session_cost_usd: 51.0})
    end
  end

  describe "durable spend sidecar survives a clean turn boundary" do
    test "checkpoint_state mirrors spend into the sidecar; clearing the checkpoint keeps it",
         %{session: session} do
      Checkpoint.checkpoint_state(state(session, %{}))

      # The crash-recovery checkpoint is cleared at every clean turn boundary.
      Checkpoint.clear_checkpoint(session)
      assert Checkpoint.restore_checkpoint(session) == %{}

      # ... but the between-turn spend sidecar is NOT cleared there.
      sidecar = SessionPersistence.load_spend(session)
      assert sidecar.cost_usd == 48.25
      assert sidecar.input_tokens == 1_200
      assert sidecar.started_at == "2026-07-19T00:00:00Z"
    end

    test "load_spend returns zero defaults when no sidecar exists", %{session: session} do
      spend = SessionPersistence.load_spend(session)
      assert spend.cost_usd == 0.0
      assert spend.output_tokens == 0
      assert spend.started_at == nil
    end
  end

  describe "budget cap is honored post-resume" do
    test "a resumed state with restored spend >= cap trips budget_exceeded?", %{session: session} do
      Checkpoint.checkpoint_state(state(session, %{session_cost_usd: 48.0}))
      Checkpoint.clear_checkpoint(session)

      restored = Checkpoint.restore_checkpoint(session)
      sidecar = SessionPersistence.load_spend(session)

      # Mirror loop.ex init: MAX of checkpoint spend and the sidecar (spend only
      # grows, so max = latest regardless of which resume path fired).
      resumed_cost = max(Map.get(restored, :session_cost_usd, 0.0), sidecar.cost_usd)
      assert resumed_cost == 48.0

      resumed_state = %{max_budget_usd: 50.0, session_cost_usd: resumed_cost}
      refute Limits.budget_exceeded?(resumed_state)

      # One more turn's spend pushes it over the $50 cap — the cap now fires on the
      # RESTORED total, not a post-crash $0.
      over = %{max_budget_usd: 50.0, session_cost_usd: resumed_cost + 3.0}
      assert Limits.budget_exceeded?(over)
    end

    test "without the fix a reset-to-zero spend would defeat the cap (regression guard)", %{
      session: session
    } do
      Checkpoint.checkpoint_state(state(session, %{session_cost_usd: 49.9}))
      restored = Checkpoint.restore_checkpoint(session)

      # The whole point: the restored spend is the real accumulated total, so a
      # cap set below it is already exceeded on resume.
      assert restored.session_cost_usd == 49.9

      assert Limits.budget_exceeded?(%{
               max_budget_usd: 25.0,
               session_cost_usd: restored.session_cost_usd
             })
    end
  end
end
