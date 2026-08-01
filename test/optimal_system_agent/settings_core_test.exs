defmodule OptimalSystemAgent.SettingsCoreTest do
  # Changes the process cwd (project/local settings paths derive from File.cwd!)
  # — must not run concurrently with other tests.
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Settings
  alias OptimalSystemAgent.Settings.Schema

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_ws2_t#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, ".osa"))
    old_cwd = File.cwd!()
    old_original = OptimalSystemAgent.Workspace.Cwd.original_cwd()
    File.cd!(tmp)
    OptimalSystemAgent.Workspace.Cwd.put_process_override(tmp)
    # The settings watcher runs in its OWN process, so a process-dict override
    # won't reach it — set the global original cwd too (async: false makes this
    # safe) so the watcher resolves the settings path under `tmp`.
    OptimalSystemAgent.Workspace.Cwd.set_original_cwd(tmp)
    Settings.reset_cache()

    on_exit(fn ->
      OptimalSystemAgent.Workspace.Cwd.clear_process_override()
      OptimalSystemAgent.Workspace.Cwd.set_original_cwd(old_original)
      File.cd!(old_cwd)
      File.rm_rf!(tmp)
      Settings.reset_cache()
    end)

    :ok
  end

  test "nested maps deep-merge across layers; arrays concat + dedupe" do
    File.write!(
      ".osa/settings.json",
      Jason.encode!(%{
        "osa_ws2_ui" => %{"theme" => "dark", "cols" => 80},
        "osa_ws2_tags" => ["a", "b"]
      })
    )

    File.write!(
      ".osa/settings.local.json",
      Jason.encode!(%{"osa_ws2_ui" => %{"cols" => 120}, "osa_ws2_tags" => ["b", "c"]})
    )

    assert Settings.get(:osa_ws2_ui) == %{"theme" => "dark", "cols" => 120}
    assert Settings.get(:osa_ws2_tags) == ["a", "b", "c"]
  end

  test "--settings flag file is the highest-priority file layer" do
    File.write!(".osa/settings.local.json", ~s({"osa_ws2_flagged": "local"}))
    flag = Path.join(File.cwd!(), "flag.json")
    File.write!(flag, ~s({"osa_ws2_flagged": "flag"}))
    Application.put_env(:optimal_system_agent, :settings_flag_path, flag)
    on_exit(fn -> Application.delete_env(:optimal_system_agent, :settings_flag_path) end)

    assert Settings.get(:osa_ws2_flagged) == "flag"
  end

  test "internal writes invalidate the settings cache; delete-key semantics" do
    File.write!(".osa/settings.json", ~s({"osa_ws2_cached": 1}))
    assert Settings.get(:osa_ws2_cached) == 1
    assert Settings.set_project(:osa_ws2_cached, 2) == :ok
    assert Settings.get(:osa_ws2_cached) == 2
    assert Settings.delete_project(:osa_ws2_cached) == :ok
    assert Settings.get(:osa_ws2_cached, :gone) == :gone
  end

  test "apply_env_settings applies the merged env key to the OS environment" do
    tmp = File.cwd!()
    File.write!(".osa/settings.json", Jason.encode!(%{"env" => %{"OSA_WS2_ENV_TEST" => "yes"}}))
    on_exit(fn -> System.delete_env("OSA_WS2_ENV_TEST") end)

    # `env` in a CHECKED-IN project settings file is workspace-supplied
    # executable config (PATH, loader vars), so it is trust-gated like project
    # hooks and permission rules: withheld until the workspace is trusted.
    Settings.apply_env_settings()
    assert System.get_env("OSA_WS2_ENV_TEST") == nil

    OptimalSystemAgent.Workspace.Trust.accept(tmp)
    on_exit(fn -> OptimalSystemAgent.Workspace.Trust.forget(tmp) end)
    Settings.reset_cache()

    Settings.apply_env_settings()
    assert System.get_env("OSA_WS2_ENV_TEST") == "yes"
  end

  test "schema flags type errors with a fix tip; clean settings pass" do
    assert [%{key: "env", severity: :error, tip: tip}] = Schema.validate(%{"env" => "nope"})
    assert tip =~ "NAME"
    assert Schema.validate(%{"model" => "glm-4.7:cloud", "http_port" => 9089}) == []
  end

  test "schema reports JSON parse errors per file" do
    path = Path.join(File.cwd!(), ".osa/settings.json")
    File.write!(path, "{oops")
    assert [%{severity: :error, message: msg}] = Schema.validate_file(path)
    assert msg =~ "invalid JSON"
  end

  test "watcher fires settings_changed on external edit, suppresses internal writes" do
    Application.put_env(:optimal_system_agent, :settings_watcher_enabled, true)

    on_exit(fn ->
      Application.put_env(:optimal_system_agent, :settings_watcher_enabled, false)
    end)

    :ok = Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "command_center:events")
    start_supervised!({Settings.Watcher, poll_ms: 50})

    # Internal write → suppressed (no event)
    Settings.set_project(:osa_ws2_internal, 1)
    refute_receive {:command_center_event, %{type: "settings_changed"}}, 400

    # External edit (bypasses the Settings API) → fires within a couple polls
    File.write!(".osa/settings.local.json", ~s({"osa_ws2_external": 42}))
    assert_receive {:command_center_event, %{type: "settings_changed"}}, 3_000
    assert Settings.get(:osa_ws2_external) == 42
  end
end
