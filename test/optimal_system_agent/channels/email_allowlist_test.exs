defmodule OptimalSystemAgent.Channels.EmailAllowlistTest do
  @moduledoc """
  The inbound-email allowlist was case-folded on ONE side only.

  `parse_allowed/1` stored the configured values verbatim; `allowed_sender?/2`
  downcased the sender. Any `email_allowed_senders` value containing an
  uppercase letter — the normal way a human types an address — could therefore
  never match, and an unmatched sender was skipped with no log and no error.
  The observable symptom was a channel that silently ignored every message
  forever.

  The opposite direction matters too: `String.downcase/1` performs full Unicode
  case folding, so U+212A KELVIN SIGN folds onto ASCII "k" and U+017F LATIN
  SMALL LETTER LONG S folds onto ASCII "s". A different address folding onto an
  allowlisted one is a privilege bypass here, because a permitted sender starts
  an agent task.
  """

  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Channels.EmailChannel

  defp allowed?(config, from),
    do: EmailChannel.allowed_sender?(from, EmailChannel.parse_allowed(config))

  describe "an allowlist entry matches regardless of how it was typed" do
    test "an uppercase configured address matches a lowercase sender" do
      assert allowed?("Alice@Example.COM", "alice@example.com")
    end

    test "a lowercase configured address matches an uppercase sender" do
      assert allowed?("alice@example.com", "Alice@Example.COM")
    end

    test "mixed case on both sides still matches" do
      assert allowed?("AlIcE@ExAmPlE.cOm", "aLiCe@eXaMpLe.CoM")
    end

    test "surrounding whitespace in the config is tolerated" do
      assert allowed?("  Alice@Example.com  ,  bob@example.com ", "alice@example.com")
      assert allowed?("  Alice@Example.com  ,  BOB@example.com ", "bob@example.com")
    end

    test "a multi-entry list matches any of its entries" do
      config = "Alice@Example.com,Bob@Example.com,carol@example.com"
      assert allowed?(config, "alice@example.com")
      assert allowed?(config, "bob@example.com")
      assert allowed?(config, "carol@example.com")
    end
  end

  describe "the allowlist still excludes" do
    test "an address that is not configured" do
      refute allowed?("alice@example.com", "mallory@example.com")
    end

    test "a near-miss on the domain" do
      refute allowed?("alice@example.com", "alice@example.com.evil.test")
    end
  end

  describe "an unconfigured allowlist imposes no restriction" do
    test "an empty string allows anyone" do
      assert allowed?("", "anyone@example.com")
    end

    test "nil allows anyone" do
      assert allowed?(nil, "anyone@example.com")
    end

    test "a value of only separators and whitespace allows anyone" do
      # Empty entries must be dropped, not stored as "" — a set containing ""
      # is non-empty, so it would silently switch the channel into
      # restrict-everything mode.
      assert allowed?(" , , ", "anyone@example.com")
    end
  end

  describe "Unicode case folding must not create a match" do
    test "U+212A KELVIN SIGN does not fold onto an allowlisted ASCII k" do
      # "kelvin@example.com" vs a sender spelled with U+212A in place of the k.
      spoofed = "Kelvin@example.com"
      refute spoofed == "kelvin@example.com"

      refute allowed?("kelvin@example.com", spoofed),
             "a different address folded onto an allowlisted one and was accepted"
    end

    test "U+017F LATIN SMALL LETTER LONG S does not fold onto an allowlisted ASCII s" do
      spoofed = "ſam@example.com"
      refute spoofed == "sam@example.com"

      refute allowed?("sam@example.com", spoofed),
             "a different address folded onto an allowlisted one and was accepted"
    end

    test "the same spoofing does not work through the CONFIG side either" do
      refute allowed?("Kelvin@example.com", "kelvin@example.com")
    end
  end

  describe "parse_allowed/1" do
    test "normalizes entries to lowercase ASCII" do
      assert EmailChannel.parse_allowed("Alice@Example.COM") ==
               MapSet.new(["alice@example.com"])
    end

    test "drops empty entries" do
      assert EmailChannel.parse_allowed("a@b.test,,  ,c@d.test") ==
               MapSet.new(["a@b.test", "c@d.test"])
    end

    test "a non-binary value yields an empty set rather than crashing the channel" do
      assert EmailChannel.parse_allowed(:not_a_string) == MapSet.new()
      assert EmailChannel.parse_allowed(nil) == MapSet.new()
    end
  end
end
