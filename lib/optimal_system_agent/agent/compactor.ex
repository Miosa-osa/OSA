defmodule OptimalSystemAgent.Agent.Compactor do
  @moduledoc """
  Intelligent sliding-window context compaction with importance-weighted retention.

  ## Architecture

  The compactor divides the conversation into three zones and applies
  progressively heavier compression as messages age:

      Zone 1 — HOT  (last 10 messages): Verbatim, never touched.
      Zone 2 — WARM (messages 11-30):   Progressive compression pipeline.
      Zone 3 — COLD (messages 31+):     Collapsed to a single key-facts summary.

  ## Progressive Compression Pipeline

  Instead of a single jump from "full messages" to "emergency truncate",
  compression proceeds through discrete steps. After each step the total
  token count is checked — the pipeline stops as soon as usage drops below
  the target threshold.

      Step 1  Strip tool-call argument details (keep name + result only)
      Step 2  Merge consecutive same-role messages
      Step 3  Summarize groups of 5 warm-zone messages (LLM call)
      Step 4  Compress cold zone to key-facts (LLM call)
      Step 5  Emergency truncate (last resort, no LLM)

  ## Importance-Weighted Retention

  Not all messages are equal. An importance score determines how long a
  message resists compression:

      Tool calls present   → +50% retention bonus
      Long/substantive     → up to +30% retention bonus (length / 500, capped)
      Pure acknowledgment  → -50% retention (compressed first)

  Messages with higher importance scores are kept verbatim longer during
  warm-zone compression.

  ## Token Estimation

  Uses a word + punctuation heuristic floored by byte length:

      max(words * 1.3 + punctuation * 0.5, bytes / 4)

  Image blocks are excluded from that text estimate and charged a flat
  per-image cost instead — see `@image_token_estimate`.

  ## Public API

      maybe_compact/4         — inspect and possibly compact a message list
      stats/0                 — compaction metrics from the GenServer
      start_link/1            — GenServer lifecycle
      utilization_percent/2   — context-window utilization, 0.0-100.0 PERCENT
      estimate_tokens/1       — token estimate for a string or message list
      micro_compact/1         — P5 token-protected prune tier, standalone
      format_for_summary/1    — P6 media-strip + tool-output-cap text formatter

  ## Context window resolution (NO hardcoded default)

  Every decision this module makes is measured against the REAL context window
  of the model currently in use, threaded in by the caller as
  `context_window: Registry.effective_context_window_info(model, provider)`.

  There is deliberately **no** `max_tokens/0` accessor with a built-in default
  any more. A hardcoded 128k default silently won over real data and made OSA
  summarize a 1M-window model at ~11% occupancy, destroying fidelity on every
  long session. When the window cannot be resolved the answer is `:unknown` and
  compaction is DEFERRED (see `maybe_compact/4`), never guessed.

  The `:max_context_tokens` application env is honoured only as an EXPLICIT
  operator/test override, and only when the caller did not supply a window. It
  has no default — unset means `:unknown`, not 128k.

  ## Thresholds

  "How full is too full" has exactly one definition, shared with
  `Agent.Loop.ProactiveCompaction`:
  `OptimalSystemAgent.Agent.Loop.CompactionThresholds` (reserve-based, Claude
  Code parity). The three severity tiers are derived from it:

      tokens >= block_at(window)   → :emergency
      tokens >= compact_at(window) → :aggressive
      tokens >= warn_at(window)    → :background
      otherwise                    → :none
  """

  use GenServer
  require Logger

  @behaviour OptimalSystemAgent.Agent.ContextEngine

  alias OptimalSystemAgent.Providers.Registry, as: Providers
  alias OptimalSystemAgent.PromptLoader
  alias OptimalSystemAgent.Agent.CompactionSafety
  alias OptimalSystemAgent.Agent.CompactionEvents
  alias OptimalSystemAgent.Agent.Loop.CompactionThresholds
  alias OptimalSystemAgent.Agent.Trajectory

  @type window_input :: {:ok, pos_integer()} | :unknown | pos_integer() | nil
  @type severity :: :none | :background | :aggressive | :emergency

  # Zone boundaries (counted from the end of the non-system message list).
  # @hot_zone_size is now only a FALLBACK for the token-budgeted tail
  # selector (see `compute_hot_start/1`) — used when no user-delimited turn
  # structure can be found in the message list at all.
  @hot_zone_size 20
  @warm_zone_end 50

  # ---------------------------------------------------------------------------
  # P4: token-budgeted, turn-aware tail selection (opencode compaction.ts
  # select/splitTurn; grok select.rs select_tail).
  #
  # `preserve_recent_budget/0` mirrors opencode's `preserveRecentBudget`:
  # 25% of the usable context window, clamped to [2_000, 8_000] tokens, with
  # an operator override via config.
  # ---------------------------------------------------------------------------
  @min_preserve_recent_tokens 2_000
  @max_preserve_recent_tokens 8_000

  # Divide-and-conquer chunk token limit for cold-zone summarization (P7,
  # grok inter_compaction `dnc_chunk_token_limit`).
  @dnc_chunk_token_limit_default 3_000

  # Flat token cost charged for one image block, in place of measuring its
  # base64 envelope.
  #
  # Providers bill an image by its pixel dimensions, not by the size of the
  # transport encoding: Anthropic charges roughly (width * height) / 750,
  # capped near 1600 for a full-size image; OpenAI charges a fixed base plus
  # per-512px-tile cost in the same range. The base64 payload behind it is
  # typically ~10x larger in token-equivalent bytes, so JSON-encoding an image
  # block into the text estimate over-states the context it occupies by an
  # order of magnitude — and over-statement drives needless compaction, which
  # destroys history that did not need destroying.
  @image_token_estimate 1_600

  # Block `type` values that carry an image payload, across the provider
  # dialects this codebase sees: Anthropic (`image`), OpenAI chat
  # (`image_url`), OpenAI Responses (`input_image`).
  @image_block_types ~w(image image_url input_image)
  @text_block_types ~w(text input_text output_text)

  # Reasoning blocks. Anthropic emits `%{type: "thinking", thinking: <text>,
  # signature: <base64>}`; the signature is opaque metadata that must be echoed
  # back verbatim (anthropic.ex:808-813) but is NOT billed as content, and it is
  # routinely several times the length of the reasoning it signs. Charging the
  # JSON envelope — which is what the fallback path does, and which the byte
  # floor makes worse — over-states these blocks severalfold.
  @thinking_block_types ~w(thinking reasoning)

  # `redacted_thinking` carries ONLY an opaque `data` blob — there is no text to
  # measure. It still occupies context, so it is not free; charge it a small
  # flat cost rather than the length of its encoding.
  @redacted_thinking_token_estimate 100

  # Message keys (outside `:content`) that carry replayed reasoning. `ReactLoop`
  # stores thinking blocks at the top level as `:thinking_blocks`
  # (react_loop.ex:1011-1013) and providers surface `:reasoning_content`; both
  # are sent again on the next turn, so both occupy the context window.
  @reasoning_message_keys [:thinking_blocks, :reasoning_content]

  # Importance score marking an annotated entry as UNDROPPABLE by any purely
  # positional pipeline step.
  #
  # `:compress_cold` spends an LLM call folding the whole cold span into one
  # summary and prepends it at index 0. `:emergency_truncate` then drops
  # `Enum.slice(annotated, 0, split)` — index 0 first — so the summary was
  # destroyed by the same pipeline run that produced it, and since the
  # pipeline's return value REPLACES `state.messages`, the span it summarized
  # survived nowhere in context. Scoring it 2.0 did not help: nothing consulted
  # the annotation.
  #
  # The value sits far above anything `message_importance/1` can produce
  # (its ceiling is 1.0 + 0.5 + 0.3 + 0.3 = 2.1), so an organically-scored
  # message can never be mistaken for a pin.
  @pinned_importance 1_000.0

  # Acknowledgment patterns — these get compressed first
  @ack_patterns ~r/\A\s*(ok|okay|sure|thanks|thank you|got it|yes|no|yep|nope|k|kk|alright|cool|nice|great|perfect|noted|ack|roger|👍|👌)\s*[\.\!\?]?\s*\z/iu

  # ---------------------------------------------------------------------------
  # GenServer state
  # ---------------------------------------------------------------------------

  defstruct compaction_count: 0,
            tokens_saved: 0,
            last_compacted_at: nil,
            pipeline_steps_used: %{}

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc "Start the Compactor GenServer."
  @impl OptimalSystemAgent.Agent.ContextEngine
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  end

  @doc """
  Returns current compaction metrics including per-step usage counts.
  """
  @spec stats() :: map()
  @impl OptimalSystemAgent.Agent.ContextEngine
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Inspects the given message list and compacts it if usage has crossed the
  shared `CompactionThresholds` for the CURRENT MODEL'S context window.
  Returns the (possibly compacted) message list.

  `known_tokens` is an optional REAL, provider-reported input-token count for
  the current context (from `Loop.Accounting` / the budget stage). When it is a
  positive integer it drives the compaction *decision* instead of the
  word-count heuristic — the heuristic under-counts because it ignores the
  system prompt + tool schemas that also consume the window. `nil`/`0` falls
  back to the estimate.

  ## Options

    * `:context_window` — the model's real window. Accepts the
      `{:ok, tokens} | :unknown` shape returned by
      `Providers.Registry.effective_context_window_info/2` (preferred), a bare
      positive integer, or `nil`/omitted to fall back to the explicit
      `:max_context_tokens` operator override. NEVER defaults to a guess.

    * `:force` — when `true`, compact regardless of the resolved window (used
      by the reactive overflow-recovery path, which already has a hard
      provider-reported context-length error as its signal). Defaults to
      `false`.

  ## Unknown windows

  When the window resolves to `:unknown` and `:force` is not set, this function
  **does nothing and returns the messages unchanged**. Compacting against a
  guessed denominator is exactly the defect this design exists to prevent: a
  wrong guess destroys conversation fidelity irreversibly and silently, while
  deferring is fully recoverable — the provider will return a context-length
  error, `Loop.ContextCollapse` withholds large tool results first, and the
  overflow path then calls back in with `force: true`. Losing a turn to one
  overflow retry is cheap; losing the conversation is not.

  This function is safe — it never raises. On any unexpected error it returns
  the original messages unchanged.
  """
  @spec maybe_compact([map()], non_neg_integer() | nil, String.t() | nil, keyword()) :: [map()]
  @impl OptimalSystemAgent.Agent.ContextEngine
  def maybe_compact(messages, known_tokens \\ nil, session_id \\ nil, opts \\ []) do
    try do
      do_maybe_compact(messages, known_tokens, session_id, opts)
    rescue
      e ->
        Logger.error("Compactor.maybe_compact crashed: #{Exception.message(e)}")
        messages
    end
  end

  @doc """
  Resolve a caller-supplied context window into `{:ok, tokens} | :unknown`.

  Accepts the `Registry.effective_context_window_info/2` shape directly, a bare
  positive integer, or `nil`.

  A genuinely known window always wins. Only when the window is unknown or
  absent does this consult the explicit `:max_context_tokens` operator
  override — which has NO default, so an unset override yields `:unknown`,
  never a fabricated 128k.
  """
  @spec resolve_window(window_input()) :: {:ok, pos_integer()} | :unknown
  def resolve_window({:ok, n}) when is_integer(n) and n > 0, do: {:ok, n}
  def resolve_window(n) when is_integer(n) and n > 0, do: {:ok, n}

  def resolve_window(_unknown_or_nil) do
    case Application.get_env(:optimal_system_agent, :max_context_tokens) do
      n when is_integer(n) and n > 0 -> {:ok, n}
      _ -> :unknown
    end
  end

  @doc """
  The compaction severity for `tokens` used out of a `context_window`, derived
  entirely from the shared reserve-based `CompactionThresholds` — the SAME
  definition `Loop.ProactiveCompaction` uses. There is no second ratio ladder.

  Public so the window→decision link is directly assertable in tests.
  """
  @spec severity_for(non_neg_integer(), pos_integer()) :: severity()
  def severity_for(tokens, cw)
      when is_integer(tokens) and tokens >= 0 and is_integer(cw) and cw > 0 do
    cond do
      tokens >= CompactionThresholds.block_at(cw) -> :emergency
      tokens >= CompactionThresholds.compact_at(cw) -> :aggressive
      tokens >= CompactionThresholds.warn_at(cw) -> :background
      true -> :none
    end
  end

  def severity_for(_tokens, _cw), do: :none

  @doc """
  Run micro-compaction independently — clears old tool results without LLM call.
  Can be called on a timer for lightweight context maintenance.
  """
  @spec micro_compact([map()]) :: [map()]
  @impl OptimalSystemAgent.Agent.ContextEngine
  def micro_compact(messages) do
    {system_msgs, non_system} = split_system(messages)
    annotated = annotate_importance(non_system)
    {compacted, _, _} = apply_step(:micro_compact, annotated, system_msgs, 0, :unknown)
    system_msgs ++ strip_annotations(compacted)
  rescue
    _ -> messages
  end

  @doc """
  Context window utilization as a **PERCENT in 0.0..100.0** — not a 0.0..1.0
  fraction. The unit is in the name on purpose: the old `utilization/1`
  returned a percentage while at least one behaviour doc described the same
  concept as a fraction, and an off-by-100 here means OSA either never compacts
  or compacts constantly.

  Measured with `CompactionThresholds.used_percent/2`, the same denominator the
  status bar uses (window minus output reserve), so the displayed meter and the
  compaction decision can never drift apart.

  `context_window` takes the same shapes as `maybe_compact/4`'s
  `:context_window` option. Returns `:unknown` — never a number — when the
  window cannot be resolved, because a percentage of a fabricated denominator
  is worse than no percentage at all.
  """
  @spec utilization_percent([map()], window_input()) :: float() | :unknown
  @impl OptimalSystemAgent.Agent.ContextEngine
  def utilization_percent(messages, context_window \\ nil)

  def utilization_percent(messages, context_window) when is_list(messages) do
    case resolve_window(context_window) do
      {:ok, cw} -> CompactionThresholds.used_percent(estimate_tokens(messages), cw)
      :unknown -> :unknown
    end
  end

  @doc """
  Estimates token count for a message list or a text string.

  For message lists: sums per-message token estimates including tool call
  overhead and a 4-token per-message framing cost.

  For strings: uses a word + punctuation heuristic floored by byte length —
  `max(words * 1.3 + punctuation * 0.5, bytes / 4)`.

  Structured (block-list) content is walked block by block: image blocks are
  charged `#{@image_token_estimate}` tokens each rather than being JSON-encoded
  into the text estimate, because a base64 envelope is ~10x the tokens the
  provider actually bills for the image it carries.
  """
  @spec estimate_tokens([map()] | String.t() | nil) :: non_neg_integer()
  @impl OptimalSystemAgent.Agent.ContextEngine
  def estimate_tokens(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn msg, acc ->
      content_tokens = estimate_content_tokens(Map.get(msg, :content))

      tool_call_tokens =
        case Map.get(msg, :tool_calls) do
          nil ->
            0

          [] ->
            0

          calls when is_list(calls) ->
            Enum.reduce(calls, 0, fn tc, tc_acc ->
              name_tokens = estimate_tokens(safe_to_string(Map.get(tc, :name, "")))
              arg_tokens = estimate_tokens(safe_to_string(Map.get(tc, :arguments, "")))
              tc_acc + name_tokens + arg_tokens + 4
            end)

          _ ->
            0
        end

      # Per-message overhead (role label, delimiters)
      acc + content_tokens + tool_call_tokens + reasoning_tokens(msg) + 4
    end)
  end

  def estimate_tokens(nil), do: 0

  def estimate_tokens(text) when is_binary(text) do
    if text == "", do: 0, else: estimate_tokens_heuristic(text)
  end

  @doc false
  defp estimate_tokens_heuristic(text),
    do: OptimalSystemAgent.Utils.Tokens.estimate(text)

  @doc """
  Token estimate for one message's `content`, which may be a plain string or a
  provider block list.

  Split out from `estimate_tokens/1` so image blocks never reach the text
  heuristic. Flattening structured content with `Jason.encode!/1` first — which
  is what the string path does — drags every base64 byte of an inline image
  into the estimate, and with a byte-length floor in the heuristic that inflates
  a single screenshot from its real ~#{@image_token_estimate} tokens to tens of
  thousands.
  """
  @spec estimate_content_tokens(term()) :: non_neg_integer()
  def estimate_content_tokens(nil), do: 0
  def estimate_content_tokens(content) when is_binary(content), do: estimate_tokens(content)

  def estimate_content_tokens(blocks) when is_list(blocks),
    do: Enum.reduce(blocks, 0, fn block, acc -> acc + estimate_block_tokens(block) end)

  def estimate_content_tokens(other), do: estimate_tokens(safe_to_string(other))

  # One content block. Images are charged flat; text blocks are measured on
  # their text alone (not the JSON envelope); tool-result wrappers recurse so a
  # nested image is not re-inflated. Anything unrecognised falls back to the
  # previous behaviour: encode and measure.
  defp estimate_block_tokens(block) when is_map(block) do
    cond do
      image_block?(block) ->
        @image_token_estimate

      block_type(block) == "redacted_thinking" ->
        @redacted_thinking_token_estimate

      block_type(block) in @thinking_block_types ->
        estimate_tokens(thinking_text(block))

      block_type(block) in @text_block_types ->
        estimate_tokens(block_text(block))

      nested = block_nested_content(block) ->
        estimate_content_tokens(nested)

      true ->
        estimate_tokens(safe_to_string(block))
    end
  end

  defp estimate_block_tokens(block), do: estimate_tokens(safe_to_string(block))

  defp image_block?(block) when is_map(block), do: block_type(block) in @image_block_types

  # The human-readable reasoning carried by a thinking/reasoning block, with the
  # opaque `signature` deliberately excluded.
  @thinking_text_keys [:thinking, "thinking", :reasoning, "reasoning", :text, "text"]

  defp thinking_text(block) do
    Enum.find_value(@thinking_text_keys, "", fn key ->
      case Map.get(block, key) do
        text when is_binary(text) and text != "" -> text
        _ -> nil
      end
    end)
  end

  # Reasoning replayed on the next request but stored OUTSIDE `:content`.
  defp reasoning_tokens(msg) do
    Enum.reduce(@reasoning_message_keys, 0, fn key, acc ->
      case Map.get(msg, key) || Map.get(msg, Atom.to_string(key)) do
        nil -> acc
        "" -> acc
        [] -> acc
        value -> acc + estimate_content_tokens(value)
      end
    end)
  end

  defp block_nested_content(block) do
    case Map.get(block, :content) || Map.get(block, "content") do
      nested when is_list(nested) -> nested
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(%__MODULE__{} = state) do
    Logger.info("Compactor started (context window is resolved per-model, per-call)")
    {:ok, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    metrics = %{
      compaction_count: state.compaction_count,
      tokens_saved: state.tokens_saved,
      last_compacted_at: state.last_compacted_at,
      pipeline_steps_used: state.pipeline_steps_used
    }

    {:reply, metrics, state}
  end

  @impl true
  def handle_cast({:record_compaction, tokens_saved, step}, state) do
    step_counts = Map.update(state.pipeline_steps_used, step, 1, &(&1 + 1))

    updated = %{
      state
      | compaction_count: state.compaction_count + 1,
        tokens_saved: state.tokens_saved + tokens_saved,
        last_compacted_at: DateTime.utc_now(),
        pipeline_steps_used: step_counts
    }

    {:noreply, updated}
  end

  # ---------------------------------------------------------------------------
  # Core compaction logic
  # ---------------------------------------------------------------------------

  @doc false
  defp do_maybe_compact(messages, known_tokens, session_id, opts) do
    # Message-only heuristic estimate — used for the pipeline's savings math so
    # before/after token counts stay in the same unit.
    estimated = estimate_tokens(messages)

    # Decision token count: prefer the real provider-reported input tokens when
    # available (they include system prompt + tool schemas the estimate omits),
    # else fall back to the heuristic estimate.
    decision_tokens =
      case known_tokens do
        n when is_integer(n) and n > 0 -> n
        _ -> estimated
      end

    # Everything in the real request that the message-only estimate cannot see:
    # system prompt, tool schemas, provider framing. The DECISION is made on
    # `decision_tokens`, but every per-step budget check inside the pipeline
    # measures the message list — so without this the pipeline compacts until
    # the MESSAGES fit a budget derived from the FULL request, stops short, and
    # the next request overflows again on history it just declared small enough.
    # Zero whenever there is no provider-reported count to compare against, so
    # the heuristic-only path is unchanged.
    overhead = max(decision_tokens - estimated, 0)

    force? = Keyword.get(opts, :force, false) == true

    case resolve_window(Keyword.get(opts, :context_window)) do
      {:ok, cw} ->
        case severity_for(decision_tokens, cw) do
          :none ->
            messages

          severity ->
            # Report the OPERATIVE window, not the raw one. `used_percent/2` is
            # computed against the clamped window, so printing the raw model
            # window beside it produced lines like "32960/1000000 (59.9%)" —
            # arithmetic that cannot be checked by the person reading the log.
            Logger.info(
              "Compactor: #{decision_tokens}/#{CompactionThresholds.operative_window(cw)} tokens " <>
                "(#{CompactionThresholds.used_percent(decision_tokens, cw)}% of usable window" <>
                if(CompactionThresholds.operative_window(cw) < cw,
                  do: ", clamped from #{cw}",
                  else: ""
                ) <>
                ") — running #{severity} pipeline"
            )

            run_pipeline(messages, estimated, severity, cw, session_id, overhead)
        end

      :unknown when force? ->
        # A real provider-reported context-length error is the signal; there is
        # no window to measure against, so compact as hard as the pipeline can.
        Logger.warning(
          "Compactor: context window unknown but compaction was FORCED " <>
            "(provider reported overflow) — running emergency pipeline"
        )

        run_pipeline(messages, estimated, :emergency, :unknown, session_id, overhead)

      :unknown ->
        # DEFER. See maybe_compact/4's "Unknown windows" section: guessing a
        # denominator here is what made OSA summarize 1M-window models at ~11%
        # occupancy. Losing a turn to an overflow retry is recoverable; losing
        # conversation fidelity is not.
        Logger.debug(
          "Compactor: context window unknown — deferring compaction until a real " <>
            "overflow signal (#{decision_tokens} tokens in history)"
        )

        messages
    end
  end

  # ---------------------------------------------------------------------------
  # Progressive compression pipeline
  # ---------------------------------------------------------------------------

  @doc false
  defp run_pipeline(messages, tokens_before, severity, cw, session_id, overhead) do
    # Compaction's own bookkeeping must not accumulate — and it is dropped from
    # the pipeline's INPUT, never its output.
    #
    # Every pass appends a restore block, and a truncating pass also appends a
    # "[Context truncated…]" notice, but no pass ever removed the ones its
    # predecessors left behind. Each block describes the transcript AS IT STOOD
    # WHEN THAT PASS RAN, so a stack of twenty-five of them is one current fact
    # and twenty-four stale ones that contradict it. MEASURED, in the first
    # session where compaction ran to completion (28 turns, 25 passes): 25
    # `[Post-compaction context restore]` blocks in a single request, 2,700
    # tokens of which 2,592 were redundant.
    #
    # Dropping them here — before `split_system/1`, before any step runs — is
    # what makes this SUPERSEDE rather than DELETE. Filtering the finished
    # `final_messages` instead also removes the notice THIS pass just wrote
    # (`apply_step(:emergency_truncate, …)` emits it into `system_msgs`), which
    # silently strips the one message whose whole job is to tell the model that
    # its history was cut. Superseding is free here: compaction rewrites
    # history wholesale, so the prompt prefix is reset by this pass regardless
    # and there is no additional cache breakage to pay for.
    # `tokens_before` stays the caller's estimate of the ORIGINAL list, so the
    # tokens reclaimed by dropping stale notices are counted as savings like
    # any other step's.
    messages = drop_stale_compaction_notices(messages)

    # PreCompact hook — SYNCHRONOUS (CC parity). Command hooks receive the
    # full event on stdin and can contribute custom summarization
    # instructions (additionalContext / exit-0 stdout), threaded into every
    # summary LLM prompt for this compaction run. PreCompact cannot veto
    # compaction — a blocking hook is logged and compaction proceeds.
    compact_instructions =
      try do
        case OptimalSystemAgent.Agent.Hooks.run(:pre_compact, %{
               phase: :pre,
               trigger: "auto",
               custom_instructions: "",
               tokens_before: tokens_before,
               severity: severity,
               session_id: session_id
             }) do
          {:ok, final} ->
            final
            |> Map.get(:injected_context, [])
            |> Enum.map(&to_string/1)
            |> Enum.join("\n")
            |> String.trim()

          {:blocked, reason} ->
            Logger.warning("Compactor: PreCompact hook reported #{inspect(reason)} — proceeding")
            ""

          _ ->
            ""
        end
      rescue
        _ -> ""
      catch
        :exit, _ -> ""
      end

    if compact_instructions == "" do
      Process.delete(:osa_compact_instructions)
    else
      Process.put(:osa_compact_instructions, compact_instructions)
    end

    # Scope the iterative structured summary to THIS session for the duration
    # of this pipeline run — same discipline as `:osa_compact_instructions`
    # directly above. `get_previous_summary/0` and `store_previous_summary/1`
    # read this to build a session-keyed ETS key, so one session's summary text
    # can never be folded into another session's compaction prompt.
    if is_binary(session_id) do
      Process.put(:osa_compact_session_id, session_id)
    else
      Process.delete(:osa_compact_session_id)
    end

    # Announce before any step runs. `:osa_compact_session_id` is already in the
    # process dictionary above, which is what lets the nested chunked summarizer
    # emit session-scoped progress without threading the id through six layers.
    compaction_started_at = System.monotonic_time(:millisecond)
    CompactionEvents.started(session_id, :auto, tokens_before)

    # Target: get back OUT of the warning band, i.e. below the shared
    # `warn_at/1` threshold — the same reserve-based definition that decided we
    # were too full in the first place. `:emergency` (or a forced compaction
    # with no resolvable window) goes deeper so a hard overflow actually clears.
    target_tokens = target_tokens(severity, cw)

    {system_msgs, non_system} = split_system(messages)

    # Sort non-system by importance for selective retention
    annotated = annotate_importance(non_system)

    # Run pipeline steps sequentially, stopping when under budget
    # Step 0 (micro-compact) is the cheapest — no LLM call, just truncates old tool results
    result =
      {annotated, system_msgs, :none}
      |> pipeline_step(:micro_compact, target_tokens, cw, overhead)
      |> pipeline_step(:strip_tool_args, target_tokens, cw, overhead)
      |> pipeline_step(:merge_consecutive, target_tokens, cw, overhead)
      |> pipeline_step(:summarize_warm, target_tokens, cw, overhead)
      |> pipeline_step(:compress_cold, target_tokens, cw, overhead)
      |> pipeline_step(:emergency_truncate, target_tokens, cw, overhead)

    {final_annotated, final_system, last_step} = result
    final_messages = final_system ++ strip_annotations(final_annotated)

    # NOTE: stale compaction notices were dropped from the INPUT at the top of
    # this function, deliberately. Do not filter here — `final_system` already
    # carries the truncation notice THIS pass emitted.

    # A compaction pass that reclaims NOTHING must not be applied.
    #
    # The steps above can legitimately reclaim nothing — a transcript whose tool
    # results are already truncated has nothing left to truncate — but the two
    # post-compaction injections below (`CompactRestore` and the
    # `CompactionSafety` reminder) are appended on the strength of `last_step`
    # alone, not on the strength of anything having been removed. When the steps
    # reclaim nothing, the pass would return the input PLUS those blocks: a
    # compactor that grows the context it was called to shrink.
    #
    # MEASURED, once the absolute ceiling made the warning band reachable: the
    # background pipeline ran on every request and reported `saved -62`, `-99`,
    # `-337`, `-515` on consecutive turns, each pass appending another reminder
    # for the next pass to carry.
    #
    # The test is deliberately taken HERE, on the steps' own output, not after
    # the injections. Measuring after them conflates "the steps reclaimed
    # nothing" with "the steps reclaimed less than the injections cost" — two
    # different situations with opposite correct answers. The second one is
    # ordinary on a small window, where a single restore block can outweigh a
    # real cold-zone summary, and treating it as the first throws away genuine
    # compaction work (and the LLM call already paid for to produce it) and
    # returns a transcript that still has to be compacted next turn.
    tokens_after_steps = estimate_tokens(final_messages)
    steps_saved = tokens_before - tokens_after_steps

    if steps_saved <= 0 do
      Logger.info(
        "Compactor pipeline (#{severity}): reclaimed nothing " <>
          "(#{tokens_before} tokens, last_step=#{last_step}) — returning history unchanged"
      )

      CompactionEvents.completed(session_id,
        tokens_before: tokens_before,
        tokens_after: tokens_before,
        messages_before: length(messages),
        messages_after: length(messages),
        duration_ms: System.monotonic_time(:millisecond) - compaction_started_at
      )

      messages
    else
      # Post-compact restore: re-inject working context (files, tasks, workspace)
      restored =
        case OptimalSystemAgent.Agent.CompactRestore.build_restore_message(session_id) do
          nil -> final_messages
          restore_msg -> final_messages ++ [restore_msg]
        end

      # Post-compact active-agent reminder (grok reminder.rs parity): when a step
      # dropped or summarized the working tail, the model can lose awareness of
      # work still in flight. Re-inject a <system-reminder> listing still-running
      # background tasks, sub-agents, and the live TODO list so it keeps tracking
      # them across the compaction boundary.
      restored =
        if last_step in [:summarize_warm, :compress_cold, :emergency_truncate] do
          case CompactionSafety.build_reminder_message(session_id) do
            nil -> restored
            reminder_msg -> restored ++ [reminder_msg]
          end
        else
          restored
        end

      # The injections are advisory; the compaction is the point. If they would
      # cost more than the steps reclaimed, keep the compacted history and drop
      # the injections rather than the other way round — that is what keeps a
      # net-negative pass impossible without discarding real work.
      {final_messages, tokens_after} =
        case estimate_tokens(restored) do
          t when t < tokens_before -> {restored, t}
          _ -> {final_messages, tokens_after_steps}
        end

      saved = tokens_before - tokens_after
      record_compaction(saved, last_step)

      # Emit post_compact hook event
      try do
        OptimalSystemAgent.Agent.Hooks.run_async(:post_compact, %{
          phase: :post,
          tokens_before: tokens_before,
          tokens_after: tokens_after,
          tokens_saved: saved,
          severity: severity,
          last_step: last_step
        })
      rescue
        _ -> :ok
      end

      Logger.info(
        "Compactor pipeline (#{severity}): #{tokens_before} -> #{tokens_after} tokens " <>
          "(saved #{saved}, last_step=#{last_step})"
      )

      CompactionEvents.completed(session_id,
        tokens_before: tokens_before,
        tokens_after: tokens_after,
        messages_before: length(messages),
        messages_after: length(final_messages),
        duration_ms: System.monotonic_time(:millisecond) - compaction_started_at
      )

      final_messages
    end
  end

  # Markers for the self-describing blocks compaction injects. Each describes
  # the transcript as it stood when that pass ran, so only the newest is true.
  # An EMPTY truncation notice ("…was about: ]") carries no information at all
  # and is dropped outright rather than superseded.
  @compaction_notice_markers [
    "[Post-compaction context restore",
    "[Context truncated due to length"
  ]

  @doc false
  @spec drop_stale_compaction_notices([map()]) :: [map()]
  def drop_stale_compaction_notices(messages) when is_list(messages) do
    Enum.reject(messages, fn msg ->
      text = msg |> Map.get(:content, Map.get(msg, "content")) |> notice_text()
      Enum.any?(@compaction_notice_markers, &String.starts_with?(text, &1))
    end)
  end

  defp notice_text(t) when is_binary(t), do: String.trim_leading(t)

  defp notice_text(parts) when is_list(parts) do
    parts
    |> Enum.map_join(" ", fn
      p when is_binary(p) -> p
      p when is_map(p) -> Map.get(p, :text) || Map.get(p, "text") || ""
      _ -> ""
    end)
    |> String.trim_leading()
  end

  defp notice_text(_), do: ""

  # Post-compaction token target for a severity tier, derived from the shared
  # reserve-based thresholds (no second ratio ladder). With no resolvable
  # window (a FORCED compaction after a provider overflow error) there is
  # nothing to measure against, so the target is 0 — run every step.
  @doc false
  @spec target_tokens(severity(), pos_integer() | :unknown) :: non_neg_integer()
  def target_tokens(_severity, :unknown), do: 0

  def target_tokens(severity, cw) when is_integer(cw) and cw > 0 do
    case severity do
      :emergency -> div(CompactionThresholds.warn_at(cw), 2)
      _ -> CompactionThresholds.warn_at(cw)
    end
  end

  # Pipeline step dispatcher — skips if already under budget
  @doc false
  defp pipeline_step({annotated, system_msgs, prev_step}, step, target_tokens, cw, overhead) do
    # `overhead` carries the part of the real request the message list cannot
    # see (system prompt + tool schemas), so this check measures the SAME
    # quantity the severity decision was made on. Without it the pipeline
    # declares victory while the actual request is still `overhead` over budget.
    current_tokens =
      overhead + estimate_tokens(system_msgs) + estimate_tokens(strip_annotations(annotated))

    if current_tokens <= target_tokens do
      # Already under budget — skip remaining steps
      {annotated, system_msgs, prev_step}
    else
      apply_step(step, annotated, system_msgs, target_tokens, cw)
    end
  end

  # ---------------------------------------------------------------------------
  # P5: opencode-style token-protected prune tier (compaction.ts `prune`,
  # PRUNE_PROTECT / PRUNE_MINIMUM / PRUNE_PROTECTED_TOOLS).
  #
  # Replaces the old "keep last N tool results BY COUNT, truncate the rest to
  # 100 chars" heuristic with a non-LLM tier that walks the tool-result
  # messages **newest-first**, accumulating a running token estimate of their
  # (still-intact) output. Everything within `@compaction_prune_protect_tokens`
  # (default 40_000, opencode's PRUNE_PROTECT) stays completely untouched.
  # Once the running total crosses that budget, every OLDER tool result's
  # output is erased (content replaced with a short marker noting how many
  # tokens were reclaimed) — protected-tool names
  # (`compaction_prune_protected_tools`, default mirrors opencode's
  # `PRUNE_PROTECTED_TOOLS = ["skill"]` plus OSA's plan/task-tracking tools)
  # are skipped entirely: never counted against the budget, never erased.
  #
  # Like opencode's `pruned > PRUNE_MINIMUM` gate, this only actually mutates
  # anything when the tokens reclaimable by erasure exceed
  # `@compaction_prune_minimum_tokens` (default 20_000) — a partial win below
  # that gate isn't worth spending a compaction pass over.
  # ---------------------------------------------------------------------------

  @compaction_prune_protect_tokens_default 40_000
  @compaction_prune_minimum_tokens_default 20_000
  @compaction_prune_protected_tools_default [
    "skill",
    "use_skill",
    "find_skill",
    "save_skill",
    "create_skill",
    "list_skills",
    "task_write",
    "exit_plan_mode",
    "enter_plan_mode"
  ]

  defp prune_protect_tokens,
    do:
      Application.get_env(
        :optimal_system_agent,
        :compaction_prune_protect_tokens,
        @compaction_prune_protect_tokens_default
      )

  defp prune_minimum_tokens,
    do:
      Application.get_env(
        :optimal_system_agent,
        :compaction_prune_minimum_tokens,
        @compaction_prune_minimum_tokens_default
      )

  defp prune_protected_tools,
    do:
      Application.get_env(
        :optimal_system_agent,
        :compaction_prune_protected_tools,
        @compaction_prune_protected_tools_default
      )
      |> MapSet.new()

  # Best-effort tool name for a tool-result message — mirrors the field
  # fallback the old truncation path used (`:name`, then `:tool_call_id`).
  defp tool_name_of(msg), do: Map.get(msg, :name, Map.get(msg, :tool_call_id, "tool"))

  # Recognizes content already rewritten by a previous prune pass, so a
  # message pruned on an earlier micro_compact run is never double-counted
  # against the budget (its remaining text is a small fixed marker, not real
  # tool output) nor re-added to `pruned_tokens` savings.
  defp pruned_marker?(content) when is_binary(content),
    do:
      String.starts_with?(content, "[") and
        String.contains?(content, "output pruned to reclaim context")

  defp pruned_marker?(_), do: false

  @doc false
  defp apply_step(:micro_compact, annotated, system_msgs, _target, _cw) do
    protect_budget = prune_protect_tokens()
    min_savings = prune_minimum_tokens()
    protected = prune_protected_tools()

    tool_entries_newest_first =
      annotated
      |> Enum.with_index()
      |> Enum.filter(fn {{msg, _imp}, _idx} ->
        safe_to_string(Map.get(msg, :role)) == "tool"
      end)
      |> Enum.reverse()

    # Walk backward (newest tool result first). Protected-tool output is
    # skipped entirely — never counted toward the protect budget, never
    # erased. Everything else accumulates into `total`; once `total` exceeds
    # `protect_budget` the tool result that crossed the line (and everything
    # older) becomes a prune candidate.
    {_total, prune_candidates, pruned_tokens} =
      Enum.reduce(tool_entries_newest_first, {0, [], 0}, fn {{msg, _imp}, idx},
                                                            {total, candidates, pruned} ->
        if MapSet.member?(protected, tool_name_of(msg)) do
          {total, candidates, pruned}
        else
          content = safe_to_string(Map.get(msg, :content))

          # Already-pruned output costs ~0 tokens to re-estimate and must not
          # be double-counted against the budget or re-flagged as savings.
          if pruned_marker?(content) do
            {total, candidates, pruned}
          else
            estimate = estimate_tokens(content)
            new_total = total + estimate

            if new_total <= protect_budget do
              {new_total, candidates, pruned}
            else
              {new_total, [{idx, estimate} | candidates], pruned + estimate}
            end
          end
        end
      end)

    if pruned_tokens > min_savings and prune_candidates != [] do
      prune_map = Map.new(prune_candidates)

      compacted =
        annotated
        |> Enum.with_index()
        |> Enum.map(fn {{msg, imp}, idx} ->
          case Map.fetch(prune_map, idx) do
            {:ok, estimate} ->
              tool_name = tool_name_of(msg)

              pruned_content =
                "[#{tool_name} output pruned to reclaim context — ~#{estimate} tokens erased. " <>
                  "Re-run the tool if the original output is needed again.]"

              {Map.put(msg, :content, pruned_content), imp * 0.5}

            :error ->
              {msg, imp}
          end
        end)

      {compacted, system_msgs, :micro_compact}
    else
      {annotated, system_msgs, :micro_compact}
    end
  end

  # Step 1: Strip tool-call argument details, keep name + result only
  @doc false
  defp apply_step(:strip_tool_args, annotated, system_msgs, _target, _cw) do
    stripped =
      Enum.map(annotated, fn {msg, importance} ->
        msg = strip_tool_args_from_msg(msg)
        {msg, importance}
      end)

    {stripped, system_msgs, :strip_tool_args}
  end

  # Step 2: Merge consecutive same-role messages
  defp apply_step(:merge_consecutive, annotated, system_msgs, _target, _cw) do
    merged = merge_consecutive_same_role(annotated)
    {merged, system_msgs, :merge_consecutive}
  end

  # Step 3: Summarize warm-zone messages in groups of 5
  #
  # Two correctness fixes (finding #7 / K1+K2):
  #
  #   1. The cold/warm boundary is snapped through `CompactionSafety.
  #      safe_split_index/2` (same primitive `compress_cold` already uses),
  #      so the warm zone never starts on an orphaned `role: "tool"` result
  #      whose originating assistant call was left behind in the untouched
  #      cold zone.
  #   2. Before importance-sorting/chunking for summarization, warm-zone
  #      messages are grouped into pair-safe UNITS — an assistant message
  #      carrying `tool_calls` plus the `role: "tool"` results that satisfy
  #      it are bundled into a single atomic unit. Units, not raw messages,
  #      are what gets sorted/chunked/summarized, so a tool call and its
  #      result can never land in different groups (one surviving, one
  #      summarized away) and never get orphaned across the boundary.
  #   3. Final ordering is restored purely from each item's ORIGINAL index
  #      (threaded through as a plain integer the whole way), not the old
  #      dead-clause sort that collapsed every surviving message to a single
  #      shared key and destroyed chronology.
  defp apply_step(:summarize_warm, annotated, system_msgs, _target, cw) do
    total = length(annotated)

    msgs = strip_annotations(annotated)
    hot_start = compute_hot_start(msgs, cw)

    if hot_start >= total do
      # Token-budgeted tail selection kept everything hot — nothing to summarize
      {annotated, system_msgs, :summarize_warm}
    else
      raw_warm_start = max(total - @warm_zone_end, 0) |> min(hot_start)
      warm_start = CompactionSafety.safe_split_index(msgs, raw_warm_start) |> min(hot_start)

      cold = Enum.slice(annotated, 0, warm_start)
      warm = Enum.slice(annotated, warm_start, hot_start - warm_start)
      hot = Enum.slice(annotated, hot_start, total - hot_start)

      # Index the warm zone with its ORIGINAL (chronological) position before
      # any reordering, then fold it into pair-safe units.
      indexed_warm = Enum.with_index(warm)
      units = build_pair_safe_units(indexed_warm)

      # Sort units by importance — summarize the least important first. A
      # unit's importance is the MIN of its members, so a tool-call/result
      # pair is only ever as "important" as its least important half —
      # matching the intent of the original per-message sort while keeping
      # the pair atomic.
      sorted_units = Enum.sort_by(units, & &1.importance, :asc)

      # Summarize in groups of 5 units, starting with least important
      summarized_items = summarize_units_in_groups(sorted_units, 5)

      # Restore original chronological order purely by the threaded index —
      # every item (summary or survivor) carries one.
      restored_warm =
        summarized_items
        |> Enum.sort_by(fn {_msg, _imp, idx} -> idx end)
        |> Enum.map(fn {msg, imp, _idx} -> {msg, imp} end)

      {cold ++ restored_warm ++ hot, system_msgs, :summarize_warm}
    end
  end

  # Fold a chronologically-ordered, indexed warm-zone slice into pair-safe
  # units: an assistant message with non-empty `:tool_calls` plus every
  # immediately-following `role: "tool"` result becomes one unit; every other
  # message is its own singleton unit. Mirrors `CompactionSafety.tool_result?/1`
  # so both live behind the same tool-pair definition.
  #
  # Public (not `defp`) + `@doc false` so the pair-grouping invariant itself
  # (finding #7 / K2) is directly unit-testable without spinning up the full
  # progressive-compression pipeline.
  @doc false
  @spec build_pair_safe_units([{{map(), number()}, non_neg_integer()}]) :: [map()]
  def build_pair_safe_units(indexed_warm) do
    do_build_units(indexed_warm, [])
  end

  defp do_build_units([], acc), do: Enum.reverse(acc)

  defp do_build_units([{{msg, imp}, idx} = head | rest], acc) do
    if has_tool_calls?(msg) do
      {pair_items, remaining} =
        Enum.split_while(rest, fn {{m, _imp}, _idx} -> CompactionSafety.tool_result?(m) end)

      items = [{{msg, imp}, idx} | pair_items]
      unit = %{items: items, importance: min_importance(items), order: idx}
      do_build_units(remaining, [unit | acc])
    else
      unit = %{items: [head], importance: imp, order: idx}
      do_build_units(rest, [unit | acc])
    end
  end

  defp min_importance(items) do
    items |> Enum.map(fn {{_msg, imp}, _idx} -> imp end) |> Enum.min()
  end

  defp has_tool_calls?(msg) do
    case Map.get(msg, :tool_calls) do
      calls when is_list(calls) -> calls != []
      _ -> false
    end
  end

  # Step 4: Compress cold zone to key facts
  defp apply_step(:compress_cold, annotated, system_msgs, _target, _cw) do
    total = length(annotated)
    cold_end = max(total - @warm_zone_end, 0)

    if cold_end <= 0 do
      {annotated, system_msgs, :compress_cold}
    else
      # Tool-pair safety (grok select.rs): snap the cold/warm boundary FORWARD
      # past any contiguous tool-result run so `rest` never begins with an orphan
      # tool result (a tool result whose originating assistant call was folded
      # into the cold summary → provider 400). Fall back to the raw boundary if
      # snapping would consume everything.
      msgs = strip_annotations(annotated)
      snapped = CompactionSafety.safe_split_index(msgs, cold_end)
      cold_end = if snapped >= total, do: cold_end, else: snapped

      cold = Enum.slice(annotated, 0, cold_end)
      rest = Enum.slice(annotated, cold_end, total - cold_end)

      cold_messages = strip_annotations(cold)

      # P3 (grok summary.rs:143 wrap_user_query): find the most recent user
      # message across the WHOLE conversation. It normally already lives in
      # `rest` (the verbatim tail) and is never handed to the LLM, but we also
      # defensively strip any copy of it out of the summarized span so it can
      # never be paraphrased, then wrap it verbatim and prepend it to
      # whatever summary text is produced below — untouched by the LLM.
      latest_query = latest_user_query(strip_annotations(annotated))
      cold_messages_for_llm = exclude_message(cold_messages, latest_query)

      # P7 (grok inter_compaction + history/validate.rs): chunk the cold span
      # into token-bounded segments when it's large enough to warrant
      # divide-and-conquer, summarize each chunk independently, assemble, and
      # validate the assembled text before it replaces real history. Falls
      # back to the original single-call path automatically when the cold
      # span is short enough to fit one chunk.
      case call_cold_summary(cold_messages_for_llm) do
        {:ok, summary, strategy} ->
          case validate_cold_summary(summary, strategy) do
            :ok ->
              store_previous_summary(summary)
              wrapped = prepend_user_query(summary, latest_query)

              summary_entry =
                {%{role: "system", content: "[Context Summary]\n#{wrapped}"}, @pinned_importance}

              {[summary_entry | rest], system_msgs, :compress_cold}

            {:error, reason} ->
              Logger.warning(
                "Compactor cold-zone summary failed validation: #{inspect(reason)} — keeping original messages"
              )

              {annotated, system_msgs, :compress_cold}
          end

        {:error, reason} ->
          Logger.warning("Compactor cold-zone LLM summarization failed: #{inspect(reason)}")
          # Fall through to emergency truncate
          {annotated, system_msgs, :compress_cold}
      end
    end
  end

  # Step 5: Emergency truncate — no LLM call
  defp apply_step(:emergency_truncate, annotated, system_msgs, _target, cw) do
    total = length(annotated)
    msgs = strip_annotations(annotated)

    if total <= @hot_zone_size do
      {annotated, system_msgs, :emergency_truncate}
    else
      # P4: token-budgeted, turn-aware tail selection replaces the fixed
      # @hot_zone_size message-count boundary. `compute_hot_start/1` already
      # applies tool-pair-safe snapping internally, but we re-snap the final
      # candidate here too — defensive, since this is the "no LLM, no
      # further correction" last-resort step.
      candidate = compute_hot_start(msgs, cw)
      snapped = CompactionSafety.safe_split_index(msgs, candidate)
      split = if snapped >= total, do: candidate, else: snapped

      head = Enum.slice(annotated, 0, split)
      tail = Enum.slice(annotated, split, total - split)

      # The positional split is the whole point of this step, but it must not
      # take the pinned cold-zone summary with it. A summary produced earlier in
      # THIS pipeline run sits at index 0 — the first thing a positional slice
      # reaches — and it is the only surviving record of the span it folded up.
      # Carry pinned entries across the split, in order, ahead of the tail.
      {pinned, dropped} = Enum.split_with(head, &pinned?/1)

      topic_notice = %{
        role: "system",
        content:
          "[Context truncated due to length. Earlier conversation was about: #{extract_topics(strip_annotations(dropped))}]"
      }

      updated_system = system_msgs ++ [topic_notice]
      {pinned ++ tail, updated_system, :emergency_truncate}
    end
  end

  # ---------------------------------------------------------------------------
  # Importance scoring
  # ---------------------------------------------------------------------------

  @doc false
  defp annotate_importance(messages) do
    Enum.map(messages, fn msg ->
      {msg, message_importance(msg)}
    end)
  end

  @doc false
  defp message_importance(msg) do
    base = 1.0

    # Tool calls present → +50% retention bonus
    tool_bonus =
      case Map.get(msg, :tool_calls) do
        nil -> 0.0
        [] -> 0.0
        calls when is_list(calls) and length(calls) > 0 -> 0.5
        _ -> 0.0
      end

    # Tool results are also valuable
    tool_result_bonus =
      if safe_to_string(Map.get(msg, :role)) == "tool", do: 0.3, else: 0.0

    # Length / substance bonus (capped at 0.3)
    content = safe_to_string(Map.get(msg, :content))
    length_bonus = min(String.length(content) / 500, 0.3)

    # Acknowledgment penalty
    ack_penalty =
      if Regex.match?(@ack_patterns, content), do: -0.5, else: 0.0

    max(base + tool_bonus + tool_result_bonus + length_bonus + ack_penalty, 0.1)
  end

  # True for an annotated entry that no positional step may drop.
  defp pinned?({_msg, importance}) when is_number(importance),
    do: importance >= @pinned_importance

  defp pinned?(_), do: false

  @doc false
  defp strip_annotations(annotated) do
    Enum.map(annotated, fn
      {msg, _importance} -> msg
      msg when is_map(msg) -> msg
    end)
  end

  # ---------------------------------------------------------------------------
  # Step 1 helpers: strip tool call args
  # ---------------------------------------------------------------------------

  @doc """
  Test seam for `strip_tool_args_from_msg/1`.
  """
  @spec strip_tool_args(map()) :: map()
  def strip_tool_args(msg), do: strip_tool_args_from_msg(msg)

  # Heavy `arguments` are dropped, but the key MUST keep holding an OBJECT.
  #
  # This used to write the placeholder STRING `"[args stripped]"`, which poisoned
  # the session permanently: compacted history is persisted to
  # `~/.osa/sessions/<id>.json`, and every provider emits `arguments` verbatim —
  # Anthropic as `tool_use.input`, Ollama/Google as a nested map, the
  # OpenAI-compatible providers as a JSON encoding OF it. None accept a bare
  # string:
  #
  #     anthropic → 400 messages.N.content.M.tool_use.input: Input should be an object
  #     ollama    → 400 {"error":"Value looks like object, but can't find closing '}' symbol"}
  #
  # So one compaction made every LATER turn in that session fail on the primary
  # provider and then again on every provider in the fallback chain — which no
  # model switch could clear, because the corruption lived in the history rather
  # than in the provider config.
  #
  # `%{}` is the smallest valid object. The call's `name` and its tool RESULT
  # both survive compaction, which is the signal the model actually needs; the
  # arguments were the token cost this step exists to reclaim.
  defp strip_tool_args_from_msg(msg) do
    case Map.get(msg, :tool_calls) do
      nil ->
        msg

      [] ->
        msg

      calls when is_list(calls) ->
        Map.put(msg, :tool_calls, Enum.map(calls, &strip_one_call/1))

      _ ->
        msg
    end
  end

  # Write back under the key shape the call already uses. A rehydrated call from
  # a persisted session is string-keyed; putting an atom `:arguments` next to its
  # `"arguments"` would leave BOTH — the heavy payload still on the wire under
  # the string key, and the strip silently reclaiming nothing.
  defp strip_one_call(tc) when is_map(tc) do
    if Map.has_key?(tc, "arguments") and not Map.has_key?(tc, :arguments) do
      Map.put(tc, "arguments", %{})
    else
      Map.put(tc, :arguments, %{})
    end
  end

  defp strip_one_call(tc), do: tc

  # ---------------------------------------------------------------------------
  # Step 2 helpers: merge consecutive same-role messages
  # ---------------------------------------------------------------------------

  # Join two message contents WITHOUT flattening structure.
  #
  # This used to be `safe_to_string(a) <> "\n" <> safe_to_string(b)`, and
  # `safe_to_string/1` `Jason.encode!`s a list. Two consecutive user messages
  # carrying the multimodal block-list shape were therefore merged into a JSON
  # *string*: an image block became the literal text
  # `{"type":"image","source":{"data":"<base64>"…}}`.
  #
  # That is data corruption, and it inverts the step's purpose. The image is
  # destroyed as an image, and the base64 the estimator deliberately charges a
  # flat 1,600 tokens becomes plain text hit by the byte_size/4 floor — tens of
  # thousands of tokens. This runs BEFORE summarize_warm and compress_cold, so a
  # step meant to save tokens multiplied them, and the corrupted content is what
  # reached the provider and got persisted.
  #
  # Block lists now concatenate as lists. A binary joining a list is wrapped as
  # a text block in whatever key style that list already uses — both the string
  # and atom shapes are live in this codebase. Anything else declines to merge,
  # which costs one extra message and corrupts nothing.
  defp merge_contents(a, b) when is_binary(a) and is_binary(b), do: a <> "\n" <> b
  defp merge_contents(a, b) when is_list(a) and is_list(b), do: a ++ b

  defp merge_contents(a, b) when is_list(a) and is_binary(b),
    do: a ++ [text_block(b, block_key_style(a))]

  defp merge_contents(a, b) when is_binary(a) and is_list(b),
    do: [text_block(a, block_key_style(b)) | b]

  defp merge_contents(_, _), do: :incompatible

  defp block_key_style(blocks) do
    case Enum.find(blocks, &is_map/1) do
      %{} = block -> if Map.has_key?(block, "type"), do: :string, else: :atom
      _ -> :atom
    end
  end

  defp text_block(text, :string), do: %{"type" => "text", "text" => text}
  defp text_block(text, :atom), do: %{type: "text", text: text}

  @doc """
  Test seam for `merge_consecutive_same_role/1`.
  """
  @spec merge_consecutive(list()) :: list()
  def merge_consecutive(annotated), do: merge_consecutive_same_role(annotated)

  @doc false
  defp merge_consecutive_same_role([]), do: []

  defp merge_consecutive_same_role(annotated) do
    annotated
    |> Enum.reduce([], fn {msg, importance}, acc ->
      case acc do
        [{prev_msg, prev_imp} | rest]
        when is_map(prev_msg) and is_map(msg) ->
          prev_role = safe_to_string(Map.get(prev_msg, :role))
          curr_role = safe_to_string(Map.get(msg, :role))

          # Only merge user-user or assistant-assistant (not tool, not system)
          can_merge =
            prev_role == curr_role and
              prev_role in ["user", "assistant"] and
              not Map.has_key?(prev_msg, :tool_calls) and
              not Map.has_key?(msg, :tool_calls) and
              not Map.has_key?(prev_msg, :tool_call_id) and
              not Map.has_key?(msg, :tool_call_id)

          merged_content =
            if can_merge do
              merge_contents(Map.get(prev_msg, :content), Map.get(msg, :content))
            else
              :incompatible
            end

          case merged_content do
            :incompatible ->
              [{msg, importance} | acc]

            content ->
              merged_msg = Map.put(prev_msg, :content, content)
              merged_imp = max(prev_imp, importance)
              [{merged_msg, merged_imp} | rest]
          end

        _ ->
          [{msg, importance} | acc]
      end
    end)
    |> Enum.reverse()
  end

  # ---------------------------------------------------------------------------
  # Step 3 helpers: summarize in groups
  # ---------------------------------------------------------------------------

  @doc false
  # units is a list of pair-safe unit maps: %{items: [{{msg,imp},idx}, ...],
  # importance: float, order: integer} sorted least-important first. Groups
  # `group_size` UNITS at a time (never splitting a unit) and summarizes each
  # group as a whole. Returns a flat list of `{msg, imp, idx}` triples ready
  # for the final chronological restore.
  defp summarize_units_in_groups(units, group_size) do
    groups = Enum.chunk_every(units, group_size)

    Enum.flat_map(groups, fn group ->
      all_items = Enum.flat_map(group, & &1.items)
      messages = Enum.map(all_items, fn {{msg, _imp}, _idx} -> msg end)
      group_tokens = estimate_tokens(messages)

      # Only summarize if the group is substantial enough to benefit
      if group_tokens > 200 do
        case call_summary_llm(messages) do
          {:ok, summary} ->
            # Replace the whole group (every unit's messages, pairs intact)
            # with a single summary message, ordered at the earliest original
            # position in the group so chronology is preserved on restore.
            min_order = group |> Enum.map(& &1.order) |> Enum.min()

            summary_msg = %{
              role: "system",
              content: "[Warm Summary]\n#{summary}"
            }

            [{summary_msg, 1.5, min_order}]

          {:error, _reason} ->
            # Keep originals (with their pairs intact) on LLM failure
            Enum.map(all_items, fn {{msg, imp}, idx} -> {msg, imp, idx} end)
        end
      else
        Enum.map(all_items, fn {{msg, imp}, idx} -> {msg, imp, idx} end)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # LLM helpers
  # ---------------------------------------------------------------------------

  @summary_prompt_fallback """
  Summarize the following conversation excerpt concisely. Preserve:
  - All file paths and line numbers mentioned
  - All error messages and their causes
  - All decisions made and their reasoning
  - All specific values, variable names, and config settings
  - Tool names used and their key results
  Be terse — use bullet points. Never lose concrete details.

  %MESSAGES%
  """

  @doc """
  Run one summarizer `Providers.chat/2` under its own wall-clock bound.

  `TurnPipeline.bounded_compaction/2` already contains a wedged summarizer from
  *outside* (120s, then deterministic micro-compaction). That is the turn's
  safety net, not this call's. Every innermost summarizer call carries its own,
  strictly-smaller bound so that:

    * the inner bound fires first, and the caller's own deterministic fallback
      runs — instead of the whole compaction being killed brutally at 120s;
    * call sites reached OUTSIDE `bounded_compaction/2` (an unattended agent
      auto-compacting between turns) are still bounded at all. Before this,
      those had no timeout whatsoever and a provider stuck in a socket read
      parked the agent indefinitely.

  On expiry the task is `:brutal_kill`ed — a summarizer blocked in a socket read
  will not honour a graceful shutdown — and `{:error, :summarizer_timeout}` is
  returned. `CompactionSafety.sample_with_retry/2` short-circuits on `{:error,
  _}` (it only retries *degenerate* summaries), so a timeout is not re-tried;
  it goes straight to the caller's deterministic path.

  Bound is `:summarizer_timeout_ms` (default 90s — under the 120s outer bound
  by design). Public + `@doc false`-ish so `Loop.ProactiveCompaction` shares
  one policy instead of duplicating it.
  """
  @spec bounded_chat([map()], keyword()) :: {:ok, map()} | {:error, term()}
  def bounded_chat(messages, opts) do
    timeout = Application.get_env(:optimal_system_agent, :summarizer_timeout_ms, 90_000)
    opts = with_resolved_model(opts)

    task =
      Task.Supervisor.async_nolink(OptimalSystemAgent.TaskSupervisor, fn ->
        Providers.chat(messages, opts)
      end)

    result =
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} ->
          result

        {:exit, reason} ->
          {:error, {:summarizer_crashed, reason}}

        nil ->
          Logger.error(
            "[compactor] summarizer exceeded #{timeout}ms (wedged provider call) — " <>
              "killed it; falling back to the deterministic path"
          )

          {:error, :summarizer_timeout}
      end

    bill_summarizer_call(result, opts)
    result
  rescue
    # No TaskSupervisor (bare unit test, stripped release) — degrade to an
    # inline call rather than failing compaction outright. Unbounded, but
    # strictly better than crashing, and the supervisor exists in every real
    # runtime.
    _ ->
      result = Providers.chat(messages, opts)
      bill_summarizer_call(result, opts)
      result
  end

  # Bill one summarizer round-trip to the session that asked for the compaction.
  #
  # `bounded_chat/2` is the SINGLE choke point for every provider call the
  # compaction subsystem makes — `call_summary_llm/1`, `call_key_facts_llm/1`,
  # `summarize_chunk/2` here, and `Loop.ProactiveCompaction.summarize/2`. All of
  # that spend used to be invisible: it never reached `Loop.Accounting.record/2`,
  # so `session_cost_usd`, the `max_budget_usd` cap, the spend sidecar and every
  # `$/task` figure downstream all behaved as if summarization were free. It is
  # not, and it is about to fire routinely rather than never.
  #
  # This runs in the compaction task, which is NOT the `Loop` process and holds
  # no loop state, so it stages into `Accounting`'s side ledger; the loop
  # absorbs it (`Accounting.absorb_side_spend/1`) at its next compaction
  # boundary. Pricing uses the summarizer's OWN model/provider, which
  # `summarizer_opts/0` may point at something cheaper than the session model.
  #
  # The session id comes from the same process-dictionary stash
  # `CompactionEvents` already uses, so nothing needed a new signature. When
  # there is no session id in scope (a bare unit call) the spend is dropped
  # rather than billed to the wrong session.
  #
  # MUST NOT raise. `bounded_chat/2`'s `rescue` clause re-issues
  # `Providers.chat/2` (its no-TaskSupervisor degradation), so an exception
  # escaping the billing step would silently send the summarizer request a
  # SECOND time — turning a bookkeeping bug into a doubled provider bill. Hence
  # the total rescue/catch here, on top of `stage_side_spend/3`'s own.
  defp bill_summarizer_call({:ok, %{} = resp}, opts) do
    OptimalSystemAgent.Agent.Loop.Accounting.stage_side_spend(
      CompactionEvents.current_session_id(),
      Map.get(resp, :usage, %{}),
      model: summarizer_model(opts),
      provider: summarizer_provider(opts),
      kind: :compaction
    )
  rescue
    e ->
      Logger.debug("[compactor] summarizer billing failed: #{inspect(e)}")
      :ok
  catch
    _, _ -> :ok
  end

  # A failed/timed-out summarizer reports no usage — there is nothing to bill.
  defp bill_summarizer_call(_other, _opts), do: :ok

  # Pin the summariser's provider and model INTO the opts the wire sees.
  #
  # `bounded_chat/2`'s call sites pass `temperature:`/`max_tokens:` and nothing
  # else, so the compaction request was the one request in the system that
  # named no model. That was survivable only while every provider's app-env
  # fallback worked; it does not, because `:<provider>_model` is
  # present-and-nil whenever its env var is unset (see
  # `Providers.ConfiguredModel`). On xAI/`grok-4.6` the request went out as
  # `"model": null` and came back HTTP 422 in under a second — "compaction
  # failed after 0 seconds, conversation unchanged", on BOTH the `/compact`
  # path and the automatic one, since both funnel through here.
  #
  # `summarizer_model/1` already resolved a model correctly — it was just only
  # ever used to *price* the call, never to make it, so billing and the wire
  # disagreed. Now they are the same value, computed once, and the resolution
  # is the shared cascade rather than a private fourth copy of it.
  defp with_resolved_model(opts) do
    provider = summarizer_provider(opts)
    model = summarizer_model(opts)

    opts
    |> then(fn o -> if provider, do: Keyword.put(o, :provider, provider), else: o end)
    |> then(fn o -> if is_binary(model) and model != "", do: Keyword.put(o, :model, model), else: o end)
    |> tap(fn o ->
      unless is_binary(Keyword.get(o, :model)) do
        Logger.error(
          "[compactor] no model resolved for the summarizer (provider=#{inspect(provider)}) — " <>
            "the request will be refused rather than sent with a null model. " <>
            "Set #{OptimalSystemAgent.Providers.ConfiguredModel.env_var(provider)}."
        )
      end
    end)
  rescue
    e ->
      Logger.error("[compactor] summarizer model resolution failed: #{inspect(e)}")
      opts
  end

  defp summarizer_provider(opts) do
    Keyword.get(opts, :provider) || Providers.resolved_default_provider()
  rescue
    _ -> Keyword.get(opts, :provider)
  end

  # `summarizer_opts/0` may name neither a provider nor a model, in which case
  # the wire runs on the provider's own default — so resolve it exactly the way
  # `Registry.chat/2` will, rather than guessing or pricing against `nil`.
  defp summarizer_model(opts) do
    case Keyword.get(opts, :model) do
      model when is_binary(model) and model != "" ->
        model

      _ ->
        Providers.resolved_default_model(summarizer_provider(opts))
    end
  rescue
    _ -> Keyword.get(opts, :model)
  end

  @doc false
  defp call_summary_llm(messages_to_summarize) do
    if not compactor_llm_enabled?() do
      # Stub: return a placeholder summary when LLM is disabled (test env)
      {:ok, "[Summary of #{length(messages_to_summarize)} messages]"}
    else
      template = PromptLoader.get(:compactor_summary, @summary_prompt_fallback)
      formatted = format_for_summary(messages_to_summarize)

      prompt =
        if String.contains?(template, "%MESSAGES%") do
          String.replace(template, "%MESSAGES%", formatted)
        else
          template <> "\n\n" <> formatted
        end

      prompt = append_compact_instructions(prompt)

      # Degenerate-summary retry (grok sampler.rs). Warm-group summaries are
      # legitimately terser than the cold key-facts summary, so use a lighter
      # floor — this only catches truly-empty/refusal outputs ("Done.", a lone
      # header), not concise-but-valid summaries.
      sampler = fn ->
        try do
          bounded_chat([%{role: "user", content: prompt}], temperature: 0.2, max_tokens: 400)
          |> case do
            {:ok, %{content: content}} when is_binary(content) and content != "" ->
              {:ok, content}

            {:ok, %{content: content}} ->
              {:error, "Empty summary: #{inspect(content)}"}

            {:error, reason} ->
              {:error, reason}
          end
        rescue
          e ->
            {:error, "LLM call exception: #{Exception.message(e)}"}
        end
      end

      case CompactionSafety.sample_with_retry(sampler, max_attempts: 2, min_chars: 80) do
        {:ok, content} -> {:ok, content}
        {:error, {:degenerate_summary, _last}} -> {:error, :degenerate_summary}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @structured_compression_template """
  You are compressing a conversation to fit within a context window.
  Maintain a structured summary with these EXACT 8 sections. Output ONLY these sections.

  ## Goal
  What is the user trying to accomplish? What's the end state?

  ## Constraints
  Requirements, limitations, rules the user specified.

  ## Progress
  What has been done so far? Key milestones reached.

  ## Key Decisions
  Important choices made and WHY they were made.

  ## Relevant Files
  File paths that have been read, modified, or are important.
  Include line numbers for specific locations discussed.

  ## Errors & Issues
  Any errors encountered, their causes, and resolutions.

  ## Next Steps
  What still needs to be done. Ordered by priority.

  ## Working Memory
  Specific values, variable names, config settings, URLs, or other
  concrete details that must be preserved exactly.

  IMPORTANT:
  - Preserve ALL file paths, error messages, and specific values exactly
  - Update sections incrementally — do not start over if a previous summary exists
  - If a previous summary exists, MERGE new info into existing sections
  - Keep the summary concise but complete

  %PREVIOUS_SUMMARY%

  NEW CONVERSATION TURNS TO INTEGRATE:
  %MESSAGES%
  """

  @doc false
  defp call_key_facts_llm(messages_to_compress) do
    if not compactor_llm_enabled?() do
      {:ok, "[Key facts from #{length(messages_to_compress)} messages]"}
    else
      formatted = format_for_summary(messages_to_compress)

      # Retrieve previous structured summary for iterative merge
      previous_summary = get_previous_summary()

      prompt =
        if previous_summary do
          # Use structured template for iterative compression
          @structured_compression_template
          |> String.replace(
            "%PREVIOUS_SUMMARY%",
            "PREVIOUS SUMMARY (merge new info into this):\n#{previous_summary}"
          )
          |> String.replace("%MESSAGES%", formatted)
        else
          # First compression — use structured template without previous summary
          @structured_compression_template
          |> String.replace(
            "%PREVIOUS_SUMMARY%",
            "PREVIOUS SUMMARY: None — this is the first compression."
          )
          |> String.replace("%MESSAGES%", formatted)
        end

      # PreCompact hook instructions (CC parity): custom_instructions from the
      # PreCompact hook are appended to the key-facts prompt as well.
      prompt = append_compact_instructions(prompt)

      # Degenerate-summary retry (grok sampler.rs): the cold zone is being
      # replaced wholesale by this summary, so a near-empty or truncated
      # response is catastrophic — the detail is gone. Reject summaries under
      # ~500 chars and retry the sampler before accepting one.
      sampler = fn ->
        try do
          bounded_chat([%{role: "user", content: prompt}], temperature: 0.1, max_tokens: 1024)
          |> case do
            {:ok, %{content: content}} when is_binary(content) and content != "" ->
              {:ok, content}

            {:ok, %{content: content}} ->
              {:error, "Empty key-facts response: #{inspect(content)}"}

            {:error, reason} ->
              {:error, reason}
          end
        rescue
          e ->
            {:error, "LLM call exception: #{Exception.message(e)}"}
        end
      end

      case CompactionSafety.sample_with_retry(sampler, max_attempts: 2) do
        {:ok, content} ->
          # NOTE: persistence for iterative merge (`store_previous_summary/1`)
          # now happens once, centrally, in `apply_step(:compress_cold, ...)`
          # after the assembled cold-zone summary (chunked or single-call)
          # passes validation — see P7.
          {:ok, content}

        {:error, {:degenerate_summary, _last}} = err ->
          Logger.warning("Compactor: cold-zone summary was degenerate after retries")
          err

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # P7: Divide-and-conquer chunked cold-zone summarization + validation
  # (grok inter_compaction/compact.rs, history/validate.rs)
  # ---------------------------------------------------------------------------

  @chunk_summary_prompt_fallback """
  Summarize the following conversation excerpt concisely and terse, preserving:
  - All file paths and line numbers mentioned
  - All error messages and their causes
  - All decisions made and their reasoning
  - All specific values, variable names, and config settings
  - Tool names used and their key results
  Output ONLY the summary body — bullet points, no preamble, no headers.

  %MESSAGES%
  """

  # Dispatches between the original single-call cold-zone summary and the
  # divide-and-conquer chunked path. Falls back to the single-call path
  # automatically when the cold span is short enough to fit in one chunk.
  # Returns `{:ok, summary_text, strategy}` where `strategy` is `:basic` or
  # `:divide_and_conquer` (fed to `validate_cold_summary/2`).
  @doc false
  defp call_cold_summary(cold_messages) do
    chunks = chunk_messages_by_tokens(cold_messages, dnc_chunk_token_limit())

    if length(chunks) <= 1 do
      case call_key_facts_llm(cold_messages) do
        {:ok, summary} -> {:ok, summary, :basic}
        {:error, reason} -> {:error, reason}
      end
    else
      case call_key_facts_llm_chunked(chunks) do
        {:ok, summary} -> {:ok, summary, :divide_and_conquer}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Greedily packs messages into token-bounded chunks. A single message
  # larger than `limit` becomes its own (oversized) chunk rather than being
  # split mid-message.
  @doc false
  defp chunk_messages_by_tokens(messages, limit) do
    {chunks, current} =
      Enum.reduce(messages, {[], []}, fn msg, {chunks, current} ->
        msg_tokens = estimate_tokens([msg])

        cond do
          current == [] ->
            {chunks, [msg]}

          estimate_tokens(Enum.reverse(current)) + msg_tokens > limit ->
            {[Enum.reverse(current) | chunks], [msg]}

          true ->
            {chunks, [msg | current]}
        end
      end)

    chunks =
      case current do
        [] -> chunks
        _ -> [Enum.reverse(current) | chunks]
      end

    Enum.reverse(chunks)
  end

  # Summarizes each chunk into a `<chunk_summary index="N">...</chunk_summary>`
  # block, then assembles them (plus a verbatim `index="prev"` block carrying
  # the previous structured summary, when one exists, preserving iterative
  # merge across compactions) into one text blob for validation/persistence.
  @doc false
  defp call_key_facts_llm_chunked(chunks) do
    total = length(chunks)
    session_id = CompactionEvents.current_session_id()

    # The ONE place in compaction with a genuine, monotonic ratio of completed
    # to total known work: N independent summarizer calls, fixed up front by
    # `chunk_messages_by_tokens/2`. Progress is emitted per finished chunk so
    # the TUI's bar tracks measured work. Nothing else in compaction may emit
    # progress — see `CompactionEvents`' moduledoc.
    chunk_results =
      chunks
      |> Enum.with_index()
      |> Enum.map(fn {chunk_msgs, idx} ->
        result = summarize_chunk(chunk_msgs, idx)
        CompactionEvents.progress(session_id, idx + 1, total)
        result
      end)

    case Enum.find(chunk_results, &match?({:error, _}, &1)) do
      {:error, _} = err ->
        err

      nil ->
        prev_block =
          case get_previous_summary() do
            nil -> nil
            previous -> "<chunk_summary index=\"prev\">\n#{previous}\n</chunk_summary>"
          end

        body =
          [prev_block | Enum.map(chunk_results, fn {:ok, tag} -> tag end)]
          |> Enum.reject(&is_nil/1)
          |> Enum.join("\n\n")

        {:ok, body}
    end
  end

  @doc false
  defp summarize_chunk(chunk_msgs, idx) do
    if not compactor_llm_enabled?() do
      {:ok,
       "<chunk_summary index=\"#{idx}\">\n[Key facts from #{length(chunk_msgs)} messages]\n</chunk_summary>"}
    else
      template = PromptLoader.get(:compactor_summary, @chunk_summary_prompt_fallback)
      formatted = format_for_summary(chunk_msgs)

      prompt =
        if String.contains?(template, "%MESSAGES%") do
          String.replace(template, "%MESSAGES%", formatted)
        else
          template <> "\n\n" <> formatted
        end

      prompt = append_compact_instructions(prompt)

      sampler = fn ->
        try do
          bounded_chat([%{role: "user", content: prompt}], temperature: 0.1, max_tokens: 600)
          |> case do
            {:ok, %{content: content}} when is_binary(content) and content != "" ->
              {:ok, content}

            {:ok, %{content: content}} ->
              {:error, "Empty chunk-summary response: #{inspect(content)}"}

            {:error, reason} ->
              {:error, reason}
          end
        rescue
          e ->
            {:error, "LLM call exception: #{Exception.message(e)}"}
        end
      end

      case CompactionSafety.sample_with_retry(sampler, max_attempts: 2, min_chars: 80) do
        {:ok, content} ->
          {:ok, "<chunk_summary index=\"#{idx}\">\n#{content}\n</chunk_summary>"}

        {:error, {:degenerate_summary, _last}} ->
          {:error, :degenerate_chunk_summary}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Structural validation before a summary replaces real history (grok
  # history/validate.rs). Mirrors `validate_compaction_text`:
  #   1. Non-empty text content
  #   2. For :divide_and_conquer — balanced `<chunk_summary>` tags
  @doc false
  defp validate_cold_summary(text, strategy) do
    cond do
      not is_binary(text) or String.trim(text) == "" ->
        {:error, :empty_content}

      strategy == :divide_and_conquer ->
        open = count_occurrences(text, "<chunk_summary")
        close = count_occurrences(text, "</chunk_summary>")

        if open == close do
          :ok
        else
          {:error, {:unbalanced_chunk_tags, open, close}}
        end

      true ->
        :ok
    end
  end

  defp count_occurrences(text, substr) do
    (text |> String.split(substr) |> length()) - 1
  end

  defp dnc_chunk_token_limit,
    do:
      Application.get_env(
        :optimal_system_agent,
        :compaction_chunk_token_limit,
        @dnc_chunk_token_limit_default
      )

  # ---------------------------------------------------------------------------
  # P3: Verbatim latest user-query preservation (grok summary.rs:143
  # wrap_user_query)
  # ---------------------------------------------------------------------------

  # Most recent `role: "user"` message across the given messages, or nil.
  @doc false
  defp latest_user_query(messages) do
    messages
    |> Enum.filter(fn m -> safe_to_string(Map.get(m, :role)) == "user" end)
    |> List.last()
  end

  # Removes an exact copy of `target` from `messages` if present. `target` may
  # be nil (no-op).
  @doc false
  defp exclude_message(messages, nil), do: messages

  defp exclude_message(messages, target) do
    Enum.reject(messages, &(&1 == target))
  end

  # Wraps `msg`'s raw content in `<user_query>` tags and prepends it —
  # untouched by any LLM — to `summary`. No-op when there is no message to
  # wrap or it has no content.
  @doc false
  defp prepend_user_query(summary, nil), do: summary

  defp prepend_user_query(summary, msg) do
    content = safe_to_string(Map.get(msg, :content))

    if String.trim(content) == "" do
      summary
    else
      wrap_user_query(content) <> "\n\n" <> summary
    end
  end

  defp wrap_user_query(text), do: "<user_query>\n#{text}\n</user_query>"

  # ---------------------------------------------------------------------------
  # P4: token-budgeted, turn-aware tail selection helpers
  # (opencode compaction.ts select/splitTurn; grok select.rs select_tail)
  # ---------------------------------------------------------------------------

  # 25% of the usable context window, clamped to [2_000, 8_000] tokens.
  # Operator-overridable via :compaction_preserve_recent_tokens.
  @doc false
  defp preserve_recent_budget(cw) do
    case Application.get_env(:optimal_system_agent, :compaction_preserve_recent_tokens) do
      n when is_integer(n) and n > 0 ->
        n

      _ ->
        case cw do
          n when is_integer(n) and n > 0 ->
            n
            |> Kernel.*(0.25)
            |> trunc()
            |> max(@min_preserve_recent_tokens)
            |> min(@max_preserve_recent_tokens)

          # No resolvable window (forced overflow compaction). The clamp caps
          # this at 8k for every window >= 32k anyway, so the upper bound is
          # the only non-arbitrary choice: preserve as much recent context as
          # the clamp ever allows rather than inventing a window to scale from.
          _ ->
            @max_preserve_recent_tokens
        end
    end
  end

  # Groups a (stripped) message list into "turns": a turn starts at a
  # `role: "user"` message and runs up to (but not including) the next user
  # message, or the end of the list for the last turn.
  #
  # Messages BEFORE the first `role: "user"` message (if any) — e.g. a
  # `[Context Summary]` message compress_cold just inserted at index 0, or an
  # active-agent `<system-reminder>` — are not owned by any real turn, but
  # must still be given the same fitted-or-split treatment as everything
  # else. Without this they'd have no representative in `turns_desc` at all,
  # so `select_turn_tail/3` would never even consider them and any later
  # step (emergency_truncate) reusing this same `compute_hot_start/1` would
  # silently truncate them away regardless of budget. They're modeled as a
  # synthetic OLDEST turn spanning `[0, first_user_index)`.
  @doc false
  defp build_turns(messages) do
    total = length(messages)

    starts =
      messages
      |> Enum.with_index()
      |> Enum.filter(fn {msg, _i} -> safe_to_string(Map.get(msg, :role)) == "user" end)
      |> Enum.map(fn {_msg, i} -> i end)

    real_turns =
      starts
      |> Enum.with_index()
      |> Enum.map(fn {start, idx} ->
        finish =
          case Enum.at(starts, idx + 1) do
            nil -> total
            next_start -> next_start
          end

        %{start: start, finish: finish}
      end)

    case starts do
      [first | _] when first > 0 -> [%{start: 0, finish: first} | real_turns]
      _ -> real_turns
    end
  end

  # Computes the index (in `messages`) where the token-budgeted, turn-aware
  # "hot" tail begins — everything from this index to the end is kept
  # verbatim. Walks whole recent turns backward, keeping each in full while
  # it fits the remaining budget; when a turn would overflow the budget, it
  # is SPLIT to fit using `CompactionSafety.select_tail/3` (already a
  # tool-pair-safe backward token-accumulation port of grok's select.rs)
  # applied to just that turn's message slice. Always preserves at least the
  # single most-recent turn, so this never keeps strictly less than the
  # user's latest message. Falls back to the old fixed `@hot_zone_size`
  # message-count boundary when no turn structure can be found at all (e.g.
  # a pure tool/system message stream with no `role: "user"` messages).
  @doc false
  defp compute_hot_start(messages, cw) do
    total = length(messages)

    case build_turns(messages) do
      [] ->
        max(total - @hot_zone_size, 0)

      turns ->
        budget = preserve_recent_budget(cw)

        case select_turn_tail(messages, Enum.reverse(turns), budget) do
          nil -> max(total - @hot_zone_size, 0)
          hot_start -> CompactionSafety.safe_split_index(messages, hot_start)
        end
    end
  end

  defp select_turn_tail(messages, turns_desc, budget) do
    {_tokens, kept} =
      Enum.reduce_while(turns_desc, {0, nil}, fn turn, {acc_tokens, kept} ->
        turn_slice = Enum.slice(messages, turn.start, turn.finish - turn.start)
        size = estimate_tokens(turn_slice)

        cond do
          acc_tokens + size <= budget ->
            {:cont, {acc_tokens + size, turn.start}}

          true ->
            remaining = budget - acc_tokens

            case CompactionSafety.select_tail(turn_slice, remaining, &single_msg_tokens/1) do
              {:ok, split_in_turn} ->
                {:halt, {acc_tokens, turn.start + split_in_turn}}

              :none ->
                # Never keep strictly nothing: if nothing has been kept yet
                # (this IS the most-recent turn), preserve it whole even if
                # it exceeds budget — a single oversized latest turn must
                # still survive verbatim.
                {:halt, {acc_tokens, kept || turn.start}}
            end
        end
      end)

    kept
  end

  defp single_msg_tokens(msg), do: estimate_tokens([msg])

  # ── Structured Summary Persistence (ETS) ─────────────────────────────
  #
  # The iterative structured summary is SESSION-SCOPED. It used to live under a
  # single global `:previous_summary` key in the shared `:osa_compactor_state`
  # table, which meant session B's next compaction folded session A's summary
  # into its prompt as the `PREVIOUS SUMMARY` / `<chunk_summary index="prev">`
  # block — conversation content crossing a session boundary, and then being
  # shipped to the provider. Keys are `{:previous_summary, session_id}` now
  # (mirroring `{:compact_failures, session_id}` in `Loop.ProactiveCompaction`)
  # and `forget_session/1` drops them on teardown so they do not outlive the
  # session either.

  # Session key for the current compaction run. `nil` session ids (ad-hoc /
  # test callers with no session) share `:global` — the same fallback
  # `ProactiveCompaction` uses — but every real session is isolated.
  defp summary_key do
    case Process.get(:osa_compact_session_id) do
      sid when is_binary(sid) and sid != "" -> sid
      _ -> :global
    end
  end

  @doc """
  Drop the persisted structured summary for `session_id`.

  Called from session teardown (`Runtime.SessionTeardown`) and from the CLI's
  `stop_session/1`, which is the path `/clear`, `/new` and session exit all go
  through. Idempotent and never raises.
  """
  @spec forget_session(String.t() | nil) :: :ok
  def forget_session(session_id) when is_binary(session_id) do
    :ets.delete(:osa_compactor_state, {:previous_summary, session_id})
    :ets.delete(:osa_compactor_state, {:last_summary_at, session_id})
    :ok
  rescue
    _ -> :ok
  end

  def forget_session(_), do: :ok

  @doc false
  defp get_previous_summary do
    key = summary_key()

    try do
      case :ets.lookup(:osa_compactor_state, {:previous_summary, key}) do
        [{{:previous_summary, ^key}, summary}] -> summary
        _ -> nil
      end
    rescue
      _ -> nil
    end
  end

  @doc false
  defp store_previous_summary(summary) do
    key = summary_key()

    try do
      :ets.insert(:osa_compactor_state, {{:previous_summary, key}, summary})
      :ets.insert(:osa_compactor_state, {{:last_summary_at, key}, DateTime.utc_now()})
    rescue
      _ -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @doc false
  defp split_system(messages) do
    Enum.split_with(messages, fn msg ->
      safe_to_string(Map.get(msg, :role)) == "system"
    end)
  end

  # ---------------------------------------------------------------------------
  # P6: media-strip + tool-output cap inside the summarization call (opencode
  # compaction.ts `stripMedia: true` / `toolOutputMaxChars: 2_000`).
  #
  # Applied to EVERY summarization prompt assembly point (`call_summary_llm`,
  # `call_key_facts_llm`, `summarize_chunk` — all three funnel through this
  # function), so a media-heavy history can never overflow the summarizer's
  # own context window the way it could when raw base64 image payloads were
  # JSON-encoded straight into the prompt by `safe_to_string/1`.
  # ---------------------------------------------------------------------------

  @tool_output_max_chars 2_000

  @doc """
  Formats a message list into the plain-text block fed to summarization LLM
  calls, with media stripped to `[Attached <type>]` placeholders and tool
  output capped at `@tool_output_max_chars` (P6). Public (rather than `defp`)
  so it is directly unit-testable — mirrors `micro_compact/1`'s exposure of
  an internal pipeline step for the same reason.
  """
  @spec format_for_summary([map()]) :: String.t()
  @impl OptimalSystemAgent.Agent.ContextEngine
  def format_for_summary(messages) do
    messages
    |> Enum.map(fn msg ->
      role = safe_to_string(Map.get(msg, :role, "unknown"))
      content = strip_media_content(Map.get(msg, :content))

      content =
        if role == "tool" do
          cap_tool_output(content)
        else
          content
        end

      tool_info =
        case Map.get(msg, :tool_calls) do
          nil ->
            ""

          [] ->
            ""

          calls when is_list(calls) ->
            names = Enum.map(calls, &safe_to_string(Map.get(&1, :name, "?"))) |> Enum.join(", ")
            " [tools: #{names}]"

          _ ->
            ""
        end

      "#{role}#{tool_info}: #{content}"
    end)
    |> Enum.join("\n")
    # Every summarization prompt in this module is assembled from this
    # function's output (`call_summary_llm`, `call_key_facts_llm`,
    # `summarize_chunk`), so this is THE text boundary at which raw
    # conversation — including whatever a shell command echoed — is handed to
    # a provider and then written back into context as a summary. Redact once,
    # here, rather than at each of the three call sites.
    |> Trajectory.redact()
  end

  # Strips images/media from message content, replacing each media block with
  # a `[Attached <type>]` text placeholder — same placeholder shape opencode's
  # overflow `replay` path uses (`[Attached ${mime}: ${filename}]`), so the
  # LEAD's react_loop media-replay hook can mirror this format exactly.
  #
  # Plain string content passes through untouched (there is no structured
  # media to strip). List content (multimodal blocks, e.g. Anthropic-style
  # `%{"type" => "image", "source" => %{...}}` — see `ImageBudget`) has each
  # media block collapsed to its placeholder and each text block extracted;
  # any other shape falls back to `safe_to_string/1`.
  @doc false
  defp strip_media_content(content) when is_binary(content), do: content
  defp strip_media_content(nil), do: ""

  defp strip_media_content(content) when is_list(content) do
    content
    |> Enum.map(&strip_media_block/1)
    |> Enum.join("\n")
  end

  defp strip_media_content(content), do: safe_to_string(content)

  @media_types ~w(image video audio file)

  defp strip_media_block(block) when is_map(block) do
    type = block_type(block)

    cond do
      type in @media_types -> "[Attached #{type}]"
      type == "text" -> block_text(block)
      true -> safe_to_string(block)
    end
  end

  defp strip_media_block(block), do: safe_to_string(block)

  defp block_type(block), do: to_string(Map.get(block, "type", Map.get(block, :type, "")))

  defp block_text(block),
    do: safe_to_string(Map.get(block, "text", Map.get(block, :text, "")))

  # Caps a (already media-stripped) tool-result string at
  # `@tool_output_max_chars`, matching opencode's `toolOutputMaxChars`. Only
  # applied to `role: "tool"` content — assistant/user prose is left to the
  # existing zone/importance compression to size down.
  @doc false
  defp cap_tool_output(content) when is_binary(content) do
    if String.length(content) > @tool_output_max_chars do
      truncated = String.slice(content, 0, @tool_output_max_chars)
      omitted = String.length(content) - @tool_output_max_chars
      "#{truncated}\n[... #{omitted} more characters truncated for summarization]"
    else
      content
    end
  end

  defp cap_tool_output(content), do: content

  @doc false
  defp extract_topics(messages) do
    messages
    |> Enum.filter(fn msg -> safe_to_string(Map.get(msg, :role)) == "user" end)
    |> Enum.map(fn msg ->
      content = safe_to_string(Map.get(msg, :content))
      String.slice(content, 0, 100)
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("; ")
    |> String.slice(0, 500)
  end

  @doc false
  defp record_compaction(tokens_saved, step) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:record_compaction, tokens_saved, step})
    end
  end

  defp safe_to_string(val),
    do: OptimalSystemAgent.Utils.Text.safe_to_string(val)

  # Append PreCompact hook instructions (set per-run in the process dict by
  # run_pipeline) to a summarization prompt.
  defp append_compact_instructions(prompt) do
    case Process.get(:osa_compact_instructions) do
      instr when is_binary(instr) and instr != "" ->
        prompt <>
          "\n\nAdditional instructions for this summary (from PreCompact hook):\n" <> instr

      _ ->
        prompt
    end
  end

  defp compactor_llm_enabled? do
    Application.get_env(:optimal_system_agent, :compactor_llm_enabled, true)
  end
end
