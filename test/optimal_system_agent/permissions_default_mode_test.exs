defmodule OptimalSystemAgent.PermissionsDefaultModeTest do
  @moduledoc "CC parity: permissions.defaultMode → OSA permission-mode atom."
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.{Permissions, Settings}

  @flag Path.join(System.tmp_dir!(), "osa-defaultmode-flag.json")

  setup do
    prior = Application.get_env(:optimal_system_agent, :settings_flag_path)
    Application.put_env(:optimal_system_agent, :settings_flag_path, @flag)
    Settings.reset_cache()

    on_exit(fn ->
      case prior do
        nil -> Application.delete_env(:optimal_system_agent, :settings_flag_path)
        p -> Application.put_env(:optimal_system_agent, :settings_flag_path, p)
      end

      File.rm(@flag)
      Settings.reset_cache()
    end)

    :ok
  end

  defp write(mode) do
    File.write!(@flag, Jason.encode!(%{"permissions" => %{"defaultMode" => mode}}))
    Settings.reset_cache()
  end

  test "maps CC defaultMode strings to OSA mode atoms" do
    write("acceptEdits")
    assert Permissions.default_mode() == :accept_edits
    write("bypassPermissions")
    assert Permissions.default_mode() == :overdrive
    write("plan")
    assert Permissions.default_mode() == :plan
    write("default")
    assert Permissions.default_mode() == :ask
  end

  test "defaults to :ask when unset or unknown" do
    File.rm(@flag)
    Settings.reset_cache()
    assert Permissions.default_mode() == :ask
    write("weirdmode")
    assert Permissions.default_mode() == :ask
  end
end