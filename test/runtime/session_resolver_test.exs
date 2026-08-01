defmodule OptimalSystemAgent.Runtime.SessionResolverTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Runtime.SessionResolver

  @ids [
    "session-1785539672538-b5473d40b767",
    "session-1785539999999-aaaa1111bbbb",
    "session-1700000000000-cccc2222dddd",
    "tui_1785539672538_b5473d40"
  ]

  describe "resolve/2 — exact ids" do
    test "a full id resolves to itself" do
      assert SessionResolver.resolve("session-1785539672538-b5473d40b767", @ids) ==
               {:ok, "session-1785539672538-b5473d40b767"}
    end

    test "surrounding whitespace is tolerated" do
      assert SessionResolver.resolve("  tui_1785539672538_b5473d40  ", @ids) ==
               {:ok, "tui_1785539672538_b5473d40"}
    end

    test "an exact id wins even when it also prefixes a longer id" do
      ids = ["abc", "abcdef"]
      assert SessionResolver.resolve("abc", ids) == {:ok, "abc"}
    end
  end

  describe "resolve/2 — prefixes (git short-SHA style)" do
    test "an unambiguous prefix resolves to the one full id" do
      assert SessionResolver.resolve("session-17000", @ids) ==
               {:ok, "session-1700000000000-cccc2222dddd"}
    end

    test "a short but still unambiguous prefix resolves" do
      assert SessionResolver.resolve("tui_", @ids) == {:ok, "tui_1785539672538_b5473d40"}
    end

    test "an ambiguous prefix is an error carrying the candidates" do
      assert {:error, {:ambiguous, candidates}} =
               SessionResolver.resolve("session-17855", @ids)

      assert "session-1785539672538-b5473d40b767" in candidates
      assert "session-1785539999999-aaaa1111bbbb" in candidates
      assert length(candidates) == 2
    end
  end

  describe "resolve/2 — loud failure" do
    test "an unknown reference is not_found, never a silent fresh session" do
      assert SessionResolver.resolve("nope-does-not-exist", @ids) == {:error, :not_found}
    end

    test "a typo of a real id is not_found" do
      # One character off. This is the exact failure that used to open a blank
      # conversation indistinguishable from a healthy one.
      assert SessionResolver.resolve("session-1785539672539-b5473d40b767", @ids) ==
               {:error, :not_found}
    end

    test "an empty reference is not_found" do
      assert SessionResolver.resolve("", @ids) == {:error, :not_found}
      assert SessionResolver.resolve("   ", @ids) == {:error, :not_found}
    end

    test "no known sessions at all is not_found" do
      assert SessionResolver.resolve("anything", []) == {:error, :not_found}
    end
  end

  describe "explain/2" do
    test "not_found names the reference and points at the picker" do
      msg = SessionResolver.explain("bogus", :not_found)
      assert msg =~ "bogus"
      assert msg =~ "osa resume"
    end

    test "ambiguous lists the candidates" do
      msg = SessionResolver.explain("ses", {:ambiguous, ["a", "b"]})
      assert msg =~ "2 sessions"
      assert msg =~ "a, b"
    end
  end

  describe "known_session_ids/0" do
    test "returns a list of binaries and never raises" do
      ids = SessionResolver.known_session_ids()
      assert is_list(ids)
      assert Enum.all?(ids, &is_binary/1)
    end
  end
end
