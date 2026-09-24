defmodule OptimalSystemAgent.Agent.Loop.Regulation.SurpriseTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Loop.Regulation.Surprise

  defp sid, do: "surprise-#{System.unique_integer([:positive])}"
  defp state, do: %{session_id: sid()}

  defp tc(name, args, id \\ "call_1"), do: %{id: id, name: name, arguments: args}

  describe "shell_execute" do
    test "a read-only command is never risky, even if it somehow errors" do
      call = tc("shell_execute", %{"command" => "pwd"})
      results = [{call, {%{}, "Exit 1:\nsomething odd"}}]

      new_state = Surprise.check(results, [call], state())
      assert Map.get(new_state, :regulation_surprise_count, 0) == 0
    end

    test "a mutating command exiting non-zero for no excusable reason is a surprise" do
      call = tc("shell_execute", %{"command" => "rm -f /tmp/definitely-not-there-xyz"})
      results = [{call, {%{}, "Exit 1:\nrm: cannot remove: No such file or directory"}}]

      new_state = Surprise.check(results, [call], state())
      assert Map.get(new_state, :regulation_surprise_count, 0) == 1
    end

    test "grep's benign exit 1 (no matches) is NOT a surprise, even for a risky (redirecting) call" do
      # The redirect makes this NOT provably read-only (so it IS scored as
      # risky), which is exactly what isolates the `ExitClassifier.benign_exit?/2`
      # path this test is about — a plain `grep file.txt` would never reach it,
      # since a read-only call is never risky in the first place.
      call = tc("shell_execute", %{"command" => "grep TODO file.txt > /tmp/out.txt"})
      results = [{call, {%{}, "Exit 1:\n"}}]

      new_state = Surprise.check(results, [call], state())
      assert Map.get(new_state, :regulation_surprise_count, 0) == 0
    end

    test "a mutating command that succeeds is not a surprise" do
      call = tc("shell_execute", %{"command" => "mkdir -p /tmp/x"})
      results = [{call, {%{}, ""}}]

      new_state = Surprise.check(results, [call], state())
      assert Map.get(new_state, :regulation_surprise_count, 0) == 0
    end
  end

  describe "edit/write tools" do
    test "an errored edit is a surprise" do
      call = tc("file_edit", %{"path" => "/tmp/x"})
      results = [{call, {%{}, "Error: file not found"}}]

      new_state = Surprise.check(results, [call], state())
      assert Map.get(new_state, :regulation_surprise_count, 0) == 1
    end

    test "a blocked edit is a surprise" do
      call = tc("file_edit", %{"path" => "/tmp/x"})
      results = [{call, {%{}, "Blocked: outside workspace"}}]

      new_state = Surprise.check(results, [call], state())
      assert Map.get(new_state, :regulation_surprise_count, 0) == 1
    end

    test "a no-op idempotent edit is NOT a surprise" do
      call = tc("file_edit", %{"path" => "/tmp/x"})
      results = [{call, {%{}, "No change needed"}}]

      new_state = Surprise.check(results, [call], state())
      assert Map.get(new_state, :regulation_surprise_count, 0) == 0
    end

    test "a successful edit is not a surprise" do
      call = tc("file_edit", %{"path" => "/tmp/x"})
      results = [{call, {%{}, "Edited /tmp/x"}}]

      new_state = Surprise.check(results, [call], state())
      assert Map.get(new_state, :regulation_surprise_count, 0) == 0
    end
  end

  describe "reads are never risky" do
    test "a failing read is not a surprise" do
      call = tc("file_read", %{"path" => "/tmp/does-not-exist"})
      results = [{call, {%{}, "Error: enoent"}}]

      new_state = Surprise.check(results, [call], state())
      assert Map.get(new_state, :regulation_surprise_count, 0) == 0
    end
  end

  test "accumulates across iterations rather than resetting" do
    call = tc("file_edit", %{"path" => "/tmp/x"})
    results = [{call, {%{}, "Error: nope"}}]

    state1 = Surprise.check(results, [call], state())
    assert state1.regulation_surprise_count == 1

    state2 = Surprise.check(results, [call], state1)
    assert state2.regulation_surprise_count == 2
  end

  test "several surprises in one iteration all count" do
    edit = tc("file_edit", %{"path" => "/tmp/x"}, "call_1")
    shell = tc("shell_execute", %{"command" => "rm -f /tmp/nope"}, "call_2")

    results = [
      {edit, {%{}, "Error: nope"}},
      {shell, {%{}, "Exit 2:\nrm: unexpected"}}
    ]

    new_state = Surprise.check(results, [edit, shell], state())
    assert new_state.regulation_surprise_count == 2
  end
end
