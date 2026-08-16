defmodule OptimalSystemAgent.Tools.AuditTest do
  @moduledoc """
  The audit is an instrument, so its failure mode is not a crash — it is a
  number that is quietly wrong. These tests pin the three places a wrong number
  would come from: double-counting a call, scoring a failure as a success, and
  pricing a cut as a sum of its parts.
  """

  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Audit

  setup do
    dir = Path.join(System.tmp_dir!(), "osa_audit_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp write(dir, name, rows) do
    path = Path.join(dir, name)
    File.write!(path, Enum.map_join(rows, "\n", &Jason.encode!/1) <> "\n")
    path
  end

  describe "census/1 on *.updates.jsonl" do
    test "counts one call per entry in tool_calls, and the outcome separately", %{dir: dir} do
      write(dir, "a.updates.jsonl", [
        %{
          "msg" => %{
            "role" => "assistant",
            "tool_calls" => [
              %{"name" => "file_read", "arguments" => %{}},
              %{"name" => "file_read", "arguments" => %{}}
            ]
          }
        },
        %{"msg" => %{"role" => "tool", "name" => "file_read", "content" => "line one"}},
        %{"msg" => %{"role" => "tool", "name" => "file_read", "content" => "Error: no such file"}}
      ])

      %{"c" => counts} = Audit.census([{"c", dir}])

      assert counts["file_read"] == %{calls: 2, ok: 1, fail: 1}
    end
  end

  describe "census/1 on osa-events.jsonl" do
    test "a call emits both a start and an end; only the start counts", %{dir: dir} do
      write(dir, "osa-events.jsonl", [
        %{"type" => "tool_call", "phase" => "start", "name" => "shell_execute"},
        %{"type" => "tool_call", "phase" => "end", "name" => "shell_execute", "success" => true},
        %{"type" => "tool_result", "name" => "shell_execute", "result" => "total 12"}
      ])

      %{"c" => counts} = Audit.census([{"c", dir}])

      assert counts["shell_execute"].calls == 1
    end

    test "the result TEXT decides the outcome, not the success flag", %{dir: dir} do
      # Observed in bench/terminalbench: `success: true` on a body that is an
      # error. Trusting the flag would report this tool as healthy.
      write(dir, "osa-events.jsonl", [
        %{"type" => "tool_call", "phase" => "start", "name" => "file_glob"},
        %{
          "type" => "tool_result",
          "name" => "file_glob",
          "success" => true,
          "result" => "Error: Permission denied: /app is outside allowed paths"
        }
      ])

      %{"c" => counts} = Audit.census([{"c", dir}])

      assert counts["file_glob"] == %{calls: 1, ok: 0, fail: 1}
    end

    test "a result that merely CONTAINS the word Error is not a failure", %{dir: dir} do
      write(dir, "osa-events.jsonl", [
        %{"type" => "tool_call", "phase" => "start", "name" => "file_read"},
        %{
          "type" => "tool_result",
          "name" => "file_read",
          "result" => "def handle(x) do\n  # Error handling lives here\nend"
        }
      ])

      %{"c" => counts} = Audit.census([{"c", dir}])

      assert counts["file_read"].fail == 0
      assert counts["file_read"].ok == 1
    end
  end

  describe "census/1 metadata" do
    test "sessions counts transcripts with at least one call, not all files", %{dir: dir} do
      write(dir, "empty.updates.jsonl", [%{"msg" => %{"role" => "user", "content" => "hi"}}])

      write(dir, "used.updates.jsonl", [
        %{"msg" => %{"role" => "assistant", "tool_calls" => [%{"name" => "dir_list"}]}}
      ])

      %{"c" => counts} = Audit.census([{"c", dir}])

      assert counts.__meta__.files == 2
      assert counts.__meta__.sessions == 1
    end

    test "a corrupt line is skipped rather than taking the walk down", %{dir: dir} do
      path = Path.join(dir, "bad.updates.jsonl")

      File.write!(path, """
      {"msg":{"role":"assistant","tool_calls":[{"name":"git"}]}}
      {not json at all
      """)

      %{"c" => counts} = Audit.census([{"c", dir}])

      assert counts["git"].calls == 1
    end
  end

  describe "cut pricing" do
    test "a cut costs exactly the sum of its parts" do
      active = OptimalSystemAgent.Tools.Registry.list_active()
      [a, b | _] = Enum.map(active, & &1.name)

      individually = Audit.removal_cost(active, a).bytes + Audit.removal_cost(active, b).bytes
      together = Audit.cut_cost(active, [a, b]).bytes

      # An n-element array carries n-1 separators, so one removal drops one
      # element and one separator and two removals drop two of each. An earlier
      # draft of `cut_cost/2`'s docstring claimed the joint cut was strictly
      # larger; this assertion is what disproved it. Pinned so that a change to
      # how the array is serialized cannot make the two silently diverge.
      assert together == individually
      assert Audit.cut_cost(active, [a, b]).remaining == length(active) - 2
    end

    test "removal cost is zero for a tool that is not in the array" do
      active = OptimalSystemAgent.Tools.Registry.list_active()
      assert Audit.removal_cost(active, "no_such_tool_at_all") == %{bytes: 0, tokens: 0}
    end
  end

  describe "reachability" do
    test "every registered tool can be resolved by name" do
      # A withheld tool is uncallable under a native-tool provider until
      # `ToolDiscovery.widen/2` appends what `tool_search` resolved. If a name
      # stops resolving, that tool silently becomes unreachable rather than
      # merely undocumented, and no test elsewhere would notice.
      unreachable =
        OptimalSystemAgent.Tools.Registry.list_tools_direct()
        |> Enum.map(& &1.name)
        |> Enum.reject(&Audit.reachable?/1)

      assert unreachable == []
    end
  end

  describe "phantoms/1" do
    test "names no registered tool answers to are reported with their counts", %{dir: dir} do
      write(dir, "osa-events.jsonl", [
        %{"type" => "tool_call", "phase" => "start", "name" => "bash"},
        %{"type" => "tool_call", "phase" => "start", "name" => "bash"},
        %{"type" => "tool_call", "phase" => "start", "name" => "file_read"}
      ])

      phantoms = dir |> then(&Audit.census([{"c", &1}])) |> Audit.phantoms()

      assert {"bash", 2} in phantoms
      refute Enum.any?(phantoms, fn {n, _} -> n == "file_read" end)
    end
  end
end
