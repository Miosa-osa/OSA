defmodule OptimalSystemAgent.Agent.Loop.FullWindowCompactionTest do
  @moduledoc """
  Compaction on a model whose whole 1M window is live.

  Reported live on `deepseek-v4.1-flash:cloud` at 159.3k tokens, from the
  daemon log:

      Compactor: 159293/200000 tokens ... running background pipeline
      Compactor cold-zone LLM summarization failed: "Empty chunk-summary response: \\"\\""
      Compactor pipeline (background): 159293 -> 88187 tokens (... last_step=emergency_truncate)

  24 fixed 3k-token chunks were summarized one after another (1m49s). One
  came back empty (with thinking on, the model spent its 600-token budget
  reasoning), which discarded all 24 and dropped history outright. At a full
  1M window the same rules would mean ~300 sequential calls.

  These tests drive the summarizer through `MockProvider` with the LLM path
  enabled (the test config disables it globally).
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Compactor
  alias OptimalSystemAgent.Agent.Loop.ProactiveCompaction
  alias OptimalSystemAgent.Test.MockProvider

  @window 1_048_576

  @summary """
  1. Primary Request and Intent: keep working on the parser refactor.
  2. Key Technical Concepts: Elixir, GenServer.
  3. Files and Code Sections: lib/parser.ex.
  4. Errors and fixes: none outstanding.
  5. Problem Solving: split the tokenizer from the reducer.
  6. All user messages: see above.
  7. Pending Tasks: finish the reducer tests.
  8. Current Work: wiring the reducer into the pipeline.
  9. Optional Next Step: run the suite.
  """

  # The cold summarizer folds its previous structured summary (kept in the
  # shared :osa_compactor_state table) into the next one; another test's entry
  # would show up here as extra chunks.
  defp clear_previous_summary do
    :ets.match_delete(:osa_compactor_state, {{:previous_summary, :_}, :_})
    :ets.match_delete(:osa_compactor_state, {{:last_summary_at, :_}, :_})
  rescue
    ArgumentError -> :ok
  end

  setup do
    clear_previous_summary()

    keys = [
      :default_provider,
      :mock_provider_module,
      :mock_provider_script,
      :compactor_llm_enabled,
      :live_env_file_fallback
    ]

    prev = Map.new(keys, &{&1, Application.get_env(:optimal_system_agent, &1)})
    prev_default = System.get_env("OSA_DEFAULT_PROVIDER")

    # The summarizer resolves its provider the way a live session does, which
    # includes OSA_DEFAULT_PROVIDER and ~/.osa/.env. Without this, a developer
    # machine with a configured default sends these calls to a real model.
    System.delete_env("OSA_DEFAULT_PROVIDER")
    Application.put_env(:optimal_system_agent, :live_env_file_fallback, false)

    Application.put_env(:optimal_system_agent, :default_provider, :mock)
    Application.put_env(:optimal_system_agent, :mock_provider_module, MockProvider)
    Application.put_env(:optimal_system_agent, :compactor_llm_enabled, true)

    calls = :ets.new(:full_window_calls, [:public, :bag])

    on_exit(fn ->
      clear_previous_summary()
      if prev_default, do: System.put_env("OSA_DEFAULT_PROVIDER", prev_default)

      Enum.each(prev, fn
        {k, nil} -> Application.delete_env(:optimal_system_agent, k)
        {k, v} -> Application.put_env(:optimal_system_agent, k, v)
      end)
    end)

    {:ok, calls: calls}
  end

  defp record_and_reply(calls, reply_fun) do
    Application.put_env(:optimal_system_agent, :mock_provider_script, fn messages, opts ->
      prompt = messages |> List.last() |> Map.get(:content)
      :ets.insert(calls, {:call, prompt, opts})
      %{content: reply_fun.(prompt), tool_calls: []}
    end)
  end

  defp calls(table), do: for({:call, prompt, opts} <- :ets.tab2list(table), do: {prompt, opts})

  # ~`turns` user/assistant turns of ~`words` words each.
  defp history(turns, words) do
    filler = String.duplicate("the parser reducer keeps state across tokens ", div(words, 7))

    Enum.flat_map(1..turns, fn i ->
      [
        %{role: "user", content: "turn #{i}: #{filler}"},
        %{role: "assistant", content: "done #{i}: #{filler}"}
      ]
    end)
  end

  describe "a fold far larger than one summarizer call" do
    test "is summarized in concurrent segments plus one merge, with thinking off",
         %{calls: table} do
      record_and_reply(table, fn _ -> @summary end)

      messages = history(150, 1_000)
      total = Compactor.estimate_tokens(messages)
      assert total > 250_000, "precondition: a large history (#{total} tokens)"

      result = ProactiveCompaction.compact(messages, nil, nil, :auto, context_window: @window)

      made = calls(table)
      segment_calls = Enum.filter(made, fn {p, _} -> p =~ ~r/^This is part \d+ of \d+/ end)
      merge_calls = Enum.filter(made, fn {p, _} -> p =~ "Merge them into ONE summary" end)

      assert length(segment_calls) >= 3,
             "#{total} tokens went to #{length(segment_calls)} segment calls"

      assert length(merge_calls) == 1

      for {_prompt, opts} <- made do
        assert Keyword.get(opts, :thinking_disabled) == true,
               "a summarizer call ran with thinking on: #{inspect(opts)}"
      end

      for {_prompt, opts} <- segment_calls do
        assert Keyword.get(opts, :max_tokens) == 2_048
      end

      after_tokens = Compactor.estimate_tokens(result)

      assert after_tokens < 60_000,
             "a #{total}-token fold on a 1M window landed at #{after_tokens} tokens"
    end
  end

  describe "the kept verbatim tail on a 1M window" do
    test "is capped, so the fold does not keep ~157k of history", %{calls: table} do
      record_and_reply(table, fn _ -> @summary end)

      # Small enough for one summarizer call, so only the tail is measured.
      messages = history(60, 1_000)
      result = ProactiveCompaction.compact(messages, nil, nil, :auto, context_window: @window)

      kept_verbatim =
        result
        |> Enum.filter(fn m -> is_binary(m[:content]) and m.content =~ ~r/^(turn|done) \d+:/ end)
        |> Compactor.estimate_tokens()

      # 40k cap, plus at most one turn of slack for the turn boundary.
      assert kept_verbatim <= 40_000 + 4_000,
             "#{kept_verbatim} tokens of history were kept verbatim"
    end
  end

  describe "the chunked cold-zone summary" do
    test "keeps the other chunks when one chunk's summary comes back empty",
         %{calls: table} do
      # The 4th chunk to be summarized returns "", as reported live.
      counter = :counters.new(1, [])

      record_and_reply(table, fn prompt ->
        if prompt =~ "excerpt" or prompt =~ "Summarize" do
          :counters.add(counter, 1, 1)
          if :counters.get(counter, 1) == 4, do: "", else: String.duplicate("- fact ", 30)
        else
          String.duplicate("- fact ", 30)
        end
      end)

      cold = history(120, 1_000)

      assert {:ok, body, :divide_and_conquer} = Compactor.call_cold_summary(cold)

      chunks = (body |> String.split("<chunk_summary") |> length()) - 1
      assert chunks > 1 and chunks <= 24, "#{chunks} chunks"
      assert body =~ "- fact", "the chunks that succeeded were discarded"
      assert body =~ "- user: turn", "the failed chunk left no trace of what the user asked"

      for {_prompt, opts} <- calls(table) do
        assert Keyword.get(opts, :thinking_disabled) == true
      end
    end

    test "fans out into at most 24 calls however large the span" do
      span = Compactor.estimate_tokens(history(400, 1_000))
      limit = Compactor.chunk_token_limit_for(history(400, 1_000))

      assert div(span + limit - 1, limit) <= 24,
             "#{span} tokens at #{limit} per chunk is more than 24 calls"
    end
  end
end
