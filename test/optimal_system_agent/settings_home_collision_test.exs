defmodule OptimalSystemAgent.SettingsHomeCollisionTest do
  @moduledoc """
  The home-directory collision: `~/.osa/settings.json` read as a "project" file.

  A session launched from the user's home directory (or any process whose
  `Workspace.Cwd.get/0` resolves there) makes `<cwd>/.osa/settings.json` and
  `~/.osa/settings.json` THE SAME FILE on disk — the `:project` layer and the
  `:user` layer are two reads of one path. `Settings.trusted_layer/1` used to
  classify purely by layer NAME, so it gated that read behind
  `project_trusted?/0` and logged "this workspace has not been trusted yet"
  about the operator's own machine-authored settings file — a false claim,
  since nothing here was cloned.

  `Workspace.ProjectResource.machine_authored?/1` is the already-correct,
  already-used-everywhere-else answer to "is this path actually the user's
  own, or something a checked-out repository supplied". `trusted_layer/1` now
  consults it before gating a `:project`/`:local` read, so this exact
  collision applies its content (redundantly with `:user`, which already
  applied it unconditionally) and stops printing a misleading warning.

  The negative case matters just as much: a GENUINELY workspace-supplied file
  (a real clone, not `~/.osa`) must still be withheld until trust is
  accepted — this is a security gate, and the fix must not widen it.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Settings
  alias OptimalSystemAgent.Workspace.Cwd
  alias OptimalSystemAgent.Workspace.Trust

  setup do
    prev_config_dir = Application.get_env(:optimal_system_agent, :config_dir)
    prev_osa_home = System.get_env("OSA_HOME")

    on_exit(fn ->
      Cwd.clear_process_override()

      if prev_config_dir,
        do: Application.put_env(:optimal_system_agent, :config_dir, prev_config_dir),
        else: Application.delete_env(:optimal_system_agent, :config_dir)

      if prev_osa_home,
        do: System.put_env("OSA_HOME", prev_osa_home),
        else: System.delete_env("OSA_HOME")

      Settings.reset_cache()
    end)

    :ok
  end

  describe "cwd IS the config dir's parent (machine-authored collision)" do
    # Mirrors the real shape exactly: a session launched from `~` (cwd) reads
    # `<cwd>/.osa/settings.json` as its "project" layer, which is the SAME
    # file as `~/.osa/settings.json` (the "user" layer, `config_dir/settings`).
    # `parent` stands in for `~`; `config_dir` stands in for `~/.osa`.
    setup do
      parent =
        Path.join(System.tmp_dir!(), "osa-home-collision-#{System.unique_integer([:positive])}")

      config_dir = Path.join(parent, ".osa")
      File.mkdir_p!(config_dir)
      Application.put_env(:optimal_system_agent, :config_dir, config_dir)
      # `Workspace.ProjectResource.machine_authored?/1` classifies by
      # `System.get_env("OSA_HOME")` (a real env var), not by the
      # `:config_dir` app env `Settings.user_settings/0` reads — both must
      # agree with `config_dir` for this fixture to actually reproduce "cwd is
      # the operator's own home" rather than an ordinary tmp workspace.
      System.put_env("OSA_HOME", config_dir)
      Cwd.put_process_override(parent)
      Trust.forget(parent)
      Settings.reset_cache()

      on_exit(fn ->
        Trust.forget(parent)
        File.rm_rf(parent)
      end)

      {:ok, config_dir: config_dir}
    end

    test "the settings file applies without /trust accept", %{config_dir: config_dir} do
      File.write!(
        Path.join(config_dir, "settings.json"),
        Jason.encode!(%{"lean_system_prompt" => true, "permission_mode" => "overdrive"})
      )

      Settings.reset_cache()

      refute Settings.project_trusted?(), "fixture must exercise the UNTRUSTED path"

      assert Settings.trusted_layer(:project)["lean_system_prompt"] == true
      assert Settings.get_trusted("lean_system_prompt") == true
      assert Settings.get_trusted("permission_mode") == "overdrive"
    end

    test "no WITHHOLDING warning is printed for the operator's own file", %{
      config_dir: config_dir
    } do
      File.write!(
        Path.join(config_dir, "settings.json"),
        Jason.encode!(%{"lean_system_prompt" => true})
      )

      Settings.reset_cache()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Settings.merged_trusted()
        end)

      refute log =~ "WITHHOLDING workspace settings",
             "the operator's own ~/.osa/settings.json was reported as an untrusted " <>
               "workspace file: #{log}"
    end
  end

  describe "cwd is a REAL workspace (not machine-authored) — the gate still holds" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "osa-real-workspace-#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(dir, ".osa"))
      Cwd.put_process_override(dir)
      Trust.forget(dir)
      Settings.reset_cache()

      on_exit(fn ->
        Trust.forget(dir)
        File.rm_rf(dir)
      end)

      {:ok, dir: dir}
    end

    test "a hostile clone's settings.json is still withheld", %{dir: dir} do
      File.write!(
        Path.join(dir, ".osa/settings.json"),
        Jason.encode!(%{"permission_mode" => "overdrive"})
      )

      Settings.reset_cache()

      refute Settings.project_trusted?()
      assert Settings.trusted_layer(:project) == %{}
      refute Settings.get_trusted("permission_mode") == "overdrive"
    end

    test "the WITHHOLDING warning still fires for a real untrusted workspace", %{dir: dir} do
      File.write!(
        Path.join(dir, ".osa/settings.json"),
        Jason.encode!(%{"permission_mode" => "overdrive"})
      )

      Settings.reset_cache()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Settings.merged_trusted()
        end)

      assert log =~ "WITHHOLDING workspace settings",
             "a genuinely untrusted, non-machine-authored workspace must still warn"
    end
  end
end
