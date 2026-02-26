defmodule OptimalSystemAgent.Channels.HTTP.AuthTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Channels.HTTP.Auth

  # The module falls back to the compile-time default when no env var is set.
  # We test against that known default to keep tests hermetic.
  @default_secret "osa-dev-secret-change-me"

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_claims(overrides \\ %{}) do
    now = System.system_time(:second)
    Map.merge(%{"user_id" => "user-test-1", "iat" => now, "exp" => now + 900}, overrides)
  end

  defp forge_token(header, payload, secret) do
    header_b64 = Base.url_encode64(Jason.encode!(header), padding: false)
    payload_b64 = Base.url_encode64(Jason.encode!(payload), padding: false)
    sig = :crypto.mac(:hmac, :sha256, secret, "#{header_b64}.#{payload_b64}")
    sig_b64 = Base.url_encode64(sig, padding: false)
    "#{header_b64}.#{payload_b64}.#{sig_b64}"
  end

  # ---------------------------------------------------------------------------
  # generate_token/1
  # ---------------------------------------------------------------------------

  describe "generate_token/1" do
    test "returns a binary string token" do
      token = Auth.generate_token(build_claims())

      assert is_binary(token)
    end

    test "token has three dot-separated segments (JWT structure)" do
      token = Auth.generate_token(build_claims())
      parts = String.split(token, ".")

      assert length(parts) == 3
    end

    test "header segment decodes to HS256 algorithm" do
      [header_b64 | _] = Auth.generate_token(build_claims()) |> String.split(".")
      {:ok, json} = Base.url_decode64(header_b64, padding: false)
      {:ok, header} = Jason.decode(json)

      assert header["alg"] == "HS256"
      assert header["typ"] == "JWT"
    end

    test "payload segment contains supplied claims" do
      claims = %{"user_id" => "user-abc", "role" => "admin"}
      [_, payload_b64 | _] = Auth.generate_token(claims) |> String.split(".")
      {:ok, json} = Base.url_decode64(payload_b64, padding: false)
      {:ok, decoded} = Jason.decode(json)

      assert decoded["user_id"] == "user-abc"
      assert decoded["role"] == "admin"
    end

    test "adds 'iat' claim when not provided" do
      [_, payload_b64 | _] = Auth.generate_token(%{"user_id" => "u1"}) |> String.split(".")
      {:ok, json} = Base.url_decode64(payload_b64, padding: false)
      {:ok, decoded} = Jason.decode(json)

      assert is_integer(decoded["iat"])
    end

    test "adds 'exp' claim when not provided (defaults to 900s)" do
      before = System.system_time(:second)
      [_, payload_b64 | _] = Auth.generate_token(%{"user_id" => "u1"}) |> String.split(".")
      {:ok, json} = Base.url_decode64(payload_b64, padding: false)
      {:ok, decoded} = Jason.decode(json)
      after_gen = System.system_time(:second)

      assert decoded["exp"] >= before + 900
      assert decoded["exp"] <= after_gen + 900
    end

    test "does not override 'iat' when already present in claims" do
      custom_iat = 1_700_000_000
      [_, payload_b64 | _] =
        Auth.generate_token(%{"user_id" => "u1", "iat" => custom_iat}) |> String.split(".")

      {:ok, json} = Base.url_decode64(payload_b64, padding: false)
      {:ok, decoded} = Jason.decode(json)

      assert decoded["iat"] == custom_iat
    end

    test "does not override 'exp' when already present in claims" do
      custom_exp = 9_999_999_999
      [_, payload_b64 | _] =
        Auth.generate_token(%{"user_id" => "u1", "exp" => custom_exp}) |> String.split(".")

      {:ok, json} = Base.url_decode64(payload_b64, padding: false)
      {:ok, decoded} = Jason.decode(json)

      assert decoded["exp"] == custom_exp
    end

    test "two tokens generated for same claims at different times differ" do
      claims = %{"user_id" => "u1"}
      token1 = Auth.generate_token(claims)
      Process.sleep(1100)
      token2 = Auth.generate_token(claims)

      # iat differs by at least 1 second, so payloads (and signatures) differ
      refute token1 == token2
    end
  end

  # ---------------------------------------------------------------------------
  # verify_token/1 — valid token
  # ---------------------------------------------------------------------------

  describe "verify_token/1 with valid token" do
    test "returns {:ok, claims} for a freshly generated token" do
      token = Auth.generate_token(%{"user_id" => "user-123"})
      result = Auth.verify_token(token)

      assert {:ok, claims} = result
      assert claims["user_id"] == "user-123"
    end

    test "returned claims include 'iat' and 'exp'" do
      token = Auth.generate_token(%{"user_id" => "user-123"})
      {:ok, claims} = Auth.verify_token(token)

      assert is_integer(claims["iat"])
      assert is_integer(claims["exp"])
    end

    test "verifies a token without an 'exp' claim (no expiration)" do
      # Build a token manually with no exp claim
      now = System.system_time(:second)
      claims = %{"user_id" => "u1", "iat" => now}
      token = forge_token(%{"alg" => "HS256", "typ" => "JWT"}, claims, @default_secret)

      assert {:ok, _} = Auth.verify_token(token)
    end

    test "round-trip: generate then verify preserves custom claims" do
      original = %{"user_id" => "u42", "scope" => "read:all", "role" => "admin"}
      token = Auth.generate_token(original)
      {:ok, claims} = Auth.verify_token(token)

      assert claims["user_id"] == "u42"
      assert claims["scope"] == "read:all"
      assert claims["role"] == "admin"
    end
  end

  # ---------------------------------------------------------------------------
  # verify_token/1 — expired token
  # ---------------------------------------------------------------------------

  describe "verify_token/1 with expired token" do
    test "returns {:error, :invalid_token} for token whose 'exp' is in the past" do
      past_exp = System.system_time(:second) - 1
      claims = %{"user_id" => "u1", "iat" => past_exp - 900, "exp" => past_exp}
      token = forge_token(%{"alg" => "HS256", "typ" => "JWT"}, claims, @default_secret)

      assert {:error, :invalid_token} = Auth.verify_token(token)
    end

    test "returns error for token expired far in the past" do
      claims = %{"user_id" => "u1", "exp" => 1_000_000}
      token = forge_token(%{"alg" => "HS256", "typ" => "JWT"}, claims, @default_secret)

      assert {:error, :invalid_token} = Auth.verify_token(token)
    end

    test "token expiring 1 second from now is still valid" do
      exp = System.system_time(:second) + 1
      claims = %{"user_id" => "u1", "exp" => exp}
      token = forge_token(%{"alg" => "HS256", "typ" => "JWT"}, claims, @default_secret)

      assert {:ok, _} = Auth.verify_token(token)
    end
  end

  # ---------------------------------------------------------------------------
  # verify_token/1 — tampered token
  # ---------------------------------------------------------------------------

  describe "verify_token/1 with tampered token" do
    test "returns {:error, :invalid_token} when payload is base64-swapped" do
      token = Auth.generate_token(%{"user_id" => "user-good"})
      [header, _payload, sig] = String.split(token, ".")

      # Swap in a different payload with elevated privileges
      evil_claims = %{"user_id" => "admin", "role" => "superuser"}
      evil_payload = Base.url_encode64(Jason.encode!(evil_claims), padding: false)
      tampered = "#{header}.#{evil_payload}.#{sig}"

      assert {:error, :invalid_token} = Auth.verify_token(tampered)
    end

    test "returns {:error, :invalid_token} when header is replaced" do
      token = Auth.generate_token(%{"user_id" => "u1"})
      [_header, payload, sig] = String.split(token, ".")

      evil_header = Base.url_encode64(Jason.encode!(%{"alg" => "none", "typ" => "JWT"}), padding: false)
      tampered = "#{evil_header}.#{payload}.#{sig}"

      assert {:error, :invalid_token} = Auth.verify_token(tampered)
    end

    test "returns {:error, :invalid_token} when a single bit is flipped in the signature" do
      token = Auth.generate_token(%{"user_id" => "u1"})
      [header, payload, sig] = String.split(token, ".")

      # Corrupt the signature by appending an extra character
      tampered = "#{header}.#{payload}.#{sig}X"

      assert {:error, :invalid_token} = Auth.verify_token(tampered)
    end

    test "returns {:error, :invalid_token} when signature segment is empty" do
      token = Auth.generate_token(%{"user_id" => "u1"})
      [header, payload, _sig] = String.split(token, ".")

      tampered = "#{header}.#{payload}."

      assert {:error, :invalid_token} = Auth.verify_token(tampered)
    end

    test "returns {:error, :invalid_token} for completely malformed token string" do
      assert {:error, :invalid_token} = Auth.verify_token("not.a.jwt.at.all.extra")
    end

    test "returns {:error, :invalid_token} for empty string" do
      assert {:error, :invalid_token} = Auth.verify_token("")
    end

    test "returns {:error, :invalid_token} for a token with only two segments" do
      assert {:error, :invalid_token} = Auth.verify_token("header.payload")
    end

    test "returns {:error, :invalid_token} for random garbage" do
      assert {:error, :invalid_token} = Auth.verify_token("xxxxxx")
    end
  end

  # ---------------------------------------------------------------------------
  # verify_token/1 — wrong secret
  # ---------------------------------------------------------------------------

  describe "verify_token/1 with wrong secret" do
    test "returns {:error, :invalid_token} when signed with a different secret" do
      claims = build_claims()
      token = forge_token(%{"alg" => "HS256", "typ" => "JWT"}, claims, "wrong-secret")

      assert {:error, :invalid_token} = Auth.verify_token(token)
    end

    test "returns {:error, :invalid_token} for empty secret" do
      claims = build_claims()
      token = forge_token(%{"alg" => "HS256", "typ" => "JWT"}, claims, "")

      assert {:error, :invalid_token} = Auth.verify_token(token)
    end

    test "returns {:error, :invalid_token} when secret is off by one character" do
      claims = build_claims()
      token = forge_token(%{"alg" => "HS256", "typ" => "JWT"}, claims, @default_secret <> "!")

      assert {:error, :invalid_token} = Auth.verify_token(token)
    end

    test "a token generated by verify_token's own secret IS valid (regression guard)" do
      token = Auth.generate_token(%{"user_id" => "u1"})

      assert {:ok, _} = Auth.verify_token(token)
    end
  end
end
