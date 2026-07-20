defmodule OptimalSystemAgent.Channels.HTTP.RateLimiterTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias OptimalSystemAgent.Channels.HTTP.RateLimiter

  @opts RateLimiter.init([])
  @table :osa_rate_limits

  # ── Helpers ──────────────────────────────────────────────────────────

  setup do
    # Ensure the ETS table is clean between tests so limits don't bleed across.
    case :ets.whereis(@table) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(@table)
    end

    :ok
  end

  defp call_limiter(conn) do
    RateLimiter.call(conn, @opts)
  end

  # Build a conn with a specific remote IP to simulate independent clients.
  defp conn_for_ip(path, ip_tuple) do
    conn(:get, path)
    |> Map.put(:remote_ip, ip_tuple)
  end

  # Drain N requests from the rate limiter for a given IP + path.
  defp drain(n, ip_tuple, path) do
    Enum.map(1..n, fn _ ->
      conn_for_ip(path, ip_tuple) |> call_limiter()
    end)
  end

  # ── Single request ────────────────────────────────────────────────────

  describe "single request" do
    test "passes through and sets ratelimit headers" do
      # A remote (non-loopback) IP is rate-limited and carries the headers.
      # Loopback is exempt (see the loopback test below), so it cannot be used
      # here to assert the header presence.
      conn = conn_for_ip("/sessions", {203, 0, 113, 1}) |> call_limiter()

      refute conn.halted
      assert get_resp_header(conn, "x-ratelimit-limit") == ["60"]
      assert get_resp_header(conn, "x-ratelimit-remaining") != []
    end

    test "loopback is exempt: never limited, no ratelimit headers" do
      # The backend binds to 127.0.0.1 and the only loopback client is the local
      # TUI, which bursts on attach. Loopback must never be rate-limited (it was
      # 429-ing the TUI into "Session create failed"); it also skips the headers
      # entirely since no bucket is tracked for it.
      results = drain(200, {127, 0, 0, 1}, "/sessions")

      assert Enum.all?(results, &(&1.halted == false))
      last = List.last(results)
      assert get_resp_header(last, "x-ratelimit-limit") == []
    end

    test "remaining starts at limit minus one for first request" do
      conn = conn_for_ip("/sessions", {10, 0, 0, 1}) |> call_limiter()

      assert get_resp_header(conn, "x-ratelimit-remaining") == ["59"]
    end
  end

  # ── Default path (60 req/min) ─────────────────────────────────────────

  describe "default path rate limit (60/min)" do
    test "60th request still passes" do
      ip = {192, 168, 1, 1}
      results = drain(60, ip, "/sessions")

      last = List.last(results)
      refute last.halted
      assert last.status != 429
    end

    test "61st request returns 429" do
      ip = {192, 168, 1, 2}
      drain(60, ip, "/sessions")

      conn = conn_for_ip("/sessions", ip) |> call_limiter()

      assert conn.halted
      assert conn.status == 429
    end

    test "429 response has Retry-After header set to 60" do
      ip = {192, 168, 1, 3}
      drain(60, ip, "/sessions")

      conn = conn_for_ip("/sessions", ip) |> call_limiter()

      assert get_resp_header(conn, "retry-after") == ["60"]
    end

    test "429 response body contains error and message fields" do
      ip = {192, 168, 1, 4}
      drain(60, ip, "/sessions")

      conn = conn_for_ip("/sessions", ip) |> call_limiter()
      body = Jason.decode!(conn.resp_body)

      assert body["error"] == "rate_limited"
      assert is_binary(body["message"])
    end

    test "429 response has x-ratelimit-remaining: 0" do
      ip = {192, 168, 1, 5}
      drain(60, ip, "/sessions")

      conn = conn_for_ip("/sessions", ip) |> call_limiter()

      assert get_resp_header(conn, "x-ratelimit-remaining") == ["0"]
    end
  end

  # ── Auth path (10 req/min) ────────────────────────────────────────────

  describe "auth path rate limit (10/min)" do
    test "10th auth request still passes" do
      ip = {172, 16, 0, 1}
      results = drain(10, ip, "/api/v1/auth/login")

      last = List.last(results)
      refute last.halted
    end

    test "11th auth request returns 429" do
      ip = {172, 16, 0, 2}
      drain(10, ip, "/api/v1/auth/login")

      conn = conn_for_ip("/api/v1/auth/login", ip) |> call_limiter()

      assert conn.halted
      assert conn.status == 429
    end

    test "auth limit header is set to 10" do
      ip = {172, 16, 0, 3}
      conn = conn_for_ip("/api/v1/auth/login", ip) |> call_limiter()

      assert get_resp_header(conn, "x-ratelimit-limit") == ["10"]
    end

    test "auth path exhaustion shares the IP bucket with all paths" do
      ip = {172, 16, 0, 4}
      # The rate limiter is keyed by IP only, not {IP, path}. Exhausting the
      # auth bucket (10 requests) depletes the shared token count for that IP.
      # A subsequent non-auth request from the same IP is also rate-limited.
      drain(10, ip, "/api/v1/auth/login")
      conn_auth = conn_for_ip("/api/v1/auth/login", ip) |> call_limiter()
      assert conn_auth.status == 429

      conn_non_auth = conn_for_ip("/sessions", ip) |> call_limiter()
      assert conn_non_auth.halted
    end
  end

  # ── IP independence ───────────────────────────────────────────────────

  describe "different IPs are tracked independently" do
    test "exhausting IP A does not affect IP B" do
      ip_a = {10, 10, 10, 1}
      ip_b = {10, 10, 10, 2}

      drain(60, ip_a, "/sessions")
      conn_a = conn_for_ip("/sessions", ip_a) |> call_limiter()
      assert conn_a.status == 429

      conn_b = conn_for_ip("/sessions", ip_b) |> call_limiter()
      refute conn_b.halted
    end

    test "two IPs each get their own full limit" do
      ip_a = {10, 20, 30, 1}
      ip_b = {10, 20, 30, 2}

      results_a = drain(60, ip_a, "/fleet/status")
      results_b = drain(60, ip_b, "/fleet/status")

      assert Enum.all?(results_a, fn c -> not c.halted end)
      assert Enum.all?(results_b, fn c -> not c.halted end)
    end
  end

  # ── ETS table lazily created ──────────────────────────────────────────

  describe "ETS table" do
    test "table is created on first call if missing" do
      # Forcibly remove the table if it exists, then confirm the plug recreates it.
      case :ets.whereis(@table) do
        :undefined -> :ok
        _tid -> :ets.delete(@table)
      end

      conn = conn_for_ip("/sessions", {1, 2, 3, 4}) |> call_limiter()

      refute conn.halted
      assert :ets.whereis(@table) != :undefined
    end
  end
end
