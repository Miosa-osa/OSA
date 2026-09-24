defmodule OptimalSystemAgent.Tools.Builtins.ExpandOutputTest do
  @moduledoc """
  `expand_output` — the retrieval half of "summaries in context, full output
  on demand". Any tool result offloaded to `~/.osa/tool-results` (by
  `ToolResultStorage.apply_budget/4`, the tool-executor's spill-on-overflow,
  or the stale-tool-result clearing tier) can be expanded again by handle,
  with a line range or a grep pattern.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Tools.Builtins.ExpandOutput
  alias OptimalSystemAgent.Agent.Loop.ToolResultStorage

  setup do
    session = "expand-output-test-#{System.unique_integer([:positive])}"
    content = Enum.map_join(1..300, "\n", &"line #{&1}")
    {:ok, path} = ToolResultStorage.persist(content, "shell_execute", "call_eo", session)
    on_exit(fn -> ToolResultStorage.cleanup(session) end)
    {:ok, path: path, handle: Path.basename(path)}
  end

  describe "identity" do
    test "name is expand_output" do
      assert ExpandOutput.name() == "expand_output"
    end

    test "safety is read_only" do
      assert ExpandOutput.safety() == :read_only
    end

    test "requires a handle" do
      assert ExpandOutput.parameters()["required"] == ["handle"]
    end
  end

  describe "execute/1 — range mode" do
    test "returns a bounded slice by handle", %{handle: handle} do
      assert {:ok, out} = ExpandOutput.execute(%{"handle" => handle, "limit" => 5})
      assert out =~ "line 1"
      refute out =~ "line 6\n"
    end

    test "offset pages further into the file", %{handle: handle} do
      assert {:ok, out} =
               ExpandOutput.execute(%{"handle" => handle, "offset" => 200, "limit" => 3})

      assert out =~ "line 200"
      assert out =~ "line 202"
    end
  end

  describe "execute/1 — grep mode" do
    test "returns only matching lines with line numbers", %{handle: handle} do
      assert {:ok, out} = ExpandOutput.execute(%{"handle" => handle, "grep" => "line 250$"})
      assert out =~ "250: line 250"
    end
  end

  describe "execute/1 — safety" do
    test "rejects a handle that is not a string" do
      assert {:error, _} = ExpandOutput.execute(%{"handle" => 42})
    end

    test "rejects a missing handle" do
      assert {:error, _} = ExpandOutput.execute(%{})
    end

    test "rejects a handle that escapes the tool-results store" do
      assert {:error, reason} = ExpandOutput.execute(%{"handle" => "../../etc/passwd"})
      assert reason =~ "Refusing"
    end
  end
end
