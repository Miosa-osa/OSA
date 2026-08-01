defmodule OptimalSystemAgent.Channels.HTTP.RateLimiter do
  import Bitwise

  @moduledoc """
  Token-bucket rate limiting plug backed by ETS.

  No external dependencies. Uses `:osa_rate_limits` ETS table keyed by
  client IP. Two limits are enforced:

    - Auth paths (`/api/v1/auth/`): 10 requests per minute
    - All other paths:              60 requests per minute

  The table is initialised lazily on first call and a periodic cleanup
  process removes stale entries every 5 minutes (entries older than
  10 minutes).

  ETS row schema: {ip_string, token_count, last_refill_unix_seconds}
  """
  @behaviour Plug

  require Logger

  import Plug.Conn

  @table :osa_rate_limits

  # Limits
  @default_limit 60
  @auth_limit 10
  @window_seconds 60

  # Cleanup
  @cleanup_interval_ms 5 * 60 * 1_000
  @stale_threshold_seconds 10 * 60

  # ── Plug callbacks ──────────────────────────────────────────────────────

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    normalized = normalize_ip(conn.remote_ip)

    # Loopback is the trusted local TUI/SDK — the only client when the backend
    # binds to 127.0.0.1 (the default). It legitimately bursts many requests on
    # attach (session create, command execute, event polling), so a 60/min cap
    # throttles the app into unusability against itself. Rate limiting exists to
    # bound REMOTE abuse (relevant only when OSA_HTTP_IP exposes the port), so
    # skip it entirely for loopback — mirroring the "open-access on loopback"
    # posture the auth layer already takes.
    if loopback?(normalized) do
      conn
    else
      ensure_table()
      ip = format_ip(normalized)
      limit = limit_for_path(conn.request_path)

      consume(conn, ip, limit, now(opts))
    end
  end

  # The bucket's notion of "now" (unix seconds). Injectable via the plug opts so
  # tests can freeze or step the clock instead of racing the wall clock: the
  # proportional refill below hands back a whole token per elapsed second at the
  # 60/min limit, so a drain that merely straddles a second tick silently gets an
  # extra request. Production passes no `:clock` and keeps the system clock.
  defp now(opts) when is_list(opts) do
    case Keyword.get(opts, :clock) do
      nil -> unix_now()
      fun when is_function(fun, 0) -> fun.()
    end
  end

  defp now(_opts), do: unix_now()

  defp consume(conn, ip, limit, now) do
    case check_and_consume(ip, limit, now) do
      {:ok, remaining} ->
        conn
        |> put_resp_header("x-ratelimit-limit", Integer.to_string(limit))
        |> put_resp_header("x-ratelimit-remaining", Integer.to_string(remaining))

      {:error, :rate_limited} ->
        Logger.warning("[RateLimiter] 429 for #{ip} on #{conn.request_path}")

        body = Jason.encode!(%{error: "rate_limited", message: "Too many requests"})

        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("retry-after", Integer.to_string(@window_seconds))
        |> put_resp_header("x-ratelimit-limit", Integer.to_string(limit))
        |> put_resp_header("x-ratelimit-remaining", "0")
        |> send_resp(429, body)
        |> halt()
    end
  end

  # ── Token bucket ────────────────────────────────────────────────────────

  defp check_and_consume(ip, limit, now) do
    case :ets.lookup(@table, ip) do
      [] ->
        # First request: full bucket minus this one
        :ets.insert(@table, {ip, limit - 1, now})
        {:ok, limit - 1}

      [{^ip, tokens, last_refill}] ->
        tokens_after_refill = refill(tokens, limit, last_refill, now)

        if tokens_after_refill > 0 do
          new_count = tokens_after_refill - 1
          :ets.insert(@table, {ip, new_count, now})
          {:ok, new_count}
        else
          {:error, :rate_limited}
        end
    end
  end

  # Refill proportionally to elapsed time within the window.
  defp refill(current_tokens, limit, last_refill, now) do
    elapsed = now - last_refill

    if elapsed >= @window_seconds do
      # Full window elapsed: reset to full
      limit
    else
      # Partial refill: add tokens proportional to elapsed fraction
      refill_amount = trunc(elapsed / @window_seconds * limit)
      min(current_tokens + refill_amount, limit)
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp limit_for_path("/api/v1/auth/" <> _), do: @auth_limit
  defp limit_for_path("/api/v1/platform/auth/" <> _), do: @auth_limit
  defp limit_for_path(_), do: @default_limit

  # 127.0.0.0/8 and IPv6 ::1 (IPv4-mapped loopback already normalized above).
  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip({a, b, c, d, e, f, g, h}), do: "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
  defp format_ip(other), do: inspect(other)
  # Normalize IPv4-mapped IPv6 addresses (::ffff:x.x.x.x) to plain IPv4 tuples
  # so that connections arriving over IPv6 with an IPv4 source are keyed
  # identically to the same source arriving over a native IPv4 socket.
  defp normalize_ip({0, 0, 0, 0, 0, 65535, a, b}) do
    {a >>> 8, a &&& 0xFF, b >>> 8, b &&& 0xFF}
  end

  defp normalize_ip(ip), do: ip

  defp unix_now, do: System.system_time(:second)

  # ── ETS lifecycle ───────────────────────────────────────────────────────

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, {:write_concurrency, true}])
        spawn_cleanup_loop()

      _tid ->
        :ok
    end
  rescue
    # Race: two callers hit ensure_table simultaneously; second create fails.
    # That's fine — the table exists at this point.
    ArgumentError -> :ok
  end

  defp spawn_cleanup_loop do
    # Decouple the periodic reaper from the transient request process that first
    # created the table. :timer.apply_interval is owned by the :timer server, so
    # reaping survives any request-process death. spawn_link (the old approach)
    # linked the reaper to one Plug connection process; when that connection was
    # killed the reaper died and never respawned, so stale entries accumulated
    # one-per-IP forever — an unbounded-memory / DoS vector.
    :timer.apply_interval(@cleanup_interval_ms, __MODULE__, :cleanup_stale, [])
  end

  @doc false
  def cleanup_stale do
    cutoff = unix_now() - @stale_threshold_seconds

    # Delete any entry whose last_refill timestamp is older than the threshold.
    # Match spec: {ip, _tokens, last_refill} where last_refill < cutoff
    ms = [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}]
    deleted = :ets.select_delete(@table, ms)

    if deleted > 0 do
      Logger.debug("[RateLimiter] Cleaned #{deleted} stale rate-limit entries")
    end
  end
end
