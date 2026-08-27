defmodule OptimalSystemAgent.Utils.MojibakeTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Utils.Mojibake

  test "repairs doubly decoded punctuation" do
    assert Mojibake.repair("frontend Ã¢ÂÂ 16 components") == "frontend — 16 components"
  end

  test "repairs common doubly decoded symbols" do
    assert Mojibake.repair("done Ã¢ÂÂ") == "done ✅"
    assert Mojibake.repair("next Ã¢ÂÂ step") == "next → step"
  end

  test "leaves valid Unicode and legitimate Latin text unchanged" do
    text = "São Paulo — café ✅"
    assert Mojibake.repair(text) == text
  end

  test "repairs contaminated spans without changing adjacent valid Unicode" do
    assert Mojibake.repair("valid ✅ then Ã¢ÂÂ broken") == "valid ✅ then — broken"
  end

  test "repairs the single-pass form whose controls render as a lone a-circumflex" do
    assert Mojibake.repair("paused â I spent time") == "paused — I spent time"
  end

  # The exact production failure: glm-*:cloud (and other backends) emit an
  # em-dash's UTF-8 bytes (E2 80 94) already reinterpreted as Latin-1 and
  # re-encoded, so each byte becomes its own two-byte UTF-8 char. Pin the raw
  # byte sequence so a future refactor of the marker heuristic cannot silently
  # stop repairing the case that prompted the fix.
  test "reverses a byte-for-byte double-encoded em-dash" do
    corrupt =
      <<0xE2, 0x80, 0x94>>
      |> :binary.bin_to_list()
      |> Enum.map_join(fn b -> <<b::utf8>> end)

    assert String.valid?(corrupt),
           "the corruption is valid UTF-8, which is why it survives to display"

    assert Mojibake.repair(corrupt) == <<0xE2, 0x80, 0x94>>
  end

  # A helper: the on-the-wire mojibake form of an original UTF-8 byte sequence -
  # each byte re-encoded as its own UTF-8 char (latin1-as-utf8 double encoding).
  defp corrupt(orig_bytes) do
    orig_bytes |> :binary.bin_to_list() |> Enum.map_join(fn b -> <<b::utf8>> end)
  end

  describe "repair_stream/2 handles corruption split across streamed deltas" do
    test "a sequence split mid-mojibake is repaired once whole" do
      # "'" is E2 80 99; its mojibake is corrupt(<<0xE2,0x80,0x99>>). Split it
      # between the first corrupted char and the rest, as a token stream would.
      moji = corrupt(<<0xE2, 0x80, 0x99>>)
      <<first::binary-size(2), rest::binary>> = moji
      deltas = ["That", first, rest, "s the app"]

      {out, carry} =
        Enum.reduce(deltas, {"", ""}, fn d, {acc, carry} ->
          {emit, new_carry} = Mojibake.repair_stream(carry, d)
          {acc <> emit, new_carry}
        end)

      assert out <> Mojibake.flush(carry) == "That’s the app"
    end

    test "clean and legitimately-accented text streams through untouched" do
      deltas = ["Hello ", "world ", "café ", "naïve"]

      {out, carry} =
        Enum.reduce(deltas, {"", ""}, fn d, {acc, carry} ->
          {emit, new_carry} = Mojibake.repair_stream(carry, d)
          {acc <> emit, new_carry}
        end)

      assert out <> Mojibake.flush(carry) == "Hello world café naïve"
    end

    test "a lone real accented word ending in a marker char is preserved" do
      # a real "â" is a marker char; it must survive, only delayed by the carry.
      {e1, c1} = Mojibake.repair_stream("", "goâ")
      {e2, c2} = Mojibake.repair_stream(c1, " on")
      assert e1 <> e2 <> Mojibake.flush(c2) == "goâ on"
    end

    test "a DOUBLE-encoded mojibake char (glm/z.ai em-dash) is repaired when streamed" do
      # Some providers render an em-dash "—" as DOUBLE mojibake: "—" (E2 80 94)
      # -> "â\x80\x94" -> "Ã¢Â\x80Â\x94". Its markers sit at non-adjacent
      # positions, which the old last-marker carry split into un-rejoinable
      # halves — the "Ã¢" the roster showed. The whole run must survive as a unit.
      single = corrupt(<<0xE2, 0x80, 0x94>>)
      double = corrupt(:unicode.characters_to_binary(single))
      deltas = ["miosa-compute) ", double, " 6 PRs"]

      {out, carry} =
        Enum.reduce(deltas, {"", ""}, fn d, {acc, carry} ->
          {emit, new_carry} = Mojibake.repair_stream(carry, d)
          {acc <> emit, new_carry}
        end)

      assert out <> Mojibake.flush(carry) == "miosa-compute) — 6 PRs"
    end

    test "a split sequence PRECEDED by text in the same delta is still repaired" do
      # Regression: the cross-delta hold-back must fire even when ordinary text
      # sits in front of the trailing partial sequence within one delta. A bug in
      # the tail scan (halting with `len` instead of the accumulator) made it
      # hold ONLY when the whole delta was mojibake, so "price: â" leaked.
      moji = corrupt(<<0xE2, 0x80, 0x94>>)
      <<first::binary-size(2), rest::binary>> = moji
      deltas = ["price: " <> first, rest, " done"]

      {out, carry} =
        Enum.reduce(deltas, {"", ""}, fn d, {acc, carry} ->
          {emit, new_carry} = Mojibake.repair_stream(carry, d)
          {acc <> emit, new_carry}
        end)

      assert out <> Mojibake.flush(carry) == "price: — done"
    end

    test "a double-encoded char split across deltas still rejoins" do
      single = corrupt(<<0xE2, 0x80, 0x94>>)
      double = corrupt(:unicode.characters_to_binary(single))
      # Split at a codepoint boundary, as the decoded SSE stream would.
      {first, rest} = String.split_at(double, 2)
      deltas = ["a ", first, rest, " b"]

      {out, carry} =
        Enum.reduce(deltas, {"", ""}, fn d, {acc, carry} ->
          {emit, new_carry} = Mojibake.repair_stream(carry, d)
          {acc <> emit, new_carry}
        end)

      assert out <> Mojibake.flush(carry) == "a — b"
    end
  end
end
