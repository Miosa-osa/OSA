defmodule OptimalSystemAgent.Providers.SurplusClaudeParityTest do
  @moduledoc """
  Surplus is an OpenAI-compatible gateway that fronts Anthropic for its Claude
  ids. Anthropic performs NO automatic prefix caching — `cache_control`
  breakpoints are the only mechanism — so a Claude model reached through Surplus
  must be treated exactly like one reached through OpenRouter: blocks emitted,
  breakpoints preserved on the wire. Before the fix `anthropic_prompt_cache?/2`
  only recognised the `anthropic/`-prefixed OpenRouter route, so every Surplus
  Claude turn sent its whole static prefix uncached at full input rate — the
  0%-hit-rate, token-burn defect this locks closed, without widening the
  carve-out to Surplus's non-Claude ids (which must never carry an Anthropic
  field to a non-Anthropic upstream).

  It also pins the context-window fix: Surplus relists `claude-opus-4-8` under
  the dotted id `claude-opus-4.8`, which missed the catalog's 1M window and
  defaulted to 128k — mis-stating context% and mis-timing compaction.
  """
  # async: false — the headless describe mutates `:<provider>_model` app-env,
  # which is process-global.
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.Registry
  alias OptimalSystemAgent.Providers.PromptCache
  alias OptimalSystemAgent.Agent.Loop.ContextWindow

  # Surplus's two featured Claude ids and its non-Claude ids (which must be
  # left byte-identical). From Providers.SurplusModels.
  @surplus_claude ["claude-fable-5.1", "claude-opus-4.8"]
  @surplus_non_claude ["gpt-6-astra", "glm-5.3", "grok-4.6", "minimax-m2"]

  @static_base "STATIC BASE: you are OSA."
  @world_state "WORLD STATE: tool doctrine and AGENTS.md."
  @volatile "VOLATILE: - Timestamp: 2026-09-08T00:00:00Z"

  defp block_system do
    [
      %{type: "text", text: @static_base, cache_control: %{type: "ephemeral"}},
      %{type: "text", text: @world_state, cache_control: %{type: "ephemeral"}},
      %{type: "text", text: @volatile}
    ]
  end

  defp flat_system, do: Enum.join([@static_base, @world_state, @volatile], "\n\n")

  defp block_messages,
    do: [%{role: "system", content: block_system()}, %{role: "user", content: "hi"}]

  describe "caching capability gate (finding #1)" do
    test "a Surplus Claude model honours cache_control, dispatch tuple and bare atom" do
      for model <- @surplus_claude do
        assert Registry.anthropic_prompt_cache?({:compat, :surplus}, model),
               "#{model} on Surplus fronts Anthropic and must honour cache_control"

        assert Registry.anthropic_prompt_cache?(:surplus, model)
      end
    end

    test "a Surplus non-Claude model does NOT — no Anthropic field to a non-Anthropic upstream" do
      for model <- @surplus_non_claude do
        refute Registry.anthropic_prompt_cache?({:compat, :surplus}, model),
               "#{model} is not Anthropic-backed; cache_control would be a foreign field"
      end
    end

    test "the OpenRouter and native routes are unchanged" do
      assert Registry.anthropic_prompt_cache?({:compat, :openrouter}, "anthropic/claude-opus-5")
      assert Registry.anthropic_prompt_cache?(:anthropic, "claude-opus-5")
      refute Registry.anthropic_prompt_cache?({:compat, :openrouter}, "openai/gpt-4o")
    end
  end

  describe "breakpoints survive dispatch for Surplus Claude, flatten for the rest" do
    test "Claude keeps its block list (breakpoints reach the gateway)" do
      for model <- @surplus_claude do
        [system | _] =
          Registry.normalize_message_content(block_messages(), {:compat, :surplus}, model: model)

        assert is_list(system.content),
               "#{model}: flattening deletes every breakpoint and pins the hit rate at 0%"
      end
    end

    test "non-Claude is flattened to the exact pre-fix bytes" do
      for model <- @surplus_non_claude do
        [system | _] =
          Registry.normalize_message_content(block_messages(), {:compat, :surplus}, model: model)

        assert is_binary(system.content)
        assert system.content == flat_system()
        refute system.content =~ "cache_control"
      end
    end
  end

  describe "context window for Surplus Claude ids (finding #3)" do
    test "the dotted claude-opus-4.8 resolves to its real 1M window, not the 128k default" do
      assert Registry.context_window("claude-opus-4.8") == 1_000_000
    end

    test "claude-fable-5.1 also resolves to 1M" do
      assert Registry.context_window("claude-fable-5.1") == 1_000_000
    end
  end

  # The route allowlist is GONE — the gate now asks "compat gateway + Claude id",
  # not "is this one of two blessed providers". This is what stops the next
  # reseller from shipping the Surplus dead-cache bug.
  describe "capability-keyed gate covers EVERY Claude-fronting compat route" do
    test "uncensored — whose DEFAULT model is claude-opus-5 — now honours cache_control" do
      # This route returned false before the refactor: a second live dead-cache
      # bug the allowlist hid.
      assert Registry.anthropic_prompt_cache?({:compat, :uncensored}, "claude-opus-5")
      assert Registry.anthropic_prompt_cache?({:compat, :uncensored}, "claude-opus-4.8")
      refute Registry.anthropic_prompt_cache?({:compat, :uncensored}, "glm-5.2")
    end

    test "a hypothetical NEW compat reseller serving a Claude id caches with no code change" do
      # :miosa and :custom are compat routes that could front Claude; the gate
      # must not need a per-provider clause for them.
      assert Registry.anthropic_prompt_cache?({:compat, :miosa}, "claude-opus-5")
      assert Registry.anthropic_prompt_cache?({:compat, :custom}, "anthropic/claude-sonnet-5")
    end

    test "a compat route serving a non-Claude id never receives cache_control" do
      for id <- ["gpt-5.6-terra", "glm-5.3", "grok-4.6", "gemini-3.1-pro", "deepseek-v4-pro"] do
        refute Registry.anthropic_prompt_cache?({:compat, :openrouter}, id)
        refute Registry.anthropic_prompt_cache?({:compat, :surplus}, id)
      end
    end

    test "Bedrock is NOT in this gate — it fronts Anthropic over cachePoint, its own path" do
      refute Registry.anthropic_prompt_cache?(
               OptimalSystemAgent.Providers.Bedrock,
               "claude-opus-5"
             )
    end

    test "native Anthropic always honours it, regardless of id spelling" do
      assert Registry.anthropic_prompt_cache?(:anthropic, "claude-opus-4.8")
      assert Registry.anthropic_prompt_cache?(OptimalSystemAgent.Providers.Anthropic, "anything")
    end
  end

  # Headless/serve/benchmark: no :model in opts and no :<provider>_model app-env.
  # Before this, resolved_model returned nil → the route looked non-caching and
  # the window fell to the fallback. Now it falls back to the provider's own
  # default — capability only, never routing.
  describe "headless (no :model, no app-env) resolves the provider default" do
    setup do
      keys = [:surplus_model, :uncensored_model, :openrouter_model]
      prev = Enum.map(keys, &{&1, Application.get_env(:optimal_system_agent, &1)})
      Enum.each(keys, &Application.delete_env(:optimal_system_agent, &1))

      on_exit(fn ->
        Enum.each(prev, fn
          {k, nil} -> Application.delete_env(:optimal_system_agent, k)
          {k, v} -> Application.put_env(:optimal_system_agent, k, v)
        end)
      end)

      :ok
    end

    test "(a) caching turns ON: surplus/uncensored/openrouter resolve their Claude default" do
      for target <- [{:compat, :surplus}, {:compat, :uncensored}, {:compat, :openrouter}] do
        model = Registry.resolved_model(target, [])
        assert is_binary(model) and model =~ "claude", "#{inspect(target)} -> #{inspect(model)}"
        assert Registry.anthropic_prompt_cache?(target, model)
      end
    end

    test "(a) context window turns ON: a headless Surplus/Uncensored session sizes at 1M" do
      assert ContextWindow.resolve(%{provider: :surplus}) == {:ok, 1_000_000}
      assert ContextWindow.resolve(%{provider: :uncensored}) == {:ok, 1_000_000}
    end

    test "a non-Claude default (openai) stays uncached — the fallback is not blanket-on" do
      model = Registry.resolved_model({:compat, :openai}, [])
      assert is_binary(model)
      refute model =~ "claude"
      refute Registry.anthropic_prompt_cache?({:compat, :openai}, model)
    end
  end

  # INCREMENTAL HISTORY CACHING — the biggest $ lever on a 126:1 input:output
  # loop. Fixing the gate does not just cache the static prefix; it also unblocks
  # PromptCache.restructure (gated on the same predicate), which rolls a cache
  # breakpoint onto the LAST HISTORY message so turn N re-reads turns 1..N-1 at
  # 0.1x instead of full rate. Before the gate fix this SKIPPED for Surplus.
  describe "rolling history breakpoint reaches Surplus Claude (incremental history caching)" do
    defp history_messages do
      [
        %{role: "system", content: block_system()},
        %{role: "user", content: "read the file"},
        %{role: "assistant", content: "reading"},
        %{role: "tool", tool_call_id: "t1", name: "read", content: "line one\nline two"},
        %{role: "assistant", content: "done"}
      ]
    end

    defp marked?(%{content: parts}) when is_list(parts),
      do:
        Enum.any?(
          parts,
          &(is_map(&1) and (Map.has_key?(&1, :cache_control) or Map.has_key?(&1, "cache_control")))
        )

    defp marked?(_), do: false

    test "the last history message carries a breakpoint for a Surplus Claude model" do
      out =
        PromptCache.restructure(history_messages(), {:compat, :surplus}, model: "claude-opus-4.8")

      # Shape: [system | history-with-last-marked] ++ [volatile tail].
      history_part = out |> Enum.drop(1) |> Enum.drop(-1)
      assert history_part != []

      assert marked?(List.last(history_part)),
             "no rolling breakpoint on the last history message — turns 1..N-1 re-read at full rate"
    end

    test "a Surplus NON-Claude model is left untouched (no rolling breakpoint)" do
      msgs = history_messages()
      assert PromptCache.restructure(msgs, {:compat, :surplus}, model: "gpt-6-astra") == msgs
    end
  end

  # The load-bearing safety property: the fallback feeds capability only. An
  # explicit choice always wins, and the value is never a routing input.
  describe "(b) model selection is unchanged — capability-only, never routing" do
    test "an explicit model always wins; the default never overrides it" do
      assert Registry.resolved_model({:compat, :surplus}, model: "gpt-6-astra") == "gpt-6-astra"

      assert Registry.resolved_model({:compat, :openrouter}, model: "openai/gpt-4o") ==
               "openai/gpt-4o"
    end

    test "an explicit model drives the window; the provider default is not consulted" do
      # kimi-k3 has no catalog window → :unknown. If the default (claude, 1M) had
      # leaked in, this would be {:ok, 1_000_000}. It must stay :unknown.
      assert ContextWindow.resolve(%{provider: :surplus, model: "kimi-k3"}) == :unknown
    end

    test "provider_default_model is a pure read (same answer, no state change)" do
      a = Registry.provider_default_model({:compat, :surplus})
      b = Registry.provider_default_model({:compat, :surplus})
      assert a == b
      assert a == "claude-fable-5.1"
    end
  end

  # #3 diagnostic: on a WARM Claude turn that carries tools, emit a telemetry
  # event reporting whether the tool-schema array is inside the cached prefix or
  # re-sent as fresh input each turn. Measures only — places no cache hint.
  describe "tool-schema cache probe (diagnostic)" do
    alias OptimalSystemAgent.Providers.OpenAICompat

    @probe [:osa, :prompt_cache, :tool_schema_probe]

    setup do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        "probe-#{inspect(ref)}",
        @probe,
        fn _e, meas, meta, _ -> send(parent, {:probe, meas, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("probe-#{inspect(ref)}") end)
      # The human-readable line dedupes per process; clear it so each test can
      # exercise the log path independently of ordering.
      Process.delete(:osa_tool_schema_probed)
      :ok
    end

    # Internal tool shape (atom keys) — what `opts[:tools]` carries in production
    # and what `format_tools/1` consumes.
    @tools [
      %{
        name: "read",
        description: String.duplicate("read a file from disk ", 400),
        parameters: %{"type" => "object", "properties" => %{}}
      }
    ]

    test "warm turn where fresh input dwarfs the tool array → flagged UNCACHED" do
      # total_input inclusive; fresh = 30000 - 100 - 0 = 29900 >> tool tokens.
      usage = %{
        input_tokens: 30_000,
        output_tokens: 200,
        cache_read_input_tokens: 100,
        cache_creation_input_tokens: 0
      }

      OpenAICompat.probe_tool_schema_cache(usage, [tools: @tools], "claude-opus-4.8")

      assert_receive {:probe, meas, %{tools_cached: false, model: "claude-opus-4.8"}}
      assert meas.tool_tokens > 0
      assert meas.fresh_input == 29_900
    end

    test "warm turn where fresh input is tiny → tools appear cached" do
      usage = %{
        input_tokens: 30_000,
        output_tokens: 200,
        # Nearly the whole prompt served from cache; only ~50 fresh tokens.
        cache_read_input_tokens: 29_950,
        cache_creation_input_tokens: 0
      }

      OpenAICompat.probe_tool_schema_cache(usage, [tools: @tools], "claude-opus-4.8")

      assert_receive {:probe, _meas, %{tools_cached: true}}
    end

    test "a COLD turn (no cache read) does not fire the probe" do
      usage = %{
        input_tokens: 30_000,
        output_tokens: 200,
        cache_read_input_tokens: 0,
        cache_creation_input_tokens: 0
      }

      OpenAICompat.probe_tool_schema_cache(usage, [tools: @tools], "claude-opus-4.8")
      refute_receive {:probe, _, _}, 50
    end

    test "a non-Claude model does not fire the probe" do
      usage = %{
        input_tokens: 30_000,
        output_tokens: 200,
        cache_read_input_tokens: 100,
        cache_creation_input_tokens: 0
      }

      OpenAICompat.probe_tool_schema_cache(usage, [tools: @tools], "gpt-6-astra")
      refute_receive {:probe, _, _}, 50
    end
  end
end
