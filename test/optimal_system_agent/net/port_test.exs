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
      prev_app = Application.get_env(:optimal_system_agent, :http_port)

      on_exit(fn ->
        if prev_env, do: System.put_env("OSA_HTTP_PORT", prev_env), else: System.delete_env("OSA_HTTP_PORT")

        if prev_app,
          do: Application.put_env(:optimal_system_agent, :http_port, prev_app),
          else: Application.delete_env(:optimal_system_agent, :http_port)
      end)

      :ok
    end

    test "OSA_HTTP_PORT env wins" do
      System.put_env("OSA_HTTP_PORT", "12345")
      assert Port.configured_http_port() == 12_345
    end

    test "falls back to app-env :http_port when env is unset" do
      System.delete_env("OSA_HTTP_PORT")
      Application.put_env(:optimal_system_agent, :http_port, 23456)
      assert Port.configured_http_port() == 23_456
    end

    test "defaults to 9089 when nothing is configured" do
      System.delete_env("OSA_HTTP_PORT")
      Application.delete_env(:optimal_system_agent, :http_port)
      assert Port.configured_http_port() == 9089
    end

    test "a non-integer OSA_HTTP_PORT degrades to the default instead of raising" do
      System.put_env("OSA_HTTP_PORT", "not-a-port")
      Application.delete_env(:optimal_system_agent, :http_port)
      assert Port.configured_http_port() == 9089
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
      {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])
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
