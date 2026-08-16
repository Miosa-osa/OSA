defmodule OptimalSystemAgent.PermissionsDefaultModeTest do
  @moduledoc "CC parity: permissions.defaultMode → OSA permission-mode atom."
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.{Permissions, Settings}

  # Per-test path, not a fixed one. A shared `/tmp/osa-defaultmode-flag.json`
  # is readable and writable by every concurrent `mix test`, and a run that
  # dies before `on_exit` leaves it behind for the next one to inherit as
  # settings it never wrote.
  setup do
    flag =
      Path.join(
        System.tmp_dir!(),
        "osa-defaultmode-flag-#{System.unique_integer([:positive])}.json"
      )

    prior = Application.get_env(:optimal_system_agent, :settings_flag_path)
    Application.put_env(:optimal_system_agent, :settings_flag_path, flag)
    Settings.reset_cache()

    on_exit(fn ->
      case prior do
        nil -> Application.delete_env(:optimal_system_agent, :settings_flag_path)
        p -> Application.put_env(:optimal_system_agent, :settings_flag_path, p)
      end

      File.rm(flag)
      Settings.reset_cache()
    end)

    {:ok, flag: flag}
  end

  defp write(flag, mode) do
    File.write!(flag, Jason.encode!(%{"permissions" => %{"defaultMode" => mode}}))
    Settings.reset_cache()
  end

  test "maps CC defaultMode strings to OSA mode atoms", %{flag: flag} do
    write(flag, "acceptEdits")
    assert Permissions.default_mode() == :accept_edits
    write(flag, "bypassPermissions")
    assert Permissions.default_mode() == :overdrive
    write(flag, "plan")
    assert Permissions.default_mode() == :plan
    write(flag, "default")
    assert Permissions.default_mode() == :ask
  end

  test "defaults to :ask when unset or unknown", %{flag: flag} do
    File.rm(flag)
    Settings.reset_cache()
    assert Permissions.default_mode() == :ask
    write(flag, "weirdmode")
    assert Permissions.default_mode() == :ask
  end

  defp write_legacy(flag, mode) do
    File.write!(flag, Jason.encode!(%{"permission_mode" => mode}))
    Settings.reset_cache()
  end

  defp write_both(flag, cc_mode, legacy_mode) do
    File.write!(
      flag,
      Jason.encode!(%{
        "permissions" => %{"defaultMode" => cc_mode},
        "permission_mode" => legacy_mode
      })
    )

    Settings.reset_cache()
  end

  test "falls back to legacy permission_mode key when defaultMode absent", %{flag: flag} do
    write_legacy(flag, "auto-edit")
    assert Permissions.default_mode() == :accept_edits
    write_legacy(flag, "plan")
    assert Permissions.default_mode() == :plan
    write_legacy(flag, "overdrive")
    assert Permissions.default_mode() == :overdrive
    write_legacy(flag, "ask")
    assert Permissions.default_mode() == :ask
    write_legacy(flag, "bogus")
    assert Permissions.default_mode() == :ask
  end

  test "CC permissions.defaultMode wins over legacy permission_mode", %{flag: flag} do
    write_both(flag, "plan", "overdrive")
    assert Permissions.default_mode() == :plan
  end
end
