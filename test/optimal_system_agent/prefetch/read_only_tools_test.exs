defmodule OptimalSystemAgent.Prefetch.ReadOnlyToolsTest do
  @moduledoc """
  This module's whole reason to exist is "never open a permission dialog for
  a call nobody made" — so the negative cases (deny, ask-shaped, unsupported)
  matter at least as much as the happy path.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Prefetch.ReadOnlyTools

  @moduletag :tmp_dir

  describe "supported?/1" do
    test "the two whitelisted tools are supported" do
      assert ReadOnlyTools.supported?("file_read")
      assert ReadOnlyTools.supported?("dir_list")
    end

    test "shell_execute is deliberately NOT supported" do
      # `Prefetch.Cache` can only prove a hit is fresh when it watches a
      # single stat-able path; a shell command's output does not fit that
      # shape, so this module never runs one at all — see the moduledoc.
      refute ReadOnlyTools.supported?("shell_execute")
    end

    test "anything else is not, including write tools" do
      refute ReadOnlyTools.supported?("file_edit")
      refute ReadOnlyTools.supported?("nonexistent_tool")
    end
  end

  describe "run/3 — file_read" do
    test "reads an allowed file back", %{tmp_dir: dir} do
      path = Path.join(dir, "a.ex")
      File.write!(path, "defmodule A do\nend\n")

      assert {:ok, body} = ReadOnlyTools.run("file_read", %{"path" => path}, "test-session")
      assert body =~ "defmodule A"
    end

    test "denies a sensitive path instead of running it" do
      sensitive = Path.expand("~/.osa/subscriptions.json")
      assert :skip = ReadOnlyTools.run("file_read", %{"path" => sensitive}, "test-session")
    end

    test "skips a nonexistent file rather than raising", %{tmp_dir: dir} do
      path = Path.join(dir, "does_not_exist.ex")
      assert :skip = ReadOnlyTools.run("file_read", %{"path" => path}, "test-session")
    end
  end

  describe "run/3 — dir_list" do
    test "lists an allowed directory", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "one.txt"), "x")
      assert {:ok, body} = ReadOnlyTools.run("dir_list", %{"path" => dir}, "test-session")
      assert body =~ "one.txt"
    end
  end

  test "shell_execute is never dispatched, not even for an obviously read-only command" do
    assert :skip =
             ReadOnlyTools.run("shell_execute", %{"command" => "pwd"}, "test-session")
  end

  test "an unsupported tool name is skipped, never dispatched" do
    assert :skip = ReadOnlyTools.run("file_edit", %{"path" => "/tmp/x"}, "test-session")
  end
end
