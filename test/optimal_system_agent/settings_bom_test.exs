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

    test "an empty settings file is absence, not corruption" do
      File.write!(".osa/settings.local.json", "   \n")
      Settings.reset_cache()

      assert Settings.unparseable_sources() == []
      refute Settings.get("permission_mode") == "ask"
    end
  end
end
