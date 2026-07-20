defmodule OptimalSystemAgent.OpenComputers.RemoteTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.OpenComputers.Remote
  alias OptimalSystemAgent.OpenComputers.Remote.Protocol

  setup do
    previous_env = System.get_env("MIOSA_PLATFORM_API_KEY")
    previous_dir = Application.get_env(:optimal_system_agent, :miosa_cli_config_dir)

    temp_dir =
      Path.join(System.tmp_dir!(), "osa_remote_test_#{System.unique_integer([:positive])}")

    System.delete_env("MIOSA_PLATFORM_API_KEY")
    Application.put_env(:optimal_system_agent, :miosa_cli_config_dir, temp_dir)

    on_exit(fn ->
      if previous_env,
        do: System.put_env("MIOSA_PLATFORM_API_KEY", previous_env),
        else: System.delete_env("MIOSA_PLATFORM_API_KEY")

      if previous_dir,
        do: Application.put_env(:optimal_system_agent, :miosa_cli_config_dir, previous_dir),
        else: Application.delete_env(:optimal_system_agent, :miosa_cli_config_dir)

      File.rm_rf(temp_dir)
    end)

    :ok
  end

  test "fails closed when no MIOSA account credential is configured" do
    assert {:error, :missing_platform_api_key} = Remote.list_hosts()
  end

  test "remote protocol accepts only high-level client operations" do
    assert Protocol.client_body?({:remote_hosts_list, %{}})

    assert Protocol.client_body?(
             {:remote_session_open, %{ref: "r", host_id: "h", kind: :exec, params: %{cmd: "pwd"}}}
           )

    assert Protocol.client_body?(
             {:remote_session_close, %{session_id: "s", reason: :client_closed}}
           )

    refute Protocol.client_body?({:remote_session_close, %{session_id: "s"}})

    refute Protocol.client_body?({:remote_session_frame, %{session_id: "s", frame: {:job, %{}}}})
  end

  test "remote protocol rejects envelopes with the wrong version" do
    assert {:error, :invalid_envelope} =
             Protocol.unwrap({:oc_remote, %{v: 2, request_id: "r", body: :x}})
  end

  test "remote protocol preserves the request correlation id" do
    assert {:ok, "request-123", {:remote_hosts_list, %{}}} =
             Protocol.unwrap(Protocol.envelope({:remote_hosts_list, %{}}, "request-123"))
  end
end
