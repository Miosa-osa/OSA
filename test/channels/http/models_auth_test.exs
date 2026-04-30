defmodule OptimalSystemAgent.Channels.HTTP.ModelsAuthTest do
  @moduledoc "Tests that /models works with stale/expired tokens when require_auth=false."
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias OptimalSystemAgent.Channels.HTTP.API
  alias OptimalSystemAgent.Channels.HTTP.Auth

  @test_secret "test-secret-models-auth"

  setup do
    original_auth = Application.get_env(:optimal_system_agent, :require_auth)
    original_secret = Application.get_env(:optimal_system_agent, :shared_secret)

    # Restore both values on exit regardless of what tests set.
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

  defp call_api(conn) do
    opts = API.init([])
    API.call(conn, opts)
  end

  defp expired_token do
    header = %{"alg" => "HS256", "typ" => "JWT"}
    payload = %{"user_id" => "stale-user", "iat" => 1_000_000, "exp" => 1_000_001}
    header_b64 = Base.url_encode64(Jason.encode!(header), padding: false)
    payload_b64 = Base.url_encode64(Jason.encode!(payload), padding: false)
    sig = :crypto.mac(:hmac, :sha256, @test_secret, "#{header_b64}.#{payload_b64}")
    sig_b64 = Base.url_encode64(sig, padding: false)
    "#{header_b64}.#{payload_b64}.#{sig_b64}"
  end

  defp garbage_token, do: "not.a.valid.jwt"

  # Add HMAC integrity headers required by the Integrity plug when require_auth=true
  defp with_integrity_headers(conn) do
    timestamp = Integer.to_string(System.system_time(:second))
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    body = ""

    payload = timestamp <> "\n" <> nonce <> "\n" <> body
    signature = :crypto.mac(:hmac, :sha256, @test_secret, payload) |> Base.encode16(case: :lower)

    conn
    |> put_req_header("x-osa-signature", signature)
    |> put_req_header("x-osa-timestamp", timestamp)
    |> put_req_header("x-osa-nonce", nonce)
  end

  # ── require_auth=false (the primary bug scenario) ─────────────────
  #
  # When require_auth=false the auth plug accepts any/no token.
  # We deliberately do NOT configure a shared_secret here so the
  # Integrity plug (which auto-enables when a secret is present) stays
  # dormant — matching the real-world "local dev with no secret" setup.

  describe "GET /models with require_auth=false" do
    setup do
      Application.put_env(:optimal_system_agent, :require_auth, false)
      Application.delete_env(:optimal_system_agent, :shared_secret)
      :ok
    end

    test "succeeds without any token" do
      resp = conn(:get, "/models") |> call_api()
      refute resp.status == 401
    end

    test "succeeds with an expired token (stale TUI token)" do
      resp =
        conn(:get, "/models")
        |> put_req_header("authorization", "Bearer #{expired_token()}")
        |> call_api()

      refute resp.status == 401,
             "Expected non-401 when require_auth=false with expired token, got #{resp.status}"
    end

    test "succeeds with a garbage token" do
      resp =
        conn(:get, "/models")
        |> put_req_header("authorization", "Bearer #{garbage_token()}")
        |> call_api()

      refute resp.status == 401,
             "Expected non-401 when require_auth=false with garbage token, got #{resp.status}"
    end

    test "succeeds with a valid token" do
      token = Auth.generate_token(%{"user_id" => "real-user"})

      resp =
        conn(:get, "/models")
        |> put_req_header("authorization", "Bearer #{token}")
        |> call_api()

      refute resp.status == 401
    end
  end

  # ── require_auth=true ─────────────────────────────────────────────
  #
  # When require_auth=true both the auth plug AND the Integrity plug enforce
  # authentication.  We set a fixed shared_secret so generated tokens and
  # HMAC integrity headers are consistent within the describe block.

  describe "GET /models with require_auth=true" do
    setup do
      Application.put_env(:optimal_system_agent, :require_auth, true)
      Application.put_env(:optimal_system_agent, :shared_secret, @test_secret)
      :ok
    end

    test "returns 401 without a token" do
      resp = conn(:get, "/models") |> call_api()
      assert resp.status == 401
    end

    test "returns 401 with an expired token" do
      resp =
        conn(:get, "/models")
        |> put_req_header("authorization", "Bearer #{expired_token()}")
        |> with_integrity_headers()
        |> call_api()

      assert resp.status == 401
    end

    test "returns 401 with a garbage token" do
      resp =
        conn(:get, "/models")
        |> put_req_header("authorization", "Bearer #{garbage_token()}")
        |> with_integrity_headers()
        |> call_api()

      assert resp.status == 401
    end

    test "succeeds with a valid token and integrity headers" do
      token = Auth.generate_token(%{"user_id" => "real-user"})

      resp =
        conn(:get, "/models")
        |> put_req_header("authorization", "Bearer #{token}")
        |> with_integrity_headers()
        |> call_api()

      refute resp.status == 401
    end
  end
end
