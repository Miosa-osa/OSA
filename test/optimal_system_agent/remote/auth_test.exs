defmodule OptimalSystemAgent.Remote.AuthTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Remote.Auth

  # Isolate credential resolution from the real machine: point the MIOSA CLI
  # config dir at an empty tmp dir and clear both credential env vars, so tests
  # never read a real ~/.miosa/config.json or a live token.
  setup do
    dir = Path.join(System.tmp_dir!(), "osa_remote_auth_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    prev_cfg = Application.get_env(:optimal_system_agent, :miosa_cli_config_dir)
    Application.put_env(:optimal_system_agent, :miosa_cli_config_dir, dir)

    prev_override = System.get_env("OSA_REMOTE_TOKEN")
    prev_platform = System.get_env("MIOSA_PLATFORM_API_KEY")
    System.delete_env("OSA_REMOTE_TOKEN")
    System.delete_env("MIOSA_PLATFORM_API_KEY")

    on_exit(fn ->
      restore("OSA_REMOTE_TOKEN", prev_override)
      restore("MIOSA_PLATFORM_API_KEY", prev_platform)

      if prev_cfg do
        Application.put_env(:optimal_system_agent, :miosa_cli_config_dir, prev_cfg)
      else
        Application.delete_env(:optimal_system_agent, :miosa_cli_config_dir)
      end

      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  defp restore(key, nil), do: System.delete_env(key)
  defp restore(key, val), do: System.put_env(key, val)

  test "absent credential -> friendly, actionable error (not a raise)" do
    refute Auth.configured?()
    assert Auth.token() == nil

    assert {:error, message} = Auth.require_token()
    assert message =~ "No MIOSA account credential"
    assert message =~ "miosa login"
    assert message =~ "OSA_REMOTE_TOKEN"
  end

  test "OSA_REMOTE_TOKEN override is used and takes precedence" do
    System.put_env("MIOSA_PLATFORM_API_KEY", "msk_u_platform")
    System.put_env("OSA_REMOTE_TOKEN", "override_tok")

    assert Auth.token() == "override_tok"
    assert {:ok, "override_tok"} = Auth.require_token()
  end

  test "falls back to the shared MIOSA platform credential" do
    System.put_env("MIOSA_PLATFORM_API_KEY", "msk_u_platform")

    assert Auth.configured?()
    assert {:ok, "msk_u_platform"} = Auth.require_token()
  end

  test "reads the platform key from ~/.miosa/config.json when no env var", %{dir: dir} do
    File.write!(Path.join(dir, "config.json"), Jason.encode!(%{"api_key" => "msk_u_fromfile"}))
    assert {:ok, "msk_u_fromfile"} = Auth.require_token()
  end
end
