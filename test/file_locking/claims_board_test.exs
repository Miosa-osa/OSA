defmodule OptimalSystemAgent.FileLocking.ClaimsBoardTest do
  @moduledoc """
  Claims board (VSM System 2 — anti-oscillation for parallel work).

  Built on `RegionLock` for file claims (a whole-file claim is a RegionLock
  region over the full plausible line range) and its own small table for
  task claims. Conflicts are SURFACED, not silently granted; claims expire
  when their owning agent finishes or dies (a `Registry`-absent process, or a
  `RunStore` row that settled terminal).
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.FileLocking.ClaimsBoard, as: Board

  setup do
    on_exit(fn ->
      Application.delete_env(:optimal_system_agent, :claims_board_block_on_conflict)
    end)

    :ok
  end

  # ClaimsBoard's tables are global/shared for the whole test run (no
  # per-test reset — it is a real GenServer + public ETS, same as
  # RegionLock). Every dynamically-created agent id used by a test schedules
  # its own cleanup here so an earlier test's claim can never leak into a
  # later one when the same task description text is reused across tests.
  defp uniq(prefix) do
    id = prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))
    ExUnit.Callbacks.on_exit(fn -> Board.release_all(id) end)
    id
  end

  describe "file claims (built on RegionLock)" do
    test "two agents claiming the SAME file: the second gets {:conflict, holder}, not a silent grant" do
      path = "/tmp/osa-claims-board-test-#{System.unique_integer([:positive])}.ex"
      a = uniq("agent-a")
      b = uniq("agent-b")

      assert {:ok, claim_id} = Board.claim_file(a, path)
      assert {:conflict, holder} = Board.claim_file(b, path)
      assert holder.agent_id == a
      assert holder.kind == :file

      # Visible to anyone asking BEFORE they start — the whole point of a board.
      assert %{agent_id: ^a} = Board.file_conflict(b, path)
      refute Board.file_conflict(a, path), "an agent's own claim is not a conflict against itself"

      Board.release(a, claim_id)
      assert {:ok, _new_claim} = Board.claim_file(b, path)
    end

    test "claiming DIFFERENT files never conflicts" do
      a = uniq("agent-a")
      b = uniq("agent-b")
      path_a = "/tmp/osa-claims-board-a-#{System.unique_integer([:positive])}.ex"
      path_b = "/tmp/osa-claims-board-b-#{System.unique_integer([:positive])}.ex"

      assert {:ok, _} = Board.claim_file(a, path_a)
      assert {:ok, _} = Board.claim_file(b, path_b)
    end

    test "a relative and an absolute path to the SAME file compare equal (ConflictScope.canonical/2 reuse)" do
      a = uniq("agent-a")
      b = uniq("agent-b")

      abs_path =
        Path.join(
          System.tmp_dir!(),
          "osa-claims-board-rel-#{System.unique_integer([:positive])}.ex"
        )

      File.write!(abs_path, "x")

      cwd = File.cwd!()
      rel_path = Path.relative_to(abs_path, cwd)

      assert {:ok, _} = Board.claim_file(a, abs_path)

      result =
        if String.starts_with?(abs_path, cwd),
          do: Board.claim_file(b, rel_path),
          # Not under cwd on this machine — fall back to re-claiming the
          # absolute path itself, which must still conflict.
          else: Board.claim_file(b, abs_path)

      assert match?({:conflict, _}, result)
      File.rm(abs_path)
    end
  end

  describe "task claims (no file target — RegionLock does not apply)" do
    test "a near-duplicate investigation is surfaced as a conflict" do
      a = uniq("agent-a")
      b = uniq("agent-b")

      assert {:ok, _} = Board.claim_task(a, "investigate the flaky auth integration test")

      assert {:conflict, holder} =
               Board.claim_task(b, "look into the flaky auth integration test failures")

      assert holder.agent_id == a
      assert holder.kind == :task
    end

    test "an unrelated task never conflicts" do
      a = uniq("agent-a")
      b = uniq("agent-b")

      assert {:ok, _} = Board.claim_task(a, "investigate the flaky auth integration test")
      assert {:ok, _} = Board.claim_task(b, "write the release notes for v2")
    end

    test "released and re-claimable" do
      a = uniq("agent-a")
      b = uniq("agent-b")

      assert {:ok, claim_id} = Board.claim_task(a, "audit the billing pipeline")
      Board.release(a, claim_id)

      assert {:ok, _} = Board.claim_task(b, "audit the billing pipeline")
    end
  end

  describe "visibility — see active claims before starting" do
    test "active_claims/0 lists every active claim, file and task alike, from any agent" do
      a = uniq("agent-a")
      b = uniq("agent-b")
      path = "/tmp/osa-claims-board-visible-#{System.unique_integer([:positive])}.ex"

      {:ok, file_claim_id} = Board.claim_file(a, path)
      {:ok, task_claim_id} = Board.claim_task(b, "survey the plugin ecosystem")

      claims = Board.active_claims()
      ids = Enum.map(claims, & &1.claim_id)

      assert file_claim_id in ids
      assert task_claim_id in ids
    end
  end

  describe "surfaced by default, blocking is opt-in" do
    test "the CONFLICT is always returned to the caller regardless of the blocking setting" do
      a = uniq("agent-a")
      b = uniq("agent-b")
      path = "/tmp/osa-claims-board-block-#{System.unique_integer([:positive])}.ex"

      {:ok, _} = Board.claim_file(a, path)

      refute Board.block_on_conflict?()
      assert {:conflict, _} = Board.claim_file(b, path)

      Application.put_env(:optimal_system_agent, :claims_board_block_on_conflict, true)
      assert Board.block_on_conflict?()
      # The MODULE's own contract is unchanged either way — it always
      # returns {:conflict, holder}; it is the TOOL layer (`claims_board`)
      # that decides whether that becomes a blocking {:error, _} or an
      # advisory {:ok, _}. See `tools/builtins/claims_board_test.exs`.
      assert {:conflict, _} = Board.claim_file(b, path)
    end
  end

  describe "expiry — claims released when the owning agent finishes or dies" do
    test "sweep_now/0 releases a task claim whose agent is neither registered nor a running RunStore row" do
      dead_agent = uniq("agent-dead")
      assert {:ok, claim_id} = Board.claim_task(dead_agent, "a task claimed by a dead agent")

      assert Enum.any?(Board.active_claims(), &(&1.claim_id == claim_id))

      Board.sweep_now()

      refute Enum.any?(Board.active_claims(), &(&1.claim_id == claim_id)),
             "a claim whose agent is neither a live process nor a running RunStore row must be " <>
               "released by the liveness sweep"
    end

    test "a claim for an agent with a :running RunStore row survives the sweep even with no live process" do
      queued_agent = uniq("agent-queued")

      RunStore.start_run(%{
        agent_id: queued_agent,
        parent_session_id: "some-parent",
        role: "tester",
        task: "queued work",
        phase: :queued
      })

      assert {:ok, claim_id} = Board.claim_task(queued_agent, "work still queued, not dead")

      Board.sweep_now()

      assert Enum.any?(Board.active_claims(), &(&1.claim_id == claim_id)),
             "a queued-but-not-yet-started agent must not have its claim released prematurely"

      RunStore.complete(queued_agent, %{
        agent_id: queued_agent,
        status: :completed,
        summary: "done"
      })

      Board.sweep_now()

      refute Enum.any?(Board.active_claims(), &(&1.claim_id == claim_id)),
             "once the run settles terminal, its claim must be released"
    end

    test "release_all/1 frees every claim (file and task) held by one agent" do
      agent = uniq("agent-multi")
      path = "/tmp/osa-claims-board-multi-#{System.unique_integer([:positive])}.ex"

      {:ok, file_claim_id} = Board.claim_file(agent, path)
      {:ok, task_claim_id} = Board.claim_task(agent, "a second thing this agent is doing")

      Board.release_all(agent)

      refute Enum.any?(Board.active_claims(), &(&1.claim_id in [file_claim_id, task_claim_id]))
      refute Board.file_conflict(uniq("agent-checker"), path)
    end
  end
end
