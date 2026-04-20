defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Tunnel do
  @moduledoc """
  HTTP tunnel executor for the OpenComputers direct-mode protocol.

  One GenServer for the entire session. Manages a map of active in-flight
  TCP connections: `%{req_id => %{socket, tunnel_id, bytes_in, bytes_out}}`.

  ## Wire protocol handled

    * Inbound (MIOSA → OSA):
        `{:tunnel_open_request, %{...}}` — open TCP + forward HTTP request
        `{:tunnel_request_body, %{...}}` — stream additional body chunks
        `{:tunnel_close, %{...}}`        — abort a request

    * Outbound (OSA → MIOSA):
        `{:tunnel_opened, %{...}}`           — response headers received
        `{:tunnel_response_chunk, %{...}}`   — response body chunk
        `{:tunnel_close, %{...}}`            — EOF or error close
        `{:tunnel_error, %{...}}`            — could not connect

  ## Configuration (`~/.osa/open_computers.toml`)

      [tunnel]
      enabled = true
      allowed_ports = []          # empty = all ports allowed
      max_concurrent = 20
      connect_timeout_ms = 5000
      response_timeout_ms = 30000

  ## Security
    - `allowed_ports` allowlist enforced before any TCP connect
    - `target_host` is validated to reject non-loopback addresses
    - Max `max_concurrent` simultaneous tunnels per session
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.OpenComputers.FrameRouter

  @default_connect_timeout_ms 5_000
  @default_max_concurrent 20
  @max_frame_bytes 4 * 1024 * 1024

  # ── Public API ───────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.merge([name: __MODULE__], opts))
  end

  @doc "Handle an inbound tunnel frame dispatched by FrameRouter."
  @spec handle_frame(term()) :: :ok
  def handle_frame(frame) do
    GenServer.cast(__MODULE__, {:inbound, frame})
  end

  # ── GenServer ────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{tunnels: %{}}}
  end

  @impl true
  def handle_cast({:inbound, {:tunnel_open_request, payload}}, state) do
    %{req_id: req_id, tunnel_id: tunnel_id, target_port: port} = payload
    target_host = Map.get(payload, :target_host, "127.0.0.1")

    cfg = read_tunnel_config()

    cond do
      not cfg.enabled ->
        send_error(tunnel_id, req_id, :tunnel_disabled)
        {:noreply, state}

      map_size(state.tunnels) >= cfg.max_concurrent ->
        send_error(tunnel_id, req_id, :too_many_tunnels)
        {:noreply, state}

      not port_allowed?(port, cfg.allowed_ports) ->
        Logger.warning("[Tunnel] port #{port} not in allowed_ports — rejected")
        send_error(tunnel_id, req_id, :target_not_allowed)
        {:noreply, state}

      not safe_target_host?(target_host) ->
        Logger.warning("[Tunnel] non-loopback target_host=#{target_host} rejected")
        send_error(tunnel_id, req_id, :target_not_allowed)
        {:noreply, state}

      true ->
        self_pid = self()

        Task.start(fn ->
          do_open_tunnel(self_pid, payload, cfg)
        end)

        {:noreply, state}
    end
  end

  def handle_cast({:inbound, {:tunnel_request_body, %{req_id: req_id, data: data}}}, state) do
    case Map.get(state.tunnels, req_id) do
      nil ->
        Logger.debug("[Tunnel] tunnel_request_body for unknown req=#{req_id} — ignored")

      %{socket: socket} ->
        :gen_tcp.send(socket, data)
    end

    {:noreply, state}
  end

  def handle_cast({:inbound, {:tunnel_close, %{req_id: req_id}}}, state) do
    case Map.pop(state.tunnels, req_id) do
      {nil, _} ->
        {:noreply, state}

      {%{socket: socket}, tunnels} ->
        :gen_tcp.close(socket)
        {:noreply, %{state | tunnels: tunnels}}
    end
  end

  def handle_cast({:inbound, _frame}, state), do: {:noreply, state}

  # ── Called from Task when tunnel is successfully opened ──────────────────────

  def handle_cast({:tunnel_open_ok, req_id, socket, opened_frame, body_prefix}, state) do
    FrameRouter.send_frame(opened_frame)

    tunnel_id = elem(opened_frame, 1).tunnel_id

    tunnel_info = %{
      socket: socket,
      tunnel_id: tunnel_id,
      bytes_in: 0,
      bytes_out: 0
    }

    self_pid = self()

    # Spawn a reader task; pass any body bytes already buffered with the headers
    # so they are forwarded as the first chunk before we block on the next recv.
    Task.start(fn ->
      read_response_body(self_pid, socket, tunnel_id, req_id, body_prefix)
    end)

    {:noreply, put_in(state.tunnels[req_id], tunnel_info)}
  end

  def handle_cast({:tunnel_open_error, req_id, tunnel_id, reason}, state) do
    send_error(tunnel_id, req_id, reason)
    {:noreply, state}
  end

  # ── Called from reader task with response chunks ──────────────────────────────

  def handle_cast({:tunnel_chunk, req_id, data, last}, state) do
    case Map.get(state.tunnels, req_id) do
      nil ->
        {:noreply, state}

      %{tunnel_id: tid} = info ->
        FrameRouter.send_frame(
          {:tunnel_response_chunk,
           %{tunnel_id: tid, req_id: req_id, data: data, last: last}}
        )

        new_bytes_out = info.bytes_out + byte_size(data)

        state =
          if last do
            %{state | tunnels: Map.delete(state.tunnels, req_id)}
          else
            put_in(state.tunnels[req_id].bytes_out, new_bytes_out)
          end

        {:noreply, state}
    end
  end

  def handle_cast({:tunnel_eof, req_id}, state) do
    case Map.pop(state.tunnels, req_id) do
      {nil, _} ->
        {:noreply, state}

      {%{tunnel_id: tid}, tunnels} ->
        FrameRouter.send_frame(
          {:tunnel_close, %{tunnel_id: tid, req_id: req_id, reason: :eof}}
        )

        {:noreply, %{state | tunnels: tunnels}}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ── TCP connection + HTTP request in a Task ───────────────────────────────────

  defp do_open_tunnel(server_pid, payload, cfg) do
    %{
      req_id: req_id,
      tunnel_id: tunnel_id,
      method: method,
      path: path,
      headers: headers,
      body_first: body_first,
      target_port: port
    } = payload

    target_host = Map.get(payload, :target_host, "127.0.0.1") |> to_charlist()

    case :gen_tcp.connect(target_host, port, [:binary, {:active, false}, {:packet, 0}],
           cfg.connect_timeout_ms
         ) do
      {:ok, socket} ->
        request_line = "#{method} #{path} HTTP/1.1\r\n"
        host_value = Map.get_lazy(%{}, :host, fn -> "127.0.0.1:#{port}" end)

        forwarded_headers =
          headers
          |> Enum.reject(fn {name, _} -> String.downcase(name) == "host" end)
          |> Enum.map(fn {n, v} -> "#{n}: #{v}\r\n" end)
          |> IO.iodata_to_binary()

        http_request =
          request_line <>
            "Host: #{host_value}\r\n" <>
            forwarded_headers <>
            "\r\n" <>
            body_first

        case :gen_tcp.send(socket, http_request) do
          :ok ->
            # Read response headers; body_prefix holds any bytes already read
            # past the \r\n\r\n separator.
            case read_response_headers(socket, cfg.connect_timeout_ms) do
              {:ok, status, resp_headers, body_prefix} ->
                opened_frame =
                  {:tunnel_opened,
                   %{
                     tunnel_id: tunnel_id,
                     req_id: req_id,
                     status: status,
                     headers: resp_headers
                   }}

                GenServer.cast(
                  server_pid,
                  {:tunnel_open_ok, req_id, socket, opened_frame, body_prefix}
                )

              {:error, reason} ->
                :gen_tcp.close(socket)
                GenServer.cast(server_pid, {:tunnel_open_error, req_id, tunnel_id, map_error(reason)})
            end

          {:error, reason} ->
            :gen_tcp.close(socket)
            GenServer.cast(server_pid, {:tunnel_open_error, req_id, tunnel_id, map_error(reason)})
        end

      {:error, :econnrefused} ->
        GenServer.cast(server_pid, {:tunnel_open_error, req_id, tunnel_id, :connection_refused})

      {:error, :timeout} ->
        GenServer.cast(server_pid, {:tunnel_open_error, req_id, tunnel_id, :timeout})

      {:error, reason} ->
        Logger.warning("[Tunnel] connect error port=#{port}: #{inspect(reason)}")
        GenServer.cast(server_pid, {:tunnel_open_error, req_id, tunnel_id, map_error(reason)})
    end
  end

  # Read HTTP response headers in raw binary mode (no :packet helper, handles both
  # HTTP/1.0 and HTTP/1.1 including chunked transfer-encoding).
  defp read_response_headers(socket, timeout_ms) do
    read_until_header_end(socket, "", timeout_ms)
  end

  # Returns {:ok, status, headers, body_prefix} where body_prefix is any bytes
  # already read past the \r\n\r\n separator.  Callers must forward body_prefix
  # as the first chunk rather than discarding it — this is critical when the
  # upstream server closes the connection immediately after sending (e.g. HTTP/1.0
  # or a simple test echo server), otherwise the body reader sees only :closed.
  defp read_until_header_end(socket, acc, timeout_ms) do
    if byte_size(acc) > 65_536 do
      {:error, :headers_too_large}
    else
      case :gen_tcp.recv(socket, 0, timeout_ms) do
        {:ok, data} ->
          combined = acc <> data

          case :binary.split(combined, "\r\n\r\n") do
            [header_part, body_prefix] ->
              case parse_response_headers(header_part) do
                {:ok, status, headers} -> {:ok, status, headers, body_prefix}
                error -> error
              end

            [_] ->
              read_until_header_end(socket, combined, timeout_ms)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp parse_response_headers(header_text) do
    [status_line | header_lines] = String.split(header_text, "\r\n")

    with [_, code, _] <- String.split(status_line, " ", parts: 3),
         {status, ""} <- Integer.parse(code) do
      headers =
        header_lines
        |> Enum.flat_map(fn line ->
          case String.split(line, ": ", parts: 2) do
            [name, value] -> [{String.downcase(name), value}]
            _ -> []
          end
        end)

      {:ok, status, headers}
    else
      _ -> {:error, :bad_response}
    end
  rescue
    _ -> {:error, :parse_error}
  end

  # Stream response body back to server in chunks.
  # body_prefix: bytes already read past the header separator — emit as first
  # chunk before blocking on the next recv.  Empty string means no prefix.
  defp read_response_body(server_pid, socket, tunnel_id, req_id, body_prefix \\ "") do
    # Emit any bytes that were buffered together with the response headers.
    if byte_size(body_prefix) > 0 do
      for chunk <- split_into_frames(body_prefix) do
        GenServer.cast(server_pid, {:tunnel_chunk, req_id, chunk, false})
      end
    end

    do_read_response_body(server_pid, socket, tunnel_id, req_id)
  end

  defp do_read_response_body(server_pid, socket, tunnel_id, req_id) do
    case :gen_tcp.recv(socket, 0, 60_000) do
      {:ok, data} ->
        # Forward in max-frame-sized pieces; never mark last=true here because
        # we don't know if more data follows until we get :closed.
        for chunk <- split_into_frames(data) do
          GenServer.cast(server_pid, {:tunnel_chunk, req_id, chunk, false})
        end

        do_read_response_body(server_pid, socket, tunnel_id, req_id)

      {:error, :closed} ->
        :gen_tcp.close(socket)
        GenServer.cast(server_pid, {:tunnel_eof, req_id})

      {:error, reason} ->
        Logger.debug("[Tunnel] body read end req=#{req_id}: #{inspect(reason)}")
        :gen_tcp.close(socket)
        GenServer.cast(server_pid, {:tunnel_eof, req_id})
    end
  end

  defp split_into_frames(data) when byte_size(data) <= @max_frame_bytes, do: [data]

  defp split_into_frames(data) do
    <<chunk::binary-size(@max_frame_bytes), rest::binary>> = data
    [chunk | split_into_frames(rest)]
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  defp send_error(tunnel_id, req_id, reason) do
    FrameRouter.send_frame(
      {:tunnel_error, %{tunnel_id: tunnel_id, req_id: req_id, reason: reason}}
    )
  end

  defp port_allowed?(_port, []), do: true
  defp port_allowed?(port, allowed), do: port in allowed

  # Only allow loopback and private ranges as targets — never expose external services
  defp safe_target_host?("127.0.0.1"), do: true
  defp safe_target_host?("localhost"), do: true
  defp safe_target_host?("::1"), do: true

  defp safe_target_host?(host) when is_binary(host) do
    # Allow 127.x.x.x range
    String.starts_with?(host, "127.")
  end

  defp safe_target_host?(_), do: false

  defp map_error(:econnrefused), do: :connection_refused
  defp map_error(:timeout), do: :timeout
  defp map_error(_), do: :connection_refused

  defp read_tunnel_config do
    base = %{
      enabled: true,
      allowed_ports: [],
      max_concurrent: @default_max_concurrent,
      connect_timeout_ms: @default_connect_timeout_ms
    }

    config_dir =
      Application.get_env(:optimal_system_agent, :config_dir, "~/.osa")
      |> Path.expand()

    path = Path.join(config_dir, "open_computers.toml")

    case File.read(path) do
      {:ok, content} ->
        # Simple TOML [tunnel] section parser — no library dependency
        parse_tunnel_section(content, base)

      _ ->
        base
    end
  end

  defp parse_tunnel_section(content, base) do
    in_tunnel = String.contains?(content, "[tunnel]")

    if not in_tunnel do
      base
    else
      # Extract [tunnel] section lines
      lines =
        content
        |> String.split("\n")
        |> Enum.drop_while(&(&1 != "[tunnel]"))
        |> Enum.drop(1)
        |> Enum.take_while(&(not String.starts_with?(&1, "[")))

      Enum.reduce(lines, base, fn line, acc ->
        case String.split(line, "=", parts: 2) do
          [key, value] ->
            key = String.trim(key)
            value = String.trim(value)
            apply_config_key(acc, key, value)

          _ ->
            acc
        end
      end)
    end
  end

  defp apply_config_key(cfg, "enabled", "false"), do: %{cfg | enabled: false}
  defp apply_config_key(cfg, "enabled", "true"), do: %{cfg | enabled: true}

  defp apply_config_key(cfg, "max_concurrent", value) do
    case Integer.parse(value) do
      {n, _} when n > 0 -> %{cfg | max_concurrent: n}
      _ -> cfg
    end
  end

  defp apply_config_key(cfg, "connect_timeout_ms", value) do
    case Integer.parse(value) do
      {n, _} when n > 0 -> %{cfg | connect_timeout_ms: n}
      _ -> cfg
    end
  end

  defp apply_config_key(cfg, "allowed_ports", value) do
    # Parse "[3000, 8080]" or "3000, 8080"
    ports =
      value
      |> String.trim_leading("[")
      |> String.trim_trailing("]")
      |> String.split(",")
      |> Enum.flat_map(fn s ->
        case Integer.parse(String.trim(s)) do
          {n, _} when n > 0 and n < 65_536 -> [n]
          _ -> []
        end
      end)

    %{cfg | allowed_ports: ports}
  end

  defp apply_config_key(cfg, _key, _value), do: cfg
end
