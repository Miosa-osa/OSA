defmodule OptimalSystemAgent.Memory.DreamTest do
  @moduledoc """
  Unit tests for the dream-memory consolidation logic.

  Covers the pure core (gating predicates, session selection, prompt building,
  response parsing, timestamp parsing) and the injected `consolidate/2` seam so
  the LLM and Store are stubbed — no live provider, no DB.

  async: true — every function under test is pure or fully dependency-injected.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Memory.Dream

  defp ts(str), do: Dream.parse_ts(str)

  describe "gate_time/4" do
    test "opens when enough time has elapsed" do
      last = ~N[2026-07-19 10:00:00]
      now = ~N[2026-07-19 15:00:00]
      assert :ok = Dream.gate_time(last, now, 4 * 60 * 60 * 1000, false)
    end

    test "skips when too soon" do
      last = ~N[2026-07-19 14:00:00]
      now = ~N[2026-07-19 15:00:00]
      assert {:skip, {:too_soon, _}} = Dream.gate_time(last, now, 4 * 60 * 60 * 1000, false)
    end

    test "always opens with nil last_dream_at" do
      assert :ok = Dream.gate_time(nil, ~N[2026-07-19 15:00:00], 999_999, false)
    end

    test "force bypasses the time gate" do
      last = ~N[2026-07-19 14:59:00]
      now = ~N[2026-07-19 15:00:00]
      assert :ok = Dream.gate_time(last, now, 4 * 60 * 60 * 1000, true)
    end
  end

  describe "gate_idle/4" do
    test "opens when the newest activity is older than the idle threshold" do
      now = ~N[2026-07-19 15:05:00]
      sessions = [%{last_active: "2026-07-19 15:00:00"}]
      # 5 min quiet >= 90s threshold
      assert :ok = Dream.gate_idle(sessions, now, 90_000, false)
    end

    test "skips when the system is still busy" do
      now = ~N[2026-07-19 15:00:30]
      sessions = [%{last_active: "2026-07-19 15:00:00"}]
      # only 30s quiet < 90s threshold
      assert {:skip, {:busy, _}} = Dream.gate_idle(sessions, now, 90_000, false)
    end

    test "opens on empty session list" do
      assert :ok = Dream.gate_idle([], ~N[2026-07-19 15:00:00], 90_000, false)
    end

    test "force bypasses the idle gate even when busy" do
      now = ~N[2026-07-19 15:00:10]
      sessions = [%{last_active: "2026-07-19 15:00:00"}]
      assert :ok = Dream.gate_idle(sessions, now, 90_000, true)
    end
  end

  describe "gate_sessions/3" do
    test "opens with enough eligible sessions" do
      assert :ok = Dream.gate_sessions([%{}, %{}], 2, false)
    end

    test "skips with too few" do
      assert {:skip, {:too_few_sessions, 1}} = Dream.gate_sessions([%{}], 2, false)
    end

    test "force opens with at least one session" do
      assert :ok = Dream.gate_sessions([%{}], 5, true)
    end

    test "force skips with zero sessions" do
      assert {:skip, {:too_few_sessions, 0}} = Dream.gate_sessions([], 5, true)
    end
  end

  describe "eligible_sessions/3" do
    setup do
      sessions = [
        %{session_id: "old", last_active: "2026-07-19 09:00:00"},
        %{session_id: "mid", last_active: "2026-07-19 12:00:00"},
        %{session_id: "new", last_active: "2026-07-19 14:00:00"},
        %{session_id: "bad", last_active: nil}
      ]

      {:ok, sessions: sessions}
    end

    test "keeps only sessions newer than last_dream_at, newest first", %{sessions: sessions} do
      result = Dream.eligible_sessions(sessions, ~N[2026-07-19 10:00:00], 10)
      assert Enum.map(result, & &1.session_id) == ["new", "mid"]
    end

    test "nil last_dream_at includes all parseable sessions", %{sessions: sessions} do
      result = Dream.eligible_sessions(sessions, nil, 10)
      assert Enum.map(result, & &1.session_id) == ["new", "mid", "old"]
    end

    test "respects the max_sessions cap", %{sessions: sessions} do
      result = Dream.eligible_sessions(sessions, nil, 1)
      assert Enum.map(result, & &1.session_id) == ["new"]
    end
  end

  describe "build_prompt/2" do
    test "includes each session block and a durable-memory instruction" do
      texts = [%{id: "s1", text: "user: hi\nassistant: hello"}]
      {system, user} = Dream.build_prompt(texts)

      assert system =~ "dream"
      assert system =~ "[decision]"
      assert user =~ "--- Session s1 ---"
      assert user =~ "user: hi"
    end

    test "respects the input char budget" do
      texts =
        for i <- 1..50 do
          %{id: "s#{i}", text: String.duplicate("x", 500)}
        end

      {_system, user} = Dream.build_prompt(texts, max_input_chars: 1_000)
      assert byte_size(user) <= 2_000
      assert user =~ "--- Session s1 ---"
    end
  end

  describe "parse_response/1" do
    test "parses bracketed category lines" do
      response = """
      [decision] The team standardized on Ecto over raw SQL.
      [lesson] Test workers above 16 cause flaky failures.
      [preference] User prefers tabs over spaces.
      """

      assert {:ok, items} = Dream.parse_response(response)
      assert length(items) == 3
      assert %{category: :decision, content: "The team standardized on Ecto over raw SQL."} in items
      assert %{category: :lesson, content: "Test workers above 16 cause flaky failures."} in items
    end

    test "coerces unknown categories to :context" do
      assert {:ok, [%{category: :context, content: "Something notable happened."}]} =
               Dream.parse_response("[banana] Something notable happened.")
    end

    test "detects NO_REPLY" do
      assert :no_reply = Dream.parse_response("NO_REPLY")
      assert :no_reply = Dream.parse_response("  NO_REPLY  ")
    end

    test "empty response is :no_reply" do
      assert :no_reply = Dream.parse_response("   ")
    end

    test "dedups identical content case-insensitively" do
      response = """
      [lesson] Always pin patched dependency versions.
      [context] always pin patched dependency versions.
      """

      assert {:ok, items} = Dream.parse_response(response)
      assert length(items) == 1
    end

    test "falls back to :context for non-bracketed prose lines" do
      response = "The database migration must run before the deploy step."
      assert {:ok, [%{category: :context, content: content}]} = Dream.parse_response(response)
      assert content =~ "database migration"
    end

    test "ignores markdown headers and tiny fragments in fallback mode" do
      response = """
      # Summary
      ok
      This is a genuinely durable and useful memory fact.
      """

      assert {:ok, items} = Dream.parse_response(response)
      assert length(items) == 1
      assert hd(items).content =~ "genuinely durable"
    end
  end

  describe "consolidate/2 (injected LLM + Store)" do
    test "saves each parsed memory through the injected save_fun" do
      texts = [%{id: "s1", text: "user: we chose Ecto\nassistant: noted"}]

      chat_fun = fn _system, _user ->
        {:ok, "[decision] Chose Ecto over raw SQL.\n[lesson] Wrap tx in Repo.transaction."}
      end

      test_pid = self()

      save_fun = fn content, opts ->
        send(test_pid, {:saved, content, opts})
        {:ok, %{id: "x"}}
      end

      report = Dream.consolidate(texts, chat_fun: chat_fun, save_fun: save_fun)

      assert report.status == :completed
      assert report.saved == 2
      assert report.skipped == 0
      assert report.sessions == 1

      assert_receive {:saved, "Chose Ecto over raw SQL.", opts}
      assert opts[:category] == :decision
      assert opts[:source] == :sica
      assert "dream" in opts[:tags]
      assert_receive {:saved, "Wrap tx in Repo.transaction.", _}
    end

    test "counts Store rejections (e.g. duplicates) as skipped" do
      texts = [%{id: "s1", text: "user: hello"}]
      chat_fun = fn _s, _u -> {:ok, "[context] A fact worth remembering here."} end
      save_fun = fn _content, _opts -> {:error, :duplicate} end

      report = Dream.consolidate(texts, chat_fun: chat_fun, save_fun: save_fun)
      assert report.status == :completed
      assert report.saved == 0
      assert report.skipped == 1
    end

    test "NO_REPLY yields a neutral report and saves nothing" do
      texts = [%{id: "s1", text: "user: hi"}]
      chat_fun = fn _s, _u -> {:ok, "NO_REPLY"} end
      save_fun = fn _c, _o -> flunk("should not save on NO_REPLY") end

      report = Dream.consolidate(texts, chat_fun: chat_fun, save_fun: save_fun)
      assert report.status == :neutral
      assert report.saved == 0
    end

    test "LLM error propagates as an error report" do
      texts = [%{id: "s1", text: "user: hi"}]
      chat_fun = fn _s, _u -> {:error, :timeout} end
      save_fun = fn _c, _o -> flunk("should not save on error") end

      report = Dream.consolidate(texts, chat_fun: chat_fun, save_fun: save_fun)
      assert report.status == :error
      assert report.reason == :timeout
    end
  end

  describe "parse_ts/1" do
    test "parses SQLite space-separated timestamps" do
      assert %NaiveDateTime{} = ts("2026-07-19 14:00:00")
    end

    test "passes through NaiveDateTime and rejects garbage" do
      assert %NaiveDateTime{} = Dream.parse_ts(~N[2026-07-19 14:00:00])
      assert Dream.parse_ts("not-a-date") == nil
      assert Dream.parse_ts(nil) == nil
    end
  end
end
