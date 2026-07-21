defmodule OptimalSystemAgent.Agent.Fleet.FinalizerTest do
  @moduledoc """
  FLEET_ORCHESTRATION O3 — the finalizer. Pure/injectable: git + gate shell IO
  are stubbed via `:git_fun` / `:cmd_fun`, so these exercise conflict detection,
  disjoint merge, gate ordering, commit-when-green, attribution-cleanliness, and
  the never-push invariant WITHOUT touching real git.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Fleet.Finalizer

  # Builds a frozen-contract node map, overridable via opts.
  defp node(id, files, overrides \\ []) do
    %{
      node_id: id,
      worktree_ref: Keyword.get(overrides, :worktree_ref, "wt/#{id}"),
      files_changed: files,
      gate: Keyword.get(overrides, :gate, :pass),
      stubbed: Keyword.get(overrides, :stubbed, []),
      summary: Keyword.get(overrides, :summary, "did #{id}"),
      error: Keyword.get(overrides, :error, nil)
    }
  end

  # A git_fun that records every call into an Agent and returns a scripted exit.
  defp recording_git(pid, exit_code \\ 0) do
    fn args, _cwd ->
      Agent.update(pid, fn calls -> calls ++ [args] end)
      {"ok", exit_code}
    end
  end

  setup do
    {:ok, pid} = Agent.start_link(fn -> [] end)
    {:ok, calls: pid, git: recording_git(pid)}
  end

  describe "conflict detection" do
    test "flags files changed by two nodes and skips merging them", %{calls: pid, git: git} do
      nodes = [
        node("a", ["lib/x.ex", "lib/shared.ex"]),
        node("b", ["lib/y.ex", "lib/shared.ex"])
      ]

      res = Finalizer.finalize("sess", nodes, git_fun: git, cmd_fun: fn _c, _d -> {"", 0} end)

      assert res.conflicts == ["lib/shared.ex"]
      # shared.ex must NOT be merged (no clobber); the disjoint files are.
      assert Enum.sort(res.merged) == ["lib/x.ex", "lib/y.ex"]

      checkout_files =
        pid
        |> Agent.get(& &1)
        |> Enum.filter(&match?(["checkout" | _], &1))
        |> Enum.map(&List.last/1)

      refute "lib/shared.ex" in checkout_files
    end

    test "no conflicts when file sets are disjoint", %{git: git} do
      nodes = [node("a", ["lib/x.ex"]), node("b", ["lib/y.ex"])]
      res = Finalizer.finalize("sess", nodes, git_fun: git)
      assert res.conflicts == []
    end
  end

  describe "disjoint merge" do
    test "checks out each node's files from its worktree_ref", %{calls: pid, git: git} do
      nodes = [
        node("a", ["lib/a.ex"], worktree_ref: "ref-a"),
        node("b", ["lib/b1.ex", "lib/b2.ex"], worktree_ref: "ref-b")
      ]

      res = Finalizer.finalize("sess", nodes, git_fun: git)

      assert Enum.sort(res.merged) == ["lib/a.ex", "lib/b1.ex", "lib/b2.ex"]

      calls = Agent.get(pid, & &1)
      assert ["checkout", "ref-a", "--", "lib/a.ex"] in calls
      assert ["checkout", "ref-b", "--", "lib/b1.ex"] in calls
      assert ["checkout", "ref-b", "--", "lib/b2.ex"] in calls
    end

    test "nodes with an error are excluded from merge", %{git: git} do
      nodes = [
        node("a", ["lib/a.ex"]),
        node("b", ["lib/b.ex"], error: :timeout)
      ]

      res = Finalizer.finalize("sess", nodes, git_fun: git)
      assert res.merged == ["lib/a.ex"]
    end

    test "nil worktree_ref node contributes no checkout", %{calls: pid, git: git} do
      nodes = [node("a", ["lib/a.ex"], worktree_ref: nil)]
      res = Finalizer.finalize("sess", nodes, git_fun: git)

      assert res.merged == []
      refute Enum.any?(Agent.get(pid, & &1), &match?(["checkout" | _], &1))
    end

    test "a failing checkout returns a :fail result, no commit", %{calls: pid} do
      failing_git = fn args, _cwd ->
        Agent.update(pid, fn c -> c ++ [args] end)
        {"fatal: bad ref", 1}
      end

      res =
        Finalizer.finalize("sess", [node("a", ["lib/a.ex"])],
          git_fun: failing_git,
          commit: "feat: x"
        )

      assert res.gate == :fail
      assert res.committed == false
      refute Enum.any?(Agent.get(pid, & &1), &match?(["commit" | _], &1))
    end
  end

  describe "gate" do
    test "skipped when no gate_cmds given", %{git: git} do
      res = Finalizer.finalize("sess", [node("a", ["lib/a.ex"])], git_fun: git)
      assert res.gate == :skipped
      assert res.gate_output == ""
    end

    test "runs commands in order and passes when all exit 0", %{git: git} do
      {:ok, ran} = Agent.start_link(fn -> [] end)

      cmd = fn c, _d ->
        Agent.update(ran, fn xs -> xs ++ [c] end)
        {"out:#{c}", 0}
      end

      res =
        Finalizer.finalize("sess", [node("a", ["lib/a.ex"])],
          git_fun: git,
          cmd_fun: cmd,
          gate_cmds: ["mix compile", "mix test lib/a_test.exs"]
        )

      assert res.gate == :pass
      assert Agent.get(ran, & &1) == ["mix compile", "mix test lib/a_test.exs"]
      assert res.gate_output =~ "mix compile"
      assert res.gate_output =~ "mix test"
    end

    test "stops at first failure and marks :fail", %{git: git} do
      {:ok, ran} = Agent.start_link(fn -> [] end)

      cmd = fn c, _d ->
        Agent.update(ran, fn xs -> xs ++ [c] end)
        code = if c == "mix compile", do: 1, else: 0
        {"out:#{c}", code}
      end

      res =
        Finalizer.finalize("sess", [node("a", ["lib/a.ex"])],
          git_fun: git,
          cmd_fun: cmd,
          gate_cmds: ["mix compile", "mix test"]
        )

      assert res.gate == :fail
      # second command must never run
      assert Agent.get(ran, & &1) == ["mix compile"]
    end
  end

  describe "commit when green" do
    test "commits with the verbatim message when gate passes", %{calls: pid, git: git} do
      res =
        Finalizer.finalize("sess", [node("a", ["lib/a.ex"])],
          git_fun: git,
          cmd_fun: fn _c, _d -> {"", 0} end,
          gate_cmds: ["mix compile"],
          commit: "feat(fleet): merge wave"
        )

      assert res.committed == true

      calls = Agent.get(pid, & &1)
      # Scoped staging: the merged file is staged by pathspec, never `git add -A`.
      refute ["add", "-A"] in calls
      assert ["add", "--", "lib/a.ex"] in calls
      assert ["commit", "-m", "feat(fleet): merge wave"] in calls
    end

    test "commits when gate is skipped (no cmds) but commit requested", %{calls: pid, git: git} do
      res =
        Finalizer.finalize("sess", [node("a", ["lib/a.ex"])],
          git_fun: git,
          commit: "chore: land"
        )

      assert res.gate == :skipped
      assert res.committed == true
      assert ["commit", "-m", "chore: land"] in Agent.get(pid, & &1)
    end

    test "does NOT commit when gate fails", %{calls: pid, git: git} do
      res =
        Finalizer.finalize("sess", [node("a", ["lib/a.ex"])],
          git_fun: git,
          cmd_fun: fn _c, _d -> {"boom", 1} end,
          gate_cmds: ["mix test"],
          commit: "feat: x"
        )

      assert res.gate == :fail
      assert res.committed == false
      refute Enum.any?(Agent.get(pid, & &1), &match?(["commit" | _], &1))
    end

    test "does NOT commit when there are conflicts", %{calls: pid, git: git} do
      nodes = [
        node("a", ["lib/shared.ex"]),
        node("b", ["lib/shared.ex"])
      ]

      res =
        Finalizer.finalize("sess", nodes,
          git_fun: git,
          gate_cmds: [],
          commit: "feat: x"
        )

      assert res.conflicts == ["lib/shared.ex"]
      assert res.committed == false
      refute Enum.any?(Agent.get(pid, & &1), &match?(["commit" | _], &1))
    end

    test "does not commit when no :commit message given", %{calls: pid, git: git} do
      res = Finalizer.finalize("sess", [node("a", ["lib/a.ex"])], git_fun: git)
      assert res.committed == false
      refute Enum.any?(Agent.get(pid, & &1), &match?(["commit" | _], &1))
    end
  end

  describe "scoped staging (never git add -A)" do
    test "stages the merged worktree diff AND non-isolated node files by pathspec",
         %{calls: pid, git: git} do
      nodes = [
        # isolated → checked out into the working tree (part of `merged`)
        node("a", ["lib/a.ex"], worktree_ref: "ref-a"),
        # non-isolated → its edits already live in the working tree; must still be
        # staged explicitly so the commit includes them
        node("b", ["lib/b.ex"], worktree_ref: nil)
      ]

      res = Finalizer.finalize("sess", nodes, git_fun: git, commit: "feat: scoped")

      assert res.committed == true

      calls = Agent.get(pid, & &1)
      # The blanket over-staging is gone.
      refute ["add", "-A"] in calls
      # Both the merged and the non-isolated file are staged, each by pathspec.
      assert ["add", "--", "lib/a.ex"] in calls
      assert ["add", "--", "lib/b.ex"] in calls
    end

    test "a failing scoped `git add` aborts the commit (no unrelated sweep)",
         %{calls: pid} do
      failing_add = fn
        ["add" | _] = args, _cwd ->
          Agent.update(pid, fn c -> c ++ [args] end)
          {"fatal: pathspec", 1}

        args, _cwd ->
          Agent.update(pid, fn c -> c ++ [args] end)
          {"ok", 0}
      end

      res =
        Finalizer.finalize("sess", [node("a", ["lib/a.ex"], worktree_ref: nil)],
          git_fun: failing_add,
          commit: "feat: x"
        )

      assert res.committed == false
      refute Enum.any?(Agent.get(pid, & &1), &match?(["commit" | _], &1))
    end
  end

  describe "attribution-clean + never push" do
    test "commit command carries no Claude / Co-Authored-By footer", %{calls: pid, git: git} do
      Finalizer.finalize("sess", [node("a", ["lib/a.ex"])],
        git_fun: git,
        commit: "feat: honest work"
      )

      all_args = pid |> Agent.get(& &1) |> List.flatten() |> Enum.join(" ")

      refute all_args =~ "Co-Authored-By"
      refute all_args =~ "Claude"
      refute all_args =~ "Generated with"
    end

    test "never invokes git push", %{calls: pid, git: git} do
      Finalizer.finalize("sess", [node("a", ["lib/a.ex"])],
        git_fun: git,
        cmd_fun: fn _c, _d -> {"", 0} end,
        gate_cmds: ["mix compile"],
        commit: "feat: land"
      )

      refute Enum.any?(Agent.get(pid, & &1), fn args -> match?(["push" | _], args) end)
    end
  end

  describe "never raises" do
    test "a throwing git_fun becomes a :fail result, not a crash", %{} do
      boom = fn _args, _cwd -> raise "kaboom" end

      res = Finalizer.finalize("sess", [node("a", ["lib/a.ex"])], git_fun: boom)

      assert res.gate == :fail
      assert res.committed == false
      assert res.message =~ "kaboom"
    end
  end

  describe "return shape" do
    test "always returns the full documented map", %{git: git} do
      res = Finalizer.finalize("sess", [node("a", ["lib/a.ex"])], git_fun: git)

      assert %{
               merged: _,
               conflicts: _,
               gate: gate,
               gate_output: out,
               committed: committed,
               message: msg
             } = res

      assert gate in [:pass, :fail, :skipped]
      assert is_binary(out)
      assert is_boolean(committed)
      assert is_binary(msg)
    end
  end
end
