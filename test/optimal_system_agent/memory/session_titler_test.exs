defmodule OptimalSystemAgent.Memory.SessionTitlerTest do
  @moduledoc """
  Unit tests for session auto-titling (the adopted opencode idea).

  Covers the pure title-sanitization core (the port of opencode's title rules)
  and the persistence round-trip via an injected chat_fun and a tmp config_dir.

  async: false — mutates the shared `:config_dir` application env for the
  persistence tests.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.SessionPersistence
  alias OptimalSystemAgent.Memory.SessionTitler
  alias OptimalSystemAgent.Providers.Catalog

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

  describe "from_message/1 — the immediate, network-free title" do
    test "cleans a plain prompt into a capitalized title" do
      assert SessionTitler.from_message("why is app.js failing") ==
               "Why is app.js failing"
    end

    test "strips list, quote and heading markers" do
      assert SessionTitler.from_message("- fix the login bug") == "Fix the login bug"
      assert SessionTitler.from_message("## Refactor user service") == "Refactor user service"
      assert SessionTitler.from_message("> debug 500 errors") == "Debug 500 errors"
      assert SessionTitler.from_message("1. add rate limiting") == "Add rate limiting"
    end

    test "uses only the first line of a multi-line prompt" do
      assert SessionTitler.from_message("Add caching to the API\n\nSee lib/foo.ex for context") ==
               "Add caching to the API"
    end

    test "respects the 60-char cap on a word boundary" do
      long =
        "implement a comprehensive distributed rate limiting subsystem across every service"

      title = SessionTitler.from_message(long)
      assert String.length(title) <= 60
      refute String.ends_with?(title, " ")
    end

    test "empty and non-binary input yield an empty string" do
      assert SessionTitler.from_message("") == ""
      assert SessionTitler.from_message("   \n  ") == ""
      assert SessionTitler.from_message(nil) == ""
    end
  end

  describe "ensure_title/3 — a session is titled the moment it starts" do
    setup :tmp_config_dir

    test "stores a title synchronously from the opening message" do
      assert SessionTitler.get_title("s-new") == nil

      assert :ok = SessionTitler.ensure_title("s-new", "debug 500 errors", refine: false)

      # Available IMMEDIATELY after the call returns — no reply, no LLM, no wait.
      assert SessionTitler.get_title("s-new") == "Debug 500 errors"
      assert SessionTitler.display_title("s-new") == "Debug 500 errors"
    end

    test "is a no-op once the session already has a title" do
      SessionTitler.ensure_title("s-1", "first prompt wins", refine: false)
      SessionTitler.ensure_title("s-1", "a later prompt must not retitle", refine: false)

      assert SessionTitler.get_title("s-1") == "First prompt wins"
    end

    test "never overwrites a manual /rename title" do
      SessionPersistence.update_metadata("s-manual", %{title: "Hand-picked name"})

      SessionTitler.ensure_title("s-manual", "some opening message", refine: false)

      assert SessionTitler.get_title("s-manual") == nil
      assert SessionTitler.display_title("s-manual") == "Hand-picked name"
    end

    test "an empty or unusable message leaves the session untitled" do
      assert :ok = SessionTitler.ensure_title("s-blank", "   ", refine: false)
      assert SessionTitler.get_title("s-blank") == nil
    end

    test "returns :ok for non-binary input rather than raising on the hot path" do
      assert :ok = SessionTitler.ensure_title("s-x", nil, refine: false)
      assert :ok = SessionTitler.ensure_title(nil, "hello", refine: false)
    end
  end

  describe "display_title/2 — precedence" do
    setup :tmp_config_dir

    test "manual beats automatic beats fallback" do
      # Nothing stored: the caller's fallback.
      assert SessionTitler.display_title("s-p", "session-123") == "session-123"

      # Automatic only.
      SessionTitler.put_title("s-p", "Auto generated")
      assert SessionTitler.display_title("s-p", "session-123") == "Auto generated"

      # Manual wins over automatic.
      SessionPersistence.update_metadata("s-p", %{title: "Manual"})
      assert SessionTitler.display_title("s-p", "session-123") == "Manual"
    end

    test "a blank manual title does not mask the automatic one" do
      SessionTitler.put_title("s-blank-manual", "Auto generated")
      SessionPersistence.update_metadata("s-blank-manual", %{title: "   "})

      assert SessionTitler.display_title("s-blank-manual") == "Auto generated"
    end

    test "returns the fallback (never raises) for an unknown session" do
      assert SessionTitler.display_title("nope") == nil
      assert SessionTitler.display_title("nope", "fallback") == "fallback"
    end
  end

  describe "decorate_rows/2" do
    setup :tmp_config_dir

    test "adds :title to list_sessions-shaped rows, preferring manual" do
      SessionTitler.put_title("s-a", "Auto A")
      SessionPersistence.update_metadata("s-b", %{title: "Manual B"})

      rows = [
        %{session_id: "s-a", message_count: 2},
        %{session_id: "s-b", message_count: 5},
        %{session_id: "s-c", message_count: 1}
      ]

      [a, b, c] = SessionTitler.decorate_rows(rows)

      assert a.title == "Auto A"
      assert b.title == "Manual B"
      assert c.title == nil
      # Existing fields survive.
      assert a.message_count == 2
    end

    test "tolerates rows with no session id" do
      assert [%{title: nil}] = SessionTitler.decorate_rows([%{message_count: 1}])
    end
  end

  describe "small_model_opts/0 — resolved from the live catalog, not a constant" do
    test "picks whatever the catalog currently ranks smallest for the provider" do
      prev = Application.get_env(:optimal_system_agent, :default_provider)
      Application.put_env(:optimal_system_agent, :default_provider, :anthropic)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:optimal_system_agent, :default_provider, prev),
          else: Application.delete_env(:optimal_system_agent, :default_provider)
      end)

      opts = SessionTitler.small_model_opts()

      # The pick must EQUAL the catalog's current answer. If someone replaces
      # this with a hardcoded id, the catalog moves and this assertion breaks.
      expected = Catalog.small_model("anthropic")

      case expected do
        %{model_id: model_id} ->
          assert Keyword.get(opts, :provider) == :anthropic
          assert Keyword.get(opts, :model) == model_id
          # And it is genuinely a model the catalog lists for that provider.
          assert model_id in Enum.map(Catalog.models("anthropic"), & &1.model_id)

        nil ->
          assert opts == []
      end
    end

    test "degrades to [] (the session's normal model) for an unknown provider" do
      prev = Application.get_env(:optimal_system_agent, :default_provider)
      Application.put_env(:optimal_system_agent, :default_provider, :no_such_provider_xyz)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:optimal_system_agent, :default_provider, prev),
          else: Application.delete_env(:optimal_system_agent, :default_provider)
      end)

      assert SessionTitler.small_model_opts() == []
    end
  end

  defp tmp_config_dir(_ctx) do
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
end
