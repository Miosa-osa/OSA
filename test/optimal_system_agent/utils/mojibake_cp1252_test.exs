defmodule OptimalSystemAgent.Utils.MojibakeCp1252Test do
  @moduledoc """
  Regression: the common real-world mojibake is Windows-1252, not pure Latin-1.
  A byte in 0x80..0x9F read as CP1252 becomes a PRINTABLE char (€ ' ' " " – — …
  •) with a codepoint > 255. glm/z.ai render an em-dash this way as `â€"`
  ([U+00E2, U+20AC, U+201D]). The old repair only mapped codepoints <= 255 back
  to bytes, so these survived unrepaired — the `Ã¢`/`â€"` the user saw in the TUI.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Utils.Mojibake

  # CP1252 mojibake builders: the source UTF-8 byte in 0x80..0x9F becomes the
  # CP1252 codepoint, wrapped by the â (E2 lead) of the original 3-byte char.
  defp cp1252(cont), do: List.to_string([0x00E2, 0x20AC, cont])

  describe "repair/1 reverses CP1252 mojibake" do
    test "em-dash" do
      assert Mojibake.repair("ADV " <> cp1252(0x201D) <> " $29.90") == "ADV — $29.90"
    end

    test "left double quote" do
      assert Mojibake.repair(cp1252(0x0153) <> "hi") == "“hi"
    end

    test "bullet" do
      assert Mojibake.repair(cp1252(0x00A2) <> " item") == "• item"
    end

    test "ellipsis" do
      assert Mojibake.repair("wait" <> cp1252(0x00A6)) == "wait…"
    end
  end

  describe "streaming" do
    test "repairs a CP1252 char split across two deltas" do
      {e1, carry} = Mojibake.repair_stream("", "ran) " <> List.to_string([0x00E2]))
      {e2, carry} = Mojibake.repair_stream(carry, List.to_string([0x20AC, 0x201D]) <> " links")
      assert e1 <> e2 <> Mojibake.flush(carry) == "ran) — links"
    end
  end

  describe "does not corrupt legitimate text" do
    test "real dashes, quotes, euro, and accented letters are untouched" do
      legit = "café — €5 “quote” don’t"
      assert Mojibake.repair(legit) == legit
    end
  end

  describe "the pre-existing Latin-1 double-encoded form still repairs" do
    test "double-mojibaked em-dash" do
      assert Mojibake.repair("ADV " <> <<0xC3, 0xA2, 0xC2, 0x80, 0xC2, 0x94>> <> " x") ==
               "ADV — x"
    end
  end
end
