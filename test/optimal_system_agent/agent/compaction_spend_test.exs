defmodule OptimalSystemAgent.Agent.CompactionSpendTest do
  @moduledoc """
  Compaction's own LLM calls are real money and used to be recorded NOWHERE.

  `Compactor.bounded_chat/2` is the single choke point for every provider call
  the compaction subsystem makes (`call_summary_llm/1`, `call_key_facts_llm/1`,
  `summarize_chunk/2`, and `Loop.ProactiveCompaction.summarize/2`). It called
  `Providers.chat/2` directly, so none of that usage ever reached
  `Loop.Accounting.record/2`: `session_cost_usd`, the `max_budget_usd` cap, the
  spend sidecar and every `$/task` figure downstream all behaved as if
  summarization were free.

  These tests pin that it is now billed, and — just as important — billed
  EXACTLY ONCE.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Compactor
  alias OptimalSystemAgent.Agent.Loop.Accounting
  alias OptimalSystemAgent.Agent.Loop.ProactiveCompaction

  @usage %{input_tokens: 1_000_000, output_tokens: 100_000}

  setup do
    prev_provider = Application.get_env(:optimal_system_agent, :default_provider)
    prev_usage = Application.get_env(:optimal_system_agent, :mock_provider_usage)
    prev_text = Application.get_env(:optimal_system_agent, :mock_provider_final_text)

    Application.put_env(:optimal_system_agent, :mock_provider_final_text, "summary text")
    Application.put_env(:optimal_system_agent, :mock_provider_usage, @usage)

    sid = "compaction-spend-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      restore(:default_provider, prev_provider)
      restore(:mock_provider_usage, prev_usage)
      restore(:mock_provider_final_text, prev_text)
      Accounting.forget_side_spend(sid)
      Process.delete(:osa_compact_session_id)

      if Process.whereis(OptimalSystemAgent.Budget) do
        OptimalSystemAgent.Budget.reset_daily()
        OptimalSystemAgent.Budget.reset_monthly()
        OptimalSystemAgent.Budget.get_status()
      end
    end)

    {:ok, session_id: sid}
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, value), do: Application.put_env(:optimal_system_agent, key, value)

  defp state_for(session_id) do
    %{
      session_id: session_id,
      model: "claude-3-5-sonnet",
      provider: :anthropic,
      last_input_tokens: 4242,
      session_cost_usd: 0.0,
      session_input_tokens: 0,
      session_output_tokens: 0,
      session_cache_creation_tokens: 0,
      session_cache_read_tokens: 0,
      max_budget_usd: nil
    }
  end

  describe "Compactor.bounded_chat/2 bills the summarizer round-trip" do
    test "staged spend reaches the session ledger and is priced against the summarizer's model",
         %{session_id: sid} do
      Process.put(:osa_compact_session_id, sid)

      assert {:ok, %{content: "summary text"}} =
               Compactor.bounded_chat([%{role: "user", content: "summarize"}],
                 provider: :mock,
                 model: "claude-3-5-sonnet",
                 max_tokens: 400
               )

      staged = Accounting.peek_side_spend(sid)
      assert staged.calls == 1
      assert staged.kinds == [:compaction]
      assert staged.usage.input_tokens == 1_000_000
      assert staged.usage.output_tokens == 100_000
      # claude-3-5-sonnet = {$3/1M in, $15/1M out} → 1M*3 + 0.1M*15 = $4.50
      assert_in_delta staged.cost_usd, 4.5, 0.000_001

      # ...and absorbing it moves it onto the session's own counters, which is
      # what `session_cost_usd` / the spend sidecar / `$ per task` all read.
      state = Accounting.absorb_side_spend(state_for(sid))
      assert_in_delta state.session_cost_usd, 4.5, 0.000_001
      assert state.session_input_tokens == 1_000_000
      assert state.session_output_tokens == 100_000
    end

    test "two summarizer calls accumulate, and absorbing twice cannot double-bill",
         %{session_id: sid} do
      Process.put(:osa_compact_session_id, sid)

      for _ <- 1..2 do
        assert {:ok, _} =
                 Compactor.bounded_chat([%{role: "user", content: "x"}],
                   provider: :mock,
                   model: "claude-3-5-sonnet"
                 )
      end

      assert Accounting.peek_side_spend(sid).calls == 2

      state = Accounting.absorb_side_spend(state_for(sid))
      assert_in_delta state.session_cost_usd, 9.0, 0.000_001

      # The ledger row is CONSUMED by absorb, so a second absorb (a second
      # compaction boundary in the same turn) adds nothing.
      assert Accounting.peek_side_spend(sid) == nil
      again = Accounting.absorb_side_spend(state)
      assert again.session_cost_usd == state.session_cost_usd
      assert again.session_input_tokens == state.session_input_tokens
    end

    test "absorbing does NOT move last_input_tokens", %{session_id: sid} do
      # The summarizer's prompt is not the session's context. Writing it to
      # `last_input_tokens` would make the context-pressure meter — and
      # therefore the compaction trigger — read the summarizer's prompt size as
      # the conversation's size.
      Process.put(:osa_compact_session_id, sid)

      assert {:ok, _} =
               Compactor.bounded_chat([%{role: "user", content: "x"}],
                 provider: :mock,
                 model: "claude-3-5-sonnet"
               )

      state = Accounting.absorb_side_spend(state_for(sid))
      assert state.last_input_tokens == 4242
    end

    test "with no compaction session in scope the spend is dropped, not misattributed" do
      Process.delete(:osa_compact_session_id)

      assert {:ok, _} =
               Compactor.bounded_chat([%{role: "user", content: "x"}],
                 provider: :mock,
                 model: "claude-3-5-sonnet"
               )

      assert Accounting.peek_side_spend(nil) == nil
    end
  end

  describe "the single-reconcile invariant" do
    test "an OpenAI-shaped (inclusive) usage map is reconciled exactly once" do
      # `reconcile_prompt_slices/2` is NOT idempotent: for an inclusive provider
      # it subtracts the cached overlap out of `input_tokens`. Staging reconciles
      # once; absorbing must only add. Applying it twice would silently
      # under-bill the fresh input by the cached amount.
      sid = "reconcile-once-#{System.unique_integer([:positive])}"
      on_exit(fn -> Accounting.forget_side_spend(sid) end)

      Accounting.stage_side_spend(
        sid,
        %{input_tokens: 1_000, output_tokens: 0, cache_read_input_tokens: 900},
        provider: :openai,
        model: "gpt-4o"
      )

      staged = Accounting.peek_side_spend(sid)
      # 1000 inclusive of 900 cached → 100 fresh + 900 read, each counted once.
      assert staged.usage.input_tokens == 100
      assert staged.usage.cache_read_input_tokens == 900

      state = Accounting.absorb_side_spend(state_for(sid))
      assert state.session_input_tokens == 100
      assert state.session_cache_read_tokens == 900
    end
  end

  describe "ProactiveCompaction session attribution" do
    test "compact/3 publishes the session id for the summarizer to bill against, " <>
           "and restores the prior value" do
      Process.put(:osa_compact_session_id, "outer-session")

      messages =
        for i <- 1..40 do
          %{role: "user", content: String.duplicate("token#{i} ", 200)}
        end

      _ = ProactiveCompaction.compact(messages, "inner-session")

      assert Process.get(:osa_compact_session_id) == "outer-session"
    end
  end
end
