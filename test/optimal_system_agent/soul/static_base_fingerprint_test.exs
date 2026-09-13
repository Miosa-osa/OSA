defmodule OptimalSystemAgent.Soul.StaticBaseFingerprintTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Soul

  test "two reads with an unchanged toolbox return the same bytes" do
    Soul.invalidate_static_base()
    a = Soul.static_base(:native_tools)
    b = Soul.static_base(:native_tools)
    assert is_binary(a) and a != ""
    assert a == b
  end

  test "invalidate forces a rebuild that still matches the live toolbox" do
    first = Soul.static_base(:native_tools)
    Soul.invalidate_static_base()
    second = Soul.static_base(:native_tools)
    assert first == second
  end
end
