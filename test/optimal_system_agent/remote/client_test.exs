defmodule OptimalSystemAgent.Remote.ClientTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Remote.Client

  describe "control_url/0" do
    test "env override wins over the default" do
      prev = System.get_env("OSA_REMOTE_CONTROL_URL")
      System.put_env("OSA_REMOTE_CONTROL_URL", "wss://example.test/clients/ws")

      on_exit(fn ->
        if prev,
          do: System.put_env("OSA_REMOTE_CONTROL_URL", prev),
          else: System.delete_env("OSA_REMOTE_CONTROL_URL")
      end)

      assert Client.control_url() == "wss://example.test/clients/ws"
    end

    test "default points at the client endpoint on api.miosa.ai" do
      prev = System.get_env("OSA_REMOTE_CONTROL_URL")
      System.delete_env("OSA_REMOTE_CONTROL_URL")
      on_exit(fn -> if prev, do: System.put_env("OSA_REMOTE_CONTROL_URL", prev) end)

      assert Client.control_url() == "wss://api.miosa.ai/api/v1/opencomputers/clients/ws"
    end
  end

  describe "client_instance_id/0" do
    test "OSA_REMOTE_CLIENT_ID env override is used verbatim" do
      prev = System.get_env("OSA_REMOTE_CLIENT_ID")
      System.put_env("OSA_REMOTE_CLIENT_ID", "fixed-instance-id")

      on_exit(fn ->
        if prev,
          do: System.put_env("OSA_REMOTE_CLIENT_ID", prev),
          else: System.delete_env("OSA_REMOTE_CLIENT_ID")
      end)

      assert Client.client_instance_id() == "fixed-instance-id"
    end

    test "generates and caches a stable id under config_dir when no env override" do
      dir =
        Path.join(System.tmp_dir!(), "osa_remote_client_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)

      prev_env = System.get_env("OSA_REMOTE_CLIENT_ID")
      prev_cfg = Application.get_env(:optimal_system_agent, :config_dir)
      System.delete_env("OSA_REMOTE_CLIENT_ID")
      Application.put_env(:optimal_system_agent, :config_dir, dir)

      on_exit(fn ->
        if prev_env, do: System.put_env("OSA_REMOTE_CLIENT_ID", prev_env)

        if prev_cfg,
          do: Application.put_env(:optimal_system_agent, :config_dir, prev_cfg),
          else: Application.delete_env(:optimal_system_agent, :config_dir)

        File.rm_rf(dir)
      end)

      first = Client.client_instance_id()
      assert is_binary(first)
      assert File.exists?(Path.join(dir, "remote_client_id"))
      # Stable across calls (reads the cached file the second time).
      assert Client.client_instance_id() == first
    end
  end

  describe "open/1 connect-failure path" do
    test "unreachable broker yields the friendly error, not a crash" do
      # Bind then release a port so the connect target is guaranteed closed.
      {:ok, sock} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, reuseaddr: true)
      {:ok, port} = :inet.port(sock)
      :gen_tcp.close(sock)

      result = Client.open(token: "msk_u_test", url: "ws://127.0.0.1:#{port}/clients/ws")

      assert {:error, message} = result
      assert message =~ "could not reach the OSA remote broker"
      assert message =~ "MIOSA account linked"
    end

    test "missing token is rejected without dialing" do
      assert {:error, message} = Client.open(token: nil)
      assert message =~ "no account credential"
    end
  end

  describe "friendly auth / error messages" do
    test "a forbidden auth-close (4003) names the opencomputers:write scope" do
      msg = Client.auth_close_message(4003)
      assert msg =~ "opencomputers:write"
      assert msg =~ "rejected"
    end

    test "an invalid auth-close (4001) points at re-linking the credential" do
      msg = Client.auth_close_message(4001)
      assert msg =~ "invalid or inactive"
      assert msg =~ "miosa login"
    end

    test "a remote_error(:forbidden) names the opencomputers:write scope" do
      msg = Client.remote_error_message(%{reason: :forbidden})
      assert msg =~ "opencomputers:write"
    end

    test "a remote_error with an arbitrary reason renders it without crashing" do
      assert Client.remote_error_message(%{reason: :host_offline}) =~ "host_offline"
    end
  end
end
