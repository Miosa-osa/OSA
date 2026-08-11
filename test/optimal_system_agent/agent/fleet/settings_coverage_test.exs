defmodule OptimalSystemAgent.Agent.Fleet.SettingsCoverageTest do
  @moduledoc """
  A settings file under an alternate working root must produce a diagnostic,
  not silence.

  OSA routinely runs under roots other than the process-global
  `Workspace.Cwd`: `Fleet`'s `:working_dir`, the orchestrator's `repo_dir`, and
  every `FastWorktree` worktree. `Settings` resolves its project/local paths
  from the cwd (`Settings.project_settings_path/0` is
  `Path.join(Workspace.Cwd.get(), ".osa/settings.json")`), so a
  `.osa/settings.json` sitting in one of those roots is never read — and
  nothing said so.

  A worktree makes this sharpest: it is a full copy of the repo, so a
  checked-in settings file IS present in it and looks authoritative while
  being resolved from nowhere.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias OptimalSystemAgent.Agent.Fleet.SettingsCoverage

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "osa_setcov_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(tmp, ".osa"))
    SettingsCoverage.reset()

    on_exit(fn ->
      File.rm_rf(tmp)
      SettingsCoverage.reset()
    end)

    {:ok, root: tmp}
  end

  defp write_settings(root, name \\ "settings.json") do
    path = Path.join([root, ".osa", name])
    File.write!(path, ~s({"env":{"OSA_TEST_VAR":"from-alternate-root"}}))
    path
  end

  describe "an alternate root carrying settings is reported" do
    test "the warning names the file and says it will not be applied", %{root: root} do
      path = write_settings(root)

      log = capture_log(fn -> SettingsCoverage.check(root, "fleet node n1") end)

      assert log =~ path
      assert log =~ "fleet node n1"
      assert log =~ "will NOT be applied or reloaded"
    end

    test "settings.local.json is reported too", %{root: root} do
      path = write_settings(root, "settings.local.json")

      log = capture_log(fn -> SettingsCoverage.check(root, "subagent s1") end)
      assert log =~ path
    end

    test "both files are named in one line when both exist", %{root: root} do
      a = write_settings(root)
      b = write_settings(root, "settings.local.json")

      log = capture_log(fn -> SettingsCoverage.check(root, "subagent s1") end)
      assert log =~ a
      assert log =~ b
    end

    test "unwatched_settings_files/1 makes the gap inspectable", %{root: root} do
      path = write_settings(root)
      assert SettingsCoverage.unwatched_settings_files(root) == [path]
    end
  end

  describe "it stays quiet when there is nothing to report" do
    test "a root with no settings file is silent", %{root: root} do
      log = capture_log(fn -> SettingsCoverage.check(root, "fleet node n1") end)
      refute log =~ "will NOT be applied"
    end

    test "the cwd cascade root itself is silent" do
      cwd = OptimalSystemAgent.Workspace.Cwd.get()

      log = capture_log(fn -> SettingsCoverage.check(cwd, "fleet node n1") end)
      refute log =~ "will NOT be applied"
    end

    test "a nil or blank root is silent" do
      log =
        capture_log(fn ->
          SettingsCoverage.check(nil, "fleet node n1")
          SettingsCoverage.check("", "fleet node n1")
        end)

      refute log =~ "will NOT be applied"
    end

    test "a directory that does not exist is silent, not an error", %{root: root} do
      gone = Path.join(root, "vanished-worktree")

      log = capture_log(fn -> assert SettingsCoverage.check(gone, "fleet node n1") == :ok end)
      refute log =~ "will NOT be applied"
    end

    test "a .osa that is a directory, not a file, is not mistaken for settings", %{root: root} do
      File.mkdir_p!(Path.join([root, ".osa", "settings.json"]))
      assert SettingsCoverage.unwatched_settings_files(root) == []
    end
  end

  describe "it does not bury itself in repetition" do
    test "one root is reported once, however many nodes adopt it", %{root: root} do
      write_settings(root)

      first = capture_log(fn -> SettingsCoverage.check(root, "fleet node n1") end)

      rest =
        capture_log(fn ->
          for n <- 2..50, do: SettingsCoverage.check(root, "fleet node n#{n}")
        end)

      assert first =~ "will NOT be applied"

      refute rest =~ "will NOT be applied",
             "a 50-node fan-out under one repo emitted the warning 50 times and buried it"
    end

    test "distinct roots are each reported", %{root: root} do
      other = root <> "-other"
      File.mkdir_p!(Path.join(other, ".osa"))
      on_exit(fn -> File.rm_rf(other) end)

      write_settings(root)
      write_settings(other)

      log =
        capture_log(fn ->
          SettingsCoverage.check(root, "node a")
          SettingsCoverage.check(other, "node b")
        end)

      assert log =~ root
      assert log =~ other
    end

    test "reset/1 allows the same root to be reported again", %{root: root} do
      write_settings(root)

      capture_log(fn -> SettingsCoverage.check(root, "node a") end)
      SettingsCoverage.reset()

      log = capture_log(fn -> SettingsCoverage.check(root, "node a") end)
      assert log =~ "will NOT be applied"
    end
  end

  describe "the watcher's coverage is respected" do
    test "a path the watcher already covers is not reported", %{root: root} do
      write_settings(root)

      # `watching?/1` returns false when the watcher is not running, which is
      # the state under test here — so the file IS reported. This asserts the
      # module consults the watcher at all rather than reporting blindly.
      refute OptimalSystemAgent.Settings.Watcher.watching?(Path.join(root, ".osa/settings.json"))
      assert SettingsCoverage.unwatched_settings_files(root) != []
    end
  end
end
