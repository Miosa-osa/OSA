defmodule OptimalSystemAgent.Agent.AtomicWriteCallSitesTest do
  @moduledoc """
  The nine hand-rolled `write tmp; rename tmp` copies across `agent/` all
  replaced symlinks with regular files and dropped the target's mode. These
  exercise the converted call sites through their real public APIs, so they
  fail against the pre-consolidation code rather than only against the helper.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.PlanStore
  alias OptimalSystemAgent.Agent.TaskBrief

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-callsites-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "sessions"))
    prev = Application.get_env(:optimal_system_agent, :config_dir)
    Application.put_env(:optimal_system_agent, :config_dir, dir)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:optimal_system_agent, :config_dir, prev),
        else: Application.delete_env(:optimal_system_agent, :config_dir)

      File.rm_rf(dir)
    end)

    {:ok, dir: dir, sessions: Path.join(dir, "sessions")}
  end

  describe "PlanStore.write_plan_file/2" do
    test "writes the plan", %{sessions: sessions} do
      assert :ok = PlanStore.write_plan_file("sess-plain", "# Plan\n- step one\n")
      path = Path.wildcard(Path.join(sessions, "sess-plain*")) |> List.first()
      assert path, "no plan file was created in #{sessions}"
      assert File.read!(path) =~ "step one"
    end

    test "writes THROUGH a symlinked plan file instead of replacing the link",
         %{dir: dir, sessions: sessions} do
      # Establish the real path the store uses, then replace it with a symlink
      # pointing somewhere else — the "config lives in my dotfiles repo" case.
      :ok = PlanStore.write_plan_file("sess-link", "original\n")
      path = Path.wildcard(Path.join(sessions, "sess-link*")) |> List.first()
      assert path

      real = Path.join(dir, "elsewhere_plan.md")
      File.write!(real, "original\n")
      File.rm!(path)
      :ok = File.ln_s(real, path)

      assert :ok = PlanStore.write_plan_file("sess-link", "rewritten\n")

      assert File.lstat!(path).type == :symlink,
             "PlanStore replaced the user's symlink with a regular file"

      assert File.read!(real) == "rewritten\n"
    end

    test "preserves the plan file's mode", %{sessions: sessions} do
      :ok = PlanStore.write_plan_file("sess-mode", "a\n")
      path = Path.wildcard(Path.join(sessions, "sess-mode*")) |> List.first()
      File.chmod!(path, 0o600)

      assert :ok = PlanStore.write_plan_file("sess-mode", "b\n")

      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
      assert File.read!(path) == "b\n"
    end

    test "leaves no temp litter", %{sessions: sessions} do
      :ok = PlanStore.write_plan_file("sess-clean", "x\n")
      refute Enum.any?(File.ls!(sessions), &String.contains?(&1, ".tmp"))
    end
  end

  describe "TaskBrief.save/2" do
    test "round-trips a brief", %{sessions: _} do
      assert :ok = TaskBrief.save("brief-plain", %{"goal" => "ship it"})
      assert File.read!(TaskBrief.path("brief-plain")) =~ "ship it"
    end

    test "writes THROUGH a symlinked brief file", %{dir: dir} do
      :ok = TaskBrief.save("brief-link", %{"goal" => "one"})
      path = TaskBrief.path("brief-link")

      real = Path.join(dir, "elsewhere_brief.json")
      File.write!(real, File.read!(path))
      File.rm!(path)
      :ok = File.ln_s(real, path)

      assert :ok = TaskBrief.save("brief-link", %{"goal" => "two"})

      assert File.lstat!(path).type == :symlink,
             "TaskBrief replaced the user's symlink with a regular file"

      assert File.read!(real) =~ "two"
    end

    test "preserves the brief file's mode" do
      :ok = TaskBrief.save("brief-mode", %{"goal" => "a"})
      path = TaskBrief.path("brief-mode")
      File.chmod!(path, 0o600)

      assert :ok = TaskBrief.save("brief-mode", %{"goal" => "b"})

      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    end

    test "leaves no temp litter", %{sessions: sessions} do
      :ok = TaskBrief.save("brief-clean", %{"goal" => "x"})
      refute Enum.any?(File.ls!(sessions), &String.contains?(&1, ".tmp"))
    end
  end
end
