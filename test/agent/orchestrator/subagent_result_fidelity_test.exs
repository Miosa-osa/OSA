defmodule OptimalSystemAgent.Agent.Orchestrator.SubagentResultFidelityTest do
  @moduledoc """
  Three fidelity defects in how the orchestrator reports a finished subagent:

    1. `changed_files/1` parsed `git status --porcelain` WITHOUT `-z`, so any
       path containing a space or a non-ASCII byte came back git-QUOTED and a
       rename came back as the single bogus field `old -> new`. None of those
       strings name a file that exists.

    2. A deliberate user cancel (Esc) was funnelled through `failure_result/5`,
       which hardcoded `status: :failed` — durably recording user action as a
       fault even though `RunStore` models `:cancelled` first-class.

    3. The never-started (Loop spawn failed) completion event shipped
       `tool_uses: 0, tokens_used: 0`. Zero is a real wire value: the TUI
       applies it and wipes the counters it already accumulated. Absence, not
       zero, is how "no measurement" is expressed.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Orchestrator

  # ---------------------------------------------------------------------------
  # D1 — git porcelain paths survive spaces, non-ASCII and renames
  # ---------------------------------------------------------------------------

  describe "changed_files/1 — porcelain paths are real paths" do
    @tag :tmp_dir
    test "spaces, non-ASCII and renames all yield paths that exist on disk", %{tmp_dir: tmp} do
      git = fn args -> System.cmd("git", args, cd: tmp, stderr_to_stdout: true) end

      {_, 0} = git.(["init", "-q"])
      {_, 0} = git.(["config", "user.email", "t@example.com"])
      {_, 0} = git.(["config", "user.name", "t"])
      # Committed baseline: one file we will rename.
      File.write!(Path.join(tmp, "original.txt"), "base\n")
      {_, 0} = git.(["add", "-A"])
      {_, 0} = git.(["commit", "-q", "-m", "base"])

      # Now dirty the tree three different ways.
      File.write!(Path.join(tmp, "my file.txt"), "spaces\n")
      File.write!(Path.join(tmp, "café.txt"), "non-ascii\n")
      {_, 0} = git.(["mv", "original.txt", "renamed.txt"])
      {_, 0} = git.(["add", "-A"])

      changed = Orchestrator.changed_files(%{path: tmp})

      # A rename must never be reported as the single field "old -> new".
      refute Enum.any?(changed, &String.contains?(&1, " -> ")),
             "rename collapsed into a bogus 'old -> new' path: #{inspect(changed)}"

      # Paths must NOT arrive git-quoted (`"my file.txt"`, `"caf\303\251.txt"`).
      refute Enum.any?(changed, &String.starts_with?(&1, "\"")),
             "path arrived git-quoted: #{inspect(changed)}"

      assert "my file.txt" in changed
      assert "café.txt" in changed
      # Both sides of the rename are genuinely changed.
      assert "renamed.txt" in changed
      assert "original.txt" in changed

      # Every reported path except the rename ORIGIN (which no longer exists)
      # must resolve to something on disk.
      for p <- changed -- ["original.txt"] do
        assert File.exists?(Path.join(tmp, p)), "reported path does not exist: #{inspect(p)}"
      end
    end

    test "nil / unknown worktree is []" do
      assert Orchestrator.changed_files(nil) == []
      assert Orchestrator.changed_files(%{}) == []
    end

    test "a vanished worktree path is [] and never raises" do
      gone = Path.join(System.tmp_dir!(), "osa-no-such-worktree-#{System.unique_integer([:positive])}")
      refute File.exists?(gone)
      assert Orchestrator.changed_files(%{path: gone}) == []
    end
  end

  # ---------------------------------------------------------------------------
  # D2 — a user cancel is recorded as :cancelled, not :failed
  # ---------------------------------------------------------------------------

  describe "failure_result/5 — cancellation is not failure" do
    test "an explicit cancel settles as :cancelled" do
      result = Orchestrator.failure_result("sub-1", "parent-1", "coder", :cancelled)

      assert result.status == :cancelled
      refute result.summary =~ "FAILED"
      assert result.summary =~ "CANCELLED"
    end

    test "every other reason still settles as :failed" do
      for reason <- [:timeout, :already_started, {:crashed, :badarg}, :whatever] do
        result = Orchestrator.failure_result("sub-1", "parent-1", "coder", reason)
        assert result.status == :failed, "#{inspect(reason)} should be a failure"
      end
    end

    test "terminal_status/1 maps only :cancelled to :cancelled" do
      assert Orchestrator.terminal_status(:cancelled) == :cancelled
      assert Orchestrator.terminal_status(:timeout) == :failed
      assert Orchestrator.terminal_status({:crashed, :killed}) == :failed
    end

    test "the status RunStore would latch for a cancelled run is a RunStore terminal status" do
      # RunStore.complete/2 latches the FIRST terminal status. When Loop.cancel
      # has already settled the run as :cancelled, a :failed result would be
      # ignored anyway — but when the orchestrator lands first, the status it
      # stamps IS the latched truth, so it has to be right at the source.
      result = Orchestrator.failure_result("sub-2", "parent-1", "coder", :cancelled)
      assert result.status in [:completed, :failed, :cancelled]
      assert result.status == :cancelled
    end
  end

  # ---------------------------------------------------------------------------
  # D3 — never-started event omits usage rather than zeroing it
  # ---------------------------------------------------------------------------

  describe "start_failure_event/2 — absent, not zero" do
    test "carries no tool_uses / tokens_used keys at all" do
      event = Orchestrator.start_failure_event("sub-3", :enoent)

      refute Map.has_key?(event, :tool_uses),
             "tool_uses: 0 wipes the TUI's accumulated counter — omit the key"

      refute Map.has_key?(event, :tokens_used),
             "tokens_used: 0 wipes the TUI's accumulated counter — omit the key"
    end

    test "still identifies the agent and the failure" do
      event = Orchestrator.start_failure_event("sub-3", :enoent)

      assert event.event == "orchestrator_agent_completed"
      assert event.agent_name == "sub-3"
      assert event.status == "failed"
      assert event.error =~ "enoent"
      assert is_binary(event.summary)
    end
  end
end
