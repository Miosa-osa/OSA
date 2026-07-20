defmodule OptimalSystemAgent.ScratchpadTest do
  @moduledoc """
  Unit tests for the file-based shared scratchpad.

  A tmp `:config_dir` override keeps every test rooted in a throwaway
  directory — nothing here ever touches the real `~/.osa`.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.ConfigFile
  alias OptimalSystemAgent.Scratchpad
  alias OptimalSystemAgent.Agent.RunStore

  setup do
    prev_dir = Application.get_env(:optimal_system_agent, :config_dir)
    prev_boot = Application.get_env(:optimal_system_agent, :bootstrap_dir)

    tmp = Path.join(System.tmp_dir!(), "osa_scratchpad_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:optimal_system_agent, :config_dir, tmp)
    Application.delete_env(:optimal_system_agent, :bootstrap_dir)
    ConfigFile.reload()

    on_exit(fn ->
      restore(:config_dir, prev_dir)
      restore(:bootstrap_dir, prev_boot)
      ConfigFile.reload()
      File.rm_rf(tmp)
    end)

    {:ok, tmp: tmp}
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, v), do: Application.put_env(:optimal_system_agent, key, v)

  describe "directory resolution" do
    test "dir_for is rooted at config_dir/scratchpad and resolved at runtime", %{tmp: tmp} do
      dir = Scratchpad.dir_for("sess-a")
      assert dir == Path.join([tmp, "scratchpad", "sess-a"])
    end

    test "a crafted id cannot escape the scratchpad root" do
      dir = Scratchpad.dir_for("../../etc")
      root = Scratchpad.root_dir()
      assert String.starts_with?(dir, root <> "/")
      refute String.contains?(dir, "..")
    end
  end

  describe "write / read / append" do
    test "write then read round-trips" do
      assert {:ok, _path} = Scratchpad.write("s1", "findings.md", "hello")
      assert {:ok, "hello"} = Scratchpad.read("s1", "findings.md")
    end

    test "append accumulates" do
      assert {:ok, _} = Scratchpad.write("s1", "log.md", "a")
      assert {:ok, _} = Scratchpad.append("s1", "log.md", "b")
      assert {:ok, _} = Scratchpad.append("s1", "log.md", "c")
      assert {:ok, "abc"} = Scratchpad.read("s1", "log.md")
    end

    test "append to a missing entry creates it" do
      assert {:ok, _} = Scratchpad.append("s1", "new.md", "x")
      assert {:ok, "x"} = Scratchpad.read("s1", "new.md")
    end

    test "reading a missing entry returns :not_found" do
      assert {:error, :not_found} = Scratchpad.read("s1", "nope.md")
    end
  end

  describe "list" do
    test "list shows entries with sizes, newest first" do
      assert {:ok, _} = Scratchpad.write("s1", "a.md", "12345")
      assert {:ok, _} = Scratchpad.write("s1", "b.md", "1")

      entries = Scratchpad.list("s1")
      names = Enum.map(entries, & &1.name)
      assert "a.md" in names
      assert "b.md" in names

      a = Enum.find(entries, &(&1.name == "a.md"))
      assert a.size == 5
    end

    test "the internal index log is not listed as an entry" do
      assert {:ok, _} = Scratchpad.write("s1", "a.md", "x")
      refute "INDEX.log" in Enum.map(Scratchpad.list("s1"), & &1.name)
    end

    test "a fresh session starts empty" do
      assert Scratchpad.list("brand-new-session") == []
    end
  end

  describe "delete" do
    test "delete removes an entry" do
      assert {:ok, _} = Scratchpad.write("s1", "a.md", "x")
      assert :ok = Scratchpad.delete("s1", "a.md")
      assert {:error, :not_found} = Scratchpad.read("s1", "a.md")
    end

    test "deleting a missing entry is still :ok" do
      assert :ok = Scratchpad.delete("s1", "ghost.md")
    end
  end

  describe "path safety" do
    test "a '..' path segment is rejected" do
      assert {:error, reason} = Scratchpad.write("s1", "../escape.md", "x")
      assert reason =~ ".."
      # And nothing was written outside the dir.
      refute File.exists?(Path.join(Scratchpad.root_dir(), "escape.md"))
    end

    test "a nested '..' traversal is rejected" do
      assert {:error, _} = Scratchpad.write("s1", "sub/../../escape.md", "x")
    end

    test "an absolute path is rejected" do
      assert {:error, reason} = Scratchpad.write("s1", "/etc/passwd", "x")
      assert reason =~ "absolute"
    end

    test "a '~' path is rejected" do
      assert {:error, _} = Scratchpad.write("s1", "~/secret", "x")
    end

    test "a blank name is rejected" do
      assert {:error, _} = Scratchpad.write("s1", "   ", "x")
    end

    test "a legitimate nested subdir is allowed" do
      assert {:ok, _} = Scratchpad.write("s1", "sub/dir/note.md", "ok")
      assert {:ok, "ok"} = Scratchpad.read("s1", "sub/dir/note.md")
    end
  end

  describe "sharing and isolation" do
    test "two agents with the same id see each other's entries" do
      # Agent A writes under coordination id "shared".
      assert {:ok, _} = Scratchpad.write("shared", "from-a.md", "A was here")
      # Agent B, same id, reads it.
      assert {:ok, "A was here"} = Scratchpad.read("shared", "from-a.md")
    end

    test "different sessions are isolated" do
      assert {:ok, _} = Scratchpad.write("sess-x", "note.md", "x-only")
      assert {:error, :not_found} = Scratchpad.read("sess-y", "note.md")
    end
  end

  describe "session_root (shared coordination id)" do
    test "a top-level session with no parent resolves to itself" do
      assert Scratchpad.session_root("top-level-#{System.unique_integer([:positive])}") =~
               "top-level-"
    end

    test "a worker resolves to its root ancestor via the RunStore chain" do
      root = "root-#{System.unique_integer([:positive])}"
      child = "agent:#{root}:1"
      grandchild = "agent:#{child}:1"

      RunStore.start_run(%{agent_id: child, parent_session_id: root, role: "worker", task: "t"})

      RunStore.start_run(%{
        agent_id: grandchild,
        parent_session_id: child,
        role: "worker",
        task: "t"
      })

      # Both descendants resolve to the same root, hence the same directory.
      assert Scratchpad.session_root(child) == root
      assert Scratchpad.session_root(grandchild) == root
      assert Scratchpad.dir_for(Scratchpad.session_root(grandchild)) == Scratchpad.dir_for(root)
    end
  end
end
