defmodule OptimalSystemAgent.SettingsBomTest do
  @moduledoc """
  A UTF-8 BOM used to silently disable the user's ENTIRE settings file.

  `Jason` has no BOM handling, so `{"permissions": …}` written by a Windows
  editor failed to decode, and `parse_json_file/1` turned that into `%{}` —
  the whole cascade layer vanished. That fails OPEN: the user's `deny` rules
  and their chosen `permission_mode` disappeared without a word, leaving the
  agent MORE permissive than configured.
  """
  # Changes the process cwd (project/local settings paths derive from it).
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Settings

  @bom "﻿"

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_bom_t#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, ".osa"))
    old_cwd = File.cwd!()
    old_original = OptimalSystemAgent.Workspace.Cwd.original_cwd()
    File.cd!(tmp)
    OptimalSystemAgent.Workspace.Cwd.put_process_override(tmp)
    OptimalSystemAgent.Workspace.Cwd.set_original_cwd(tmp)
    Settings.reset_cache()

    on_exit(fn ->
      OptimalSystemAgent.Workspace.Cwd.clear_process_override()
      OptimalSystemAgent.Workspace.Cwd.set_original_cwd(old_original)
      File.cd!(old_cwd)
      File.rm_rf!(tmp)
      Settings.reset_cache()
    end)

    {:ok, tmp: tmp}
  end

  describe "BOM tolerance" do
    test "a BOM'd settings file still delivers its permission rules and mode" do
      File.write!(
        ".osa/settings.local.json",
        @bom <>
          Jason.encode!(%{
            "permissions" => %{"deny" => ["shell_execute(rm:*)"]},
            "permission_mode" => "plan",
            "osa_bom_marker" => "present"
          })
      )

      Settings.reset_cache()

      assert Settings.get("osa_bom_marker") == "present",
             "a leading UTF-8 BOM wiped the entire settings layer"

      assert Settings.get("permissions") == %{"deny" => ["shell_execute(rm:*)"]}
      assert Settings.get("permission_mode") == "plan"
    end

    test "a BOM'd file is not treated as corrupt on the write path" do
      File.write!(".osa/settings.json", @bom <> ~s({"osa_bom_existing": 1}))
      Settings.reset_cache()

      assert :ok = Settings.set_project("osa_bom_added", 2)
      Settings.reset_cache()

      assert Settings.get("osa_bom_existing") == 1
      assert Settings.get("osa_bom_added") == 2
    end
  end

  describe "an unparseable settings file fails CLOSED" do
    test "genuinely broken JSON is reported, not silently read as no restrictions" do
      File.write!(".osa/settings.local.json", ~s({"permissions": {"deny": ["x"]},,,))
      Settings.reset_cache()

      assert Settings.unparseable_sources() != [],
             "an existing-but-unparseable settings file was silently read as empty"

      # The deny rules cannot be recovered, so nothing may run unprompted while
      # they are missing.
      assert Settings.get("permission_mode") == "ask"
    end

    test "a permissive permission_mode in another layer cannot survive an unparseable layer" do
      File.write!(".osa/settings.json", Jason.encode!(%{"permission_mode" => "overdrive"}))
      File.write!(".osa/settings.local.json", "{ not json at all")
      Settings.reset_cache()

      assert Settings.get("permission_mode") == "ask"
      assert Settings.get_trusted("permission_mode") == "ask"
    end

    test "a permissive permissions.defaultMode cannot survive an unparseable layer either",
         %{tmp: tmp} do
      # The CC spelling of the mode, not the legacy one — and it is the
      # spelling that WINS: `Permissions.default_mode/0` reads
      # `permissions.defaultMode` first and only falls back to the top-level
      # `permission_mode`. So the fail-closed pin above was inert for exactly
      # the users who followed the newer documentation: a corrupt layer took
      # their `deny` rules away and left `bypassPermissions` in force, running
      # every tool call unprompted with nothing bounding it.
      #
      # The permissive value lives in the FLAG layer on purpose. A workspace
      # `.osa/settings.json` is withheld from `merged_trusted/0` until the
      # workspace is trusted, which would make this pass for a reason that has
      # nothing to do with the pin.
      flag = Path.join(tmp, "flag-settings.json")
      prior_flag = Application.get_env(:optimal_system_agent, :settings_flag_path)
      Application.put_env(:optimal_system_agent, :settings_flag_path, flag)

      on_exit(fn ->
        case prior_flag do
          nil -> Application.delete_env(:optimal_system_agent, :settings_flag_path)
          p -> Application.put_env(:optimal_system_agent, :settings_flag_path, p)
        end

        Settings.reset_cache()
      end)

      File.write!(
        flag,
        Jason.encode!(%{"permissions" => %{"defaultMode" => "bypassPermissions"}})
      )

      File.write!(".osa/settings.local.json", "{ not json at all")
      Settings.reset_cache()

      assert Settings.unparseable_sources() != []
      assert OptimalSystemAgent.Permissions.default_mode() == :ask
    end

    test "`osa doctor` reports the pin instead of the value it overrides" do
      # `Inspection`'s "effective keys" section walks the RAW layers, so left to
      # itself it prints the `overdrive` the operator configured while
      # `merged/0` returns "ask". A diagnostic that disagrees with the runtime
      # about permissions is read as confirmation that the permissive value is
      # live, which is the worst possible direction for it to be wrong in.
      File.write!(".osa/settings.json", Jason.encode!(%{"permission_mode" => "overdrive"}))
      File.write!(".osa/settings.local.json", "{ not json at all")
      Settings.reset_cache()

      %{sections: sections} = OptimalSystemAgent.CLI.Doctor.Inspection.report()
      %{rows: rows} = Enum.find(sections, &(&1.title =~ "effective keys"))

      pin = Enum.find(rows, &(&1.label == "permission_mode" and &1.layer =~ "PINNED"))

      assert pin, "doctor reported the configured permission_mode with no word of the pin"
      assert pin.status == :malformed
      assert pin.detail =~ "ask"
      assert pin.path =~ "settings.local.json", "the pin must name the file that broke"
    end

    test "an empty settings file is absence, not corruption" do
      File.write!(".osa/settings.local.json", "   \n")
      Settings.reset_cache()

      assert Settings.unparseable_sources() == []
      refute Settings.get("permission_mode") == "ask"
    end
  end
end
