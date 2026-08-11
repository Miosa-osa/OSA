defmodule OptimalSystemAgent.Agent.Fleet.FinalizerConflictBriefsTest do
  @moduledoc """
  The finalizer detects conflicts and SKIPS the conflicted files — which voids
  every claimant's work on them. These pin the recovery path: the finalizer must
  emit enough structured detail for the `merge-reconciler` skill to salvage that
  work, and must say so in the human-readable message.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Fleet.Finalizer

  defp node(id, files, overrides \\ []) do
    %{
      node_id: id,
      worktree_ref: Keyword.get(overrides, :worktree_ref, "wt/#{id}"),
      files_changed: files,
      gate: Keyword.get(overrides, :gate, :pass),
      stubbed: [],
      summary: Keyword.get(overrides, :summary, "did #{id}"),
      error: Keyword.get(overrides, :error, nil)
    }
  end

  defp ok_git, do: fn _args, _cwd -> {"ok", 0} end
  defp ok_cmd, do: fn _c, _d -> {"", 0} end

  defp finalize(nodes, opts \\ []) do
    Finalizer.finalize("sess", nodes, Keyword.merge([git_fun: ok_git(), cmd_fun: ok_cmd()], opts))
  end

  describe "conflict_briefs" do
    test "names every claimant of each conflicted file, with the ref its work is recoverable from" do
      nodes = [
        node("a", ["lib/x.ex", "lib/shared.ex"], summary: "added auth guard"),
        node("b", ["lib/y.ex", "lib/shared.ex"], summary: "rewrote token parse")
      ]

      res = finalize(nodes)

      assert res.conflicts == ["lib/shared.ex"]
      assert [%{file: "lib/shared.ex", claimants: claimants}] = res.conflict_briefs

      assert Enum.map(claimants, & &1.node_id) |> Enum.sort() == ["a", "b"]

      # The worktree ref is the whole point: without it the skipped edits are
      # unreachable.
      assert Enum.map(claimants, & &1.worktree_ref) |> Enum.sort() == ["wt/a", "wt/b"]

      # Intent travels with the claim so a reconciler can combine rather than pick.
      assert Enum.map(claimants, & &1.summary) |> Enum.sort() ==
               ["added auth guard", "rewrote token parse"]
    end

    test "an errored claimant is included and flagged, not dropped" do
      nodes = [
        node("a", ["lib/shared.ex"]),
        node("b", ["lib/shared.ex"], error: :timeout, gate: :fail)
      ]

      res = finalize(nodes)

      assert [%{claimants: claimants}] = res.conflict_briefs
      assert length(claimants) == 2

      errored = Enum.find(claimants, & &1.errored)
      assert errored.node_id == "b"
      assert errored.gate == :fail

      # ...and the healthy one is not mislabelled.
      assert Enum.find(claimants, &(&1.node_id == "a")).errored == false
    end

    test "a non-isolated claimant is recorded with a nil ref (its edits are on disk)" do
      nodes = [
        node("a", ["lib/shared.ex"], worktree_ref: nil),
        node("b", ["lib/shared.ex"])
      ]

      res = finalize(nodes)

      assert [%{claimants: claimants}] = res.conflict_briefs
      assert Enum.find(claimants, &(&1.node_id == "a")).worktree_ref == nil
    end

    test "is empty when the wave was genuinely disjoint" do
      res = finalize([node("a", ["lib/x.ex"]), node("b", ["lib/y.ex"])])

      assert res.conflicts == []
      assert res.conflict_briefs == []
    end

    test "briefs survive a failed merge, when they matter most" do
      failing_git = fn
        ["checkout" | _], _cwd -> {"fatal: pathspec", 1}
        _args, _cwd -> {"ok", 0}
      end

      res =
        finalize(
          [node("a", ["lib/x.ex", "lib/shared.ex"]), node("b", ["lib/shared.ex"])],
          git_fun: failing_git
        )

      assert res.gate == :fail
      assert res.merged == []
      assert [%{file: "lib/shared.ex"}] = res.conflict_briefs
    end

    test "one brief per conflicted file, in the same order as :conflicts" do
      nodes = [
        node("a", ["lib/one.ex", "lib/two.ex"]),
        node("b", ["lib/one.ex", "lib/two.ex"])
      ]

      res = finalize(nodes)

      assert res.conflicts == ["lib/one.ex", "lib/two.ex"]
      assert Enum.map(res.conflict_briefs, & &1.file) == res.conflicts
    end
  end

  describe "the message names the recovery path" do
    test "a conflicted finalize points at merge-reconciler instead of reading as a failure" do
      res = finalize([node("a", ["lib/shared.ex"]), node("b", ["lib/shared.ex"])])

      assert res.message =~ "merge-reconciler"
      assert res.message =~ "conflict_briefs"
      assert res.message =~ "do not re-run the wave"
    end

    test "a clean finalize says nothing about reconciliation" do
      res = finalize([node("a", ["lib/x.ex"])])
      refute res.message =~ "merge-reconciler"
    end
  end

  describe "the no-clobber invariant still holds" do
    test "conflicted files are never checked out and never staged" do
      {:ok, pid} = Agent.start_link(fn -> [] end)

      git = fn args, _cwd ->
        Agent.update(pid, &(&1 ++ [args]))
        {"ok", 0}
      end

      finalize(
        [
          node("a", ["lib/x.ex", "lib/shared.ex"]),
          node("b", ["lib/shared.ex"], worktree_ref: nil)
        ],
        git_fun: git,
        commit: "wave"
      )

      touched =
        pid
        |> Agent.get(& &1)
        |> Enum.filter(&(match?(["checkout" | _], &1) or match?(["add" | _], &1)))
        |> Enum.map(&List.last/1)

      refute "lib/shared.ex" in touched
    end
  end
end
