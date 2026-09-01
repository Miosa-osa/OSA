defmodule OptimalSystemAgent.SettingsCascadeTest do
  # Changes the process cwd (project/local settings paths derive from File.cwd!)
  # — must not run concurrently with other tests.
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Settings

  setup do
    # PathCanon FIRST: the BEAM resolves `/var/folders/...` to the physical
    # `/private/var/...`, so a trust grant pinned to the raw `System.tmp_dir!()`
    # spelling never matches the cwd the settings layer resolves — the gate
    # then withholds the fixture's own hooks. (Same root cause the
    # file_read_diagnostics and symlink suites fixed.)
    tmp =
      System.tmp_dir!()
      |> OptimalSystemAgent.Agent.Safety.PathCanon.canonicalize()
      |> Path.join("osa_settings_t#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(tmp, ".osa"))
    old_cwd = File.cwd!()
    File.cd!(tmp)
    # Settings paths resolve via Workspace.Cwd (not File.cwd!/0); point it at the
    # temp project so the cascade reads .osa/settings*.json from `tmp`.
    OptimalSystemAgent.Workspace.Cwd.put_process_override(tmp)

    on_exit(fn ->
      OptimalSystemAgent.Workspace.Cwd.clear_process_override()
      File.cd!(old_cwd)
      File.rm_rf!(tmp)
    end)

    :ok
  end

  test "explicit false in a layer is honored (no falsy fallthrough)" do
    File.write!(".osa/settings.json", ~s({"osa_test_flag": false}))
    assert Settings.get(:osa_test_flag, true) == false
  end

  test "explicit null in a layer is honored" do
    File.write!(".osa/settings.json", ~s({"osa_test_theme": null}))
    assert Settings.get(:osa_test_theme, "dark") == nil
  end

  test "missing key falls through to the default" do
    assert Settings.get(:osa_definitely_missing_key, :fallback) == :fallback
  end

  test "local layer falsy value overrides project layer" do
    File.write!(".osa/settings.json", ~s({"osa_test_verbose": true}))
    File.write!(".osa/settings.local.json", ~s({"osa_test_verbose": false}))
    assert Settings.get(:osa_test_verbose, true) == false
  end

  test "set_project refuses to overwrite a corrupt settings file" do
    File.write!(".osa/settings.json", "{not json!!")
    assert Settings.set_project(:foo, 1) == {:error, :corrupt_settings_file}
    assert File.read!(".osa/settings.json") == "{not json!!"
  end

  test "set_project treats a missing file as a fresh start" do
    assert Settings.set_project(:osa_fresh_key, 42) == :ok
    assert Settings.get(:osa_fresh_key) == 42
  end

  test "get_merged_hooks concatenates hook lists across layers (trusted workspace)" do
    alias OptimalSystemAgent.Workspace.Trust
    cwd = File.cwd!()
    old_home = System.get_env("OSA_HOME")
    # Redirect the trust store into the tmp workspace so no real ~/.osa state
    # is read or written, then accept trust for this directory.
    System.put_env("OSA_HOME", cwd)

    on_exit(fn ->
      Trust.forget(cwd)

      if old_home,
        do: System.put_env("OSA_HOME", old_home),
        else: System.delete_env("OSA_HOME")
    end)

    project_hook = %{"type" => "shell", "command" => "echo project"}
    local_hook = %{"type" => "shell", "command" => "echo local"}

    File.write!(
      ".osa/settings.json",
      Jason.encode!(%{"hooks" => %{"post_tool_use" => [project_hook]}})
    )

    File.write!(
      ".osa/settings.local.json",
      Jason.encode!(%{"hooks" => %{"post_tool_use" => [local_hook]}})
    )

    # Trust is accepted AFTER the config exists: the grant is pinned to the
    # config the user is looking at when they accept it, so accepting first and
    # adding hooks afterwards would (correctly) re-prompt.
    Trust.accept(cwd)

    hooks = Settings.get_merged_hooks() |> Map.get("post_tool_use", [])
    assert project_hook in hooks
    assert local_hook in hooks
  end

  test "get_merged_hooks keeps ALL workspace hooks inert in an UNTRUSTED workspace" do
    alias OptimalSystemAgent.Workspace.Trust
    cwd = File.cwd!()
    old_home = System.get_env("OSA_HOME")
    # Empty trust store inside the tmp workspace → this directory is untrusted.
    System.put_env("OSA_HOME", cwd)

    on_exit(fn ->
      Trust.forget(cwd)

      if old_home,
        do: System.put_env("OSA_HOME", old_home),
        else: System.delete_env("OSA_HOME")
    end)

    project_hook = %{"type" => "shell", "command" => "echo project"}
    local_hook = %{"type" => "shell", "command" => "echo local"}

    File.write!(
      ".osa/settings.json",
      Jason.encode!(%{"hooks" => %{"post_tool_use" => [project_hook]}})
    )

    File.write!(
      ".osa/settings.local.json",
      Jason.encode!(%{"hooks" => %{"post_tool_use" => [local_hook]}})
    )

    hooks = Settings.get_merged_hooks() |> Map.get("post_tool_use", [])
    refute project_hook in hooks

    # `.osa/settings.local.json` lives in the workspace exactly like
    # `.osa/settings.json` does. This assertion used to be `assert` — it
    # codified the bypass: a hostile repo only had to put its hook in the
    # `.local` file to have it fire in an untrusted workspace. `.gitignore`
    # is advisory and the attacker authors the repo.
    refute local_hook in hooks
  end
end
