defmodule OptimalSystemAgent.Channels.HTTP.IntegrityTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias OptimalSystemAgent.Channels.HTTP.Integrity

  @secret "test-secret-key"

  setup do
    # Ensure we have a clean nonce table
    case :ets.whereis(:osa_integrity_nonces) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(:osa_integrity_nonces)
    end

    # Set require_auth and shared_secret for tests
    original_auth = Application.get_env(:optimal_system_agent, :require_auth)
    original_secret = Application.get_env(:optimal_system_agent, :shared_secret)

    Application.put_env(:optimal_system_agent, :require_auth, true)
    Application.put_env(:optimal_system_agent, :shared_secret, @secret)

    on_exit(fn ->
      if original_auth,
        do: Application.put_env(:optimal_system_agent, :require_auth, original_auth),
        else: Application.delete_env(:optimal_system_agent, :require_auth)

      if original_secret,
        do: Application.put_env(:optimal_system_agent, :shared_secret, original_secret),
        else: Application.delete_env(:optimal_system_agent, :shared_secret)
    end)

    :ok
  end

  defp sign(timestamp, nonce, body) do
    payload = "#{timestamp}\n#{nonce}\n#{body}"
    :crypto.mac(:hmac, :sha256, @secret, payload) |> Base.encode16(case: :lower)
  end

  defp build_signed_conn(body_str, opts \\ []) do
    timestamp = Keyword.get(opts, :timestamp, System.system_time(:second))

    nonce =
      Keyword.get(
        opts,
        :nonce,
        "nonce_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
      )

    signature = Keyword.get(opts, :signature, sign(to_string(timestamp), nonce, body_str))

    conn(:post, "/test", body_str)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-osa-signature", signature)
    |> put_req_header("x-osa-timestamp", to_string(timestamp))
    |> put_req_header("x-osa-nonce", nonce)
    |> assign(:raw_body, body_str)
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
  end

  describe "call/2" do
    test "valid signature passes" do
      body = ~s({"input": "hello"})
      conn = build_signed_conn(body) |> Integrity.call([])
      refute conn.halted
    end

    test "missing signature header returns 401" do
      conn =
        conn(:post, "/test", ~s({"input": "hello"}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-osa-timestamp", to_string(System.system_time(:second)))
        |> put_req_header("x-osa-nonce", "test-nonce")
        |> assign(:raw_body, ~s({"input": "hello"}))
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
        |> Integrity.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "expired timestamp returns 401" do
      body = ~s({"input": "hello"})
      # 10 min ago
      old_ts = System.system_time(:second) - 600
      conn = build_signed_conn(body, timestamp: old_ts) |> Integrity.call([])

      assert conn.halted
      assert conn.status == 401
      assert conn.resp_body =~ "expired"
    end

    test "replayed nonce returns 401" do
      body = ~s({"input": "hello"})
      nonce = "replay-nonce-test"

      # First request succeeds
      conn1 = build_signed_conn(body, nonce: nonce) |> Integrity.call([])
      refute conn1.halted

      # Second request with same nonce fails
      conn2 = build_signed_conn(body, nonce: nonce) |> Integrity.call([])
      assert conn2.halted
      assert conn2.status == 401
    end

    test "tampered body returns 401" do
      body = ~s({"input": "hello"})
      tampered = ~s({"input": "hacked"})
      ts = System.system_time(:second)
      nonce = "tamper-nonce"
      sig = sign(to_string(ts), nonce, body)

      conn =
        conn(:post, "/test", tampered)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-osa-signature", sig)
        |> put_req_header("x-osa-timestamp", to_string(ts))
        |> put_req_header("x-osa-nonce", nonce)
        |> assign(:raw_body, tampered)
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
        |> Integrity.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "disabled when require_auth is false" do
      Application.put_env(:optimal_system_agent, :require_auth, false)
      body = ~s({"input": "hello"})
      # No signature headers at all
      conn =
        conn(:post, "/test", body)
        |> put_req_header("content-type", "application/json")
        |> assign(:raw_body, body)
        |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
        |> Integrity.call([])

      refute conn.halted
    end
  end
end
