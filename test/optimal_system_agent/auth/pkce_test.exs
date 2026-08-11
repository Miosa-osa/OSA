defmodule OptimalSystemAgent.Auth.PKCETest do
  @moduledoc """
  RFC 7636 S256.

  The trap this file exists to avoid: a round-trip test of `generate/0`
  against `verify/2` passes just as happily on a WRONG hash, because both
  sides use the same wrong derivation. So the first assertion is against the
  RFC's own published worked example, which is the only external check
  available.
  """

  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Auth.PKCE

  describe "the S256 derivation" do
    test "matches RFC 7636 Appendix B's worked example" do
      # RFC 7636, Appendix B: the verifier and its expected challenge.
      verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
      expected = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

      assert PKCE.challenge(verifier) == expected
    end

    test "is base64url with no padding and no URL-unsafe characters" do
      challenge = PKCE.challenge("any-verifier-at-all")

      refute String.contains?(challenge, "=")
      refute String.contains?(challenge, "+")
      refute String.contains?(challenge, "/")
      # SHA-256 is 32 bytes; base64url unpadded is 43 characters.
      assert String.length(challenge) == 43
    end

    test "is deterministic for a given verifier and differs for a different one" do
      assert PKCE.challenge("a") == PKCE.challenge("a")
      refute PKCE.challenge("a") == PKCE.challenge("b")
    end
  end

  describe "generate/0" do
    test "produces RFC-legal verifiers at the maximum permitted length" do
      %PKCE{verifier: verifier, method: method} = PKCE.generate()

      # RFC 7636 section 4.1 allows 43..128 characters. This module always
      # takes the ceiling; a change that quietly shortens it fails here.
      assert String.length(verifier) == 128
      assert method == "S256"
      assert verifier =~ ~r/\A[A-Za-z0-9\-._~]+\z/
    end

    test "carries at least 32 bytes of entropy, well above the required floor" do
      %PKCE{verifier: verifier} = PKCE.generate()

      {:ok, raw} = Base.url_decode64(verifier, padding: false)
      assert byte_size(raw) >= 32
      assert byte_size(raw) == 96
    end

    test "the challenge it reports really is the challenge for its own verifier" do
      %PKCE{verifier: verifier, challenge: challenge} = PKCE.generate()

      assert challenge == PKCE.challenge(verifier)
      assert PKCE.verify(verifier, challenge)
    end

    test "every pair is fresh — a reused verifier would defeat the binding" do
      pairs = for _ <- 1..64, do: PKCE.generate().verifier

      assert length(Enum.uniq(pairs)) == 64
    end
  end

  describe "verify/2" do
    test "rejects a mismatched verifier, a truncated challenge and non-strings" do
      %PKCE{verifier: verifier, challenge: challenge} = PKCE.generate()

      refute PKCE.verify(verifier <> "x", challenge)
      refute PKCE.verify(verifier, String.slice(challenge, 0..-2//1))
      refute PKCE.verify(verifier, "")
      refute PKCE.verify(nil, challenge)
      refute PKCE.verify(verifier, nil)
    end
  end

  describe "secret handling" do
    test "inspecting a pair never reveals the verifier" do
      pkce = PKCE.generate()
      rendered = inspect(pkce)

      refute rendered =~ pkce.verifier
      assert rendered =~ "[REDACTED]"
      # The challenge is public by construction, so it may be shown.
      assert rendered =~ pkce.challenge
    end

    test "a pair nested inside another structure is redacted too" do
      pkce = PKCE.generate()
      rendered = inspect(%{config: %{pkce: pkce}, client_id: "public-id"})

      refute rendered =~ pkce.verifier
      assert rendered =~ "[REDACTED]"
    end
  end
end
