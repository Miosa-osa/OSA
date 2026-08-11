defmodule OptimalSystemAgent.Auth.PKCE do
  @moduledoc """
  RFC 7636 Proof Key for Code Exchange — the `S256` half of it, and only that.

  ## Why this module exists, and why it did not before

  `Auth.DeviceFlow`'s moduledoc says plainly that PKCE is not part of the
  plain device grant: there is no authorization code redirected through a user
  agent, so there is nothing for a challenge to bind. That is still true, and
  this module does not change it.

  What changed is that two providers landed whose flows DO need a
  client-generated challenge:

    * **Qwen** runs an otherwise-ordinary RFC 8628 device grant, but its own
      client (`QwenLM/qwen-code`, `packages/core/src/qwen/qwenOAuth2.ts`)
      sends `code_challenge`/`code_challenge_method=S256` with the device
      authorization request and `code_verifier` with the token exchange.
      Omitting them is not "PKCE off" — the endpoint rejects the exchange.
    * **MiniMax** uses a bespoke `user_code` grant that is PKCE-bound in the
      same shape.

  So it is built once, here, rather than twice inside two providers — which is
  how one of them ends up with the subtly weaker version.

  ## Why only S256

  RFC 7636 also defines `plain`, where the challenge IS the verifier. That
  offers no protection whatsoever against an attacker who can observe the
  authorization request, which is the entire threat PKCE addresses; the RFC
  itself says clients MUST use S256 where they can, and a client that computes
  SHA-256 always can. Offering `plain` here would only create a way to pick
  the useless option by accident, so it is absent rather than discouraged.

  ## Entropy

  RFC 7636 permits a verifier of 43–128 characters. This module always
  generates the **full 128**, from 96 bytes of `:crypto.strong_rand_bytes/1`
  (base64url of 96 bytes is exactly 128 characters with no padding), rather
  than the 32-byte minimum. The extra bytes are free — this runs once per
  sign-in — and picking the ceiling means the value can never drift down
  toward the floor through a later "simplification".

  `:crypto.strong_rand_bytes/1` is the CSPRNG. `:rand` and friends are
  deliberately not used: they are seeded predictably and are not
  cryptographic.

  ## Secret handling

  The **verifier** is a secret for the lifetime of the grant — anyone holding
  it plus an intercepted authorization code can complete the exchange. It is
  therefore never logged, never printed, and never passed as a command-line
  argument. The **challenge** is public by construction; it is what goes on
  the wire in the authorization request.
  """

  # 96 bytes → exactly 128 base64url characters, RFC 7636's maximum. Well
  # above the 32-byte floor the spec sets, and above the >=32 bytes OSA
  # requires of any CSPRNG credential.
  @verifier_bytes 96

  @typedoc """
  A verifier and the challenge derived from it, kept together so the two can
  never be paired up wrongly by a caller holding them as loose strings.
  """
  @type t :: %__MODULE__{verifier: String.t(), challenge: String.t(), method: String.t()}

  @enforce_keys [:verifier, :challenge, :method]
  defstruct [:verifier, :challenge, :method]

  # The verifier is a live credential for the pending grant — keep it out of
  # every accidental `inspect/1`, which is how secrets reach logs and crash
  # reports. Same treatment `DeviceFlow.Session` gives `device_code`.
  defimpl Inspect do
    import Inspect.Algebra

    def inspect(pkce, opts) do
      concat([
        "#Auth.PKCE<challenge: ",
        to_doc(pkce.challenge, opts),
        ", verifier: [REDACTED]>"
      ])
    end
  end

  @doc """
  Generate a fresh verifier/challenge pair.

  Called once per sign-in attempt. Never reuse a pair across attempts: the
  point of the challenge is that it is bound to exactly one authorization
  request, and a reused verifier is no better than no verifier.
  """
  @spec generate() :: t()
  def generate do
    verifier = @verifier_bytes |> :crypto.strong_rand_bytes() |> b64url()

    %__MODULE__{
      verifier: verifier,
      challenge: challenge(verifier),
      method: "S256"
    }
  end

  @doc """
  The `S256` challenge for a verifier: `BASE64URL(SHA256(ASCII(verifier)))`.

  Exposed separately from `generate/0` so the derivation can be checked
  against RFC 7636's own worked example rather than only against itself — a
  round-trip test of `generate/0` alone would pass just as happily on a wrong
  hash.
  """
  @spec challenge(String.t()) :: String.t()
  def challenge(verifier) when is_binary(verifier) do
    :sha256 |> :crypto.hash(verifier) |> b64url()
  end

  @doc """
  Verify a verifier against a challenge, in constant time.

  Not needed by any OSA client flow — OSA is the party that HOLDS the verifier
  — but it is what makes the derivation testable as a property, and it is the
  correct primitive to have on hand rather than an `==` written at a call site
  later. `:crypto.hash_equals/2` avoids leaking a prefix match through timing.
  """
  @spec verify(String.t(), String.t()) :: boolean()
  def verify(verifier, challenge) when is_binary(verifier) and is_binary(challenge) do
    computed = challenge(verifier)

    byte_size(computed) == byte_size(challenge) and :crypto.hash_equals(computed, challenge)
  end

  def verify(_, _), do: false

  # base64url WITHOUT padding. The padding characters are not merely optional
  # here: RFC 7636 excludes `=` from the verifier's allowed character set, and
  # several providers reject a padded challenge outright.
  defp b64url(bytes), do: Base.url_encode64(bytes, padding: false)
end
