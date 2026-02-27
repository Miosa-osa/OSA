defmodule OptimalSystemAgent.Channels.HTTP.Integrity do
  @moduledoc """
  HMAC-SHA256 request body integrity verification.

  Verifies: X-OSA-Signature, X-OSA-Timestamp (5min window), X-OSA-Nonce (ETS dedup).
  Enabled when `require_auth: true`.
  """
  import Plug.Conn
  @behaviour Plug

  @nonce_table :osa_integrity_nonces
  # 5 minutes
  @timestamp_window 300
  # 1 minute
  @reap_interval 60_000

  def init(opts), do: opts

  def call(conn, _opts) do
    if Application.get_env(:optimal_system_agent, :require_auth, false) do
      verify_integrity(conn)
    else
      conn
    end
  end

  @doc "Start the nonce ETS table and reaper. Called from application startup or on first use."
  def ensure_table do
    case :ets.whereis(@nonce_table) do
      :undefined ->
        :ets.new(@nonce_table, [:set, :public, :named_table])
        schedule_reap()

      _ ->
        :ok
    end
  end

  defp verify_integrity(conn) do
    ensure_table()

    with {:ok, signature} <- get_header(conn, "x-osa-signature"),
         {:ok, timestamp_str} <- get_header(conn, "x-osa-timestamp"),
         {:ok, nonce} <- get_header(conn, "x-osa-nonce"),
         {:ok, timestamp} <- parse_timestamp(timestamp_str),
         :ok <- check_freshness(timestamp),
         :ok <- check_nonce(nonce),
         {:ok, body} <- read_cached_body(conn),
         :ok <- verify_signature(signature, timestamp_str, nonce, body) do
      record_nonce(nonce, timestamp)
      conn
    else
      {:error, reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "integrity_check_failed", details: reason}))
        |> halt()
    end
  end

  defp get_header(conn, header) do
    case get_req_header(conn, header) do
      [value | _] when value != "" -> {:ok, value}
      _ -> {:error, "Missing header: #{header}"}
    end
  end

  defp parse_timestamp(str) do
    case Integer.parse(str) do
      {ts, ""} -> {:ok, ts}
      _ -> {:error, "Invalid timestamp format"}
    end
  end

  defp check_freshness(timestamp) do
    now = System.system_time(:second)

    if abs(now - timestamp) <= @timestamp_window do
      :ok
    else
      {:error, "Timestamp expired (#{@timestamp_window}s window)"}
    end
  end

  defp check_nonce(nonce) do
    case :ets.lookup(@nonce_table, nonce) do
      [] -> :ok
      _ -> {:error, "Nonce already used"}
    end
  end

  defp record_nonce(nonce, timestamp) do
    :ets.insert(@nonce_table, {nonce, timestamp})
  end

  defp read_cached_body(conn) do
    # Plug.Parsers caches the raw body if we configure it
    # Fall back to reading body_params as JSON
    body = conn.assigns[:raw_body] || Jason.encode!(conn.body_params || %{})
    {:ok, body}
  end

  defp verify_signature(signature, timestamp, nonce, body) do
    secret = Application.get_env(:optimal_system_agent, :shared_secret, "")

    if secret == "" or is_nil(secret) do
      {:error, "HMAC secret not configured — set OSA_SHARED_SECRET"}
    else
      payload = timestamp <> "\n" <> nonce <> "\n" <> body
      expected = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)

      if Plug.Crypto.secure_compare(expected, signature) do
        :ok
      else
        {:error, "Invalid signature"}
      end
    end
  end

  @doc false
  def handle_info(:reap_nonces, _) do
    reap_expired()
    schedule_reap()
    :ok
  end

  defp reap_expired do
    cutoff = System.system_time(:second) - @timestamp_window

    case :ets.whereis(@nonce_table) do
      :undefined ->
        :ok

      _ ->
        :ets.foldl(
          fn {nonce, ts}, acc ->
            if ts < cutoff, do: :ets.delete(@nonce_table, nonce)
            acc
          end,
          :ok,
          @nonce_table
        )
    end
  rescue
    _ -> :ok
  end

  defp schedule_reap do
    # Use :timer.apply_interval for crash-safe periodic reaping
    # (unlike a raw spawn chain, this survives if reap_expired raises)
    :timer.apply_interval(@reap_interval, __MODULE__, :do_reap, [])
  end

  @doc false
  def do_reap, do: reap_expired()
end
