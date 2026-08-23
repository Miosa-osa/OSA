defmodule OptimalSystemAgent.Agent.Context do
  @moduledoc """
  Two-tier token-budgeted system prompt assembly.

  ## Architecture

  The context builder operates in two tiers:

      Tier 1 — Static Base (cached, from Soul.static_base/0)
        SYSTEM.md interpolated with {{TOOL_DEFINITIONS}}, {{RULES}}, {{USER_PROFILE}}.
        Cached in persistent_term. Never recomputed within a session.
        Includes Signal Theory instructions — the LLM self-classifies signals.

      Tier 2 — Dynamic Context (per-request, token-budgeted)
        Runtime, environment, plan mode, memory, tasks, workflow.
        All blocks are budget-fitted to prevent overflow.

  No code-level signal classification on the hot path. The LLM reads the
  Signal Theory tables in SYSTEM.md and applies Mode/Genre/Weight behavior
  natively — same pattern as the upstream agent CLI, Cursor, Windsurf.

  ## Token Budget

      dynamic_budget = max_tokens - static_tokens - conversation_tokens - reserve

  ## Provider Cache Hints

  For Anthropic, the system message is split into 2 content blocks:
    - Static base with `cache_control: %{type: "ephemeral"}` (~90% cache hit)
    - Dynamic context (per-request, uncached)

  ## Public API

      build(state)         — returns %{messages: [system_msg | conversation]}
      token_budget(state)  — returns token usage breakdown map
  """

  require Logger

  alias OptimalSystemAgent.Agent.Context.Budget
  alias OptimalSystemAgent.Agent.Context.PromptTemplate
  alias OptimalSystemAgent.Agent.Context.WorldState
  alias OptimalSystemAgent.Agent.ProjectInstructions
  alias OptimalSystemAgent.Agent.Scratchpad
  alias OptimalSystemAgent.Agent.Tasks
  alias OptimalSystemAgent.Agent.Memory.Episodic
  alias OptimalSystemAgent.Memory.Scoring
  alias OptimalSystemAgent.Soul

  @response_reserve 8_192

  # Smallest dynamic budget the assembler will operate with. See
  # `report_budget_shortfall/2` for why reaching it is reported rather than
  # absorbed. Declared here, before its first use in `token_budget/1`.
  @dynamic_budget_floor 1_000

  # A window at or below this is "small": it gets the trimmed prompt variant and
  # the trimmed tool list. This is a property of the MODEL's resolved window, not
  # of the provider transport — see `small_window?/2`.
  @small_window_tokens 40_000

  # Ceiling on the embedding round-trip taken while ASSEMBLING a prompt. A local
  # `nomic-embed-text` call answers in tens of milliseconds; anything past this
  # is a sick sidecar, and prompt assembly must not wait on one. Overridable via
  #   config :optimal_system_agent, :prompt_embed_deadline_ms, N
  @prompt_embed_deadline_ms 300

  defp prompt_embed_deadline_ms,
    do:
      Application.get_env(
        :optimal_system_agent,
        :prompt_embed_deadline_ms,
        @prompt_embed_deadline_ms
      )

  # Fraction of the REAL window the response reserve may claim. A flat 8k reserve
  # is right for a 128k+ cloud window and catastrophic for a 32k local one: with a
  # ~24k static base, 8k of reserve leaves 964 tokens for ALL dynamic context and
  # the entire conversation, so `dynamic_budget` pinned to its 1_000 floor and the
  # world state ate every token before a single per-turn block was fitted. That is
  # how the runtime block — 57 tokens carrying the session id, the channel and the
  # model identity — was being dropped on every build. The reserve is an output
  # allowance, so it scales with the window instead of being a constant sized for
  # the largest one.
  @response_reserve_frac 8

  defp response_reserve(max_tok),
    do: min(@response_reserve, max(div(max_tok, @response_reserve_frac), 512))

  defp max_tokens, do: Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Builds the full message list (system prompt + conversation history) within
  the configured token budget.

  Returns `%{messages: [system_msg | conversation_messages]}`.
  """
  @spec build(map()) :: %{messages: [map()]}
  def build(state, _signal), do: build(state)

  def build(state) do
    conversation = state.messages || []
    conversation_tokens = estimate_tokens_messages(conversation)

    provider =
      Map.get(state, :provider) ||
        Application.get_env(:optimal_system_agent, :default_provider, :ollama)

    # Single source of truth for the window OSA actually operates within. For
    # local providers this is capped to :ollama_num_ctx (the same num_ctx we send
    # to Ollama), so the assembled prompt is budgeted against the REAL window
    # rather than the model's trained maximum.
    #
    # The model is RESOLVED, never read raw. A state with `model: nil` — which is
    # what every non-CLI entry point produces today, `serve`/HTTP included — used
    # to resolve as an unknown local model: `effective_context_window(nil,
    # :ollama)` falls through to the 128k config default and then applies the
    # local `:ollama_num_ctx` ceiling, because a nil model cannot match the
    # ":cloud" tag test that exempts hosted tags. MEASURED: 32,768 for `nil`
    # against 1,000,000 for the `glm-5.2:cloud` that was actually serving the
    # request — a 30x under-budget, with two knock-on effects, both of them the
    # wrong way round:
    #
    #   * `lite?` went true, so the request took the :lite static base (17,733
    #     tokens MEASURED) instead of the :native_tools one (9,332) — the small
    #     window got the BIGGER prompt;
    #   * `dynamic_budget` bottomed out on its floor, and the world state was
    #     gutted section by section (Terminal-Bench `dna-assembly` /
    #     `make-mips-interpreter`: tool doctrine truncated, environment, apps and
    #     agent roster dropped) to fit a window that was never the real one.
    #
    # `environment_block/1` already resolves the same way — it has to, or the
    # prompt tells the model it is a model it is not. Budgeting and the identity
    # line must agree, so both go through the same resolver.
    model = Map.get(state, :model) || get_active_model(provider)

    max_tok = OptimalSystemAgent.Providers.Registry.effective_context_window(model, provider)

    # Local providers (or any small effective window) get the LITE static base:
    # only the core-tool allowlist is inlined; every other tool is advertised by
    # name in a <system-reminder> and pulled on demand via tool_search.
    #
    # This comment used to claim lite kept the static base "~4-6k instead of
    # ~24k". MEASURED at v1.0.82: :full is 30,901 tokens and :lite is 24,375 —
    # trimming the tool section saves ~6.5k, and the rest is the SYSTEM.md body,
    # which :lite does not touch. So the saving is real but the destination is
    # not: on a 32k window, 24,375 static + a ~4k response reserve leaves under
    # 4k for the conversation AND all dynamic context — the same starvation
    # described for `response_reserve/1` above, not the comfortable fit the old
    # number implied. Nothing computes against the claim (the budget below uses
    # `Soul.static_token_count(variant)`, a real measurement), but the CHOICE to
    # route small windows here was made believing it, and it does not buy what
    # it was thought to buy.
    #
    # The predicate keys on the REAL resolved window, never on the provider
    # atom. It used to read `provider in [:ollama, :lmstudio, :llamacpp] or
    # max_tok < 40_000`, which handed every model served through a local
    # provider the small-window prompt — including Ollama CLOUD tags. A
    # frontier model like `glm-5.2:cloud` has a 1M window and is proxied to
    # hosted hardware (`Registry.effective_context_window/2` already declines to
    # apply the local num_ctx ceiling to it), yet it was routed to :lite —
    # which, MEASURED, is 24,375 tokens against :native_tools' 16,059. The
    # small-window path was making the prompt 8,316 tokens BIGGER on the one
    # model that could least afford it, and that cost is paid on every request.
    lite? = max_tok < @small_window_tokens

    # Which flavour of the cached static base this provider gets.
    variant = static_base_variant(provider, lite?)

    # Subagents with a system_prompt_override use that instead of Soul.static_base.
    # This gives each agent role its own focused prompt from AGENT.md.
    static_base =
      case Map.get(state, :system_prompt_override) do
        override when override in [nil, ""] -> Soul.static_base(variant)
        override -> override
      end

    static_tokens =
      case Map.get(state, :system_prompt_override) do
        override when override in [nil, ""] -> Soul.static_token_count(variant)
        override -> estimate_tokens(override)
      end

    # Tier 2: Dynamic context. Essentials fit into the leftover slack; the
    # RECALL group (memory/project/skills) is additionally capped to a fraction
    # of the REAL window so trivial turns can't balloon into the free space.
    reserve = response_reserve(max_tok)
    raw_dynamic = max_tok - reserve - conversation_tokens - static_tokens

    dynamic_budget =
      report_budget_shortfall(raw_dynamic, %{
        max_tok: max_tok,
        reserve: reserve,
        conversation: conversation_tokens,
        static: static_tokens,
        session: Map.get(state, :session_id, "default"),
        model: model,
        provider: provider
      })

    {world_state, volatile} = assemble_dynamic_context(state, dynamic_budget, max_tok)

    ws_tokens = estimate_tokens(world_state)
    volatile_tokens = estimate_tokens(volatile)
    dynamic_tokens = ws_tokens + volatile_tokens
    total_tokens = static_tokens + dynamic_tokens + conversation_tokens + reserve

    Logger.debug(
      "Context.build: static=#{static_tokens} world_state=#{ws_tokens} " <>
        "volatile=#{volatile_tokens} conversation=#{conversation_tokens} " <>
        "reserve=#{reserve} " <>
        "total=#{total_tokens}/#{max_tok} (#{Float.round(total_tokens / max_tok * 100, 1)}%)"
    )

    system_msg = build_system_message(static_base, world_state, volatile, provider, model)

    # Per-process build counter. Assembling this message is the expensive part
    # of preparing a request — 21 dynamic blocks, each with its own budget —
    # and the ReAct loop caches the result across iterations. A cache whose
    # hits still pay for a build is worse than no cache, because it hides the
    # cost; this makes "did that actually skip the work?" an assertion rather
    # than a belief. See `ReactLoop.cached_context/1`.
    Process.put(:osa_context_builds, Process.get(:osa_context_builds, 0) + 1)

    %{messages: [system_msg | conversation]}
  end

  @doc """
  How many times `build/1` has run in THIS process. Test/diagnostic seam for
  the ReAct loop's per-turn system-prompt cache.
  """
  @spec build_count() :: non_neg_integer()
  def build_count, do: Process.get(:osa_context_builds, 0)

  @doc """
  Returns a token usage breakdown for debugging purposes.
  """
  @spec token_budget(map()) :: map()
  def token_budget(state) do
    conversation = state.messages || []
    conversation_tokens = estimate_tokens_messages(conversation)

    provider =
      Map.get(state, :provider) ||
        Application.get_env(:optimal_system_agent, :default_provider, :ollama)

    model = Map.get(state, :model) || get_active_model(provider)

    max_tok =
      case Map.get(state, :effective_context_window) do
        n when is_integer(n) and n > 0 ->
          n

        _ ->
          OptimalSystemAgent.Providers.Registry.effective_context_window(model, provider)
      end

    lite? = small_window?(model, provider)
    variant = static_base_variant(provider, lite?)
    static_tokens = Soul.static_token_count(variant)

    # Gather dynamic blocks for individual cost breakdown
    blocks = gather_dynamic_blocks(state)

    block_details =
      Enum.map(blocks, fn {content, priority, label} ->
        %{
          label: label,
          priority: priority,
          tokens: estimate_tokens(content || "")
        }
      end)

    reserve = response_reserve(max_tok)

    # No `report_budget_shortfall/2` here: inspecting the budget must be silent,
    # or `/context` would emit the overflow report the next real build owns.
    dynamic_budget =
      max(max_tok - reserve - conversation_tokens - static_tokens, @dynamic_budget_floor)

    # emit: false — inspecting the budget must never advance the world-state
    # ledger, or the next real turn would think everything was already sent.
    {ws, volatile} = assemble_dynamic_context(state, dynamic_budget, max_tok, emit: false)
    dynamic_tokens = estimate_tokens(ws) + estimate_tokens(volatile)
    tool_tokens = tool_schema_tokens()
    tool_result = tool_result_tokens(conversation)
    total_tokens = static_tokens + dynamic_tokens + conversation_tokens + reserve + tool_tokens

    %{
      max_tokens: max_tok,
      response_reserve: reserve,
      conversation_tokens: conversation_tokens,
      static_base_tokens: static_tokens,
      dynamic_context_tokens: dynamic_tokens,
      tool_schema_tokens: tool_tokens,
      tool_result_tokens: tool_result,
      system_prompt_budget: max_tok - reserve - conversation_tokens,
      system_prompt_actual: static_tokens + dynamic_tokens + tool_tokens,
      total_tokens: total_tokens,
      utilization_pct:
        if(max_tok > 0, do: Float.round(total_tokens / max_tok * 100, 1), else: 0.0),
      headroom: max_tok - total_tokens,
      blocks: block_details
    }
  end

  @doc """
  Tokens currently spent on the native `tools` array. Public so `/context`
  and a model-swap fit check can see the same number the budget uses.
  """
  @spec tool_schema_token_count() :: non_neg_integer()
  def tool_schema_token_count, do: tool_schema_tokens()

  # Tokens spent on the native `tools` array of the request.
  #
  # These were invisible to the budget. Every consumer — the `/context` meter,
  # the compaction trigger, the headroom figure — summed the system prompt, the
  # conversation and the response reserve, and stopped there. But the tool
  # schemas are sent on every single request, and under the `:native_tools`
  # variant they live ENTIRELY in that array: the prose duplicating them is
  # deliberately stripped from the prompt precisely because the model receives
  # the schemas natively. So the one variant that moves the weight out of the
  # prompt also moved it out of the accounting, and the meter under-reported by
  # the full size of the tool payload — which for 37 registered tools is not a
  # rounding error. Compaction consequently fired later than it believed.
  #
  # Cached against the active tool set, so the JSON encode happens when the
  # toolbox changes rather than on every turn.
  defp tool_schema_tokens do
    tools = OptimalSystemAgent.Tools.Registry.list_active()
    key = :erlang.phash2(Enum.map(tools, & &1[:name]))

    case :persistent_term.get({__MODULE__, :tool_schema_tokens}, nil) do
      {^key, tokens} ->
        tokens

      _ ->
        tokens =
          case Jason.encode(tools) do
            {:ok, json} -> estimate_tokens(json)
            _ -> 0
          end

        :persistent_term.put({__MODULE__, :tool_schema_tokens}, {key, tokens})
        tokens
    end
  rescue
    _ -> 0
  end

  defp tool_result_tokens(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn msg, acc ->
      role = Map.get(msg, :role) || Map.get(msg, "role")

      if role in ["tool", :tool] do
        acc + estimate_tokens_messages([msg])
      else
        acc
      end
    end)
  end

  defp tool_result_tokens(_), do: 0

  @doc """
  `true` when the model's REAL resolved context window is small enough to need
  the trimmed prompt variant and the trimmed tool list.

  Keyed on `Registry.effective_context_window/2` — the window OSA actually
  operates within, already capped by `:ollama_num_ctx` for genuinely local
  weights and deliberately NOT capped for Ollama Cloud tags. The provider atom
  is not consulted: a 1M-window frontier model reached through the `:ollama`
  transport is not a small model, and treating it as one both inflated the
  prompt (`:lite` is larger than `:native_tools`) and cut its tool list to ten.

  Single source of truth for `Agent.Context` and `Agent.Loop.ToolFilter`, so
  the inlined prose and the native tool array can never disagree about which
  regime a request is in.

  A `nil` model is RESOLVED to the provider's configured model before the window
  is looked up, exactly as `build/1` does. `Agent.Loop.ToolFilter` passes
  `state.model` straight through, and that is `nil` on every non-CLI entry point
  — so an unresolved nil made a hosted 1M-window tag (which cannot match the
  ":cloud" test while it is nil) fall to the local `:ollama_num_ctx` ceiling,
  answer `true` here, and cut the native tool array to ten tools on the model
  that least needed it.
  """
  @spec small_window?(String.t() | nil, atom() | nil) :: boolean()
  def small_window?(model, provider) do
    provider = provider || Application.get_env(:optimal_system_agent, :default_provider, :ollama)
    model = model || get_active_model(provider)

    OptimalSystemAgent.Providers.Registry.effective_context_window(model, provider) <
      @small_window_tokens
  end

  @doc false
  @spec small_window_tokens() :: pos_integer()
  def small_window_tokens, do: @small_window_tokens

  # Which cached static base this request gets.
  #
  #   :lite          — genuinely small window. Unchanged: only the core allowlist is
  #                    inlined, and the tool list is separately capped by
  #                    ToolFilter, so the prose and the native array do NOT
  #                    describe the same set and dropping prose there would lose
  #                    information. This branch wins whenever it applies.
  #   :native_tools  — the transport carries full tool schemas in the request
  #                    body, so the duplicated prose spans are dropped.
  #   :full          — everything else, including `claude_cli` / `copilot_cli`,
  #                    which have no native tool channel at all.
  @doc false
  @spec static_base_variant(atom(), boolean()) :: :lite | :native_tools | :full
  def static_base_variant(_provider, true), do: :lite

  def static_base_variant(provider, _lite?) do
    if Soul.dedupe_native_tool_prompt?() and
         OptimalSystemAgent.Providers.Registry.native_tool_schemas?(provider) do
      :native_tools
    else
      :full
    end
  end

  # ---------------------------------------------------------------------------
  # System message construction
  # ---------------------------------------------------------------------------

  # Anthropic cache hints: up to THREE content blocks with two breakpoints.
  #
  #   1. static base   — cached (never changes within a session)
  #   2. world state   — cached (diffed; byte-identical unless a section changed)
  #   3. volatile      — uncached (clock, turn count, working tree, recall)
  #
  # The second breakpoint is the payoff for the world-state diff: before it,
  # every dynamic token was re-prefilled on every single turn because one live
  # timestamp sat in the same uncached block as the tool doctrine and AGENTS.md.
  defp build_system_message(static_base, world_state, volatile, provider, model) do
    # Blocks are emitted for any route that HONOURS `cache_control`, not just
    # the native Anthropic one.
    #
    # This branch used to read `provider == :anthropic`. Every other provider —
    # including Claude reached through OpenRouter, which is how the benchmarks
    # actually run — got `[static, world_state, volatile] |> Enum.join("\n\n")`:
    # one flat string, no breakpoints, and the volatile tail (clock, turn
    # count, working tree) welded INSIDE it.
    #
    # Measured on the wire 2026-08-14 via a logging proxy, a real 3-turn
    # headless session on `anthropic/claude-haiku-4.5`: 0 occurrences of
    # `cache_control` in the request body, and ~29.9k of the ~31.0k input
    # tokens were this static prefix plus the tool schemas — 96% of the
    # request, re-sent uncached on every single turn.
    if OptimalSystemAgent.Providers.Registry.anthropic_prompt_cache?(provider, model) and
         (world_state != "" or volatile != "") do
      blocks =
        [
          %{type: "text", text: static_base, cache_control: %{type: "ephemeral"}},
          if(world_state != "",
            do: %{type: "text", text: world_state, cache_control: %{type: "ephemeral"}}
          ),
          if(volatile != "", do: %{type: "text", text: volatile})
        ]
        |> Enum.reject(&is_nil/1)

      %{role: "system", content: blocks}
    else
      # All other providers: single concatenated string. Ordering still matters —
      # static, then stable world state, then volatile — so the shared prefix a
      # local runtime's KV cache can reuse is as long as possible.
      full_prompt =
        [static_base, world_state, volatile]
        |> Enum.reject(&(&1 == "" or is_nil(&1)))
        |> Enum.join("\n\n")

      %{role: "system", content: full_prompt}
    end
  end

  # ---------------------------------------------------------------------------
  # Dynamic context assembly
  # ---------------------------------------------------------------------------

  # ESSENTIAL blocks are the small, always-relevant VOLATILE operating state —
  # the per-turn facts (clock, turn count, working-tree state, task list) that
  # genuinely change every turn and therefore cannot live in the diffed world
  # state. Everything else (memory, episodic, skills, learned skills) is RECALL
  # and competes within a bounded sub-budget capped to a fraction of the REAL
  # window. Labels owned by `WorldState.managed_labels/0` never reach this split.
  @essential_labels ~w(task_brief active_skills runtime git_state task_state workflow)

  # `@dynamic_budget_floor` is declared with the other budget constants at the
  # top of the module — a module attribute read before its definition silently
  # evaluates to nil, and `max(x, nil)` is a comparison Elixir will happily make.
  #
  # This floor is a FICTION, and that is the point of `report_budget_shortfall/2`.
  # When the static base plus the conversation plus the response reserve already
  # exceed the window, the honest budget is negative: there is no room for
  # dynamic context because there is no room for the prompt. Clamping to 1_000
  # and carrying on is what turned a window/compaction failure into five
  # "ESSENTIAL context block dropped" lines that blamed the block for the budget.
  # The floor stays — a build that returns no prompt at all is worse — but it is
  # now announced, with the arithmetic that produced it, at a severity that
  # matches what actually happened.

  # Returns the budget to assemble against, and says so out loud when that budget
  # is the floor rather than real slack.
  #
  #   raw < 0     — the prompt does not fit the window AT ALL. Nothing the fitter
  #                 does can fix this; compaction or a correct window is the fix.
  #                 Logged at :error, because every eviction that follows is a
  #                 SYMPTOM and reading them as the disease sends the next
  #                 investigation to the wrong module (it did: the Terminal-Bench
  #                 report opened on "ESSENTIAL blocks are dropped", and the
  #                 cause was `model: nil` resolving a 1M window to 32k).
  #   0 <= raw < floor — degraded but coherent: real slack exists, just not
  #                 enough for the world state. Logged at :warning.
  defp report_budget_shortfall(raw, _meta) when raw >= @dynamic_budget_floor, do: raw

  defp report_budget_shortfall(raw, meta) do
    deficit = @dynamic_budget_floor - raw

    if raw < 0 do
      Logger.error(
        "[Context] PROMPT DOES NOT FIT: window=#{meta.max_tok} " <>
          "static=#{meta.static} conversation=#{meta.conversation} reserve=#{meta.reserve} " <>
          "→ dynamic budget #{raw} (over by #{-raw}). session=#{meta.session} " <>
          "model=#{inspect(meta.model)} provider=#{meta.provider}. " <>
          "Assembling against the #{@dynamic_budget_floor}-token floor anyway; any " <>
          "context block evicted below is a SYMPTOM of this, not its own bug. " <>
          "Fix the window resolution or compact the conversation."
      )
    else
      Logger.warning(
        "[Context] dynamic budget floored: window=#{meta.max_tok} " <>
          "static=#{meta.static} conversation=#{meta.conversation} reserve=#{meta.reserve} " <>
          "→ #{raw}, raised to #{@dynamic_budget_floor} (short by #{deficit}). " <>
          "session=#{meta.session} model=#{inspect(meta.model)} provider=#{meta.provider}."
      )
    end

    emit_overflow_telemetry(raw, deficit, meta)
    @dynamic_budget_floor
  end

  defp emit_overflow_telemetry(raw, deficit, meta) do
    :telemetry.execute(
      [:osa, :context, :overflow],
      %{
        raw_budget: raw,
        deficit: deficit,
        window: meta.max_tok,
        static: meta.static,
        conversation: meta.conversation,
        reserve: meta.reserve
      },
      %{session: meta.session, model: meta.model, provider: meta.provider, fits: raw >= 0}
    )
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp assemble_dynamic_context(state, budget, effective_window, opts \\ []) do
    blocks = gather_dynamic_blocks(state)
    session_id = Map.get(state, :session_id, "default")
    emit? = Keyword.get(opts, :emit, true)

    # Evictions are per-build, not cumulative: a block that fit this turn must
    # not still look evicted from three turns ago.
    if emit?, do: clear_evictions(session_id)

    # ── Tier 2a: WORLD STATE (diffed, Codex `world_state.rs`) ────────────────
    #
    # Sections that are stable across a session (tool-usage doctrine, AGENTS.md,
    # environment, the slash-command catalog, the subagent roster, the active
    # collaboration mode) are NOT re-concatenated every turn. They are diffed
    # against the previous turn and only re-emitted when they actually changed;
    # unchanged sections are replayed byte-for-byte from the ledger so the
    # prompt prefix stays stable and the provider's prefix/KV cache stays warm.
    managed = WorldState.managed_labels()

    {ws_blocks, rest} =
      Enum.split_with(blocks, fn {_content, _priority, label} -> label in managed end)

    {ws_sections, _summary} = WorldState.assemble(session_id, ws_blocks, emit: emit?)

    # ── Tier 2b: VOLATILE per-turn blocks ────────────────────────────────────
    {essential, recall} =
      Enum.split_with(rest, fn {_content, _priority, label} ->
        label in @essential_labels
      end)

    # World state is fitted FIRST — it carries the operating mode and the tool
    # doctrine, so it outranks every per-turn block. Sections are fitted
    # INDIVIDUALLY and are all-or-nothing: severing one mid-sentence to save a
    # few tokens produces a prompt that reads as a corrupted instruction, which
    # is worse than not having it. Anything dropped is invalidated in the ledger
    # so it is re-emitted next turn rather than being silently lost forever.
    #
    # "Outranks" is NOT "may starve". The essentials are withheld from the
    # world-state fitter before it starts, because outranking is a tiebreak for
    # the contested tail of the budget, not a licence for a 1300-token tool
    # catalog to consume a 57-token block carrying the session id, the channel
    # and the model identity. Losing that block is why OSA could not answer
    # "what model are you". The reservation is capped so the reverse failure —
    # one pathological essential (a large git diff) pushing the doctrine out —
    # cannot happen either.
    reserved = essential_reserve(essential, budget, ws_sections)

    {ws_parts, ws_used, ws_dropped} =
      fit_world_state(ws_sections, max(budget - reserved, 0), session_id)

    if emit? and ws_dropped != [], do: WorldState.invalidate(session_id, ws_dropped)

    # Clamped: a fitter that overshot its budget must not hand the next group a
    # NEGATIVE one, which `fit_blocks/4` reads as "drop every block".
    remaining = max(budget - ws_used, 0)

    # Fit essentials by PRIORITY, not by listing order. `fit_blocks/4` spends the
    # budget in the order it is handed the blocks, so with a tight dynamic budget
    # (a small local window plus a large static base) the first long block in the
    # list could swallow everything and silently drop every essential after it.
    # A dropped essential is a capability regression, not a truncation. Priority 0
    # blocks therefore get the budget first; sort_by is stable, so blocks of equal
    # priority keep their listed order and the assembled text stays otherwise
    # unchanged.
    {essential_parts, essential_used} =
      essential
      |> Enum.sort_by(fn {_content, priority, _label} -> priority end)
      |> fit_blocks(remaining, nil, session_id: session_id, group: :essential)

    # RECALL group: capped to ~dynamic_recall_budget_frac of the REAL window
    # (with a small floor), never the full leftover slack.
    leftover = remaining - essential_used
    recall_budget = Budget.recall_budget(effective_window, leftover)

    # Most query-relevant recall blocks first, so they win the budget.
    recall_ordered = order_by_query_relevance(recall, state)

    {recall_parts, _recall_used} =
      fit_blocks(recall_ordered, recall_budget, Budget.memory_context_token_cap(),
        session_id: session_id,
        group: :recall
      )

    # Returned SPLIT, not joined: the world-state half is byte-stable turn over
    # turn, so it can carry its own provider cache breakpoint. The volatile half
    # (clock, turn count, working tree, recall) changes every turn and must stay
    # outside any cached region.
    {join(ws_parts), join(essential_parts ++ recall_parts)}
  end

  # Ceiling on how much of the dynamic budget the ESSENTIAL group may withhold
  # from the world state. Essentials are small and load-bearing (identity, task
  # brief, working-tree state); world state is large and directive. Half is the
  # point where neither group can silently erase the other.
  @essential_reserve_frac 0.5

  # Floor under the ESSENTIAL group, so guaranteeing the rank-0 world state can
  # never zero it out. Both groups shrink under pressure; neither is erased.
  @essential_reserve_floor_frac 0.25

  # Withhold only what the essentials will actually SPEND — reserving a flat
  # fraction would hand budget back to nobody on a turn with no task brief and
  # no git state.
  #
  # The reservation is additionally bounded by what the RANK-0 world-state
  # sections need. Rank 0 is the operating mode and the tool doctrine: the two
  # sections the registry declares can never lose a budget race. Withholding
  # half the budget for the volatile essentials could nevertheless push them out
  # from the other side — which is what truncated `ws:tools` on Terminal-Bench,
  # a 1367-token doctrine block fitted against ~812 tokens. Order of claim is
  # now: rank-0 world state, then essentials down to their floor, then the rest
  # of the world state by rank, then recall.
  defp essential_reserve(essential, budget, ws_sections) do
    wanted =
      Enum.reduce(essential, 0, fn {content, _priority, _label}, acc ->
        acc + estimate_tokens(content)
      end)

    critical_ws =
      Enum.reduce(ws_sections, 0, fn {id, chunk}, acc ->
        if WorldState.rank(id) == 0, do: acc + estimate_tokens(chunk), else: acc
      end)

    hard_floor = min(wanted, floor(budget * @essential_reserve_floor_frac))

    [wanted, floor(budget * @essential_reserve_frac), max(budget - critical_ws, 0)]
    |> Enum.min()
    |> max(hard_floor)
  end

  defp join(parts) do
    parts
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join("\n\n---\n\n")
  end

  # Fraction of a world-state section that must survive for a truncated copy to
  # be worth sending. Above it, most of the directive still reaches the model and
  # a partial copy beats nothing. Below it, what is left is a stub that reads as
  # a corrupted instruction — drop the section whole and say so.
  @ws_truncation_floor 0.6

  # Highest `WorldState.rank/1` that still counts as ESSENTIAL when it is evicted.
  #
  # Every world-state eviction used to be recorded and logged as ESSENTIAL,
  # because `fit_world_state/3` passed `group: :essential` for all of them. That
  # is not a severity, it is a constant — and it made the label meaningless in
  # exactly the situation the label exists for. On Terminal-Bench the same
  # five-line burst announced the tool-usage doctrine (rank 0, the model loses
  # instructions it cannot rediscover) and the slash-command catalog (rank 3, a
  # convenience listing of things the USER types) at identical severity.
  #
  # Rank is already the deliberate, reviewed statement of what outranks what
  # under pressure, so it is what the severity keys on rather than a second
  # hand-maintained list that could disagree with it:
  #
  #   rank 0-1 → :essential — tool doctrine, collaboration mode, AGENTS.md,
  #              environment, onboarding. Losing one is a capability regression.
  #              Logged at :warning.
  #   rank 2+  → :optional  — personality overlay, scratchpad guidance, the
  #              slash-command catalog, the subagent roster. Losing one degrades
  #              the turn without removing a capability. Logged at :info, so it
  #              is still visible and still lands in `evictions/1` — under-
  #              reporting it would just recreate the silent-drop bug at a lower
  #              rank.
  @ws_essential_max_rank 1

  defp ws_group(id) do
    if WorldState.rank(id) <= @ws_essential_max_rank, do: :essential, else: :optional
  end

  # Fitting for world-state sections.
  #
  # Sections compete for the budget in RANK order (operating mode and tool
  # doctrine before catalogs) but are rendered back in REGISTRY order, so who
  # wins under pressure is a deliberate decision while the emitted prefix stays
  # byte-stable.
  #
  # Returns {kept_chunks_in_registry_order, tokens_used, dropped_section_ids}.
  # Only WHOLLY dropped ids are returned — a truncated section largely reached
  # the model, so re-emitting it from scratch next turn would just churn the
  # ledger.
  defp fit_world_state(sections, budget, session_id) do
    {kept, used, dropped} =
      sections
      |> Enum.with_index()
      |> Enum.sort_by(fn {{id, _chunk}, idx} -> {WorldState.rank(id), idx} end)
      |> Enum.reduce({[], 0, []}, fn {{id, chunk}, idx}, {acc, used, dropped} ->
        cost = estimate_tokens(chunk)
        available = budget - used
        opts = [session_id: session_id, group: ws_group(id)]

        cond do
          cost <= available ->
            {[{idx, chunk} | acc], used + cost, dropped}

          available >= @ws_truncation_floor * cost ->
            truncated = truncate_to_tokens(chunk, available)
            kept_tokens = estimate_tokens(truncated)
            record_eviction(opts, "ws:#{id}", :truncated, cost, kept_tokens)
            {[{idx, truncated} | acc], used + kept_tokens, dropped}

          true ->
            record_eviction(opts, "ws:#{id}", :dropped, cost, 0)
            {acc, used, [id | dropped]}
        end
      end)

    chunks = kept |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
    {chunks, used, dropped |> Enum.reverse() |> Enum.uniq()}
  end

  # Order the RECALL group by keyword overlap with the latest user message.
  # Enum.sort_by is stable, so equally-relevant blocks keep their listed order.
  defp order_by_query_relevance(blocks, state) do
    keywords = Scoring.extract_keywords(find_latest_user_message(state.messages))

    if keywords == [] do
      blocks
    else
      kw_set = MapSet.new(keywords)

      Enum.sort_by(
        blocks,
        fn {content, _priority, _label} ->
          content
          |> String.downcase()
          |> String.split(~r/\s+/, trim: true)
          |> MapSet.new()
          |> MapSet.intersection(kw_set)
          |> MapSet.size()
        end,
        :desc
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Dynamic block gathering — each returns {content, priority, label}
  # ---------------------------------------------------------------------------

  defp gather_dynamic_blocks(state) do
    [
      {bootstrap_block(), 0, "bootstrap"},
      {personality_block(), 0, "personality"},
      {task_brief_block(state), 0, "task_brief"},
      {active_skills_block(state), 0, "active_skills"},
      {tool_process_block(state), 1, "tool_process"},
      # Priority 0: tiny and load-bearing. It carries the session id, the channel
      # and the resolved model identity — the same resolver /health and the TUI
      # status bar read, so the bar and the prompt can never disagree. At ~57
      # tokens it must never lose a budget race to a longer advisory block.
      {runtime_block(state), 0, "runtime"},
      {environment_block(state), 1, "environment"},
      # Git working-tree state changes as the agent edits files, so it is
      # deliberately NOT part of the diffed world state — it would append a new
      # world-state payload on almost every turn. It stays a small per-turn block.
      {git_state_block(state), 1, "git_state"},
      {commands_block(state), 2, "commands"},
      {project_context_block(state), 1, "project_context"},
      {project_instructions_block(state), 1, "project_instructions"},
      # Priority 0: the active operating mode outranks general guidance. Plan mode
      # changes what the turn is allowed to DO, so it must never lose the budget
      # race to a longer advisory block.
      {plan_mode_block(state), 0, "plan_mode"},
      {memory_block_relevant(state), 1, "memory"},
      {memory_recall_block(state), 1, "memory_recall"},
      {episodic_block(state), 1, "episodic"},
      {task_state_block(state), 1, "task_state"},
      {workflow_block(state), 1, "workflow"},
      # Priority 0: this compact catalog is the only way the model can know a
      # relevant workflow exists before acting. Full SKILL.md bodies remain
      # on-demand through skill_view, so pinning the index does not pin bodies.
      {skills_block(state), 0, "skills"},
      {learned_skills_block(state), 2, "learned_skills"},
      {scratchpad_block(state), 1, "scratchpad"},
      {agent_roles_block(state), 2, "agent_roles"},
      # Security context: injected only when a security task is active.
      # Priority 0 so it never loses the budget race to advisory blocks.
      {security_posture_block(state), 0, "security_posture"},
      {sandbox_environment_block(state), 0, "sandbox_environment"}
    ]
    |> Enum.reject(fn {content, _, _} -> is_nil(content) or content == "" end)
  end

  # Slash-command catalog. The 40+ CLI commands live in Channels.CLI.Commands
  # and were never surfaced to the model, so asked "what can I type?" the agent
  # could only parrot the handful hardcoded in SYSTEM.md and hallucinated the
  # rest. This injects name + one-line description so the agent references real
  # commands accurately. Subagents don't drive the CLI, so they never see it.
  defp commands_block(%{permission_tier: :subagent}), do: nil

  defp commands_block(_state) do
    case OptimalSystemAgent.Channels.CLI.Commands.list_with_descriptions() do
      [] ->
        nil

      list ->
        lines = Enum.map_join(list, "\n", fn {name, desc} -> "- /#{name} — #{desc}" end)

        "## Slash Commands (the user types these)\n" <>
          "These are commands the USER types in the CLI. You cannot call them as tools, " <>
          "but reference them accurately when the user asks what they can do or when " <>
          "suggesting an action they could take.\n\n" <> lines
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp personality_block do
    try do
      OptimalSystemAgent.Personality.active_overlay()
    rescue
      _ -> nil
    end
  end

  defp project_context_block(state) do
    working_dir = Map.get(state, :working_dir)

    try do
      OptimalSystemAgent.Agent.ContextDiscovery.discover(working_dir)
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end

  # Directory-scoped LAZY instruction injection (opencode `instruction.ts`).
  #
  # `project_context_block/1` above front-loads the TOP-LEVEL AGENTS.md/CLAUDE.md
  # once. THIS block adds the nested twist: when the agent has read/edited files
  # in subdirectories, inject the nearest ancestor instruction file for each of
  # those subtrees — deduped so the same guidance never lands twice. Claims are
  # tracked per session in ETS, so a nested AGENTS.md injected on turn 3 is not
  # re-injected on turns 4+ (token savings). The top-level file is excluded via
  # ProjectInstructions' system_paths so we never double-inject what
  # project_context already carries.
  @claims_table :osa_project_instructions_claims

  defp project_instructions_block(state) do
    read_paths = extract_read_paths(Map.get(state, :messages))

    if read_paths == [] do
      nil
    else
      working_dir = Map.get(state, :working_dir) || OptimalSystemAgent.Workspace.Cwd.get()
      session_id = Map.get(state, :session_id, "default")
      claimed = get_claims(session_id)

      {results, new_claimed} =
        ProjectInstructions.resolve(read_paths, working_dir: working_dir, claimed: claimed)

      put_claims(session_id, new_claimed)
      ProjectInstructions.render(results)
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # Pull every file path the agent has read/edited from assistant tool calls.
  # Covers file_read/file_edit/file_write/notebook_edit — all keyed by "path".
  # Arguments may be a decoded map or a raw JSON string, with string or atom keys.
  @file_touching_tools ~w(file_read file_edit file_write notebook_edit)

  defp extract_read_paths(nil), do: []
  defp extract_read_paths([]), do: []

  defp extract_read_paths(messages) when is_list(messages) do
    messages
    |> Enum.flat_map(fn msg ->
      case Map.get(msg, :tool_calls) do
        calls when is_list(calls) -> calls
        _ -> []
      end
    end)
    |> Enum.flat_map(&tool_call_path/1)
    |> Enum.uniq()
  end

  defp extract_read_paths(_), do: []

  defp tool_call_path(tc) when is_map(tc) do
    name = safe_to_string(Map.get(tc, :name) || Map.get(tc, "name"))

    if name in @file_touching_tools do
      case path_from_args(Map.get(tc, :arguments) || Map.get(tc, "arguments")) do
        p when is_binary(p) and p != "" -> [p]
        _ -> []
      end
    else
      []
    end
  end

  defp tool_call_path(_), do: []

  defp path_from_args(args) when is_map(args), do: Map.get(args, "path") || Map.get(args, :path)

  defp path_from_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, map} when is_map(map) -> Map.get(map, "path")
      _ -> nil
    end
  end

  defp path_from_args(_), do: nil

  # Per-session claims: which nested instruction files have already been injected.
  defp get_claims(session_id) do
    ensure_claims_table()

    case :ets.lookup(@claims_table, session_id) do
      [{^session_id, set}] -> set
      _ -> MapSet.new()
    end
  rescue
    _ -> MapSet.new()
  end

  defp put_claims(session_id, set) do
    ensure_claims_table()
    :ets.insert(@claims_table, {session_id, set})
    :ok
  rescue
    _ -> :ok
  end

  defp ensure_claims_table do
    case :ets.whereis(@claims_table) do
      :undefined -> :ets.new(@claims_table, [:named_table, :public, :set])
      _ -> @claims_table
    end
  rescue
    ArgumentError -> @claims_table
  end

  # Inject available agent roles for delegation — only for :full tier (parent agents).
  # Subagents don't see this block since they can't delegate.
  defp agent_roles_block(%{permission_tier: :subagent}), do: nil
  defp agent_roles_block(%{permission_tier: :read_only}), do: nil

  defp agent_roles_block(_state) do
    try do
      OptimalSystemAgent.Agents.Registry.available_roles_context()
    rescue
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Fitting blocks into a budget
  # ---------------------------------------------------------------------------

  # per_block_cap (when given) bounds any SINGLE block so one oversized block
  # cannot consume the entire group budget even when slack would allow it.
  #
  # Eviction is NEVER silent. This function used to drop or truncate blocks with
  # no error and no log — a capability could vanish from the prompt (plan mode
  # did, once, when a 13KB prompt growth pushed it past the budget on 32k models)
  # and nothing anywhere said so. Every drop and every truncation now logs at
  # `warning` for essential groups, emits `[:osa, :context, :eviction]` telemetry,
  # and is recorded for `evictions/1` so it is observable after the fact.
  defp fit_blocks(blocks, budget, per_block_cap, opts)

  defp fit_blocks(blocks, budget, _per_block_cap, opts) when budget <= 0 do
    for {content, _p, label} <- blocks, not (is_nil(content) or content == "") do
      record_eviction(opts, label, :dropped, estimate_tokens(content), 0)
    end

    {[], 0}
  end

  defp fit_blocks(blocks, budget, per_block_cap, opts) do
    {parts, used} =
      Enum.reduce(blocks, {[], 0}, fn {content, _priority, label}, {acc, tokens_used} ->
        block_tokens = estimate_tokens(content)

        available =
          case per_block_cap do
            nil -> budget - tokens_used
            cap -> min(budget - tokens_used, cap)
          end

        cond do
          available <= 0 ->
            record_eviction(opts, label, :dropped, block_tokens, 0)
            {acc, tokens_used}

          block_tokens <= available ->
            {acc ++ [content], tokens_used + block_tokens}

          true ->
            truncated = truncate_to_tokens(content, available)
            truncated_tokens = estimate_tokens(truncated)

            # `truncate_to_tokens/2` works in words, so it can come back at (or
            # even above) the estimate without having cut anything. Only report a
            # truncation when text was actually lost.
            if truncated != content do
              record_eviction(opts, label, :truncated, block_tokens, truncated_tokens)
            end

            {acc ++ [truncated], tokens_used + truncated_tokens}
        end
      end)

    {parts, used}
  end

  # ---------------------------------------------------------------------------
  # Eviction observability
  # ---------------------------------------------------------------------------

  @evictions_table :osa_context_evictions

  @doc """
  Returns the blocks evicted (dropped or truncated) on this session's most
  recent `build/1`.

  Each entry is `%{label: String.t(), kind: :dropped | :truncated, wanted: n,
  kept: n, group: :essential | :recall, at: DateTime.t()}`. Empty list means
  everything fit.

  Silent eviction is the failure mode this exists to prevent: a capability can
  disappear from the prompt because a budget got tight, and without this there
  is no signal at all — the agent simply stops being told it can do something.
  """
  @spec evictions(String.t() | nil) :: [map()]
  def evictions(nil), do: []

  def evictions(session_id) when is_binary(session_id) do
    ensure_evictions_table()

    case :ets.lookup(@evictions_table, session_id) do
      [{^session_id, list}] -> list
      _ -> []
    end
  rescue
    _ -> []
  end

  @doc "Clears the recorded evictions for a session."
  @spec clear_evictions(String.t() | nil) :: :ok
  def clear_evictions(nil), do: :ok

  def clear_evictions(session_id) do
    ensure_evictions_table()
    :ets.delete(@evictions_table, session_id)
    :ok
  rescue
    _ -> :ok
  end

  defp record_eviction(opts, label, kind, wanted, kept) do
    group = Keyword.get(opts, :group, :recall)
    session_id = Keyword.get(opts, :session_id, "default")

    entry = %{
      label: label,
      kind: kind,
      wanted: wanted,
      kept: kept,
      group: group,
      session: session_id,
      at: DateTime.utc_now()
    }

    unseen = if kind == :dropped, do: "this block at all", else: "all of this block"

    case group do
      :essential ->
        Logger.warning(
          "[Context] ESSENTIAL context block #{kind}: label=#{label} session=#{session_id} " <>
            "wanted=#{wanted}tok kept=#{kept}tok — the model will NOT see #{unseen}. " <>
            "The dynamic budget is too small; reduce the static base or raise the context window."
        )

      :optional ->
        Logger.info(
          "[Context] optional context block #{kind}: label=#{label} session=#{session_id} " <>
            "wanted=#{wanted}tok kept=#{kept}tok — the model will not see #{unseen}. " <>
            "Degraded, not a capability loss; the budget spent it on higher-ranked context."
        )

      _ ->
        Logger.debug(
          "[Context] recall block #{kind}: label=#{label} wanted=#{wanted}tok kept=#{kept}tok"
        )
    end

    safe_telemetry(entry)
    append_eviction(session_id, entry)
    :ok
  end

  defp safe_telemetry(entry) do
    :telemetry.execute(
      [:osa, :context, :eviction],
      %{wanted: entry.wanted, kept: entry.kept},
      %{label: entry.label, kind: entry.kind, group: entry.group, session: entry.session}
    )
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp append_eviction(session_id, entry) do
    ensure_evictions_table()
    existing = evictions(session_id)
    # Keep only this turn's worth; a build starts by resetting via turn marker.
    :ets.insert(@evictions_table, {session_id, Enum.take(existing ++ [entry], 32)})
    :ok
  rescue
    _ -> :ok
  end

  defp ensure_evictions_table do
    case :ets.whereis(@evictions_table) do
      :undefined -> :ets.new(@evictions_table, [:named_table, :public, :set])
      ref -> ref
    end
  rescue
    ArgumentError -> @evictions_table
  end

  # ---------------------------------------------------------------------------
  # Token estimation
  # ---------------------------------------------------------------------------

  @doc """
  Estimates the number of tokens in a text string.

  Uses the Go tokenizer for accurate BPE counting when available,
  falling back to a word + punctuation heuristic.
  """
  @spec estimate_tokens(String.t() | nil) :: non_neg_integer()
  def estimate_tokens(nil), do: 0
  def estimate_tokens(""), do: 0

  def estimate_tokens(text) when is_binary(text) do
    estimate_tokens_heuristic(text)
  end

  defp estimate_tokens_heuristic(text),
    do: OptimalSystemAgent.Utils.Tokens.estimate(text)

  @doc """
  Estimates token count for a list of messages.
  """
  @spec estimate_tokens_messages([map()]) :: non_neg_integer()
  def estimate_tokens_messages([]), do: 0

  def estimate_tokens_messages(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn msg, acc ->
      content_tokens = estimate_tokens(safe_to_string(Map.get(msg, :content)))

      tool_call_tokens =
        case Map.get(msg, :tool_calls) do
          nil ->
            0

          [] ->
            0

          calls when is_list(calls) ->
            Enum.reduce(calls, 0, fn
              tc, tc_acc when is_map(tc) ->
                name_tokens = estimate_tokens(safe_to_string(Map.get(tc, :name, "")))
                arg_tokens = estimate_tokens(safe_to_string(Map.get(tc, :arguments, "")))
                tc_acc + name_tokens + arg_tokens + 4

              _, tc_acc ->
                tc_acc
            end)
        end

      acc + content_tokens + tool_call_tokens + 4
    end)
  end

  defp safe_to_string(val),
    do: OptimalSystemAgent.Utils.Text.safe_to_string(val)

  # ---------------------------------------------------------------------------
  # Truncation
  # ---------------------------------------------------------------------------

  @truncation_marker "\n\n[...truncated...]"

  defp truncate_to_tokens(_text, target_tokens) when target_tokens <= 0, do: ""

  # Cut `text` down to AT MOST `target_tokens`, measured by the same estimator the
  # budget is spent in.
  #
  # The old implementation trusted a fixed 1.3 tokens-per-word ratio and never
  # re-measured, so it routinely came back ~13% OVER target (a 1000-token target
  # returned ~1134 tokens). Every caller subtracts the result from its remaining
  # budget, so an overshoot drove `budget - used` NEGATIVE — and `fit_blocks/4`
  # treats a non-positive budget as "drop everything". One over-long world-state
  # section therefore silently evicted every per-turn block behind it, including
  # the runtime block. Overshooting a token budget is never a rounding detail:
  # it is the difference between truncating one block and losing all the others.
  defp truncate_to_tokens(text, target_tokens) do
    if estimate_tokens(text) <= target_tokens do
      text
    else
      words = String.split(text, ~r/\s+/, trim: true)
      guess = min(length(words), max(round(target_tokens / 1.3), 1))
      shrink_to_fit(words, guess, target_tokens)
    end
  end

  # Shrink until the rendered result (marker included) actually measures within
  # target. Each step strictly decreases `n`, so this terminates.
  defp shrink_to_fit(_words, n, _target) when n < 1, do: ""

  defp shrink_to_fit(words, n, target) do
    candidate = words |> Enum.take(n) |> Enum.join(" ")
    rendered = candidate <> @truncation_marker
    cost = estimate_tokens(rendered)

    if cost <= target do
      rendered
    else
      # Scale down by how far over we are, but always drop at least one word.
      scaled = floor(n * target / max(cost, 1))
      shrink_to_fit(words, min(n - 1, max(scaled, 0)), target)
    end
  end

  # ---------------------------------------------------------------------------
  # Dynamic block builders
  # ---------------------------------------------------------------------------

  # "Get to know the user" block. Injected only while the agent hasn't learned
  # who the user is yet — the completion signal is real state (USER.md has a name),
  # NOT a self-deleting file. Once the agent has filled in USER.md, this stops on
  # its own, so the agent behaves normally instead of re-introducing itself.
  defp bootstrap_block do
    bootstrap_dir =
      Application.get_env(:optimal_system_agent, :bootstrap_dir, "~/.osa")
      |> Path.expand()

    if user_known?(bootstrap_dir) do
      nil
    else
      bootstrap_path = Path.join(bootstrap_dir, "BOOTSTRAP.md")

      case File.read(bootstrap_path) do
        {:ok, content} ->
          content = String.trim(content)
          if content == "", do: nil, else: "## GET TO KNOW THE USER\n\n#{content}"

        {:error, _} ->
          nil
      end
    end
  end

  # Completion signal for the first-meet ritual. A free-form "they're called X"
  # note does NOT match — only the USER.md template line the seed writes:
  # `- **Name:** Roberto`. Doctor and Onboarding.seed_workspace/0 must use this
  # same check; a private copy is how known users get asked their name again.
  @user_known_re ~r/-\s*\*\*Name:\*\*\s*\S+/

  @doc "The regex `user_known?/1` applies to USER.md."
  @spec user_known_regex() :: Regex.t()
  def user_known_regex, do: @user_known_re

  @doc """
  True once `USER.md` in `dir` has a filled `- **Name:** …` line.

  Missing or unreadable USER.md is unknown. The blank template
  (`- **Name:**` with nothing after) is unknown.
  """
  @spec user_known?(Path.t()) :: boolean()
  def user_known?(dir) do
    case File.read(Path.join(dir, "USER.md")) do
      {:ok, content} -> Regex.match?(@user_known_re, content)
      {:error, _} -> false
    end
  end

  # Bounded, query-scored, threshold-gated memory recall (Grok-style).
  # Trivial turns (no meaningful keywords in the latest user message) get NO
  # memory block at all — the static base carries a <memory> pointer so the
  # model pulls memories on demand via memory_recall instead. Fails CLOSED:
  # errors yield nil, never an unfiltered dump.
  defp memory_block_relevant(state) do
    latest_user_msg = find_latest_user_message(state.messages)
    keywords = Scoring.extract_keywords(latest_user_msg)

    content =
      if keywords == [] do
        nil
      else
        recall_scored(latest_user_msg, keywords)
      end

    # Append taxonomy-classified memories via Injector (if available)
    taxonomy_addendum = taxonomy_inject(state, latest_user_msg)

    combined =
      case {content, taxonomy_addendum} do
        {nil, nil} -> nil
        {nil, add} -> add
        {text, nil} -> text
        {text, add} -> text <> "\n\n" <> (add || "")
      end

    case combined do
      nil -> nil
      "" -> nil
      text -> "## Long-term Memory\n#{text}"
    end
  end

  defp taxonomy_inject(_state, _latest_user_msg) do
    # Learning module removed — no taxonomy injection
    nil
  end

  defp find_latest_user_message(nil), do: nil
  defp find_latest_user_message([]), do: nil

  defp find_latest_user_message(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn msg ->
      if to_string(Map.get(msg, :role)) == "user" do
        safe_to_string(Map.get(msg, :content, ""))
      end
    end)
  end

  # Hybrid recall: FTS5/BM25 + vector-KNN semantic similarity + temporal/
  # category weighting, MMR-reranked for diversity (Memory.recall_hybrid).
  # Degrades to keyword-only recall when no embedding provider is configured.
  # recall_hybrid already filters below min_score and caps the count; the
  # already-ranked block is then hard-truncated to the token cap. No re-sort
  # here — that would undo the MMR diversity rerank.
  #
  # `:embed_deadline_ms` is what makes this safe to call from prompt assembly.
  # The embedding round-trip inside `recall_hybrid` otherwise carries a
  # 5-SECOND receive timeout, and this runs BEFORE the request is sent: a
  # wedged embedding sidecar would hold the whole turn there with nothing on
  # screen. The vector score is an optional improvement over the lexical one —
  # `Memory.recall_hybrid/2` already falls back to pure lexical whenever the
  # embedder is missing or fails — so past the deadline we simply take that
  # answer. The tools that exist to search memory keep the full 5s.
  defp recall_scored(query, _query_keywords) do
    max_results = Budget.memory_recall_max_results()
    min_score = Budget.memory_recall_min_score()

    case OptimalSystemAgent.Memory.recall_hybrid(query,
           limit: max_results,
           min_score: min_score,
           embed_deadline_ms: prompt_embed_deadline_ms()
         ) do
      {:ok, entries} when is_list(entries) and entries != [] ->
        entries
        |> Enum.map(fn entry ->
          cat = Map.get(entry, :category, "general")
          content = Map.get(entry, :content, "")
          "## #{cat}\n#{content}"
        end)
        |> Enum.join("\n\n")
        |> truncate_to_tokens(Budget.memory_context_token_cap())

      _ ->
        nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # Cross-tier memory recall (episodic ATTEMPTS + semantic skills), from
  # `Agent.Memory.Coordinator`. Distinct from `memory_block_relevant/1` (the
  # hybrid FTS5+vector long-term store) and from `episodic_block/1` (recent
  # events in THIS session); this is "how did we do on tasks like this before".
  #
  # ## Why it lives here and not in the message list
  #
  # It used to be injected by `Loop.MessageHandler.build_pre_directives/2` as a
  # `role: "system"` message appended to `state.messages` — permanently, once
  # per user turn, with no budget. MEASURED over 15 turns: 14 near-identical
  # copies in a single request, 2,950 tokens of which 2,717 were redundant —
  # 24% of everything the session had accumulated, growing ~220 tokens/turn for
  # as long as the session ran.
  #
  # Deleting the stale copy before appending a fresh one would have fixed the
  # growth and broken something worse. `Providers.PromptCache` places a rolling
  # cache breakpoint on the LAST HISTORY message, so turn N's cached segment is
  # reusable only while it stays a strict PREFIX of turn N+1's request. Removing
  # a message from the middle of history — or appending a per-turn block at the
  # end, which next turn's real messages then displace — invalidates the whole
  # stored segment. That is the exact failure `PromptCache` documents measuring
  # (prefix pinned at 26,213 tokens for six turns), and it would have traded
  # ~220 tokens/turn for the 93.5% hit rate.
  #
  # A dynamic block has neither problem. It is rebuilt from scratch each turn,
  # so it cannot accumulate; it lands in the VOLATILE half of the system
  # message, which `PromptCache` relocates AFTER the breakpoint, so it sits
  # outside the cached prefix by construction; and it is fitted against the
  # recall budget like every other recall block instead of being unbounded.
  defp memory_recall_block(state) do
    session_id = Map.get(state, :session_id)
    query = find_latest_user_message(Map.get(state, :messages) || [])

    if is_binary(session_id) and is_binary(query) and query != "" do
      opts =
        case cwd_or_nil() do
          nil -> []
          project -> [project: project]
        end

      case OptimalSystemAgent.Agent.Memory.Coordinator.recall_block(session_id, query, opts) do
        block when is_binary(block) and block != "" -> "## Relevant memory\n" <> block
        _ -> nil
      end
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp cwd_or_nil do
    File.cwd!()
  rescue
    _ -> nil
  end

  defp episodic_block(state) do
    session_id = Map.get(state, :session_id, "default")

    events =
      try do
        Episodic.recent(session_id, 10)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    case events do
      [] ->
        nil

      events ->
        lines =
          Enum.map(events, fn event ->
            ts = Map.get(event, :timestamp)
            type = Map.get(event, :event_type, :unknown)
            data = Map.get(event, :data, %{})

            summary =
              Map.get(data, :summary) || Map.get(data, :tool) || Map.get(data, :message) ||
                inspect(data)

            time_str = if ts, do: Calendar.strftime(ts, "%H:%M:%S"), else: "??:??:??"
            "[#{time_str}] #{type}: #{summary}"
          end)

        "## Recent Session Events\n" <> Enum.join(lines, "\n")
    end
  rescue
    _ -> nil
  end

  defp workflow_block(state) do
    session_id = Map.get(state, :session_id)

    if session_id do
      Tasks.workflow_context_block(session_id)
    else
      nil
    end
  rescue
    _ -> nil
  end

  # Durable, always-re-injected Task Brief (audit gap M1). When a run has a
  # founding goal captured on disk (`Agent.TaskBrief`), inject it verbatim on
  # EVERY turn as part of this `role: "system"` prompt. Because it is re-derived
  # from disk each turn AND lives in a system block (which the Compactor
  # preserves — see `split_system/1`), the original instruction can never be
  # compacted away over a days-long single-instruction run. Normal short chats
  # have no brief, so this returns nil and injects nothing.
  defp task_brief_block(state) do
    session_id = Map.get(state, :session_id)

    if is_binary(session_id) do
      OptimalSystemAgent.Agent.TaskBrief.context_block(session_id)
    else
      nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp active_skills_block(state) do
    case Map.get(state, :session_id) do
      session_id when is_binary(session_id) ->
        OptimalSystemAgent.Agent.ActiveSkills.context_block(
          session_id,
          Map.get(state, :messages, [])
        )

      _ ->
        nil
    end
  rescue
    error ->
      "## Selected Skills Checkpoint Error\n\n" <>
        "OSA could not inspect the selected-skill checkpoint (#{Exception.message(error)}). " <>
        "Do not continue the task until the skill is selected again with `skill_view`."
  end

  defp task_state_block(state) do
    session_id = Map.get(state, :session_id, "default")

    tasks =
      try do
        Tasks.get_tasks(session_id)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    case tasks do
      [] ->
        nil

      tasks ->
        completed = Enum.count(tasks, &(&1.status == :completed))
        total = length(tasks)

        lines =
          Enum.map(tasks, fn task ->
            icon = task_icon(task.status)
            suffix = task_suffix(task)
            "#{icon} #{task.id}: #{task.title}#{suffix}"
          end)

        """
        ## Active Tasks (#{completed}/#{total} completed)
        #{Enum.join(lines, "\n")}

        Stay focused on these tasks. Update status as you progress.
        """
    end
  end

  defp task_icon(:completed), do: "✔"
  defp task_icon(:in_progress), do: "◼"
  defp task_icon(:failed), do: "✘"
  defp task_icon(_), do: "◻"

  defp task_suffix(%{status: :in_progress}), do: "  [in_progress]"
  defp task_suffix(%{status: :failed, reason: nil}), do: "  [failed]"
  defp task_suffix(%{status: :failed, reason: reason}), do: "  [failed: #{reason}]"
  defp task_suffix(_), do: ""

  # Investigative plan mode (CC-parity): read-only tools remain AVAILABLE —
  # the permission layer (`ToolExecutor.approve_tool_call/2`, `mode == :plan`)
  # blocks anything mutating, so the model can freely call file_read /
  # file_grep / file_glob / dir_list / codebase_explore / web_fetch / etc. to
  # investigate before it commits to a plan. Matches CC's ExitPlanMode prompt
  # guidance ("For research tasks that involve reading files... do NOT
  # exit/finish planning") — a plan produced without grounding is a guess.
  defp plan_mode_block(%{plan_mode: true} = state) do
    existing_draft = existing_plan_draft(Map.get(state, :session_id))

    """
    ## PLAN MODE — ACTIVE (investigative)

    You are in PLAN MODE. Read-only tools (file_read, file_grep, file_glob,
    dir_list, codebase_explore, web_fetch, web_search, and similar) are
    AVAILABLE — use them to investigate the codebase and ground your plan in
    what the code actually does. Write, edit, delete, and shell/exec tools are
    BLOCKED at the permission layer while plan mode is active; calling one
    returns a blocked-tool message instead of executing.

    For research tasks that involve reading files, searching, or exploring
    the codebase to understand the current state before proposing changes:
    keep investigating with read-only tools. Do NOT stop investigating and
    write your final plan until you have grounded it in the real code — an
    ungrounded guess produces a mis-scoped plan that wastes execution steps
    later.

    Once you have enough grounding, respond with your final answer as plain
    text (no tool call) in this exact structure. That text becomes your
    answer for this turn and is written to the session's durable plan file
    for the user to review:

    ### Goal
    One sentence: what will be accomplished.

    ### Steps
    Numbered list of concrete actions you will take.
    Each step should be specific enough to execute without ambiguity.

    ### Files
    List of files you expect to create or modify.

    ### Risks
    Any edge cases, breaking changes, or concerns.

    ### Estimate
    Rough scope: trivial / small / medium / large

    Be concise. The user will approve, reject, or request changes before you execute.
    #{existing_draft}
    """
  end

  defp plan_mode_block(_), do: nil

  # Surface a previously written (but not yet approved) plan file so a
  # resumed / re-invoked plan-mode turn can incrementally revise it instead
  # of starting from a blank page — the plan file is the durable source of
  # truth and survives context resets, session restarts, and the plan_edit
  # round-trip (`Agent.PlanMode.edit/2`).
  defp existing_plan_draft(session_id) when is_binary(session_id) do
    case OptimalSystemAgent.Agent.PlanStore.read_plan_file(session_id) do
      {:ok, contents} ->
        trimmed = String.trim(contents)

        if trimmed == "" do
          ""
        else
          "\n### Existing draft plan (resumed from disk — revise or continue investigating as needed)\n\n#{trimmed}\n"
        end

      _ ->
        ""
    end
  rescue
    _ -> ""
  catch
    :exit, _ -> ""
  end

  defp existing_plan_draft(_), do: ""

  # Logical tool key → candidate registered names, most-preferred first.
  #
  # The prompt refers to tools by these STABLE logical keys; the renderer
  # resolves each to the FIRST candidate that is actually active in the live
  # registry and injects that real name (grok's `tools.by_kind.X` idea). A
  # rename / namespace / virtualization change is handled by adding the new
  # name as a candidate — the prose then follows the live toolset. For OSA the
  # canonical name usually IS the registered name, so most lists are singletons;
  # `tool_search` carries grok's `search_tool` alias as an example of surviving
  # a rename.
  @prompt_tool_candidates %{
    "ask_user" => ["ask_user"],
    "task_write" => ["task_write"],
    "file_read" => ["file_read"],
    "file_write" => ["file_write"],
    "file_edit" => ["file_edit"],
    "file_grep" => ["file_grep"],
    "file_glob" => ["file_glob"],
    "dir_list" => ["dir_list"],
    "web_fetch" => ["web_fetch"],
    "shell_execute" => ["shell_execute"],
    "codebase_explore" => ["codebase_explore"],
    "delegate" => ["delegate"],
    "mixture_of_agents" => ["mixture_of_agents"],
    "tool_search" => ["tool_search", "search_tool"],
    "use_tool" => ["use_tool"]
  }

  defp tool_process_block(state) do
    cwd = Map.get(state, :working_dir) || OptimalSystemAgent.Workspace.Cwd.get()
    tools = resolve_prompt_tools(state)

    template = """
    ## Act — don't just chat
    You are OSA, an agent, not a chatbot. When the user asks for anything that touches this machine or its code — read, find, write, edit, run, check, fix, verify — DO IT with your tools in THIS turn. Do not describe what you would do, do not ask permission to begin, do not hand back a plan when action was requested. Interpret unclear or generic instructions in the context of the current working directory and the task at hand: if the user says rename `methodName` to snake_case, don't just reply `method_name` — find it in the code and change it. The user's UI shows every tool call, so call-by-call narration is noise — but before a GROUP of related calls, send ONE short preamble (1-2 sentences) saying what you're about to do and why, building on what you just learned. Skip it for a trivial single read; when a result changes the plan, say so in one line. Then fire the tools and report the result.

    When to just answer (no tools): greetings, opinions, and questions you can fully answer from knowledge already in context. When to ACT: anything that depends on real files, real state, or real command output — default to acting. You are highly capable; take on ambitious multi-step work rather than pushing it back to the user. When genuinely blocked after investigating — ambiguous requirements or a decision only the user can make — ask ONE crisp question with ${{ tools.ask_user }}. If an approach fails, diagnose why before switching tactics: read the error, check your assumptions, try a focused fix. Don't retry the identical failing action blindly, and don't abandon a viable approach after one failure.

    ## Act with care — reversibility and blast radius
    Local, reversible actions (reading files, editing code, running tests/builds/lints) — just do them, no permission needed. But before actions that are hard to reverse, affect shared state beyond this machine, or could destroy work, stop and confirm with the user first: deleting files/branches, `rm -rf`, dropping DB tables, force-pushing, `git reset --hard`, removing dependencies, pushing code, opening/commenting on PRs, sending messages, or posting to external services. A user approving such an action once does not authorize it in all future contexts. When you hit an obstacle, never use a destructive shortcut (e.g. `--no-verify`) to make it go away — find the root cause. Investigate unfamiliar files/branches/locks before overwriting; they may be the user's in-progress work. Measure twice, cut once.${%- if tools.task_write %}

    ## Manage multi-step work
    For any task with more than a couple of steps, use ${{ tools.task_write }} to lay out the plan up front, then mark each item complete the moment it's done — do not batch completions. This keeps you focused and shows the user real progress. Stay on the listed tasks; don't wander.${%- endif %}

    ## Verify, then report faithfully
    Before claiming a task is done, prove it works: run the test, execute the script, run the build/lint, check the output. If you cannot verify (no test exists, can't run it), say so explicitly rather than implying success. Report outcomes honestly: if tests fail, say so with the relevant output; never claim "all tests pass" when they don't, never quietly weaken a failing check to manufacture green. Equally, when a check did pass, state it plainly without hollow disclaimers or re-verifying what you already confirmed. The goal is an accurate report, not a defensive one.

    ## Tools
    CRITICAL: When asked to create or write code, ALWAYS use ${{ tools.file_write }} to create actual files. NEVER output code in markdown code blocks — use the tool instead. This is your most important rule.
    Use tools proactively, and prefer the dedicated tool over shell so the user can review your work: ${{ tools.file_read }}/${{ tools.file_edit }}/${{ tools.file_write }} over cat/sed/echo; ${{ tools.file_grep }}/${{ tools.file_glob }} over grep/find; ${{ tools.dir_list }} over ls; ${{ tools.web_fetch }} over curl. Reserve ${{ tools.shell_execute }} for real system/terminal work — git, mix, npm, docker, make. To locate code in a large codebase, use ${{ tools.codebase_explore }} or ${{ tools.file_grep }}.${%- if tools.tool_search or tools.use_tool %} Tools not shown in your list are reachable via ${{ tools.tool_search }} — search for one instead of assuming you lack it.${%- endif %}

    ${%- if tools.delegate %}## When to delegate
    Do the work yourself by default — you are capable and delegation adds latency. Reach for ${{ tools.delegate }} to hand a WELL-SCOPED, independent subtask to a fresh subagent when it genuinely helps: a broad open-ended search across many files where you only need the conclusion (not every file's contents in your context), or two or more independent pieces of work that can run in parallel. Give the subagent a crisp, self-contained brief and a clear definition of done — it does not share your context.${%- if tools.mixture_of_agents %} Use ${{ tools.mixture_of_agents }} when you want several independent perspectives on one hard question, then synthesize.${%- endif %} Do NOT delegate a task you can finish faster directly, and never delegate the final decision or the user-facing report — that is yours.
    ${%- endif %}You can call multiple tools in one response. When several calls are independent (reading three files, grepping several patterns), fire them in PARALLEL in a single turn for speed. Only sequence calls when a later one depends on an earlier one's result.
    Rules: read a file before editing it, and don't propose changes to code you haven't read; ${{ tools.file_edit }} for surgical changes, ${{ tools.file_write }} for new files/full rewrites; absolute paths (cwd: #{cwd}); prefer editing an existing file over creating a new one — don't create files unless necessary for the goal; answer concisely, lead with the action or result; don't add features, refactors, comments, or abstractions beyond what was asked.
    """

    PromptTemplate.render(template, tools)
  end

  # Build the logical-key → live-name map for the prompt template from the live
  # registry (or a `state[:active_tool_names]` override in tests). Only PRESENT
  # tools land in the map, so `${%- if tools.KEY %}` sections gate correctly and
  # `${{ tools.KEY }}` injects the real registered name.
  #
  # When the active set is unknown (registry not yet populated, e.g. in unit
  # tests that build a bare state), we fall back to the full canonical set so
  # the prompt renders exactly as before — no regression.
  defp resolve_prompt_tools(state) do
    case active_tool_set(state) do
      :all ->
        Map.new(@prompt_tool_candidates, fn {key, [primary | _]} -> {key, primary} end)

      %MapSet{} = active ->
        @prompt_tool_candidates
        |> Enum.flat_map(fn {key, candidates} ->
          case Enum.find(candidates, &MapSet.member?(active, &1)) do
            nil -> []
            name -> [{key, name}]
          end
        end)
        |> Map.new()
    end
  end

  defp active_tool_set(state) do
    case Map.get(state, :active_tool_names) do
      names when is_list(names) and names != [] ->
        MapSet.new(names)

      %MapSet{} = set ->
        if MapSet.size(set) == 0, do: :all, else: set

      _ ->
        case safe_list_active_names() do
          [] -> :all
          names -> MapSet.new(names)
        end
    end
  end

  defp safe_list_active_names do
    OptimalSystemAgent.Tools.Registry.list_active()
    |> Enum.map(& &1.name)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp environment_block(state) do
    cwd = Map.get(state, :working_dir) || OptimalSystemAgent.Workspace.Cwd.get()
    git_info = cached_git_info()
    date = Date.utc_today() |> Date.to_iso8601()

    # Resolve identity through the ONE canonical resolver `Runtime.Identity`,
    # the same one `runtime_block/1` and the TUI status bar use. This block
    # used to resolve model/provider on its own (`state.model ||
    # get_active_model/1`), which fell back to the provider's CONFIG DEFAULT
    # when the session had not pinned `state.model` — so on an OpenRouter
    # session actually running `stealth/ox-alpha` this line announced
    # `anthropic/claude-opus-5` (the openrouter default), directly
    # contradicting the runtime block and the footer. Two identity lines that
    # disagree let the model pick the wrong one and confidently misreport what
    # it is. One resolver, one answer.
    %{model: model, provider: provider} = OptimalSystemAgent.Runtime.Identity.resolve(state)

    {os_family, os_name} = :os.type()
    platform = "#{os_family}/#{os_name}"

    """
    ## Environment
    Useful information about the environment you are running in:
    - Working directory: #{cwd}
    - Is directory a git repo: #{if git_info != "", do: "Yes", else: "No"}
    - Platform: #{platform}
    - Today's date: #{date}
    - You are OSA, powered by the model `#{model}` running on the `#{provider}` provider.
    """
  rescue
    _ -> nil
  end

  # Volatile half of the old environment block: branch / dirty files / recent
  # commits. Split out so the STABLE environment facts can live in the diffed
  # world state (emitted once) while the working-tree state, which the agent
  # itself mutates, stays a cheap per-turn block.
  defp git_state_block(_state) do
    case cached_git_info() do
      "" -> nil
      info -> "## Git State\n#{info}"
    end
  rescue
    _ -> nil
  end

  @git_cache_table :osa_git_info_cache
  @git_cache_ttl 30_000

  defp cached_git_info do
    ensure_git_cache_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@git_cache_table, :git_info) do
      [{:git_info, info, ts}] when now - ts < @git_cache_ttl ->
        Logger.debug("[Context] git info cache hit")
        info

      _ ->
        Logger.debug("[Context] git info cache miss — running git commands")
        info = gather_git_info()
        :ets.insert(@git_cache_table, {:git_info, info, now})
        info
    end
  end

  defp ensure_git_cache_table do
    case :ets.whereis(@git_cache_table) do
      :undefined -> :ets.new(@git_cache_table, [:named_table, :public, :set])
      _ -> @git_cache_table
    end
  rescue
    _ -> nil
  end

  defp gather_git_info do
    parts = []

    parts =
      case OptimalSystemAgent.Git.cmd(["branch", "--show-current"], stderr_to_stdout: true) do
        {b, 0} -> ["- Git branch: #{String.trim(b)}" | parts]
        _ -> parts
      end

    parts =
      case OptimalSystemAgent.Git.cmd(["status", "--short"], stderr_to_stdout: true) do
        {s, 0} when s != "" ->
          trimmed = String.trim(s)
          if trimmed != "", do: ["- Modified files:\n#{trimmed}" | parts], else: parts

        _ ->
          parts
      end

    parts =
      case OptimalSystemAgent.Git.cmd(["log", "--oneline", "-3"], stderr_to_stdout: true) do
        {l, 0} -> ["- Recent commits:\n#{String.trim(l)}" | parts]
        _ -> parts
      end

    Enum.reverse(parts) |> Enum.join("\n")
  rescue
    _ -> ""
  end

  defp get_active_model(:anthropic),
    do: Application.get_env(:optimal_system_agent, :anthropic_model, "claude-sonnet-4-6")

  defp get_active_model(:ollama),
    do: Application.get_env(:optimal_system_agent, :ollama_model, "detecting...")

  defp get_active_model(:openai),
    do: Application.get_env(:optimal_system_agent, :openai_model, "gpt-4o")

  defp get_active_model(provider) do
    key = :"#{provider}_model"
    Application.get_env(:optimal_system_agent, key, to_string(provider))
  end

  defp runtime_block(state) do
    session_id = Map.get(state, :session_id, "default")
    effort = OptimalSystemAgent.Agent.Effort.current()
    effort_config = OptimalSystemAgent.Agent.Effort.get(effort)
    coordinator = Map.get(state, :coordinator, false)
    # Tests construct partial state maps without `:turn_count` / `:max_turns` /
    # `:max_budget_usd`. Default these here so `Context.build/1` is safe to
    # call against any state shape.
    turn_count = Map.get(state, :turn_count, 0)
    max_turns = Map.get(state, :max_turns)
    max_budget_usd = Map.get(state, :max_budget_usd)

    lines = [
      "## Runtime Context",
      # Truncated to the SECOND, not microseconds. Nothing the model does with
      # this line needs sub-second resolution, and a microsecond clock is pure
      # entropy: it guarantees this block differs on every single request, which
      # matters for providers whose caching is a plain byte-prefix match (OpenAI)
      # and for any future change that moves this block earlier in the prompt.
      # This is hygiene, not the cache fix — the fix is that the block carrying
      # this line sits outside every `cache_control` region (see
      # `build_system_message/4` and `Providers.Anthropic.split_system/2`).
      "- Timestamp: #{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()}",
      # Identity is KNOWN, not discoverable: same resolver /health feeds the TUI
      # status bar from, so this line and the bar can never disagree. Without it
      # "what model are you" costs three tool calls and two wrong guesses.
      OptimalSystemAgent.Runtime.Identity.context_line(state),
      "- Channel: #{state.channel}",
      "- Session: #{session_id}",
      "- Effort: #{effort} (#{effort_config.description})",
      "- Turn: #{turn_count}"
    ]

    lines =
      if coordinator,
        do: lines ++ ["- Mode: **coordinator** (delegation/messaging only)"],
        else: lines

    lines =
      if max_budget_usd do
        # Real per-session spend accumulated by `Loop.Accounting` — not the
        # old dead `total_cost_usd` lookup that always resolved to $0.
        cost = (Map.get(state, :session_cost_usd, 0.0) || 0.0) / 1
        lines ++ ["- Budget: $#{Float.round(cost, 4)} / $#{max_budget_usd}"]
      else
        lines
      end

    lines = if max_turns, do: lines ++ ["- Turns: #{turn_count}/#{max_turns}"], else: lines

    Enum.join(lines, "\n")
  end

  defp skills_block(state) do
    try do
      message = find_latest_user_message(state.messages)
      OptimalSystemAgent.Tools.Registry.active_skills_context(message)
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end

  # Names the top relevant learned skills (from past sessions) in-context so the
  # agent can pull full bodies on demand via find_skill. Cheap: only titles/slugs.
  defp learned_skills_block(state) do
    try do
      message = find_latest_user_message(state.messages)

      case message && OptimalSystemAgent.Store.SkillLibrary.find_skills(message, limit: 3) do
        skills when is_list(skills) and skills != [] ->
          lines =
            Enum.map_join(skills, "\n", fn s ->
              "- **#{s["title"]}** (find_skill slug: #{s["slug"]}) — #{s["when_to_use"]}"
            end)

          "## Learned Skills (from past sessions)\n\n" <>
            "Verified procedures that may apply. Call `find_skill` to load the full steps:\n" <>
            lines

        _ ->
          nil
      end
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end

  # The provider default is resolved inside `Scratchpad.decision/1` now, and the
  # MODEL is what it actually needs: whether a request carries native thinking is
  # a model-level fact (`claude-*` thinking mode, an Ollama cloud tag, a Bedrock
  # Claude id), not a provider-level one. Passing the whole state hands it both.
  defp scratchpad_block(state) do
    if Scratchpad.inject?(state) do
      Scratchpad.instruction()
    else
      nil
    end
  end

  defp security_posture_block(state) do
    OptimalSystemAgent.Agent.SecurityContext.security_posture_block(state)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp sandbox_environment_block(state) do
    OptimalSystemAgent.Agent.SecurityContext.sandbox_environment_block(state)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end
end
