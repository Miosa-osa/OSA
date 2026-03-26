defmodule OptimalSystemAgent.Receipt.ReplayerTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Receipt.Replayer

  @tmp_dir Path.join(System.tmp_dir!(), "replayer_test_#{System.unique_integer([:positive])}")

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)

    {pubkey, privkey} = :crypto.generate_key(:eddsa, :ed25519)
    pubkey_hex = Base.encode16(pubkey, case: :lower)

    {:ok, dir: @tmp_dir, pubkey: pubkey, privkey: privkey, pubkey_hex: pubkey_hex}
  end

  test "empty directory returns zeros", %{pubkey_hex: pubkey_hex, dir: dir} do
    result = Replayer.replay_all(pubkey_hex, dir)
    assert result.total == 0
    assert result.verified == 0
    assert result.failed == 0
    assert result.skipped == 0
  end

  test "valid receipt verifies", %{pubkey_hex: pubkey_hex, privkey: privkey, dir: dir} do
    # The kernel signs []byte(attestation_hex) — the UTF-8 bytes of the hex string
    attestation_hex = Base.encode16(:crypto.hash(:blake2b, "test-data"), case: :lower)
    signature = :crypto.sign(:eddsa, :none, attestation_hex, [privkey, :ed25519])
    signature_hex = Base.encode16(signature, case: :lower)

    receipt = %{
      "action" => "test",
      "kernel_response" => %{
        "confirmed" => true,
        "attestation" => attestation_hex,
        "signature" => signature_hex
      }
    }

    File.write!(Path.join(dir, "valid.json"), Jason.encode!(receipt))

    result = Replayer.replay_all(pubkey_hex, dir)
    assert result.total == 1
    assert result.verified == 1
    assert result.failed == 0
  end

  test "bad signature fails", %{pubkey_hex: pubkey_hex, dir: dir} do
    attestation_hex = Base.encode16(:crypto.hash(:blake2b, "test-data"), case: :lower)
    bad_sig = String.duplicate("ab", 64)

    receipt = %{
      "kernel_response" => %{
        "confirmed" => true,
        "attestation" => attestation_hex,
        "signature" => bad_sig
      }
    }

    File.write!(Path.join(dir, "bad.json"), Jason.encode!(receipt))

    result = Replayer.replay_all(pubkey_hex, dir)
    assert result.total == 1
    assert result.failed == 1
    assert length(result.failures) == 1
  end

  test "missing attestation is skipped", %{pubkey_hex: pubkey_hex, dir: dir} do
    receipt = %{
      "kernel_response" => %{
        "confirmed" => true,
        "signature" => "deadbeef"
      }
    }

    File.write!(Path.join(dir, "old.json"), Jason.encode!(receipt))

    result = Replayer.replay_all(pubkey_hex, dir)
    assert result.total == 1
    assert result.skipped == 1
  end
end
