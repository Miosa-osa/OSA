defmodule OptimalSystemAgent.Net.PortTest do
  @moduledoc """
  Coverage for the shared port helper that boot preflight, `osa doctor`, and
  onboarding all rely on. These prove `available?/1` actually flips when a
  socket grabs the port, and that `holder_kind/1` classifies free/foreign
  correctly (the `:osa` branch is exercised via the `/health` marker probe).
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Net.Port

  describe "configured_http_port/0" do
    setup do
      prev_env = System.get_env("OSA_HTTP_PORT")
      prev_launcher_env = System.get_env("OSA_PORT")
      prev_app = Application.get_env(:optimal_system_agent, :http_port)

      on_exit(fn ->
        if prev_env,
          do: System.put_env("OSA_HTTP_PORT", prev_env),
          else: System.delete_env("OSA_HTTP_PORT")

        if prev_launcher_env,
          do: System.put_env("OSA_PORT", prev_launcher_env),
          else: System.delete_env("OSA_PORT")

        if prev_app,
          do: Application.put_env(:optimal_system_agent, :http_port, prev_app),
          else: Application.delete_env(:optimal_system_agent, :http_port)
      end)

      :ok
    end

    test "OSA_HTTP_PORT env wins" do
      System.put_env("OSA_PORT", "12344")
      System.put_env("OSA_HTTP_PORT", "12345")
      assert Port.configured_http_port() == 12_345
    end

    test "OSA_PORT is accepted as a launcher-compatible alias" do
      System.delete_env("OSA_HTTP_PORT")
      System.put_env("OSA_PORT", "12346")
      assert Port.configured_http_port() == 12_346
    end

    test "falls back to app-env :http_port when env is unset" do
      System.delete_env("OSA_HTTP_PORT")
      System.delete_env("OSA_PORT")
      Application.put_env(:optimal_system_agent, :http_port, 23456)
      assert Port.configured_http_port() == 23_456
    end

    test "defaults to 9089 when nothing is configured" do
      System.delete_env("OSA_HTTP_PORT")
      System.delete_env("OSA_PORT")
      Application.delete_env(:optimal_system_agent, :http_port)
      assert Port.configured_http_port() == 9089
    end

    test "a non-integer OSA_HTTP_PORT degrades to the default instead of raising" do
      System.put_env("OSA_HTTP_PORT", "not-a-port")
      System.delete_env("OSA_PORT")
      Application.delete_env(:optimal_system_agent, :http_port)
      assert Port.configured_http_port() == 9089
    end

    test "an invalid OSA_HTTP_PORT falls through to a valid OSA_PORT alias" do
      System.put_env("OSA_HTTP_PORT", "not-a-port")
      System.put_env("OSA_PORT", "12347")
      assert Port.configured_http_port() == 12_347
    end
  end

  describe "available?/1" do
    test "reports a free port as available, then flips to unavailable once bound" do
      # Grab an ephemeral port to learn a concrete free port number.
      {:ok, probe} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
      {:ok, port} = :inet.port(probe)
      :gen_tcp.close(probe)

      assert Port.available?(port), "expected freshly-released port #{port} to be available"

      # Now hold it and prove the helper flips.
      {:ok, holder} = :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, active: false])
      refute Port.available?(port), "expected held port #{port} to be unavailable"

      :gen_tcp.close(holder)
    end

    test "port 0 (ephemeral) is always available" do
      assert Port.available?(0)
    end

    # Regression: the preflight must mirror Bandit's bind, not be stricter than
    # it. ThousandIsland.Transports.TCP hard-defaults `reuseaddr: true`, so a
    # TIME_WAIT left behind by a closed CLIENT connection does NOT stop Bandit
    # from binding. When `available?/1` omitted `reuseaddr` it reported such a
    # port as occupied, and boot aborted with "Port 9089 is in use by another
    # process" seconds after a restart, with nothing listening at all.
    #
    # The fixture MUST create its listener with `reuseaddr: true`, exactly as
    # ThousandIsland does. Linux's `inet_csk_bind_conflict` only lets a new bind
    # step over a TIME_WAIT when SO_REUSEADDR is set on BOTH sockets: the one
    # binding now AND the one that left the TIME_WAIT behind. An accepted socket
    # inherits `sk_reuse` from its listener, so in production the lingering entry
    # on :9089 carries reuse=1 (ThousandIsland's default) and the rebind succeeds.
    # A fixture that listens without `reuseaddr` leaves a reuse=0 TIME_WAIT, which
    # no bind can ever step over — it would assert something the kernel never
    # promised, and fail regardless of whether `available?/1` is correct.
    test "a TIME_WAIT from a closed client connection does not mark the port occupied" do
      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

      {:ok, port} = :inet.port(listener)

      {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      {:ok, accepted} = :gen_tcp.accept(listener, 1_000)

      # The SERVER side must close first. TIME_WAIT lands on whichever peer
      # performs the active close, and it is the dying backend that closes its
      # accepted sockets - which is why the real netstat shows the lingering
      # entry on local port 9089 rather than on the client's ephemeral port.
      :gen_tcp.close(accepted)
      :gen_tcp.close(listener)
      :gen_tcp.close(client)

      assert Port.available?(port),
             "expected port #{port} to be bindable despite a lingering TIME_WAIT"
    end

    # The other half of the same contract: `reuseaddr` must not make the check
    # blind. SO_REUSEADDR never permits binding over an actively LISTENing
    # socket, so a genuinely occupied port is still reported occupied.
    test "reuseaddr does not hide an actively listening socket" do
      {:ok, holder} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
      {:ok, port} = :inet.port(holder)

      refute Port.available?(port),
             "expected an actively listening port #{port} to still be detected"

      :gen_tcp.close(holder)
    end
  end

  describe "holder_kind/1" do
    test "classifies a free port as :free" do
      {:ok, probe} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
      {:ok, port} = :inet.port(probe)
      :gen_tcp.close(probe)

      assert Port.holder_kind(port) == :free
    end

    test "classifies a non-OSA listener as :foreign" do
      # A bare TCP listener that never speaks OSA's /health JSON.
      {:ok, holder} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
      {:ok, port} = :inet.port(holder)

      assert Port.holder_kind(port) == :foreign

      :gen_tcp.close(holder)
    end

    test "classifies a server that returns OSA's /health markers as :osa" do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

      {:ok, port} = :inet.port(listen)

      # Minimal fake OSA: accept one connection and reply with the /health
      # markers holder_kind/1 sniffs for.
      task =
        Task.async(fn ->
          {:ok, conn} = :gen_tcp.accept(listen, 2_000)
          _ = :gen_tcp.recv(conn, 0, 1_000)
          body = ~s({"status":"ok","uptime_seconds":42})

          :gen_tcp.send(
            conn,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" <>
              "Content-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <> body
          )

          :gen_tcp.close(conn)
        end)

      assert Port.holder_kind(port) == :osa

      Task.await(task, 3_000)
      :gen_tcp.close(listen)
    end
  end
end
