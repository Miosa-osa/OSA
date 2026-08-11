defmodule OptimalSystemAgent.Orchestrator.FailureReportingTest do
  @moduledoc """
  Three ways the orchestrator reported things that were not true.

  1. `changed_files/1` parsed `git status --porcelain` WITHOUT `-z` and did
     `String.slice(3..-1)`, so a path containing a space or non-ASCII byte
     stayed git-quoted and a rename came back as the bogus single path
     `"old -> new"`. The correct NUL-separated parser already existed in
     `Agent.Fleet.parse_porcelain_z/1`.

  2. A deliberate user cancellation was funnelled through `failure_result/5`,
     which hardcoded `status: :failed` — durably recording an Esc as a fault
     although `RunStore` models `:cancelled` first-class.

  3. The rescue path emitted `orchestrator_agent_completed` with
     `tool_uses: 0, tokens_used: 0`. Those are real wire values, so the TUI
     applied them as `Some(0)` and wiped the counters it had accumulated. The
     keys must be ABSENT, not zero.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Orchestrator

  describe "changed_files/1 porcelain parsing" do
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "osa_orch_porcelain_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf(tmp) end)

      {_, 0} = System.cmd("git", ["init", "-q", tmp], stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["-C", tmp, "config", "user.email", "t@t"], stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["-C", tmp, "config", "user.name", "t"], stderr_to_stdout: true)

      {:ok, tmp: tmp}
    end

    defp commit_all(tmp) do
      {_, 0} = System.cmd("git", ["-C", tmp, "add", "-A"], stderr_to_stdout: true)

      {_, 0} =
        System.cmd("git", ["-C", tmp, "commit", "-q", "-m", "base"], stderr_to_stdout: true)
    end

    test "a path with a space is returned unquoted and whole", %{tmp: tmp} do
      File.write!(Path.join(tmp, "a file with spaces.ex"), "x")

      files = Orchestrator.changed_files(%{path: tmp})

      assert "a file with spaces.ex" in files,
             "got #{inspect(files)} — the path was truncated or left git-quoted"
    end

    test "a non-ASCII path is not left git-quoted", %{tmp: tmp} do
      File.write!(Path.join(tmp, "café.ex"), "x")

      files = Orchestrator.changed_files(%{path: tmp})

      assert "café.ex" in files, "got #{inspect(files)}"
      refute Enum.any?(files, &String.contains?(&1, "\\"))
    end

    test "a rename yields two real paths, never the literal \"old -> new\"", %{tmp: tmp} do
      File.write!(Path.join(tmp, "old.ex"), "x")
      commit_all(tmp)

      File.rename!(Path.join(tmp, "old.ex"), Path.join(tmp, "new.ex"))
      {_, 0} = System.cmd("git", ["-C", tmp, "add", "-A"], stderr_to_stdout: true)

      files = Orchestrator.changed_files(%{path: tmp})

      refute Enum.any?(files, &String.contains?(&1, "->")),
             "got #{inspect(files)} — a rename was reported as one bogus path"

      assert "new.ex" in files
    end

    test "a nil or pathless worktree is []" do
      assert Orchestrator.changed_files(nil) == []
      assert Orchestrator.changed_files(%{}) == []
    end
  end

  describe "a user cancellation is recorded as :cancelled, not :failed" do
    test "terminal_status/1 keeps :cancelled first-class" do
      assert Orchestrator.terminal_status(:cancelled) == :cancelled
      assert Orchestrator.terminal_status(:timeout) == :failed
      assert Orchestrator.terminal_status({:exit, :boom}) == :failed
    end

    test "failure_result/5 settles a cancel as :cancelled and says CANCELLED" do
      result = Orchestrator.failure_result("child-1", "parent-1", "gp", :cancelled)

      assert result.status == :cancelled
      assert result.summary =~ "CANCELLED"
      refute result.summary =~ "FAILED"
    end

    test "failure_result/5 still settles a real fault as :failed" do
      result = Orchestrator.failure_result("child-1", "parent-1", "gp", :timeout)

      assert result.status == :failed
      assert result.summary =~ "FAILED"
    end
  end

  describe "the rescue completion event omits counters rather than zeroing them" do
    test "start_failure_event/2 carries no tool_uses / tokens_used keys" do
      event = Orchestrator.start_failure_event("child-1", :boom)

      refute Map.has_key?(event, :tool_uses),
             "tool_uses: 0 is a real wire value — the TUI applies it and wipes its counters"

      refute Map.has_key?(event, :tokens_used)
      assert event.status == "failed"
      assert event.agent_name == "child-1"
    end
  end
end
