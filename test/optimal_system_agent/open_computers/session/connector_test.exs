defmodule OptimalSystemAgent.OpenComputers.Session.ConnectorTest do
  @moduledoc """
  Tests for the Session WebSocket transport layer.

  Network tests (tagged `:network`) spin up a raw TCP + manual WebSocket
  server on 127.0.0.1:0.  No external dependencies (no cowboy, no
  websock_adapter) — the handshake is done by hand using the WS RFC 6455
  framing helpers at the bottom of this file.

  Exclude on CI if flaky: `mix test --exclude network`.
  """

  use ExUnit.Case, async: false

  @moduletag :network

  import Bitwise, only: [bxor: 2, band: 2, bsr: 2]

  alias OptimalSystemAgent.OpenComputers.Session
  alias OptimalSystemAgent.OpenComputers.Session.{Backoff, Connector, FrameCodec}

  # ── Pure-unit tests — no sockets ─────────────────────────────────────────────

  describe "Backoff" do
    test "initial is 1_000 ms" do
      assert Backoff.initial() == 1_000
    end

    test "next/1 doubles up to 60_000" do
      assert Backoff.next(1_000) == 2_000
      assert Backoff.next(30_000) == 60_000
      assert Backoff.next(60_000) == 60_000
    end

    test "with_jitter/1 adds a non-negative value" do
      base = 5_000
      result = Backoff.with_jitter(base)
      assert result >= base
    end
  end

  describe "FrameCodec round-trip" do
    test "encode then decode is identity for common terms" do
      term = {:hello_ok, %{host_id: "host-1", heartbeat_ms: 30_000}}
      assert {:ok, ^term} = FrameCodec.decode(FrameCodec.encode(term))
    end

    test "decode returns :error on garbage binary" do
      assert :error = FrameCodec.decode(<<1, 2, 3>>)
    end
  end

  describe "Connector.connect/1 — unreachable host" do
    test "returns {:error, _} when nothing is listening" do
      # Pick an ephemeral port that is definitely not listening.
      {:ok, sock} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, reuseaddr: true)
      {:ok, free_port} = :inet.port(sock)
      :gen_tcp.close(sock)

      result =
        try do
          Connector.connect("ws://127.0.0.1:#{free_port}/ws")
        rescue
          e -> {:error, Exception.message(e)}
        end

      assert {:error, _} = result
    end
  end

  # ── Integration: Session GenServer ───────────────────────────────────────────

  describe "Session — connect → hello → hello_ok → active" do
    test "Session sends :hello on connect; transitions to :active after :hello_ok" do
      test_pid = self()

      # Start a raw TCP + WebSocket server that accepts one connection.
      {:ok, listen_sock} =
        :gen_tcp.listen(0, [
          :binary,
          active: false,
          reuseaddr: true,
          ip: {127, 0, 0, 1}
        ])

      {:ok, port} = :inet.port(listen_sock)

      # Server process: accept, upgrade, receive hello, reply hello_ok.
      server_pid =
        spawn_link(fn ->
          case :gen_tcp.accept(listen_sock, 8_000) do
            {:ok, client_sock} ->
              ws_server_run(client_sock, test_pid)

            {:error, reason} ->
              send(test_pid, {:server_error, reason})
          end
        end)

      on_exit(fn ->
        :gen_tcp.close(listen_sock)
        if Process.alive?(server_pid), do: Process.exit(server_pid, :kill)
      end)

      # Config pointing at the local server.
      toml_path = write_temp_toml("ws://127.0.0.1:#{port}/ws", "oc_host_testkey123")
      on_exit(fn -> File.rm(toml_path) end)

      {:ok, _cfg} =
        start_supervised(
          {OptimalSystemAgent.OpenComputers.Config, path: toml_path},
          id: :cfg_hello_test
        )

      {:ok, _fr} =
        start_supervised(
          {OptimalSystemAgent.OpenComputers.FrameRouter, []},
          id: :fr_hello_test
        )

      {:ok, session_pid} =
        start_supervised(
          {Session, []},
          id: :session_hello_test
        )

      # Expect the server to forward the decoded :hello frame.
      assert_receive {:ws_server_received, {:hello, hello_payload}}, 7_000
      assert Map.has_key?(hello_payload, :host_key)
      assert hello_payload.host_key == "oc_host_testkey123"

      # Tell the server process to send hello_ok back.
      send(server_pid, {:ws_send, {:hello_ok, %{host_id: "h-abc", heartbeat_ms: 60_000}}})

      # Allow Session to process hello_ok via the TCP receive loop.
      Process.sleep(300)

      %{phase: phase} = :sys.get_state(session_pid, 2_000)
      assert phase == :active
    end
  end

  describe "Session — reconnect on unreachable host" do
    test "stays :disconnected and increments failure_count" do
      # Use a port that's guaranteed to be closed (bind then release).
      {:ok, tmp_sock} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, reuseaddr: true)
      {:ok, free_port} = :inet.port(tmp_sock)
      :gen_tcp.close(tmp_sock)

      toml_path = write_temp_toml("ws://127.0.0.1:#{free_port}/ws", "oc_host_backoff_test")
      on_exit(fn -> File.rm(toml_path) end)

      {:ok, _} =
        start_supervised(
          {OptimalSystemAgent.OpenComputers.Config, path: toml_path},
          id: :cfg_backoff
        )

      {:ok, _} =
        start_supervised(
          {OptimalSystemAgent.OpenComputers.FrameRouter, []},
          id: :fr_backoff
        )

      {:ok, session_pid} =
        start_supervised(
          {Session, []},
          id: :session_backoff
        )

      # Wait for at least one failed attempt (backoff starts at 1 s).
      Process.sleep(2_000)

      %{phase: phase, failure_count: failures} = :sys.get_state(session_pid, 2_000)
      assert phase == :disconnected
      assert failures >= 1
    end
  end

  describe "Session — missing host_key" do
    test "stays :disconnected without crashing when host_key is blank" do
      toml_path = write_temp_toml("ws://127.0.0.1:9999/ws", "")
      on_exit(fn -> File.rm(toml_path) end)

      {:ok, _} =
        start_supervised(
          {OptimalSystemAgent.OpenComputers.Config, path: toml_path},
          id: :cfg_nokey
        )

      {:ok, _} =
        start_supervised(
          {OptimalSystemAgent.OpenComputers.FrameRouter, []},
          id: :fr_nokey
        )

      {:ok, session_pid} =
        start_supervised(
          {Session, []},
          id: :session_nokey
        )

      Process.sleep(400)
      assert Process.alive?(session_pid)

      %{phase: phase} = :sys.get_state(session_pid, 1_000)
      assert phase == :disconnected
    end
  end

  describe "Session — outbound frame path ({:send_frame, _})" do
    test "frames sent via send/2 while phase :disconnected are silently dropped" do
      toml_path = write_temp_toml("ws://127.0.0.1:9999/ws", "")
      on_exit(fn -> File.rm(toml_path) end)

      {:ok, _} =
        start_supervised(
          {OptimalSystemAgent.OpenComputers.Config, path: toml_path},
          id: :cfg_drop
        )

      {:ok, _} =
        start_supervised(
          {OptimalSystemAgent.OpenComputers.FrameRouter, []},
          id: :fr_drop
        )

      {:ok, session_pid} =
        start_supervised(
          {Session, []},
          id: :session_drop
        )

      Process.sleep(100)

      # Send a frame message — should not raise and session should survive.
      send(session_pid, {:send_frame, {:job_done, "job-1", %{exit_code: 0}}})

      Process.sleep(100)
      assert Process.alive?(session_pid)
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  defp write_temp_toml(control_url, host_key) do
    path =
      Path.join(
        System.tmp_dir!(),
        "oc_connector_test_#{System.unique_integer([:positive])}.toml"
      )

    File.write!(path, """
    control_url = "#{control_url}"
    host_key = "#{host_key}"
    fingerprint_path = "/tmp/oc_test_fp_#{System.unique_integer([:positive])}.ed25519"
    modes = ["direct"]
    heartbeat_ms = 60000
    """)

    path
  end

  # ── Raw WebSocket server helpers ──────────────────────────────────────────────

  # Perform HTTP→WS handshake then loop reading/writing frames.
  defp ws_server_run(sock, test_pid) do
    request = ws_recv_http_headers(sock, "")
    ws_key = ws_extract_key(request)

    if is_nil(ws_key) do
      send(test_pid, {:ws_server_error, :no_ws_key_found, request})
    else
      :gen_tcp.send(sock, ws_handshake_response(ws_key))
      ws_loop(sock, test_pid)
    end
  end

  # Accumulate data until we see the end of HTTP headers (\r\n\r\n).
  defp ws_recv_http_headers(sock, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      case :gen_tcp.recv(sock, 0, 5_000) do
        {:ok, data} -> ws_recv_http_headers(sock, acc <> data)
        {:error, _} -> acc
      end
    end
  end

  defp ws_handshake_response(ws_key) do
    accept = ws_accept_key(ws_key)

    "HTTP/1.1 101 Switching Protocols\r\n" <>
      "Upgrade: websocket\r\n" <>
      "Connection: Upgrade\r\n" <>
      "Sec-WebSocket-Accept: #{accept}\r\n" <>
      "Sec-WebSocket-Protocol: miosa-opencomputers-v1\r\n" <>
      "\r\n"
  end

  defp ws_accept_key(key) do
    :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()
  end

  defp ws_extract_key(request) do
    request
    |> String.split("\r\n")
    |> Enum.find_value(fn line ->
      case String.split(line, ": ", parts: 2) do
        [header, key] ->
          if String.downcase(header) == "sec-websocket-key" do
            String.trim(key)
          else
            nil
          end

        _ ->
          nil
      end
    end)
  end

  defp ws_loop(sock, test_pid) do
    receive do
      {:ws_send, term} ->
        :gen_tcp.send(sock, ws_encode_binary(:erlang.term_to_binary(term)))
        ws_loop(sock, test_pid)
    after
      0 ->
        case :gen_tcp.recv(sock, 0, 50) do
          {:ok, data} ->
            data
            |> ws_decode_frames()
            |> Enum.each(fn
              {:binary, payload} ->
                case :erlang.binary_to_term(payload, [:safe]) do
                  term -> send(test_pid, {:ws_server_received, term})
                end

              {:ping, _} ->
                :gen_tcp.send(sock, ws_encode_pong())

              {:close, _} ->
                :ok

              _ ->
                :ok
            end)

            ws_loop(sock, test_pid)

          {:error, :timeout} ->
            ws_loop(sock, test_pid)

          {:error, _} ->
            :ok
        end
    end
  end

  # Encode a server→client binary frame (no masking for server frames per RFC 6455).
  defp ws_encode_binary(payload) do
    len = byte_size(payload)

    header =
      cond do
        len <= 125 -> <<0b10000010, len>>
        len <= 65_535 -> <<0b10000010, 126, len::16>>
        true -> <<0b10000010, 127, len::64>>
      end

    header <> payload
  end

  defp ws_encode_pong, do: <<0b10001010, 0>>

  # Decode zero or more WS frames from a binary blob (client→server, possibly masked).
  defp ws_decode_frames(data), do: ws_decode_frames(data, [])

  defp ws_decode_frames(<<>>, acc), do: Enum.reverse(acc)

  defp ws_decode_frames(<<fin_op, mask_len, rest::binary>>, acc) do
    opcode = band(fin_op, 0x0F)
    masked = band(mask_len, 0x80) != 0
    base_len = band(mask_len, 0x7F)

    {payload_len, rest} =
      case base_len do
        126 ->
          <<l::16, r::binary>> = rest
          {l, r}

        127 ->
          <<l::64, r::binary>> = rest
          {l, r}

        n ->
          {n, rest}
      end

    {mask_key, rest} =
      if masked do
        <<mk::4-bytes, r::binary>> = rest
        {mk, r}
      else
        {nil, rest}
      end

    <<payload::binary-size(payload_len), remainder::binary>> = rest

    data =
      if masked and mask_key != nil do
        ws_unmask(payload, mask_key)
      else
        payload
      end

    frame =
      case opcode do
        0x2 -> {:binary, data}
        0x9 -> {:ping, data}
        0xA -> {:pong, data}
        0x8 -> {:close, data}
        _ -> {:other, data}
      end

    ws_decode_frames(remainder, [frame | acc])
  end

  defp ws_decode_frames(_, acc), do: Enum.reverse(acc)

  defp ws_unmask(payload, mask_key) do
    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, idx} ->
      bxor(byte, :binary.at(mask_key, rem(idx, 4)))
    end)
    |> :binary.list_to_bin()
  end
end
