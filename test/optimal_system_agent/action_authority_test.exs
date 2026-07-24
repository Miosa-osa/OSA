defmodule OptimalSystemAgent.ActionAuthorityTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.ActionAuthority
  alias OptimalSystemAgent.Agent.Scheduler.JobExecutor
  alias OptimalSystemAgent.MIOSA.Platform
  alias OptimalSystemAgent.Tools.Registry

  setup do
    config_dir =
      Path.join(
        System.tmp_dir!(),
        "osa-authority-test-#{System.unique_integer([:positive])}"
      )

    previous = %{
      action_authority: Application.get_env(:optimal_system_agent, :action_authority),
      cli_config_dir: Application.get_env(:optimal_system_agent, :miosa_cli_config_dir),
      sandbox_backend: Application.get_env(:optimal_system_agent, :sandbox_backend),
      computer_use_platform: Application.get_env(:optimal_system_agent, :computer_use_platform),
      platform_api_key: System.get_env("MIOSA_PLATFORM_API_KEY"),
      platform_endpoint: System.get_env("MIOSA_PLATFORM_ENDPOINT"),
      platform_workspace_id: System.get_env("MIOSA_PLATFORM_WORKSPACE_ID")
    }

    System.delete_env("MIOSA_PLATFORM_API_KEY")
    System.delete_env("MIOSA_PLATFORM_ENDPOINT")
    System.delete_env("MIOSA_PLATFORM_WORKSPACE_ID")
    Application.put_env(:optimal_system_agent, :miosa_cli_config_dir, config_dir)
    Application.put_env(:optimal_system_agent, :sandbox_backend, :miosa)

    :ok = File.mkdir_p(config_dir)

    File.write!(
      Platform.config_path(),
      Jason.encode!(%{
        "api_key" => "msk_test_authority",
        "workspace" => "workspace-123",
        "endpoint" => "https://api.example.test"
      })
    )

    on_exit(fn ->
      File.rm_rf(config_dir)
      restore_env(:action_authority, previous.action_authority)
      restore_env(:miosa_cli_config_dir, previous.cli_config_dir)
      restore_env(:sandbox_backend, previous.sandbox_backend)
      restore_env(:computer_use_platform, previous.computer_use_platform)
      restore_system_env("MIOSA_PLATFORM_API_KEY", previous.platform_api_key)
      restore_system_env("MIOSA_PLATFORM_ENDPOINT", previous.platform_endpoint)

      restore_system_env(
        "MIOSA_PLATFORM_WORKSPACE_ID",
        previous.platform_workspace_id
      )
    end)

    :ok
  end

  test "canonical fingerprints match the CLI contract independent of map key order" do
    left = %{"b" => [%{"z" => true, "a" => nil}], "a" => 1}
    right = %{"a" => 1, "b" => [%{"a" => nil, "z" => true}]}

    assert ActionAuthority.canonical_json(left) ==
             ~s({"a":1,"b":[{"a":null,"z":true}]})

    assert ActionAuthority.fingerprint(left) == ActionAuthority.fingerprint(right)
  end

  test "MIOSA sandbox execution uses the server catalog and allows an approved call" do
    test_pid = self()
    plug_name = unique_plug_name()

    Req.Test.stub(plug_name, fn conn ->
      case conn.request_path do
        "/api/v1/actions/catalog" ->
          Req.Test.json(conn, %{
            "data" => [
              %{
                "name" => "sandbox.exec",
                "version" => "1.0.0",
                "fingerprint" => capability_fingerprint("sandbox.exec")
              }
            ]
          })

        "/api/v1/actions/authorize" ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:authority_request, Jason.decode!(raw), conn.req_headers})

          Req.Test.json(conn, %{
            "decision" => "allow",
            "receipt_id" => "receipt-1"
          })
      end
    end)

    configure_plug(plug_name)

    assert {:allow, %{"receipt_id" => "receipt-1"}} =
             ActionAuthority.authorize_tool("shell_execute", %{
               "command" => "echo safe",
               "__session_id__" => "session-secret",
               "__surface__" => "mcp"
             })

    assert_receive {:authority_request, request, headers}
    assert request["capability"]["name"] == "sandbox.exec"
    assert request["workspace_id"] == "workspace-123"
    assert request["surface"] == "mcp"

    assert request["params_fingerprint"] ==
             ActionAuthority.fingerprint(%{"command" => "echo safe"})

    assert {"authorization", "Bearer msk_test_authority"} in headers
    refute inspect(request) =~ "session-secret"
  end

  test "reuses the versioned server catalog within the configured cache window" do
    test_pid = self()
    plug_name = unique_plug_name()

    Req.Test.stub(plug_name, fn conn ->
      case conn.request_path do
        "/api/v1/actions/catalog" ->
          send(test_pid, :catalog_requested)

          Req.Test.json(conn, %{
            "data" => [
              %{
                "name" => "sandbox.exec",
                "version" => "1.0.0",
                "fingerprint" => capability_fingerprint("sandbox.exec")
              }
            ]
          })

        "/api/v1/actions/authorize" ->
          Req.Test.json(conn, %{"decision" => "allow", "receipt_id" => "receipt-cache"})
      end
    end)

    configure_plug(plug_name)

    assert {:allow, _receipt} =
             ActionAuthority.authorize_tool("shell_execute", %{"command" => "echo one"})

    assert {:allow, _receipt} =
             ActionAuthority.authorize_tool("shell_execute", %{"command" => "echo two"})

    assert_receive :catalog_requested
    refute_receive :catalog_requested, 50
  end

  test "an environment credential uses only its matching endpoint and workspace context" do
    System.put_env("MIOSA_PLATFORM_API_KEY", "msk_environment")
    System.put_env("MIOSA_PLATFORM_ENDPOINT", "https://environment.miosa.test/")
    System.put_env("MIOSA_PLATFORM_WORKSPACE_ID", "workspace-environment")

    assert Platform.platform_api_key() == "msk_environment"
    assert Platform.endpoint() == "https://environment.miosa.test"
    assert Platform.workspace_id() == "workspace-environment"

    System.delete_env("MIOSA_PLATFORM_ENDPOINT")
    System.delete_env("MIOSA_PLATFORM_WORKSPACE_ID")

    assert Platform.endpoint() == "https://api.miosa.ai"
    assert Platform.workspace_id() == nil
  end

  test "pending central approval blocks the registry before the tool dispatches" do
    plug_name = unique_plug_name()

    Req.Test.stub(plug_name, fn conn ->
      case conn.request_path do
        "/api/v1/actions/catalog" ->
          Req.Test.json(conn, %{
            "data" => [
              %{
                "name" => "sandbox.exec",
                "version" => "1.0.0",
                "fingerprint" => capability_fingerprint("sandbox.exec")
              }
            ]
          })

        "/api/v1/actions/authorize" ->
          conn
          |> Plug.Conn.put_status(202)
          |> Req.Test.json(%{
            "decision" => "pending_approval",
            "approval_request_id" => "approval-42",
            "receipt_id" => "receipt-42"
          })
      end
    end)

    configure_plug(plug_name, %{"file_read" => "sandbox.exec"})
    missing_path = Path.join(System.tmp_dir!(), "must-not-be-read-#{System.unique_integer()}")

    assert {:error, message} = Registry.execute("file_read", %{"path" => missing_path})
    assert message =~ "central approval required"
    assert message =~ "approval-42"
    refute message =~ "File not found"
  end

  test "a governed action fails closed when platform authentication is absent" do
    File.rm!(Platform.config_path())

    assert {:blocked, message} =
             ActionAuthority.authorize_tool("shell_execute", %{"command" => "echo nope"})

    assert message =~ "platform authentication is missing"
  end

  test "local tools remain ungoverned" do
    assert :not_governed =
             ActionAuthority.authorize_tool("file_read", %{"path" => "/tmp/example"})
  end

  test "MIOSA computer use resolves each operation through the generated contract" do
    test_pid = self()
    plug_name = unique_plug_name()

    Req.Test.stub(plug_name, fn conn ->
      case conn.request_path do
        "/api/v1/actions/catalog" ->
          Req.Test.json(conn, %{
            "data" => [
              %{
                "name" => "computer.screenshot",
                "version" => "1.0.0",
                "fingerprint" => capability_fingerprint("computer.screenshot")
              }
            ]
          })

        "/api/v1/actions/authorize" ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:computer_authority_request, Jason.decode!(raw)})
          Req.Test.json(conn, %{"decision" => "allow", "receipt_id" => "computer-receipt"})
      end
    end)

    configure_plug(plug_name)
    Application.put_env(:optimal_system_agent, :computer_use_platform, :miosa)

    assert {:allow, %{"receipt_id" => "computer-receipt"}} =
             ActionAuthority.authorize_tool("computer_use", %{
               "action" => "screenshot",
               "region" => %{"x" => 0, "y" => 0, "width" => 200, "height" => 100}
             })

    assert_receive {:computer_authority_request, request}
    assert request["capability"]["name"] == "computer.screenshot"
  end

  test "unknown MIOSA computer use operations fail closed" do
    Application.put_env(:optimal_system_agent, :computer_use_platform, :miosa)

    assert {:blocked, message} =
             ActionAuthority.authorize_tool("computer_use", %{"action" => "future_action"})

    assert message =~ "no canonical capability"
  end

  test "computer use on a local display remains under OSA local safety only" do
    Application.put_env(:optimal_system_agent, :computer_use_platform, :macos)

    assert :not_governed =
             ActionAuthority.authorize_tool("computer_use", %{"action" => "screenshot"})
  end

  test "scheduled commands use the shared authority seam with a schedule surface" do
    test_pid = self()
    plug_name = unique_plug_name()

    Req.Test.stub(plug_name, fn conn ->
      case conn.request_path do
        "/api/v1/actions/catalog" ->
          Req.Test.json(conn, %{
            "data" => [
              %{
                "name" => "sandbox.exec",
                "version" => "1.0.0",
                "fingerprint" => capability_fingerprint("sandbox.exec")
              }
            ]
          })

        "/api/v1/actions/authorize" ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:scheduled_authority_request, Jason.decode!(raw)})
          Req.Test.json(conn, %{"decision" => "allow", "receipt_id" => "schedule-receipt"})
      end
    end)

    Application.put_env(:optimal_system_agent, :sandbox_backend, :host)
    configure_plug(plug_name, %{"shell_execute" => "sandbox.exec"})

    assert {:ok, "scheduled-ok"} = JobExecutor.run_shell_command("printf scheduled-ok")
    assert_receive {:scheduled_authority_request, %{"surface" => "schedule"}}
  end

  defp configure_plug(plug_name, capability_map \\ %{}) do
    Application.put_env(
      :optimal_system_agent,
      :action_authority,
      plug: {Req.Test, plug_name},
      base_url: "https://api.example.test",
      capability_map: capability_map
    )
  end

  defp capability_fingerprint(name) do
    digest =
      :crypto.hash(:sha256, "miosa-capability/#{name}@1.0.0")
      |> Base.encode16(case: :lower)

    "sha256:" <> digest
  end

  defp unique_plug_name do
    :"authority_test_#{System.unique_integer([:positive])}"
  end

  defp restore_env(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore_env(key, value), do: Application.put_env(:optimal_system_agent, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
