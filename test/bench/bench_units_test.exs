defmodule OptimalSystemAgent.BenchUnitsTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Bench.{Check, Report, Script, TaskSpec, Workspace}

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-bench-unit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  describe "TaskSpec" do
    test "every shipped task file loads and validates" do
      {:ok, tasks} = TaskSpec.load_dir(Path.join(File.cwd!(), "bench/osabench/tasks"))
      assert length(tasks) >= 20
      assert Enum.all?(tasks, &(&1.reference != []))
    end

    test "rejects a task without a checker" do
      assert {:error, msg} = TaskSpec.from_map(%{id: "x", prompt: "p", check: []})
      assert msg =~ ":check"
    end

    test "par counts the reference's tool calls" do
      {:ok, t} =
        TaskSpec.from_map(%{
          id: "x",
          prompt: "p",
          check: [{:answer_matches, "y"}],
          reference: [[{"a", %{}}, {"b", %{}}], [{"c", %{}}], {:answer, "y"}]
        })

      assert TaskSpec.par_tool_calls(t) == 3
    end
  end

  describe "Workspace" do
    test "applies setup ops and refuses paths outside the workspace", %{dir: dir} do
      File.write!(Path.join(dir, "a.txt"), "hello world\n")

      assert :ok =
               Workspace.apply_ops(dir, [
                 {:replace, "a.txt", "world", "there"},
                 {:write, "sub/b.txt", "b"},
                 {:noise, "deps", 3, "p{{n}}/x.ex", "file {{n}}"},
                 {:large_file, "big.log", 5, "line {{n}}", %{3 => "needle"}}
               ])

      assert File.read!(Path.join(dir, "a.txt")) == "hello there\n"
      assert File.read!(Path.join(dir, "deps/p2/x.ex")) == "file 2"
      assert File.read!(Path.join(dir, "big.log")) == "line 1\nline 2\nneedle\nline 4\nline 5\n"

      assert {:error, msg} = Workspace.apply_ops(dir, [{:replace, "a.txt", "absent", "x"}])
      assert msg =~ "exactly one match"
      assert {:error, _} = Workspace.apply_ops(dir, [{:write, "../escape.txt", "x"}])
    end
  end

  describe "Check" do
    test "file, json, tree and answer ops", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "lib"))
      File.write!(Path.join(dir, "lib/a.ex"), "foo()\nfoo()\n")
      File.write!(Path.join(dir, "s.json"), ~s({"a": 1, "b": {"c": 2}}))

      checks = [
        {:file_contains, "lib/a.ex", "foo()"},
        {:file_lacks, "lib/a.ex", ~r/bar/},
        {:tree_count, "lib/**/*.ex", "foo()", 2},
        {:json_equals, "s.json", ["b", "c"], 2},
        {:json_unchanged_except, "s.json", [["a"]]},
        {:answer_matches, ~r/\b42\b/},
        {:answer_lacks, "43"}
      ]

      snap = Check.snapshot(dir, checks)
      File.write!(Path.join(dir, "s.json"), ~s({"a": 9, "b": {"c": 2}}))

      assert {true, results} = Check.run(checks, dir, "It is 42.", snap)
      assert length(results) == length(checks)

      File.write!(Path.join(dir, "s.json"), ~s({"a": 9, "b": {"c": 3}}))
      assert {false, results} = Check.run(checks, dir, "It is 42.", snap)
      assert Enum.count(results, &(not &1.pass)) == 2
    end

    test "a missing file fails instead of raising", %{dir: dir} do
      assert {false, [%{pass: false}]} = Check.run([{:file_contains, "nope", "x"}], dir, "", %{})
    end
  end

  describe "Script" do
    test "oracle plays one step per assistant turn and substitutes the workdir" do
      fun =
        Script.responder(
          :oracle,
          [[{"file_read", %{"path" => "$WORKDIR/a"}}], {:answer, "done in $WORKDIR"}],
          "/w"
        )

      first = fun.([%{role: "user", content: "go"}], [])
      assert [%{name: "file_read", arguments: %{"path" => "/w/a"}}] = first.tool_calls

      second = fun.([%{role: "user", content: "go"}, %{role: "assistant", content: ""}], [])
      assert second.content == "done in /w"
      assert second.tool_calls == []

      # an extra harness round replays the final answer
      third = fun.([%{role: "assistant"}, %{"role" => "assistant"}, %{role: "user"}], [])
      assert third.content == "done in /w"
    end

    test "nop answers without tools" do
      assert %{tool_calls: []} = Script.responder(:nop, [], "/w").([], [])
    end
  end

  describe "Report" do
    defp row(id, pass, wall, attempt \\ 1) do
      %{
        id: id,
        category: "edit",
        attempt: attempt,
        pass: pass,
        status: "done",
        par_tool_calls: 2,
        wall_ms: wall,
        model_ms: div(wall, 2),
        tool_ms: div(wall, 4),
        tool_calls: 2,
        tokens_in: 1000,
        tokens_out: 100,
        cost_usd: 0.01,
        retries: 0,
        wasted_steps: 0,
        checks: [],
        error: nil
      }
    end

    test "aggregate takes the median over attempts" do
      [t] =
        Report.aggregate([row("a", true, 100), row("a", false, 900, 2), row("a", true, 200, 3)])

      assert t.wall_ms == 200
      assert t.passes == 2
      assert t.attempts == 3
    end

    test "compare flags regressions and fixes and reports a geometric speed ratio" do
      a =
        Jason.decode!(
          Jason.encode!(
            Report.document(%{run_id: "a"}, [
              row("x", true, 1000),
              row("y", false, 1000),
              row("z", true, 1000)
            ])
          )
        )

      b =
        Jason.decode!(
          Jason.encode!(
            Report.document(%{run_id: "b"}, [
              row("x", false, 500),
              row("y", true, 500),
              row("z", true, 250)
            ])
          )
        )

      result = Report.compare(a, b)
      assert result.summary.regressed == ["x"]
      assert result.summary.fixed == ["y"]
      assert_in_delta result.summary.geo_wall_ratio, 0.25, 0.001
      assert result.text =~ "REGRESSED: x"
    end
  end
end
