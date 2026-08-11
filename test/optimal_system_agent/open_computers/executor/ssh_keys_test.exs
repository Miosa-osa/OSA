defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.SshKeysTest do
  @moduledoc """
  Unit tests for the OSA SSH keys executor.

  Covers:
    - add_request: creates authorized_keys when absent + appends key with marker
    - add_request: detects duplicate by key body and sends :duplicate error
    - add_request: marker-based duplicate detection
    - remove_request: removes only the miosa-marked line, leaves others intact
    - remove_request: missing file treated as success
    - list_request: returns only miosa-marked keys

  Uses a temp directory for authorized_keys to avoid touching real SSH config.
  """

  # async: false — tests share named GenServers (SshKeys + MockFrameRouter) and
  # System.put_env("HOME", ...) which are process-global. Running async would
  # cause :already_started conflicts and HOME dir races between tests.
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.OpenComputers.Executor.Direct.SshKeys

  # Minimal valid key body (not a real private key)
  @test_key_body "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
  @test_pubkey "ssh-ed25519 #{@test_key_body} test@example.com"

  @test_key_body_2 "AAAAB3NzaC1yc2EAAAADAQABAAABgQC2N6ygNzSP7B4JZ9y8K6cA7sWtAjQuX4BzKiABCde"
  @test_pubkey_2 "ssh-rsa #{@test_key_body_2} other@example.com"

  setup do
    # Each test gets a fresh tmp directory so tests are fully isolated.
    tmp_dir = Path.join(System.tmp_dir!(), "osa_ssh_test_#{System.unique_integer([:positive])}")
    ssh_dir = Path.join(tmp_dir, ".ssh")
    auth_keys = Path.join(ssh_dir, "authorized_keys")
    File.mkdir_p!(ssh_dir)

    # Override the home directory for this test process. HOME is per-OS-process,
    # not per-test-process, so it must be RESTORED, not deleted: `delete_env`
    # here left the whole VM without a HOME for every test that ran afterwards,
    # breaking any assertion that reads `System.get_env("HOME")` (the trajectory
    # home-anonymization test) or compares a child process's HOME against it
    # (`OS.EnvTest`, "a real subprocess still sees PATH and HOME").
    prev_home = System.get_env("HOME")
    System.put_env("HOME", tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)

      case prev_home do
        nil -> System.delete_env("HOME")
        home -> System.put_env("HOME", home)
      end
    end)

    %{auth_keys: auth_keys, ssh_dir: ssh_dir, tmp_dir: tmp_dir}
  end

  # ── Test helpers ──────────────────────────────────────────────────────────────

  defp start_executor do
    # Start the SshKeys GenServer in isolation. The FrameRouter is not started,
    # so we intercept outbound frames by starting a mock FrameRouter.
    {:ok, _fr} = start_supervised({MockFrameRouter, test_pid: self()})
    {:ok, pid} = start_supervised({SshKeys, []})
    pid
  end

  defp send_frame(pid, frame) do
    SshKeys.handle_frame(frame)
    # Give the async Task a moment to execute
    Process.sleep(50)
    pid
  end

  # ── Add request ───────────────────────────────────────────────────────────────

  describe "ssh_key_add_request" do
    test "creates authorized_keys when absent and emits ssh_key_added", %{auth_keys: auth_keys} do
      _pid = start_executor()

      SshKeys.handle_frame(
        {:ssh_key_add_request,
         %{key_id: "key-abc", pubkey: @test_pubkey, comment: "miosa:key-abc", user: nil}}
      )

      # Wait for async Task
      Process.sleep(100)

      # authorized_keys should exist now
      assert File.exists?(auth_keys)
      content = File.read!(auth_keys)
      assert String.contains?(content, @test_key_body)
      assert String.contains?(content, "# miosa:key-abc")

      # Should have received the outbound frame
      assert_receive {:outbound_frame, {:ssh_key_added, %{key_id: "key-abc"}}}, 500
    end

    test "detects duplicate by key body and emits :duplicate error", %{auth_keys: auth_keys} do
      _pid = start_executor()

      # Add the key once
      SshKeys.handle_frame(
        {:ssh_key_add_request,
         %{key_id: "key-1", pubkey: @test_pubkey, comment: "miosa:key-1", user: nil}}
      )

      Process.sleep(100)
      assert_receive {:outbound_frame, {:ssh_key_added, %{key_id: "key-1"}}}, 500

      # Try to add the same key again (same key body = same base64 chunk)
      SshKeys.handle_frame(
        {:ssh_key_add_request,
         %{key_id: "key-2", pubkey: @test_pubkey, comment: "miosa:key-2", user: nil}}
      )

      Process.sleep(100)

      assert_receive {:outbound_frame, {:ssh_key_error, %{key_id: "key-2", reason: :duplicate}}},
                     500
    end

    test "appends multiple distinct keys without touching others", %{auth_keys: auth_keys} do
      File.write!(auth_keys, "ssh-rsa MANUALKEY user@manual\n")

      _pid = start_executor()

      SshKeys.handle_frame(
        {:ssh_key_add_request,
         %{key_id: "key-1", pubkey: @test_pubkey, comment: "miosa:key-1", user: nil}}
      )

      Process.sleep(100)
      assert_receive {:outbound_frame, {:ssh_key_added, %{key_id: "key-1"}}}, 500

      SshKeys.handle_frame(
        {:ssh_key_add_request,
         %{key_id: "key-2", pubkey: @test_pubkey_2, comment: "miosa:key-2", user: nil}}
      )

      Process.sleep(100)
      assert_receive {:outbound_frame, {:ssh_key_added, %{key_id: "key-2"}}}, 500

      content = File.read!(auth_keys)
      # Manual key must still be there
      assert String.contains?(content, "MANUALKEY")
      # Both miosa keys present
      assert String.contains?(content, "# miosa:key-1")
      assert String.contains?(content, "# miosa:key-2")
    end
  end

  # ── Remove request ────────────────────────────────────────────────────────────

  describe "ssh_key_remove_request" do
    test "removes only the miosa-marked line, leaves other lines intact", %{auth_keys: auth_keys} do
      manual_line = "ssh-rsa MANUALKEY user@manual"

      File.write!(auth_keys, "#{manual_line}\nssh-ed25519 #{@test_key_body} # miosa:key-abc\n")

      _pid = start_executor()

      SshKeys.handle_frame({:ssh_key_remove_request, %{key_id: "key-abc"}})
      Process.sleep(100)

      assert_receive {:outbound_frame, {:ssh_key_removed, %{key_id: "key-abc"}}}, 500

      content = File.read!(auth_keys)
      # The manual key must be preserved
      assert String.contains?(content, manual_line)
      # The miosa key must be gone
      refute String.contains?(content, "# miosa:key-abc")
    end

    test "succeeds when authorized_keys does not exist (no file = key never added)", %{
      auth_keys: auth_keys
    } do
      refute File.exists?(auth_keys)

      _pid = start_executor()

      SshKeys.handle_frame({:ssh_key_remove_request, %{key_id: "key-xyz"}})
      Process.sleep(100)

      assert_receive {:outbound_frame, {:ssh_key_removed, %{key_id: "key-xyz"}}}, 500
    end
  end

  # ── List request ──────────────────────────────────────────────────────────────

  describe "ssh_key_list_request" do
    test "returns only miosa-marked keys", %{auth_keys: auth_keys} do
      File.write!(
        auth_keys,
        "ssh-rsa MANUALKEY user@manual\n" <>
          "ssh-ed25519 #{@test_key_body} # miosa:key-abc\n" <>
          "ssh-rsa #{@test_key_body_2} # miosa:key-xyz\n"
      )

      _pid = start_executor()

      SshKeys.handle_frame({:ssh_key_list_request, %{}})
      Process.sleep(100)

      assert_receive {:outbound_frame, {:ssh_key_list_response, %{keys: keys}}}, 500

      key_ids = Enum.map(keys, & &1.key_id)
      assert "key-abc" in key_ids
      assert "key-xyz" in key_ids
      # Manual key should NOT be in the list
      assert length(keys) == 2
    end

    test "returns empty list when file does not exist", _ctx do
      _pid = start_executor()

      SshKeys.handle_frame({:ssh_key_list_request, %{}})
      Process.sleep(100)

      assert_receive {:outbound_frame, {:ssh_key_list_response, %{keys: []}}}, 500
    end
  end
end

# ── Mock FrameRouter ──────────────────────────────────────────────────────────

defmodule MockFrameRouter do
  @moduledoc "Captures outbound frames and forwards them as messages to the test process."
  use GenServer

  def start_link(opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    GenServer.start_link(__MODULE__, test_pid, name: OptimalSystemAgent.OpenComputers.FrameRouter)
  end

  @impl true
  def init(test_pid), do: {:ok, test_pid}

  @impl true
  def handle_cast({:outbound, frame}, test_pid) do
    send(test_pid, {:outbound_frame, frame})
    {:noreply, test_pid}
  end

  def handle_cast(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(_msg, _from, state), do: {:reply, :ok, state}
end
