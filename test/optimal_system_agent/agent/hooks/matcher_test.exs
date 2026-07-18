defmodule OptimalSystemAgent.Agent.Hooks.MatcherTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Hooks.Matcher

  test "nil, empty and * match everything" do
    assert Matcher.matches?(nil, "file_write")
    assert Matcher.matches?("", "file_write")
    assert Matcher.matches?("*", "anything")
  end

  test "exact and pipe-separated matches" do
    assert Matcher.matches?("file_write", "file_write")
    refute Matcher.matches?("file_write", "file_edit")
    assert Matcher.matches?("file_write|file_edit", "file_edit")
    refute Matcher.matches?("file_write|file_edit", "shell_execute")
  end

  test "regex matchers" do
    assert Matcher.matches?("^file_.*", "file_write")
    refute Matcher.matches?("^file_.*", "shell_execute")
    assert Matcher.matches?(".*", "anything")
  end

  test "invalid regex never matches" do
    refute Matcher.matches?("([", "anything")
  end

  test "nil query (event without matcher dimension) always matches" do
    assert Matcher.matches?("file_write", nil)
  end
end
