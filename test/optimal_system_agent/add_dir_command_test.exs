defmodule OptimalSystemAgent.AddDirCommandTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias OptimalSystemAgent.Channels.CLI.Commands
  alias OptimalSystemAgent.Permissions

  # `Permissions.add_directory/1` writes `permissions.additionalDirectories`
  # into the SESSION settings layer — `:ets.insert(:osa_settings, ...)`, which
  # is process-wide and has no per-test lifetime. Removing only the temp
  # directory left the recorded permission behind for the rest of the VM, and
  # because the cascade DEEP-MERGES `permissions`, every later test that read
  # the key got an extra `"additionalDirectories" => ["/tmp/osa_adddir_<n>"]`
  # entry it never wrote. `SettingsBomTest` asserts on the map by equality, so
  # it failed whenever the seed happened to order this file first — the classic
  # shape: a test that mutates global state and cleans up only the part it can
  # see on disk.
  defp restore_session_permissions do
    prior =
      case :ets.whereis(:osa_settings) do
        :undefined -> :missing
        _ -> :ets.lookup(:osa_settings, {:session, "permissions"})
      end

    on_exit(fn ->
      if :ets.whereis(:osa_settings) != :undefined do
        case prior do
          [{key, value}] -> :ets.insert(:osa_settings, {key, value})
          _ -> :ets.delete(:osa_settings, {:session, "permissions"})
        end
      end
    end)
  end

  test "/add-dir validates and records an existing directory" do
    restore_session_permissions()
    tmp = Path.join(System.tmp_dir!(), "osa_adddir_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    out = capture_io(fn -> Commands.cmd_add_dir(tmp, "s1") end)

    assert out =~ "Added working directory"
    assert Path.expand(tmp) in Permissions.additional_directories()
  end

  test "/add-dir rejects a missing path" do
    out = capture_io(fn -> Commands.cmd_add_dir("/definitely/not/here_osa_123", "s1") end)
    assert out =~ "does not exist"
  end

  test "/add-dir with no argument prints usage" do
    out = capture_io(fn -> Commands.cmd_add_dir("", "s1") end)
    assert out =~ "Usage: /add-dir"
  end
end
