defmodule OptimalSystemAgent.FSCheckpoint.HookTest do
  @moduledoc """
  Path extraction for the pre-tool-use checkpoint hook (findings 3 and 4).

  These assert on `Hook.extract_paths/2` directly, so nothing here starts a
  server or writes to the operator's real shadow repo.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.FSCheckpoint.{Config, Hook}

  setup do
    dir = Path.join(System.tmp_dir!(), "osa_hook_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "shell_execute is actually covered (finding 3)" do
    # Pre-fix, `extract_paths("shell_execute", _)` computed the destructive
    # check and then returned `[]` from BOTH branches of its `if`. Every
    # assertion in this block returned `[]` and so failed.
    test "rm -rf on an existing file yields that file", %{dir: dir} do
      file = Path.join(dir, "victim.txt")
      File.write!(file, "important\n")

      assert Hook.extract_paths("shell_execute", %{"command" => "rm -rf #{file}"}) == [file]
    end

    test "sed -i yields the edited file", %{dir: dir} do
      file = Path.join(dir, "config.ex")
      File.write!(file, "x\n")

      assert Hook.extract_paths("shell_execute", %{"command" => "sed -i s/a/b/ #{file}"}) ==
               [file]
    end

    test "mv yields both source and destination when both exist", %{dir: dir} do
      a = Path.join(dir, "a.txt")
      b = Path.join(dir, "b.txt")
      File.write!(a, "1\n")
      File.write!(b, "2\n")

      paths = Hook.extract_paths("shell_execute", %{"command" => "mv #{a} #{b}"})
      assert Enum.sort(paths) == Enum.sort([a, b])
    end

    test "a destructive command after && is still found", %{dir: dir} do
      file = Path.join(dir, "gone.txt")
      File.write!(file, "x\n")

      assert Hook.extract_paths("shell_execute", %{"command" => "cd /tmp && rm #{file}"}) ==
               [file]
    end

    test "quoted paths are unquoted", %{dir: dir} do
      file = Path.join(dir, "name.txt")
      File.write!(file, "x\n")

      assert Hook.extract_paths("shell_execute", %{"command" => ~s(rm "#{file}")}) == [file]
    end

    test "option flags are never treated as paths", %{dir: dir} do
      file = Path.join(dir, "f.txt")
      File.write!(file, "x\n")

      paths = Hook.extract_paths("shell_execute", %{"command" => "rm -rf --verbose #{file}"})
      assert paths == [file]
    end
  end

  describe "shell_execute does not over-collect" do
    test "a non-destructive command yields nothing", %{dir: dir} do
      file = Path.join(dir, "readme.txt")
      File.write!(file, "hello\n")

      assert Hook.extract_paths("shell_execute", %{"command" => "cat #{file}"}) == []
    end

    test "a word merely CONTAINING a utility name is not destructive", %{dir: dir} do
      # Pre-fix `String.contains?(command, "rm")` fired on "confirm" and
      # "cp" on "cpu" — the check was noise in both directions.
      file = Path.join(dir, "f.txt")
      File.write!(file, "x\n")

      assert Hook.extract_paths("shell_execute", %{"command" => "confirm #{file}"}) == []
      assert Hook.extract_paths("shell_execute", %{"command" => "cpupower #{file}"}) == []
    end

    test "paths that do not exist are not snapshotted" do
      assert Hook.extract_paths("shell_execute", %{"command" => "rm /nope/missing.txt"}) == []
    end

    test "a directory is not snapshotted", %{dir: dir} do
      assert Hook.extract_paths("shell_execute", %{"command" => "rm -rf #{dir}"}) == []
    end
  end

  describe "notebook_edit is checkpointed (finding 4)" do
    test "a notebook mutation yields the notebook", %{dir: dir} do
      # Pre-fix the guard clause listed only file_write/file_edit, so every
      # notebook edit — delete_cell included — was unrecoverable via /rollback.
      nb = Path.join(dir, "analysis.ipynb")
      File.write!(nb, ~s({"cells":[],"metadata":{},"nbformat":4,"nbformat_minor":5}))

      assert Hook.extract_paths("notebook_edit", %{"path" => nb, "action" => "delete_cell"}) ==
               [nb]
    end

    test "notebook_edit is listed among the destructive tools" do
      assert "notebook_edit" in Config.destructive_tools()
    end
  end

  describe "the tools that already worked still work" do
    test "file_edit yields its path", %{dir: dir} do
      file = Path.join(dir, "a.ex")
      File.write!(file, "x\n")
      assert Hook.extract_paths("file_edit", %{"path" => file}) == [file]
    end

    test "multi_file_edit yields every existing target", %{dir: dir} do
      a = Path.join(dir, "a.ex")
      b = Path.join(dir, "b.ex")
      File.write!(a, "x\n")
      File.write!(b, "y\n")

      edits = [%{"path" => a}, %{"path" => b}, %{"path" => Path.join(dir, "missing.ex")}]
      assert Hook.extract_paths("multi_file_edit", %{"edits" => edits}) == [a, b]
    end

    test "an unrelated tool yields nothing" do
      assert Hook.extract_paths("web_search", %{"query" => "rm -rf"}) == []
    end
  end

  describe "the hook never breaks the tool call" do
    test "returns {:ok, payload} for an unknown tool" do
      payload = %{tool_name: "web_search", arguments: %{"query" => "x"}}
      assert {:ok, ^payload} = Hook.pre_tool_use(payload)
    end

    test "returns {:ok, payload} for a malformed payload" do
      assert {:ok, %{}} = Hook.pre_tool_use(%{})
    end
  end
end
