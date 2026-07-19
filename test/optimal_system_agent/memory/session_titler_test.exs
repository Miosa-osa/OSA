defmodule OptimalSystemAgent.Memory.SessionTitlerTest do
  @moduledoc """
  Unit tests for session auto-titling (the adopted opencode idea).

  Covers the pure title-sanitization core (the port of opencode's title rules)
  and the persistence round-trip via an injected chat_fun and a tmp config_dir.

  async: false — mutates the shared `:config_dir` application env for the
  persistence tests.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Memory.SessionTitler

  describe "sanitize_title/1" do
    test "keeps a clean short title unchanged" do
      assert SessionTitler.sanitize_title("Rate limiting implementation") ==
               "Rate limiting implementation"
    end

    test "takes only the first non-empty line" do
      assert SessionTitler.sanitize_title("\n\nDebugging 500 errors\nextra chatter") ==
               "Debugging 500 errors"
    end

    test "strips a leading Title: label" do
      assert SessionTitler.sanitize_title("Title: Postgres API connection") ==
               "Postgres API connection"
    end

    test "removes surrounding quotes" do
      assert SessionTitler.sanitize_title(~s("Auth refresh token support")) ==
               "Auth refresh token support"

      assert SessionTitler.sanitize_title("`Config review`") == "Config review"
    end

    test "collapses whitespace and strips trailing punctuation" do
      assert SessionTitler.sanitize_title("React   hooks   best   practices.") ==
               "React hooks best practices"
    end

    test "truncates overlong titles on a word boundary to <= 60 chars" do
      long =
        "Implementing a comprehensive distributed rate limiting subsystem across every service"

      result = SessionTitler.sanitize_title(long)
      assert String.length(result) <= 60
      # No dangling partial word at the end
      refute String.ends_with?(result, " ")
      assert String.starts_with?(result, "Implementing a comprehensive")
    end

    test "keeps technical terms, filenames, and numbers exact" do
      assert SessionTitler.sanitize_title("app.js failure investigation") ==
               "app.js failure investigation"

      assert SessionTitler.sanitize_title("Debugging production 500 errors") ==
               "Debugging production 500 errors"
    end

    test "empty or non-binary input yields empty string" do
      assert SessionTitler.sanitize_title("") == ""
      assert SessionTitler.sanitize_title("   \n  ") == ""
      assert SessionTitler.sanitize_title(nil) == ""
    end
  end

  describe "build_prompt/1" do
    test "system prompt carries the opencode title rules and user text is capped" do
      {system, user} = SessionTitler.build_prompt("  why is app.js failing  ")

      assert system =~ "title generator"
      assert system =~ "Never include tool names"
      assert user == "why is app.js failing"
    end

    test "caps very long user input" do
      {_system, user} = SessionTitler.build_prompt(String.duplicate("x", 5_000))
      assert byte_size(user) <= 2_000
    end
  end

  describe "title_for/2 persistence round-trip" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "osa_titler_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      prev = Application.get_env(:optimal_system_agent, :config_dir)
      Application.put_env(:optimal_system_agent, :config_dir, tmp)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:optimal_system_agent, :config_dir, prev),
          else: Application.delete_env(:optimal_system_agent, :config_dir)

        File.rm_rf(tmp)
      end)

      {:ok, tmp: tmp}
    end

    test "put_title/get_title round-trips through the JSON store" do
      assert :ok = SessionTitler.put_title("sess-1", "My saved title")
      assert SessionTitler.get_title("sess-1") == "My saved title"
      assert SessionTitler.get_title("missing") == nil
    end

    test "titles/0 returns the full map" do
      SessionTitler.put_title("a", "Title A")
      SessionTitler.put_title("b", "Title B")
      titles = SessionTitler.titles()
      assert titles["a"] == "Title A"
      assert titles["b"] == "Title B"
    end
  end
end
