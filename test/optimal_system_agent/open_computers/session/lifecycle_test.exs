defmodule OptimalSystemAgent.OpenComputers.Session.LifecycleTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Bitwise

  alias OptimalSystemAgent.OpenComputers.{Config, Session}

  setup %{tmp_dir: dir} do
    previous_home = System.get_env("OSA_HOME")
    System.put_env("OSA_HOME", dir)

    on_exit(fn ->
      if previous_home,
        do: System.put_env("OSA_HOME", previous_home),
        else: System.delete_env("OSA_HOME")
    end)

    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    path = Path.join(dir, "open_computers.toml")

    File.write!(path, """
    control_url = "ws://127.0.0.1:#{port}/ws"
    host_key = "s3cr3t"
    fingerprint_path = "#{dir}/fingerprint"
    modes = ["direct"]
    """)

    start_supervised!({Config, path: path})
    on_exit(fn -> :gen_tcp.close(listener) end)
    %{listener: listener}
  end

  @tag :tmp_dir
  test "auth rejection reports an actionable close without leaking secrets or retrying", ctx do
    log =
      capture_log(fn ->
        start_supervised!(Session)
        socket = accept_hello(ctx.listener)
        close_frame(socket, 4001, "auth s3cr3t bearer-token")
        assert {:error, :timeout} = :gen_tcp.accept(ctx.listener, 2_700)
      end)

    assert log =~ "code=4001"
    assert log =~ "auth"
    assert log =~ "osa opencomputers login"
    refute log =~ "s3cr3t"
    refute log =~ "bearer-token"
  end

  @tag :tmp_dir
  test "an earlier hello deadline cannot disconnect the next attempt", ctx do
    start_supervised!(Session)
    first = accept_hello(ctx.listener)
    close_frame(first, 4008, "timeout")
    second = accept_hello(ctx.listener)
    # The first hello deadline expires at 5s. The second still has time to reply.
    Process.sleep(3_200)
    send_term(second, {:hello_ok, %{heartbeat_ms: 60_000}})
    send_term(second, {:ping, 123})
    assert {:pong, 123} = receive_term(second)
  end

  @tag :tmp_dir
  test "transient rejections increase delay until hello_ok resets it", ctx do
    start_supervised!(Session)
    first = accept_hello(ctx.listener)
    close_frame(first, 4008, "timeout")
    second = accept_hello(ctx.listener)
    close_frame(second, 4008, "timeout")
    # Second consecutive failure must wait ~4s, even though HTTP upgraded.
    assert {:error, :timeout} = :gen_tcp.accept(ctx.listener, 3_000)
    third = accept_hello(ctx.listener)
    send_term(third, {:hello_ok, %{heartbeat_ms: 60_000}})
    send_term(third, {:ping, 99})
    assert {:pong, 99} = receive_term(third)
    close_frame(third, 4008, "timeout")
    fourth = accept_hello(ctx.listener, 3_000)
    send_term(fourth, {:hello_ok, %{heartbeat_ms: 60_000}})
    send_term(fourth, {:ping, 100})
    assert {:pong, 100} = receive_term(fourth)
  end

  @tag :tmp_dir
  test "application close uses the same safe permanent rejection policy", ctx do
    log =
      capture_log(fn ->
        start_supervised!(Session)
        socket = accept_hello(ctx.listener)
        send_term(socket, {:close, 4003, "s3cr3t bearer-token"})
        assert {:error, :timeout} = :gen_tcp.accept(ctx.listener, 2_700)
      end)

    assert log =~ "code=4003"
    assert log =~ "upgrade_required"
    assert log =~ "Update OSA"
    refute log =~ "s3cr3t"
    refute log =~ "bearer-token"
  end

  defp accept_hello(listener, timeout \\ 8_000) do
    {:ok, socket} = :gen_tcp.accept(listener, timeout)
    upgrade(socket)
    assert {:hello, %{host_key: "s3cr3t"}} = receive_term(socket)
    socket
  end

  @tag :tmp_dir
  test "missing selected subprotocol reports a handshake error before sending credentials", ctx do
    log =
      capture_log(fn ->
        start_supervised!(Session)
        {:ok, socket} = :gen_tcp.accept(ctx.listener, 2_000)
        upgrade(socket, "")
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
        assert {:error, :timeout} = :gen_tcp.accept(ctx.listener, 2_700)
      end)

    assert log =~ "handshake"
    assert log =~ "subprotocol"
    assert log =~ "Update OSA"
    refute log =~ "s3cr3t"
  end

  @tag :tmp_dir
  test "HTTP auth rejection reports actual status without response headers", ctx do
    log =
      capture_log(fn ->
        start_supervised!(Session)
        {:ok, socket} = :gen_tcp.accept(ctx.listener, 2_000)
        headers(socket, "")

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nSet-Cookie: s3cr3t\r\n\r\n"
          )

        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
        assert {:error, :timeout} = :gen_tcp.accept(ctx.listener, 2_700)
      end)

    assert log =~ "status=401"
    assert log =~ "osa opencomputers login"
    refute log =~ "s3cr3t"
  end

  @tag :tmp_dir
  test "HTTP service failure reports status and reconnects successfully", ctx do
    log =
      capture_log(fn ->
        start_supervised!(Session)
        {:ok, socket} = :gen_tcp.accept(ctx.listener, 2_000)
        headers(socket, "")

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\nSet-Cookie: s3cr3t\r\n\r\n"
          )

        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
        second = accept_hello(ctx.listener, 3_000)
        send_term(second, {:hello_ok, %{heartbeat_ms: 60_000}})
        send_term(second, {:ping, 503})
        assert {:pong, 503} = receive_term(second)
      end)

    assert log =~ "status=503"
    assert log =~ "retrying"
    refute log =~ "s3cr3t"
  end

  @tag :tmp_dir
  test "a fragmented HTTP upgrade still establishes a usable session", ctx do
    start_supervised!(Session)
    {:ok, socket} = :gen_tcp.accept(ctx.listener, 2_000)
    upgrade(socket, "Sec-WebSocket-Protocol: miosa-opencomputers-v1\r\n", true)
    assert {:hello, _} = receive_term(socket)
    send_term(socket, {:hello_ok, %{heartbeat_ms: 60_000}})
    send_term(socket, {:ping, 42})
    assert {:pong, 42} = receive_term(socket)
  end

  @tag :tmp_dir
  test "status exposes safe rejection details and stale timer messages cannot resume retries",
       ctx do
    pid = start_supervised!(Session)
    socket = accept_hello(ctx.listener)
    close_frame(socket, 4007, "s3cr3t bearer-token")
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)

    assert %{
             phase: :rejected,
             failure: %{code: 4007, reason: :key_revoked, action: action},
             retry_in_ms: nil
           } = Session.status()

    assert action =~ "new host key"
    # Fault injection at the timer boundary: already queued legacy/current events.
    for message <- [
          :hello_timeout,
          :connect,
          :heartbeat,
          :dead_check,
          {:executor_frame, {:job_done, "old-job", %{}}},
          {:timeout, make_ref(), :connect},
          {:timeout, make_ref(), :hello_timeout}
        ] do
      send(pid, message)
    end

    assert %{phase: :rejected} = Session.status()
    assert {:error, :timeout} = :gen_tcp.accept(ctx.listener, 2_700)
    refute inspect(Session.status()) =~ "s3cr3t"
  end

  @tag :tmp_dir
  test "an incomplete upgrade times out, closes its socket, and allows reconnect", ctx do
    start_supervised!(Session)
    {:ok, socket} = :gen_tcp.accept(ctx.listener, 2_000)
    headers(socket, "")
    :ok = :gen_tcp.send(socket, "HTTP/1.1 101 Switching Protocols\r\n")
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 6_000)
    assert %{phase: :disconnected, failure: %{reason: :upgrade_timeout}} = Session.status()
    second = accept_hello(ctx.listener, 3_000)
    send_term(second, {:hello_ok, %{heartbeat_ms: 60_000}})
    send_term(second, {:ping, 7})
    assert {:pong, 7} = receive_term(second)
  end

  @tag :tmp_dir
  test "invalid HTTP stream closes the owned connection before retrying", ctx do
    start_supervised!(Session)
    {:ok, socket} = :gen_tcp.accept(ctx.listener, 2_000)
    headers(socket, "")
    :ok = :gen_tcp.send(socket, "not HTTP\r\n\r\n")
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)

    assert %{phase: :disconnected, failure: %{reason: :upgrade_transport_error}} =
             Session.status()

    accept_hello(ctx.listener, 3_000)
  end

  @tag :tmp_dir
  test "CLI status displays rejected reason and action instead of connecting", ctx do
    start_supervised!(Session)
    socket = accept_hello(ctx.listener)
    close_frame(socket, 4004, "s3cr3t")
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        OptimalSystemAgent.CLI.OpenComputers.dispatch(["status"])
      end)

    assert output =~ "REJECTED"
    assert output =~ "fingerprint_pinned"
    assert output =~ "code=4004"
    assert output =~ "administrator"
    assert output =~ "paused"
    refute output =~ "connecting - session"
    refute output =~ "s3cr3t"
  end

  @tag :tmp_dir
  test "CLI displays transient retry timing and heartbeats still work after reconnect", ctx do
    start_supervised!(Session)
    first = accept_hello(ctx.listener)
    close_frame(first, 4008, "timeout")
    assert {:error, :closed} = :gen_tcp.recv(first, 0, 2_000)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        OptimalSystemAgent.CLI.OpenComputers.dispatch(["status"])
      end)

    assert output =~ "reason=timeout"
    assert output =~ "code=4008"
    assert output =~ "retrying in"
    second = accept_hello(ctx.listener, 3_000)
    send_term(second, {:hello_ok, %{heartbeat_ms: 100}})
    assert {:heartbeat, %{seq: 1}} = receive_term(second)
    assert %{phase: :active, failure: nil, retry_in_ms: nil} = Session.status()
  end

  for protocol <- [
        "Sec-WebSocket-Protocol: wrong\r\n",
        "Sec-WebSocket-Protocol: miosa-opencomputers-v1\r\nSec-WebSocket-Protocol: miosa-opencomputers-v1\r\n"
      ] do
    @tag :tmp_dir
    test "rejects an unnegotiated or duplicate protocol: #{inspect(protocol)}", ctx do
      start_supervised!(Session)
      {:ok, socket} = :gen_tcp.accept(ctx.listener, 2_000)
      upgrade(socket, unquote(protocol))
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)

      assert %{phase: :rejected, failure: %{reason: :subprotocol_mismatch}, retry_in_ms: nil} =
               Session.status()
    end
  end

  defp upgrade(
         socket,
         protocol \\ "Sec-WebSocket-Protocol: miosa-opencomputers-v1\r\n",
         fragmented? \\ false
       ) do
    request = headers(socket, "")
    [_, key] = Regex.run(~r/sec-websocket-key: ([^\r]+)/i, request)
    accept = Base.encode64(:crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))

    status = "HTTP/1.1 101 Switching Protocols\r\n"

    rest =
      "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n#{protocol}\r\n"

    if fragmented? do
      :ok = :gen_tcp.send(socket, status)
      Process.sleep(100)
      :ok = :gen_tcp.send(socket, rest)
    else
      :ok = :gen_tcp.send(socket, status <> rest)
    end
  end

  defp headers(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
      headers(socket, acc <> data)
    end
  end

  defp receive_term(socket, timeout \\ 5_000) do
    {:ok, <<0x82, size>>} = :gen_tcp.recv(socket, 2, timeout)

    length =
      case band(size, 127) do
        126 ->
          {:ok, <<length::16>>} = :gen_tcp.recv(socket, 2, timeout)
          length

        length ->
          length
      end

    {:ok, mask} = :gen_tcp.recv(socket, 4, timeout)
    {:ok, payload} = :gen_tcp.recv(socket, length, timeout)

    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, index} -> bxor(byte, :binary.at(mask, rem(index, 4))) end)
    |> :binary.list_to_bin()
    |> :erlang.binary_to_term([:safe])
  end

  defp close_frame(socket, code, reason) do
    payload = <<code::16, reason::binary>>
    :ok = :gen_tcp.send(socket, <<0x88, byte_size(payload), payload::binary>>)
  end

  defp send_term(socket, term) do
    payload = :erlang.term_to_binary(term)
    :ok = :gen_tcp.send(socket, <<0x82, byte_size(payload), payload::binary>>)
  end
end
