defmodule OptimalSystemAgent.FrozenHomeRuntimeTest do
  @moduledoc """
  Regression guard for the "frozen home directory" install bug.

  Several modules used to bake `Path.expand("~/.osa/...")` into a COMPILE-time
  module attribute. In a prebuilt release (compiled on a CI runner) that froze
  the runner's home into the binary, so a prebuilt install on another machine
  wrote to a non-existent path and appeared dead.

  The fix resolves the home at RUNTIME via
  `OptimalSystemAgent.ConfigFile.config_dir/0`. This test proves it: with the
  runtime `:config_dir` pointed at a throwaway directory, every affected module
  must resolve its storage UNDER that override, not under the compiled-in path.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.PlanStore
  alias OptimalSystemAgent.Agent.ProgressLedger
  alias OptimalSystemAgent.Agent.SessionPersistence
  alias OptimalSystemAgent.Agent.Loop.ToolResultStorage
  alias OptimalSystemAgent.Channels.Manager
  alias OptimalSystemAgent.ConfigFile
  alias OptimalSystemAgent.Settings

  setup do
    override =
      Path.join(
        System.tmp_dir!(),
        "osa-home-probe-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(override)

    prev = Application.get_env(:optimal_system_agent, :config_dir)
    Application.put_env(:optimal_system_agent, :config_dir, override)

    on_exit(fn ->
      if prev == nil do
        Application.delete_env(:optimal_system_agent, :config_dir)
      else
        Application.put_env(:optimal_system_agent, :config_dir, prev)
      end

      # Don't let the manager's cached config leak into other tests.
      :persistent_term.erase({Manager, :config_cache})
      File.rm_rf(override)
    end)

    %{override: override}
  end

  test "ConfigFile.config_dir/0 reflects the runtime override", %{override: override} do
    assert ConfigFile.config_dir() == Path.expand(override)
  end

  test "SessionPersistence writes under the runtime-resolved home", %{override: override} do
    assert :ok = SessionPersistence.save("probe_sess", [%{"role" => "user", "content" => "hi"}])

    expected = Path.join([override, "sessions", "probe_sess.json"])
    assert File.exists?(expected), "expected session JSON at #{expected}"
  end

  test "PlanStore resolves and writes plan files under the override", %{override: override} do
    assert PlanStore.plan_file_path("probe") == Path.join([override, "sessions", "probe.plan.md"])

    assert :ok = PlanStore.write_plan_file("probe", "the plan")
    assert File.exists?(Path.join([override, "sessions", "probe.plan.md"]))
  end

  test "ProgressLedger resolves its path under the override", %{override: override} do
    assert ProgressLedger.path("probe") ==
             Path.join([override, "sessions", "probe.progress.md"])
  end

  test "ToolResultStorage offloads large results under the override", %{override: override} do
    big = String.duplicate("x\n", 60_000)
    result = ToolResultStorage.apply_budget(big, "grep_search", "call-1", "sess-1")

    results_dir = Path.join(override, "tool-results")
    assert String.contains?(result, results_dir), "reference note should point under #{results_dir}"
    assert Path.wildcard(Path.join(results_dir, "*.txt")) != []
  end

  test "Channels.Manager reads config.json from the runtime-resolved home", %{override: override} do
    :persistent_term.erase({Manager, :config_cache})

    File.write!(
      Path.join(override, "config.json"),
      Jason.encode!(%{"channels" => %{"telegram" => %{"token" => "fake"}}})
    )

    assert {:ok, %{configured: true}} = Manager.channel_status(:telegram)
  end

  test "Settings resolves the user settings file under the override", %{override: override} do
    assert List.first(Settings.source_paths()) == Path.join(override, "settings.json")
  end
end
