defmodule OptimalSystemAgent.Security.UpdaterMetadataVerificationTest do
  @moduledoc """
  Update metadata is attacker-controlled. Anyone who can answer `:update_url`
  — the host, a CDN edge, a TLS-terminating proxy, a DNS hijack — writes every
  byte of it.

  Before the fix, `Updater` fetched `root.json` / `timestamp.json` /
  `targets.json` with a bare `Req.get` + `Jason.decode`, never looked at the
  `signatures` key, and read `signed.version` straight out of the result to
  emit `:update_available`. It was TUF-shaped without being TUF.

  These tests pin the properties that make it real, and — most importantly —
  `describe "installation gate"` fails if anyone ever wires installation to an
  unverified document.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.System.Updater

  # ── helpers ────────────────────────────────────────────────────────────

  defp keypair do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    {pub, priv}
  end

  defp hex(bin), do: Base.encode16(bin, case: :lower)

  defp keyid(pub), do: :crypto.hash(:sha256, pub) |> Base.encode16(case: :lower)

  defp future, do: DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
  defp past, do: DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()

  defp signed_doc(signed, {pub, priv}) do
    payload = Updater.canonical_json(signed)
    sig = :crypto.sign(:eddsa, :none, payload, [priv, :ed25519])
    %{"signed" => signed, "signatures" => [%{"keyid" => keyid(pub), "sig" => hex(sig)}]}
  end

  defp pinned({pub, _priv}), do: [{keyid(pub), pub}]

  # ── the gate that must stay red if staging is wired to unverified data ──

  describe "installation gate (ensure_installable/1)" do
    @tag :security
    test "REFUSES an update record that was not verified against pinned root keys" do
      # This is the shape `do_check/1` used to build straight out of a fetched
      # document: a version, a URL, and nothing certifying where it came from.
      unverified = %{
        version: "9.9.9",
        current_version: "1.0.0",
        url: "https://updates.example.com/tuf",
        metadata: %{root_version: 1}
      }

      assert {:error, message} = Updater.ensure_installable(unverified)
      assert message =~ "REFUSING to install"
      assert message =~ "pinned root keys"
    end

    @tag :security
    test "REFUSES an explicit verified: false, and a forged non-boolean stamp" do
      assert {:error, _} = Updater.ensure_installable(%{version: "9.9.9", verified: false})
      assert {:error, _} = Updater.ensure_installable(%{version: "9.9.9", verified: "true"})
      assert {:error, _} = Updater.ensure_installable(%{version: "9.9.9", verified: 1})
      assert {:error, _} = Updater.ensure_installable(%{version: "9.9.9"})
      assert {:error, _} = Updater.ensure_installable(nil)
      assert {:error, _} = Updater.ensure_installable(%{})
    end

    @tag :security
    test "admits only a record carrying the verified stamp" do
      assert :ok = Updater.ensure_installable(%{version: "9.9.9", verified: true})
    end

    @tag :security
    test "the staging path routes through the gate" do
      # Guards the wiring, not just the predicate: apply_update/1 must reject an
      # unverified available_update rather than write a staged artifact for it.
      # If someone later implements a real download that skips
      # ensure_installable/1, this is the test that goes red.
      source = File.read!("lib/optimal_system_agent/system/updater.ex")

      [_, stage_body] = String.split(source, "defp stage_update(", parts: 2)

      assert stage_body =~ "ensure_installable",
             "stage_update/2 must call ensure_installable/1 before touching the filesystem — " <>
               "installing from unverified update metadata is remote code execution"
    end
  end

  # ── pinned keys ────────────────────────────────────────────────────────

  describe "pinned_root_keys/0" do
    setup do
      prev_keys = Application.get_env(:optimal_system_agent, :update_root_keys)
      prev_thr = Application.get_env(:optimal_system_agent, :update_root_threshold)

      on_exit(fn ->
        if prev_keys,
          do: Application.put_env(:optimal_system_agent, :update_root_keys, prev_keys),
          else: Application.delete_env(:optimal_system_agent, :update_root_keys)

        if prev_thr,
          do: Application.put_env(:optimal_system_agent, :update_root_threshold, prev_thr),
          else: Application.delete_env(:optimal_system_agent, :update_root_threshold)
      end)

      :ok
    end

    @tag :security
    test "no configured keys ⇒ refuse, never 'trust whatever arrives'" do
      Application.delete_env(:optimal_system_agent, :update_root_keys)
      assert {:error, :no_pinned_root_keys} = Updater.pinned_root_keys()

      Application.put_env(:optimal_system_agent, :update_root_keys, [])
      assert {:error, :no_pinned_root_keys} = Updater.pinned_root_keys()
    end

    @tag :security
    test "a threshold higher than the pinned key count is refused, not silently lowered" do
      {pub, _priv} = keypair()
      Application.put_env(:optimal_system_agent, :update_root_keys, [hex(pub)])
      Application.put_env(:optimal_system_agent, :update_root_threshold, 2)

      assert {:error, :threshold_exceeds_pinned_keys} = Updater.pinned_root_keys()
    end

    @tag :security
    test "accepts both bare-hex and %{keyid, public} forms" do
      {pub, _priv} = keypair()
      Application.put_env(:optimal_system_agent, :update_root_threshold, 1)

      Application.put_env(:optimal_system_agent, :update_root_keys, [hex(pub)])
      assert {:ok, [{_id, ^pub}], 1} = Updater.pinned_root_keys()

      Application.put_env(:optimal_system_agent, :update_root_keys, [
        %{"keyid" => "custom-id", "public" => hex(pub)}
      ])

      assert {:ok, [{"custom-id", ^pub}], 1} = Updater.pinned_root_keys()
    end
  end

  # ── signature verification ─────────────────────────────────────────────

  describe "verify_metadata/3" do
    @tag :security
    test "a document with NO signatures key is rejected" do
      # Exactly what the old code accepted and read `signed.version` out of.
      {pub, _priv} = keypair()
      doc = %{"signed" => %{"version" => 42, "expires" => future()}}

      assert {:error, :missing_signatures} = Updater.verify_metadata(doc, [{keyid(pub), pub}], 1)
      assert {:error, :missing_signatures} = Updater.verify_metadata(Map.put(doc, "signatures", []), [{keyid(pub), pub}], 1)
    end

    @tag :security
    test "accepts a document correctly signed by a pinned key" do
      kp = keypair()
      doc = signed_doc(%{"version" => 42, "expires" => future()}, kp)

      assert :ok = Updater.verify_metadata(doc, pinned(kp), 1)
    end

    @tag :security
    test "rejects a document signed by a key that is NOT pinned" do
      attacker = keypair()
      legit = keypair()
      doc = signed_doc(%{"version" => 42, "expires" => future()}, attacker)

      assert {:error, {:signature_threshold_not_met, 0, 1}} =
               Updater.verify_metadata(doc, pinned(legit), 1)
    end

    @tag :security
    test "rejects a document whose signed body was tampered with after signing" do
      kp = keypair()
      doc = signed_doc(%{"version" => 42, "expires" => future()}, kp)

      # The attack: keep the valid signature, swap the version it covers.
      tampered = put_in(doc, ["signed", "version"], 9999)

      assert {:error, {:signature_threshold_not_met, 0, 1}} =
               Updater.verify_metadata(tampered, pinned(kp), 1)
    end

    @tag :security
    test "rejects a signature copied onto a different keyid it does not belong to" do
      kp = {pub, _priv} = keypair()
      other = {other_pub, _} = keypair()
      doc = signed_doc(%{"version" => 42, "expires" => future()}, kp)

      relabeled = put_in(doc, ["signatures"], [%{"keyid" => keyid(other_pub), "sig" => hd(doc["signatures"])["sig"]}])

      assert {:error, {:signature_threshold_not_met, 0, 1}} =
               Updater.verify_metadata(relabeled, [{keyid(pub), pub}, {keyid(other_pub), other_pub}], 1)

      _ = other
    end

    @tag :security
    test "one valid key repeated does not satisfy a threshold of two" do
      kp = {pub, _} = keypair()
      other = {other_pub, _} = keypair()
      doc = signed_doc(%{"version" => 42, "expires" => future()}, kp)
      sig = hd(doc["signatures"])["sig"]

      duplicated = Map.put(doc, "signatures", [
        %{"keyid" => keyid(pub), "sig" => sig},
        %{"keyid" => keyid(pub), "sig" => sig}
      ])

      assert {:error, {:signature_threshold_not_met, 1, 2}} =
               Updater.verify_metadata(duplicated, [{keyid(pub), pub}, {keyid(other_pub), other_pub}], 2)

      _ = other
    end

    @tag :security
    test "rejects expired metadata even when the signature is valid" do
      kp = keypair()
      doc = signed_doc(%{"version" => 42, "expires" => past()}, kp)

      assert {:error, :metadata_expired} = Updater.verify_metadata(doc, pinned(kp), 1)
    end

    @tag :security
    test "malformed input never raises — it returns an error" do
      {pub, _} = keypair()
      keys = [{keyid(pub), pub}]

      assert {:error, _} = Updater.verify_metadata(nil, keys, 1)
      assert {:error, _} = Updater.verify_metadata("not a doc", keys, 1)
      assert {:error, :missing_signed} = Updater.verify_metadata(%{"signatures" => []}, keys, 1)

      assert {:error, _} =
               Updater.verify_metadata(
                 %{"signed" => %{}, "signatures" => [%{"keyid" => 1, "sig" => nil}]},
                 keys,
                 1
               )
    end
  end

  # ── rollback protection ────────────────────────────────────────────────

  describe "check_rollback/3" do
    @tag :security
    test "accepts a monotonically increasing version and records it" do
      assert {:ok, seen} = Updater.check_rollback("targets", %{"signed" => %{"version" => 5}}, %{})
      assert seen["targets"] == 5

      assert {:ok, seen} = Updater.check_rollback("targets", %{"signed" => %{"version" => 6}}, seen)
      assert seen["targets"] == 6
    end

    @tag :security
    test "rejects a replayed older document — the pin-to-vulnerable-build attack" do
      seen = %{"targets" => 10}

      assert {:error, {:rollback_detected, 3, 10}} =
               Updater.check_rollback("targets", %{"signed" => %{"version" => 3}}, seen)
    end

    @tag :security
    test "a document with no version at all is refused" do
      assert {:error, :missing_metadata_version} =
               Updater.check_rollback("root", %{"signed" => %{}}, %{})
    end
  end

  # ── canonical serialization ────────────────────────────────────────────

  describe "canonical_json/1" do
    test "is insensitive to map insertion order, so signer and verifier agree" do
      a = %{"b" => 1, "a" => 2, "c" => %{"z" => 1, "y" => [1, 2]}}
      b = %{"c" => %{"y" => [1, 2], "z" => 1}, "a" => 2, "b" => 1}

      assert Updater.canonical_json(a) == Updater.canonical_json(b)
      assert Updater.canonical_json(a) == ~s({"a":2,"b":1,"c":{"y":[1,2],"z":1}})
    end
  end
end
