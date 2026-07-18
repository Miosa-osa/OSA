defmodule OptimalSystemAgent.SettingsCascadeTest do
  # Changes the process cwd (project/local settings paths derive from File.cwd!)
  # — must not run concurrently with other tests.
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Settings

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_settings_t#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, ".osa"))
    old_cwd = File.cwd!()
    File.cd!(tmp)

    on_exit(fn ->
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

    Trust.accept(cwd)

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
    assert project_hook in hooks
    assert local_hook in hooks
  end

  test "get_merged_hooks keeps project hooks inert in an UNTRUSTED workspace" do
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
    assert local_hook in hooks
  end
end
