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
end
