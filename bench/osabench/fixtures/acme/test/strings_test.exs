defmodule Acme.Util.StringsTest do
  use ExUnit.Case, async: true

  alias Acme.Util.Strings

  test "titlecase" do
    assert Strings.titlecase("ada lovelace") == "Ada Lovelace"
  end

  test "truncate" do
    assert Strings.truncate("abcdefghij", 6) == "abc..."
    assert Strings.truncate("abc", 6) == "abc"
  end
end
