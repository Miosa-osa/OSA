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
end
