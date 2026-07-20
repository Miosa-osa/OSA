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
end
