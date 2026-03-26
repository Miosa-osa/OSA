defmodule OptimalSystemAgent.Receipt.VerifierTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Receipt.Verifier

  # Generate a test Ed25519 keypair using :crypto
  setup_all do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    %{pub: pub, priv: priv, pub_hex: Base.encode16(pub, case: :lower), priv_raw: priv}
  end

  describe "verify/3" do
    test "accepts valid signature", %{priv: priv, pub_hex: pub_hex} do
      # The kernel signs []byte(attestation_hex) — the UTF-8 bytes of the hex string.
      # So the Verifier must verify against the same raw string bytes.
      attestation_hex = "abc123def456"
      sig = :crypto.sign(:eddsa, :none, attestation_hex, [priv, :ed25519])
      sig_hex = Base.encode16(sig, case: :lower)

      assert Verifier.verify(attestation_hex, sig_hex, pub_hex)
    end

    test "rejects tampered data", %{priv: priv, pub_hex: pub_hex} do
      attestation_hex = "abc123def456"
      sig = :crypto.sign(:eddsa, :none, attestation_hex, [priv, :ed25519])
      sig_hex = Base.encode16(sig, case: :lower)

      # Tamper with the attestation
      tampered = "000000000000"
      refute Verifier.verify(tampered, sig_hex, pub_hex)
    end

    test "rejects wrong key", %{priv: priv} do
      attestation_hex = "abc123def456"
      sig = :crypto.sign(:eddsa, :none, attestation_hex, [priv, :ed25519])
      sig_hex = Base.encode16(sig, case: :lower)

      # Generate a different keypair
      {wrong_pub, _wrong_priv} = :crypto.generate_key(:eddsa, :ed25519)
      wrong_pub_hex = Base.encode16(wrong_pub, case: :lower)

      refute Verifier.verify(attestation_hex, sig_hex, wrong_pub_hex)
    end

    test "returns false for invalid hex" do
      refute Verifier.verify("not-hex!", "not-hex!", "not-hex!")
    end
  end
end
