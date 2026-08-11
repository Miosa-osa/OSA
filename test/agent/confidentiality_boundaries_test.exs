defmodule OptimalSystemAgent.Agent.ConfidentialityBoundariesTest do
  @moduledoc """
  Two confidentiality boundaries, both regressions that were silent in practice.

  ## 1. The compaction summary must not cross sessions

  `Compactor` persists the last structured cold-zone summary so the next
  compaction can merge into it instead of starting over. That entry used to
  live under a single GLOBAL `:previous_summary` key in the shared
  `:osa_compactor_state` ETS table, so session B's compaction folded session
  A's summary — verbatim conversation content — into its own prompt as the
  `<chunk_summary index="prev">` block, shipped it to the provider, and wrote
  it back into B's context. Nothing ever deleted it either, so it also outlived
  the session that produced it.

  ## 2. Secrets must be scrubbed at the sinks

  `Trajectory.redact/1` was correct but wired to almost nothing: an API key a
  shell command echoed reached the terminal, the summarization prompt (i.e. a
  third-party provider) and the on-disk subagent transcript unredacted. These
  tests plant a key and assert it does not reach each sink — plus a
  no-corruption guard, because over-eager redaction is its own bug.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias OptimalSystemAgent.Agent.Compactor
  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Agent.Trajectory
  alias OptimalSystemAgent.Channels.CLI.Spinner
  alias OptimalSystemAgent.Runtime.SessionTeardown

  # A shape `redact/1` definitely recognises, with a unique marker so a test
  # failure tells us WHICH plant leaked.
  defp planted_key(marker), do: "sk-ant-api03-#{marker}0123456789abcdefghij"

  defp summary_entry(session_id) do
    :ets.lookup(:osa_compactor_state, {:previous_summary, session_id})
  end

  defp clear_all_summaries do
    :ets.match_delete(:osa_compactor_state, {{:previous_summary, :_}, :_})
    :ets.match_delete(:osa_compactor_state, {{:last_summary_at, :_}, :_})
    :ets.delete(:osa_compactor_state, :previous_summary)
    :ets.delete(:osa_compactor_state, :last_summary_at)
  rescue
    ArgumentError -> :ok
  end

  # Mirrors compactor_test.exs: force the pipeline deep enough that the cold
  # zone is actually summarized, and small enough chunks that the
  # divide-and-conquer path (the one that folds the previous summary back in)
  # is the path taken.
  defp force_background_stop_at(target_tokens) do
    Application.put_env(:optimal_system_agent, :compaction_warn, 0.0)
    Application.put_env(:optimal_system_agent, :compaction_aggressive, 1.1)
    Application.put_env(:optimal_system_agent, :compaction_emergency, 1.1)
    Application.put_env(:optimal_system_agent, :max_context_tokens, round(target_tokens / 0.70))
  end

  defp clear_severity_env do
    Application.delete_env(:optimal_system_agent, :compaction_warn)
    Application.delete_env(:optimal_system_agent, :compaction_aggressive)
    Application.delete_env(:optimal_system_agent, :compaction_emergency)
    Application.delete_env(:optimal_system_agent, :max_context_tokens)
    Application.delete_env(:optimal_system_agent, :compaction_chunk_token_limit)
  end

  defp build_conversation(n, word_count) do
    words = String.duplicate("word ", word_count)

    Enum.flat_map(1..n, fn i ->
      [
        %{role: "user", content: "User turn #{i}: #{words}"},
        %{role: "assistant", content: "Asst turn #{i}: #{words}"}
      ]
    end)
  end

  # Run a compaction under `session_id` that takes the chunked cold path, and
  # return the emitted `[Context Summary]` message content (or nil).
  defp compact_under(session_id) do
    Application.put_env(:optimal_system_agent, :compaction_chunk_token_limit, 30)
    messages = build_conversation(35, 8)

    rest_tokens = messages |> Enum.take(-50) |> Compactor.estimate_tokens()
    total_tokens = Compactor.estimate_tokens(messages)
    force_background_stop_at(rest_tokens + div(total_tokens - rest_tokens, 2))

    messages
    |> Compactor.maybe_compact(nil, session_id)
    |> Enum.find_value(fn m ->
      content = Map.get(m, :content, "")
      if String.contains?(content, "[Context Summary]"), do: content
    end)
  end

  setup do
    clear_all_summaries()

    on_exit(fn ->
      clear_severity_env()
      clear_all_summaries()
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Defect 1 — the compaction summary is session-scoped
  # ---------------------------------------------------------------------------

  describe "compaction summary — session isolation" do
    test "a summary written under session A is NOT visible to session B" do
      leak_marker = "SUMMARY_FROM_SESSION_A_DO_NOT_CROSS"
      :ets.insert(:osa_compactor_state, {{:previous_summary, "sess_a"}, leak_marker})

      content = compact_under("sess_b")

      assert content, "expected session B's compaction to emit a [Context Summary]"

      refute String.contains?(content, leak_marker),
             "session A's persisted summary was folded into session B's compaction"

      # And B's own compaction must not have overwritten A's slot either.
      assert [{{:previous_summary, "sess_a"}, ^leak_marker}] = summary_entry("sess_a")
    end

    test "POSITIVE CONTROL: a session's OWN previous summary IS folded back in" do
      # Without this, the assertion above could pass for the wrong reason (e.g.
      # the merge path never running at all). Same setup, same session id.
      own_marker = "SUMMARY_FROM_SESSION_B_OWN"
      :ets.insert(:osa_compactor_state, {{:previous_summary, "sess_b"}, own_marker})

      content = compact_under("sess_b")

      assert content

      assert String.contains?(content, own_marker),
             "a session must still merge into its OWN previous summary"
    end

    test "the global (unkeyed) :previous_summary slot is never written" do
      assert compact_under("sess_c")

      assert :ets.lookup(:osa_compactor_state, :previous_summary) == [],
             "the global summary key is the cross-session leak — it must stay empty"

      assert summary_entry("sess_c") != [],
             "the summary must be persisted under the session's own key"
    end

    test "two sessions keep independent summaries" do
      :ets.insert(:osa_compactor_state, {{:previous_summary, "sess_x"}, "X_ONLY"})
      :ets.insert(:osa_compactor_state, {{:previous_summary, "sess_y"}, "Y_ONLY"})

      assert [{_, "X_ONLY"}] = summary_entry("sess_x")
      assert [{_, "Y_ONLY"}] = summary_entry("sess_y")
    end
  end

  describe "compaction summary — teardown" do
    setup do
      :ets.insert(:osa_compactor_state, {{:previous_summary, "sess_td"}, "TEARDOWN_ME"})
      :ets.insert(:osa_compactor_state, {{:last_summary_at, "sess_td"}, DateTime.utc_now()})
      assert summary_entry("sess_td") != []
      :ok
    end

    test "forget_session/1 removes the entry" do
      assert Compactor.forget_session("sess_td") == :ok
      assert summary_entry("sess_td") == []
      assert :ets.lookup(:osa_compactor_state, {:last_summary_at, "sess_td"}) == []
    end

    test "forget_session/1 is idempotent and safe on nil / unknown sessions" do
      assert Compactor.forget_session("sess_td") == :ok
      assert Compactor.forget_session("sess_td") == :ok
      assert Compactor.forget_session("never_existed") == :ok
      assert Compactor.forget_session(nil) == :ok
    end

    test "Runtime.SessionTeardown.run/1 removes the entry (SessionManager path)" do
      ran = SessionTeardown.run("sess_td")

      assert :compactor_summary in ran,
             "compactor summary cleanup must be wired into the single teardown path"

      assert summary_entry("sess_td") == []
    end

    test "the CLI stop_session/1 path removes the entry (/clear, /new, exit)" do
      # The CLI stops its Loop directly rather than via SessionManager, so it
      # never reaches SessionTeardown — it must drop the summary itself.
      assert OptimalSystemAgent.Channels.CLI.Session.stop_session("sess_td") == :ok
      assert summary_entry("sess_td") == []
    end

    test "forget_session/1 does not touch OTHER sessions' summaries" do
      :ets.insert(:osa_compactor_state, {{:previous_summary, "sess_other"}, "KEEP_ME"})

      Compactor.forget_session("sess_td")

      assert summary_entry("sess_td") == []
      assert [{_, "KEEP_ME"}] = summary_entry("sess_other")
    end
  end

  # ---------------------------------------------------------------------------
  # Defect 2 — redaction is wired to the sinks
  # ---------------------------------------------------------------------------

  describe "redact/1 — no corruption of ordinary output" do
    # Over-eager redaction is its own bug: these are the shapes that LOOK
    # secret-ish and must survive byte-identical.
    @ordinary [
      "commit 9fceb02d0ae598e95dc970b74767f19372d61af8 refactor: tidy",
      "abcdef1234567890abcdef1234567890abcdef12  build/out.tar.gz",
      "session id 3f2504e0-4f89-11d3-9a0c-0305e82c3301 started",
      "integrity sha512-Xc9m0Zp7lQK5vZ8n2fLQ3sVb1xY6tGh0Jd4RwPqSuT8nLmKjHgFeDcBaZyXwVuTsRqPoNmLkJiHgFeDcBa==",
      "Bearer tokens are not supported by this endpoint",
      "Compiling 214 files (.ex) — Generated optimal_system_agent app",
      "npm WARN deprecated request@2.88.2: request has been deprecated",
      "-rw-r--r-- 1 user user 4096 Aug 10 12:00 secret_plans.md",
      "diff --git a/lib/foo.ex b/lib/foo.ex\n-  defp secret_sauce(x), do: x\n"
    ]

    for {text, idx} <- Enum.with_index(@ordinary) do
      test "leaves ordinary output ##{idx} byte-identical" do
        text = unquote(text)
        assert Trajectory.redact(text) == text
      end
    end
  end

  describe "redact/1 — recognises the shapes that actually leak" do
    @secrets [
      {"json Authorization header",
       ~s|{"headers":{"Authorization":"Bearer sk-ant-api03-LEAKAAAABBBBCCCCDDDD"}}|,
       "sk-ant-api03-LEAKAAAABBBBCCCCDDDD"},
      {"git remote with token in url",
       "origin\thttps://x-access-token:ghp_LEAKABCDEFGHIJKLMNOPQRSTUV@github.com/o/r.git (fetch)",
       "ghp_LEAKABCDEFGHIJKLMNOPQRSTUV"},
      {"env dump", "OPENAI_API_KEY=sk-proj-LEAKabcdefghijklmnopqrstuvwxyz",
       "sk-proj-LEAKabcdefghijklmnopqrstuvwxyz"},
      {"aws key id", "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE", "AKIAIOSFODNN7EXAMPLE"}
    ]

    for {name, text, secret} <- @secrets do
      test "redacts a #{name}" do
        refute String.contains?(Trajectory.redact(unquote(text)), unquote(secret))
      end
    end
  end

  describe "redaction call sites" do
    test "compaction summarization text (format_for_summary/1) is redacted" do
      key = planted_key("FMTSUM")

      messages = [
        %{role: "user", content: "run env"},
        %{role: "tool", content: "OPENAI_API_KEY=#{key}"},
        %{role: "assistant", content: "the key is #{key}"}
      ]

      formatted = Compactor.format_for_summary(messages)

      refute String.contains?(formatted, key),
             "a planted key reached the summarization prompt (and thus the provider)"

      # Structure must survive: this is still the role-prefixed transcript.
      assert String.contains?(formatted, "user: run env")
    end

    test "redaction happens BEFORE the tool-output cap, not as a side effect of it" do
      # `format_for_summary/1` caps tool output at 2_000 chars. A key in the
      # first bytes survives that cap, so the cap must not be what is relied on
      # — the scrub has to be a real scrub.
      key = planted_key("PRECAP")
      long = "TOKEN=#{key}\n" <> String.duplicate("filler line\n", 500)

      formatted = Compactor.format_for_summary([%{role: "tool", content: long}])

      refute String.contains?(formatted, key)
      assert String.contains?(formatted, "filler line")
    end

    test "a multi-message summarization block is scrubbed at every role" do
      user_key = planted_key("ROLEUSER")
      tool_key = planted_key("ROLETOOL")
      asst_key = planted_key("ROLEASST")

      formatted =
        Compactor.format_for_summary([
          %{role: "user", content: "use #{user_key}"},
          %{role: "tool", content: "echoed #{tool_key}"},
          %{role: "assistant", content: "confirmed #{asst_key}"}
        ])

      for k <- [user_key, tool_key, asst_key] do
        refute String.contains?(formatted, k)
      end

      assert String.contains?(formatted, "assistant: confirmed")
    end

    test "the subagent transcript on disk carries no planted key" do
      key = planted_key("RUNSTORE")
      tmp = Path.join(System.tmp_dir!(), "osa_conf_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      prev = Application.get_env(:optimal_system_agent, :agent_runs_dir)
      Application.put_env(:optimal_system_agent, :agent_runs_dir, tmp)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:optimal_system_agent, :agent_runs_dir, prev),
          else: Application.delete_env(:optimal_system_agent, :agent_runs_dir)

        File.rm_rf(tmp)
      end)

      id = "conf_agent_#{System.unique_integer([:positive])}"

      RunStore.start_run(%{
        agent_id: id,
        parent_session_id: "parent",
        role: "agent",
        task: "call the api with #{key}"
      })

      RunStore.progress(id, "ran: curl -H 'Authorization: Bearer #{key}'", 1)

      RunStore.complete(id, %{
        agent_id: id,
        status: :completed,
        duration_ms: 1,
        summary: "used #{key}"
      })

      written = File.read!(Path.join(tmp, "#{id}.md"))

      refute String.contains?(written, key),
             "a planted key was persisted to the subagent transcript on disk"

      assert String.contains?(written, "START role=agent"),
             "redaction must not have destroyed the transcript structure"
    end

    test "the CLI tool line does not print tool arguments containing a key" do
      key = planted_key("SPINARG")

      output =
        capture_io(fn ->
          spinner = Spinner.start()
          Spinner.update(spinner, {:tool_start, "shell_execute", "curl -H 'Bearer #{key}'"})
          Spinner.update(spinner, {:tool_end, "shell_execute", 12})
          # Let the spinner process drain both messages before we stop it.
          Process.sleep(120)
          Spinner.stop(spinner)
        end)

      refute String.contains?(output, key),
             "a planted key in tool arguments was printed to the terminal"

      assert String.contains?(output, "shell_execute"),
             "the tool line itself must still be shown"
    end

    test "the CLI does not print a computer_use result containing a key" do
      key = planted_key("SPINRES")

      output =
        capture_io(fn ->
          spinner = Spinner.start()
          Spinner.update(spinner, {:computer_use_result, "OPENAI_API_KEY=#{key}"})
          Process.sleep(120)
          Spinner.stop(spinner)
        end)

      refute String.contains?(output, key),
             "a planted key in tool output was printed to the terminal"
    end
  end
end
