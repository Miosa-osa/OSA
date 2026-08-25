defmodule OptimalSystemAgent.Agent.Loop.Accounting do
  @moduledoc """
  Per-session token and cost accounting for the agent loop (primitive #29).

  Accounting is **always on** — every LLM round-trip's usage object is parsed,
  priced via `OptimalSystemAgent.Agent.Pricing`, and accumulated into the loop
  state. The running spend is exposed on the state (`session_cost_usd` +
  per-kind token counters) so:

    * `Loop.Limits` can enforce a *real* `max_budget_usd` cap, and
    * the TUI / auto-mode can display live spend.

  This module is intentionally pure with respect to loop state — `record/2`
  takes a state and returns an updated state. Side effects are limited to
  emitting a `:cost_update` system event and a best-effort bridge to the global
  `OptimalSystemAgent.Budget` daily/monthly ledger.
  """
  require Logger

  alias OptimalSystemAgent.Agent.Pricing
  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.Agent.SessionPersistence
  alias OptimalSystemAgent.Events.Bus

  @usage_keys [
    :input_tokens,
    :output_tokens,
    :cache_creation_input_tokens,
    :cache_read_input_tokens
  ]

  @doc """
  Normalize a provider usage map into the canonical shape with all four token
  kinds present as non-negative integers.

  Accepts atom- or string-keyed maps (providers vary) and tolerates `nil`.
  """
  @spec normalize_usage(map() | nil) :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_creation_input_tokens: non_neg_integer(),
          cache_read_input_tokens: non_neg_integer()
        }
  def normalize_usage(nil), do: zero_usage()

  def normalize_usage(usage) when is_map(usage) do
    Map.new(@usage_keys, fn key -> {key, fetch_tok(usage, key)} end)
  end

  def normalize_usage(_), do: zero_usage()

  @doc """
  Total prompt tokens that actually occupied the model's context window for one
  round-trip: fresh input + cache writes + cache reads.

  Providers disagree about how they slice the prompt:

    * **Anthropic** (`Providers.Anthropic.extract_usage/1`) reports the three
      slices SEPARATELY — `input_tokens` counts only the uncached tail, with
      `cache_creation_input_tokens` and `cache_read_input_tokens` alongside it.
    * **OpenAI-compatible** (`Providers.OpenAICompat.parse_usage/1`) folds the
      whole prompt into `prompt_tokens` → `input_tokens`, leaving both cache
      fields at zero.

  So `input_tokens` alone is NOT comparable across providers: on Anthropic with
  caching active it is a small fraction of the real context occupancy, and it
  shrinks further the better caching works. Summing all three yields the same
  effective total in both shapes, which is the number every context-pressure
  consumer (`Loop.ProactiveCompaction.estimated_tokens/1`) actually wants.
  """
  @spec effective_input_tokens(map() | nil) :: non_neg_integer()
  def effective_input_tokens(usage) do
    norm = normalize_usage(usage)
    norm.input_tokens + norm.cache_creation_input_tokens + norm.cache_read_input_tokens
  end

  @doc """
  Record one LLM round-trip's usage into the session accounting on `state`.

  Parses `usage`, prices it against `state.model`, and accumulates cost and
  per-kind token counts. Returns the updated state. Also refreshes
  `last_input_tokens` (used by context-pressure telemetry) and emits a
  `:cost_update` event with the new running totals.
  """
  @spec record(map(), map() | nil) :: map()
  def record(state, usage), do: record(state, usage, [])

  @doc """
  As `record/2`, plus whatever the provider said about the turn's price that
  OSA's rate card cannot know.

  `opts`:

    * `:provider_cost_usd` — the provider's OWN authoritative dollar figure for
      this round-trip (`ClaudeCli.reported_cost/0` publishes the CLI's
      `total_cost_usd` here). When present it REPLACES the rate-card estimate;
      it is never added to one.
    * `:provider_quota` — a non-dollar meter the provider bills in
      (`CopilotCli.reported_quota/0` publishes `%{premium_requests: float}`).
      Accumulated and reported alongside cost; never converted into dollars or
      tokens.
    * `:requested_at` — the instant the request was ISSUED (a `DateTime`, a
      `NaiveDateTime`, or unix seconds). See "Which clock prices a turn" below.

  ## Which clock prices a turn

  `Pricing` resolves DATED and HOURED rates against the instant the request was
  issued, falling back to `DateTime.utc_now/0` when nobody says. For an entire
  release nobody said: `normalize_usage/1` rebuilds the usage map from
  `@usage_keys` alone, so a `:requested_at` arriving on a provider's usage map
  was discarded here before `Pricing` ever saw it, and every turn was priced
  against the wall clock at the moment accounting happened to run.

  In the hot loop that is milliseconds after the round-trip and harmless. It is
  not harmless for anything STORED: a DeepSeek session recorded at 03:00 UTC
  (peak) and re-costed at 12:00 (off-peak) reports half the number, for the same
  finished turn, with no indication that anything moved.

  So the instant is captured where the request is issued — `ReactLoop` stamps it
  immediately before `LLMClient.llm_chat_stream/3`, not after the response lands
  — passed here, used to price, and then carried ON the normalized usage map so
  every downstream consumer (the `:cost_update` stream, the trajectory record on
  disk) can re-price the same turn to the same number forever.

  ## Why a provider figure has to win

  `Pricing.cost/2` computes `tokens x list price`. On a Max-plan account that
  is simply the wrong number — the marginal cost of a turn is not the list
  rate, and the CLI is the only party that knows what it actually was. The user
  running this is on such a plan, so the rate-card estimate is not a rounding
  error here; it is a figure that never matched the bill.

  Both figures are also the input to `max_budget_usd`, which is enforced off
  these totals. A cap checked against an invented number is not a cap.
  """
  @spec record(map(), map() | nil, keyword()) :: map()
  def record(state, usage, opts) do
    report_unaccounted(state, usage)
    do_record(state, usage, opts)
  rescue
    e ->
      # Accounting is best-effort telemetry — a pricing/emit failure must never
      # crash the turn. Degrade to the un-updated state (this round-trip's spend
      # is simply not accumulated) rather than propagating the error into the
      # ReAct loop.
      Logger.warning("[Accounting] record failed, skipping this round-trip: #{inspect(e)}")
      state
  catch
    kind, reason ->
      Logger.warning("[Accounting] record caught #{kind}: #{inspect(reason)} — skipping")
      state
  end

  @doc """
  Announce, once per provider per process, that a round-trip was billed as zero
  because the provider reported nothing.

  A provider that returns no `:usage` key is indistinguishable here from one
  that genuinely used no tokens: `normalize_usage/1` turns both into all-zeros,
  `Pricing.cost/2` returns `0.0`, and `max_budget_usd` — enforced by
  `Loop.Limits` off these totals — becomes unenforceable. That is the whole
  defect shape in one line: not an error, not a wrong-looking number, just a
  session that costs nothing and a spend limit that never trips.

  `Providers.Cohere` and `Providers.Replicate` return no usage; `ClaudeCli` and
  `CopilotCli` collect real usage (including the provider's own authoritative
  `total_cost_usd`) into a `:persistent_term` side channel that has no readers.
  Rather than pin those four in a list that will drift, the instrument is
  generic: any provider whose turns arrive unaccounted says so, at `:warning`,
  the first time it happens.
  """
  @spec report_unaccounted(map(), map() | nil) :: :ok
  def report_unaccounted(state, usage) do
    if usage == nil or usage == %{} do
      provider = Map.get(state, :provider)

      :telemetry.execute(
        [:osa, :accounting, :unaccounted_turn],
        %{count: 1},
        %{provider: provider, model: Map.get(state, :model)}
      )

      if Process.get(:osa_unaccounted_provider) != provider do
        Process.put(:osa_unaccounted_provider, provider)

        Logger.warning(
          "[Accounting] provider #{inspect(provider)} reported no token usage — this " <>
            "round-trip is billed as 0 tokens / $0.00 and max_budget_usd cannot be enforced " <>
            "for it"
        )
      end
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc """
  Put one provider's usage map onto the DISJOINT convention that
  `Pricing.cost/2` and `effective_input_tokens/1` both assume — fresh input,
  cache writes and cache reads counting each prompt token exactly once.

  Providers disagree, and the disagreement is silent:

    * **Anthropic native** (`Providers.Anthropic.extract_usage/1`) is already
      disjoint: `input_tokens` is the uncached tail only.
    * **Every OpenAI-shaped API** — `Providers.OpenAICompat.parse_usage/1`
      (`prompt_tokens` + `prompt_tokens_details.cached_tokens`) and
      `Providers.OpenAIResponses.parse_usage/3`
      (`input_tokens` + `input_tokens_details.cached_tokens`) — reports
      `input_tokens` INCLUSIVE of the cached portion, with `cached_tokens` as a
      breakdown of it, not an addition to it.

  Left unreconciled, an inclusive usage map is billed as
  `cached * rate + cached * rate * 0.1` — **11x** what the provider charges for
  a cache read — and `effective_input_tokens/1` reports the cached prompt twice
  to the context-pressure meter. Neither shows today because the cache-read
  count is 0 on the live path; both go live the moment prompt caching starts
  hitting, which is exactly why this is here now rather than after.

  Unknown providers are left ALONE. Guessing that an unrecognised usage map is
  inclusive would under-bill it, and this function is not allowed to invent
  either direction.

  This convention table belongs next to the transports in
  `Providers.Registry`; it lives here only because that file is under
  concurrent edit.
  """
  # Anthropic's wire format, wherever it is reached from.
  @disjoint_prompt_slices [:anthropic, :bedrock, :claude_cli]

  # OpenAI's wire format, plus every gateway that speaks it.
  #
  # `:google` is here on the same footing though it is not an OpenAI shape:
  # Gemini's `usageMetadata.promptTokenCount` is INCLUSIVE of
  # `cachedContentTokenCount` (see `Providers.Google.extract_usage/1`), so the
  # cached slice must be subtracted back out of `input_tokens` exactly as for
  # OpenAI. Unverified against a live Gemini call; documented shape only.
  @inclusive_prompt_slices [
    :google,
    :openai,
    :openai_codex,
    :openrouter,
    :groq,
    :together,
    :fireworks,
    :deepseek,
    :perplexity,
    :mistral,
    :qwen,
    :moonshot,
    :zhipu,
    :volcengine,
    :baichuan,
    :xai,
    :ollama,
    :ollama_cloud
  ]

  @spec reconcile_prompt_slices(map(), atom() | {:compat, atom()} | String.t() | nil) :: map()
  def reconcile_prompt_slices(norm, provider) when is_map(norm) do
    if inclusive_prompt_slices?(provider) do
      overlap = norm.cache_creation_input_tokens + norm.cache_read_input_tokens
      %{norm | input_tokens: max(norm.input_tokens - overlap, 0)}
    else
      norm
    end
  end

  defp inclusive_prompt_slices?({:compat, _}), do: true

  defp inclusive_prompt_slices?(p) when is_binary(p) do
    inclusive_prompt_slices?(safe_atom(p))
  end

  defp inclusive_prompt_slices?(p) when is_atom(p) and not is_nil(p) do
    cond do
      p in @disjoint_prompt_slices -> false
      p in @inclusive_prompt_slices -> true
      # `{:compat, _}` above already answers `true`, but the provider handed in
      # here is `state.provider` — a BARE atom, never the dispatch tuple — so
      # that clause never fires on the live path and the hand-written list is
      # what actually decides. The list had drifted: `:cerebras`, `:sambanova`,
      # `:hyperbolic`, `:lmstudio`, `:llamacpp` and `:miosa` are all
      # `{:compat, _}` entries in `Providers.Registry`, all parsed by
      # `OpenAICompat.parse_usage/1`, and all fell through to the `false`
      # default below — i.e. to Anthropic's disjoint convention, the 11x
      # over-bill this whole function exists to prevent.
      #
      # Asking the Registry instead of restating it means a provider added to
      # `@providers` cannot silently acquire the wrong billing convention. The
      # explicit list is kept and consulted FIRST so `:google` (inclusive but
      # not compat-routed) and the disjoint entries still win.
      compat_routed?(p) -> true
      true -> false
    end
  end

  defp inclusive_prompt_slices?(_), do: false

  defp compat_routed?(p) do
    OptimalSystemAgent.Providers.Registry.compat_routed?(p)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp safe_atom(p) do
    String.to_existing_atom(p)
  rescue
    ArgumentError -> nil
  end

  defp do_record(state, usage, opts) do
    norm =
      usage
      |> normalize_usage()
      |> reconcile_prompt_slices(Map.get(state, :provider))
      # Stamp BEFORE pricing: `turn_cost/3` reads the instant off the map, and
      # every consumer downstream of here gets a usage map that re-prices to the
      # same number rather than to whatever the wall clock says later.
      |> stamp_requested_at(request_instant(usage, opts))

    turn_cost = turn_cost(state, norm, opts)

    state =
      state
      |> accumulate_counters(norm, turn_cost)
      |> accumulate_provider_quota(Keyword.get(opts, :provider_quota))
      |> maybe_put_last_input(effective_input_tokens(norm))

    # Surrender this round-trip's numbers OUTSIDE the immutable state thread,
    # so a turn that crashes after burning tokens can still be billed for them.
    # See `adopt_partial/1`.
    stash_partial(state)

    emit_cost_update(state, norm, turn_cost, cost_update_extra(state, opts))
    maybe_bridge_budget(state, norm, turn_cost)
    maybe_record_trajectory(state, norm, turn_cost)

    state
  end

  # ── When the request was issued ───────────────────────────────────────────

  @doc """
  The instant a round-trip's request was ISSUED, as `record/3` will use it, or
  `nil` when neither the caller nor the provider supplied a usable one.

  Precedence: the `:requested_at` option (what `ReactLoop` stamps at the call
  site) beats a `:requested_at` the provider happened to put on its own usage
  map. Both are validated — an unparseable value is REFUSED rather than carried,
  because a stamp that `Pricing` cannot resolve would silently fall back to the
  wall clock while looking, on disk and in the event stream, exactly like a
  stamped turn.
  """
  @spec request_instant(map() | nil, keyword()) :: DateTime.t() | nil
  def request_instant(usage, opts) do
    from_opts = Keyword.get(opts, :requested_at)

    from_usage =
      if is_map(usage) do
        Map.get(usage, :requested_at) || Map.get(usage, "requested_at")
      end

    coerce_instant(from_opts) || coerce_instant(from_usage)
  end

  # Every shape `Pricing.clock/1` can resolve to an HOUR, normalized to one.
  # A bare `Date` is deliberately NOT accepted: it names a day but not an hour,
  # and `Pricing` treats an unknown hour as peak with `:estimated` confidence.
  # Recording that as a request instant would turn a guess into a stored fact.
  defp coerce_instant(%DateTime{} = dt), do: DateTime.shift_zone!(dt, "Etc/UTC")

  defp coerce_instant(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")

  defp coerce_instant(unix) when is_integer(unix) do
    case DateTime.from_unix(unix) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp coerce_instant(_), do: nil

  defp stamp_requested_at(norm, nil), do: norm
  defp stamp_requested_at(norm, %DateTime{} = at), do: Map.put(norm, :requested_at, at)

  # ── The provider's own price beats OSA's rate card ────────────────────────

  @doc """
  This round-trip's price: the provider's own figure when it published one,
  otherwise `Pricing.cost/2` against the rate card.

  Never the sum. A provider that reports `total_cost_usd` has ALREADY priced
  every token in the same usage map OSA would price again, so adding the two
  double-bills the turn — which is why this is a replacement and the telemetry
  below names which of the two produced the number.

  The rate-card branch prices `Pricing.qualify(model, provider)`, not the bare
  model: a reselling gateway serves other vendors' model ids at its own margin,
  so the id alone does not name a price. Identity for every provider that is
  not a reseller.
  """
  @spec turn_cost(map(), map(), keyword()) :: float()
  def turn_cost(state, norm, opts \\ []) do
    estimate =
      Pricing.cost(
        Pricing.qualify(Map.get(state, :model), Map.get(state, :provider)),
        norm
      )

    case provider_cost(opts) do
      nil ->
        estimate

      reported ->
        report_cost_source(state, reported, estimate)
        reported
    end
  end

  defp provider_cost(opts) do
    case Keyword.get(opts, :provider_cost_usd) do
      c when is_float(c) and c >= 0.0 -> round6(c)
      c when is_integer(c) and c >= 0 -> c * 1.0
      _ -> nil
    end
  end

  # A billing figure that changed must be visible. This is the one place a
  # session's cost stops being derived from OSA's own price table, and a silent
  # substitution would be indistinguishable from a pricing bug.
  defp report_cost_source(state, reported, estimate) do
    :telemetry.execute(
      [:osa, :accounting, :provider_cost],
      %{
        provider_cost_usd: reported,
        rate_card_estimate_usd: estimate,
        delta_usd: reported - estimate
      },
      %{provider: Map.get(state, :provider), model: Map.get(state, :model)}
    )

    signature = {Map.get(state, :provider), Map.get(state, :model)}

    if Process.get(:osa_provider_cost_source) != signature do
      Process.put(:osa_provider_cost_source, signature)

      Logger.info(
        "[Accounting] pricing #{inspect(Map.get(state, :provider))} turns from the provider's " <>
          "own total_cost_usd ($#{reported}) instead of the rate card ($#{estimate}) — the " <>
          "rate-card figure is tokens x list price, which is not what a Max-plan turn costs."
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  # A meter that is not dollars and not tokens. Copilot bills in fractional
  # `premiumRequests` against a monthly allowance, so there is nothing to price
  # and nothing to convert; the honest thing is to carry it under its own name.
  # `:copilot_cli` is in NEITHER prompt-slice list on purpose — it reports no
  # tokens, so it has no slice convention to belong to.
  defp accumulate_provider_quota(state, %{premium_requests: n}) when is_number(n) and n > 0 do
    put(state, :session_premium_requests, round6(get(state, :session_premium_requests, 0.0) + n))
  end

  defp accumulate_provider_quota(state, _), do: state

  defp cost_update_extra(state, opts) do
    base =
      case provider_cost(opts) do
        nil -> %{cost_source: :rate_card}
        c -> %{cost_source: :provider_reported, provider_cost_usd: c}
      end

    case Keyword.get(opts, :provider_quota) do
      %{premium_requests: n} when is_number(n) ->
        base
        |> Map.put(:provider_quota, %{premium_requests: n})
        |> Map.put(
          :session_premium_requests,
          get(state, :session_premium_requests, 0.0)
        )

      _ ->
        base
    end
  end

  # Add ONE already-normalized, already-reconciled, already-priced usage map to
  # the session's running counters.
  #
  # Split out of `do_record/2` so the side-spend path (`absorb_side_spend/1`)
  # can accumulate WITHOUT going through `reconcile_prompt_slices/2` a second
  # time. That function is not idempotent — on an OpenAI-shaped provider it
  # subtracts the cached overlap out of `input_tokens`, so applying it twice
  # under-bills the fresh input by the cached amount. Exactly one reconcile per
  # usage map, at the point the map first enters accounting, is the invariant.
  defp accumulate_counters(state, norm, cost) do
    state
    |> put(:session_cost_usd, round6(get(state, :session_cost_usd, 0.0) + cost))
    |> put(:session_input_tokens, get(state, :session_input_tokens, 0) + norm.input_tokens)
    |> put(:session_output_tokens, get(state, :session_output_tokens, 0) + norm.output_tokens)
    |> put(
      :session_cache_creation_tokens,
      get(state, :session_cache_creation_tokens, 0) + norm.cache_creation_input_tokens
    )
    |> put(
      :session_cache_read_tokens,
      get(state, :session_cache_read_tokens, 0) + norm.cache_read_input_tokens
    )
  end

  # ══════════════════════════════════════════════════════════════════════
  # Side spend — LLM calls billed to the session but made OUTSIDE the loop
  #
  # `Agent.Compactor.bounded_chat/2` is the single choke point for every
  # compaction/summarization provider call (three sites in `Compactor`, one in
  # `Loop.ProactiveCompaction`). None of that usage ever reached `record/2`, so
  # compaction was free as far as OSA's own books were concerned. It is real
  # money on any long session, and it stops being rare the moment the
  # compaction trigger thresholds are fixed.
  #
  # It cannot simply call `record/2`: compaction runs inside a supervised Task
  # (`TurnPipeline.bounded_compaction/2`), a DIFFERENT process from the `Loop`
  # GenServer, and it never sees the loop state. The immutable state thread
  # does not cross that boundary, and neither does the process dictionary the
  # crashed-turn stash uses.
  #
  # So the summarizer STAGES its priced usage into a public ETS ledger keyed by
  # session id, and the loop ABSORBS it into state at the next point it holds
  # both the state and the session id. Pricing/reconciliation happens once, at
  # stage time, against the SUMMARIZER's own model and provider (which may
  # differ from the session's). Absorb only adds.
  # ══════════════════════════════════════════════════════════════════════

  @side_table :osa_side_spend

  @doc """
  Stage one out-of-loop LLM round-trip's usage against `session_id`.

  Called from whatever process made the call (typically a compaction task).
  `opts` carries `:model` and `:provider` — the ones the call ACTUALLY used, not
  the session's — plus a `:kind` label (default `:compaction`) that rides the
  eventual `:cost_update` event so the spend is attributable.

  Never raises: this is billing telemetry on a path whose failure must not take
  compaction down with it.
  """
  @spec stage_side_spend(String.t() | nil, map() | nil, keyword()) :: :ok
  def stage_side_spend(session_id, usage, opts \\ [])

  def stage_side_spend(session_id, usage, opts)
      when is_binary(session_id) and session_id != "" do
    norm =
      usage
      |> normalize_usage()
      |> reconcile_prompt_slices(Keyword.get(opts, :provider))
      # Staged spend is priced HERE, at stage time, and only the resulting
      # dollar figure is absorbed later — so the stamp matters for exactly one
      # thing on this path, which is getting this pricing right.
      |> stamp_requested_at(request_instant(usage, opts))

    if norm.input_tokens + norm.output_tokens + norm.cache_creation_input_tokens +
         norm.cache_read_input_tokens > 0 do
      # Same rule as the in-loop path: a provider that priced its own call wins
      # over the rate card, and is never added to it.
      cost =
        provider_cost(opts) ||
          Pricing.cost(
            Pricing.qualify(Keyword.get(opts, :model), Keyword.get(opts, :provider)),
            norm
          )

      kind = Keyword.get(opts, :kind, :compaction)

      table = side_table()

      prior =
        case :ets.lookup(table, session_id) do
          [{^session_id, acc}] -> acc
          _ -> %{usage: zero_usage(), cost_usd: 0.0, calls: 0, kinds: []}
        end

      acc = %{
        usage: %{
          input_tokens: prior.usage.input_tokens + norm.input_tokens,
          output_tokens: prior.usage.output_tokens + norm.output_tokens,
          cache_creation_input_tokens:
            prior.usage.cache_creation_input_tokens + norm.cache_creation_input_tokens,
          cache_read_input_tokens:
            prior.usage.cache_read_input_tokens + norm.cache_read_input_tokens
        },
        cost_usd: round6(prior.cost_usd + cost),
        calls: prior.calls + 1,
        kinds: Enum.uniq([kind | prior.kinds])
      }

      :ets.insert(table, {session_id, acc})
    end

    :ok
  rescue
    e ->
      Logger.debug("[Accounting] stage_side_spend failed: #{inspect(e)}")
      :ok
  catch
    _, _ -> :ok
  end

  def stage_side_spend(_session_id, _usage, _opts), do: :ok

  @doc """
  Merge (and clear) any staged side spend for `state`'s session into the
  session counters. Returns the updated state; a no-op when nothing is staged,
  so it is safe to call on every compaction path.

  Deliberately does NOT touch `last_input_tokens`: a summarizer's prompt is not
  the session's context, and writing it there would make the context-pressure
  meter (and therefore the compaction trigger) read the summarizer's prompt
  size as the conversation's size.
  """
  @spec absorb_side_spend(map()) :: map()
  def absorb_side_spend(state) when is_map(state) do
    session_id = Map.get(state, :session_id)

    case take_side_spend(session_id) do
      nil ->
        state

      acc ->
        state = accumulate_counters(state, acc.usage, acc.cost_usd)

        # Same surrender-across-a-crash guarantee the in-loop path gets.
        stash_partial(state)

        emit_cost_update(state, acc.usage, acc.cost_usd, %{
          side_spend: true,
          side_spend_calls: acc.calls,
          side_spend_kinds: acc.kinds
        })

        maybe_bridge_budget(state, acc.usage, acc.cost_usd)

        state
    end
  rescue
    e ->
      Logger.warning("[Accounting] absorb_side_spend failed: #{inspect(e)}")
      state
  end

  def absorb_side_spend(state), do: state

  @doc false
  # Peek without consuming — tests and diagnostics only.
  @spec peek_side_spend(String.t() | nil) :: map() | nil
  def peek_side_spend(session_id) when is_binary(session_id) do
    case :ets.lookup(side_table(), session_id) do
      [{^session_id, acc}] -> acc
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def peek_side_spend(_), do: nil

  @doc """
  Drop any staged side spend for a session without billing it.

  Used by session teardown so a dead session's ledger row cannot be absorbed by
  a later session that happens to reuse the id.
  """
  @spec forget_side_spend(String.t() | nil) :: :ok
  def forget_side_spend(session_id) when is_binary(session_id) do
    :ets.delete(side_table(), session_id)
    :ok
  rescue
    _ -> :ok
  end

  def forget_side_spend(_), do: :ok

  defp take_side_spend(session_id) when is_binary(session_id) and session_id != "" do
    table = side_table()

    case :ets.take(table, session_id) do
      [{^session_id, acc}] -> acc
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp take_side_spend(_), do: nil

  # Lazily-created public named table, matching the convention used by
  # `Agent.TurnTermination` and `Agent.RunStore` — no supervisor entry needed,
  # and it survives every process that writes to it.
  defp side_table do
    case :ets.whereis(@side_table) do
      :undefined ->
        :ets.new(@side_table, [:named_table, :public, :set, read_concurrency: true])

      _ ->
        @side_table
    end
  rescue
    ArgumentError -> @side_table
  end

  # ── Partial-spend surrender across a crashed turn ────────────────────────
  #
  # `Loop.run_and_reply/1` wraps `ReactLoop.run/1` in a `try`. Both the `rescue`
  # and the `catch` arm return the state bound BEFORE the call, because on an
  # exception every intermediate state is unreachable — Elixir state is
  # immutable and threaded through the recursion, so the unwind takes it with
  # it. The consequence was that a turn which completed three billed round-trips
  # and then crashed on the fourth recorded a token delta of zero and dropped
  # that spend from session accounting entirely: the `:cost_update` stream, the
  # transcript's token column, and — worse — the `max_budget_usd` cap all went
  # on believing the money had never been spent.
  #
  # The seam is the process dictionary, which is the mechanism this codebase
  # already uses to carry work across an error boundary (`ReactLoop` drains
  # streamed tool results through `:osa_streaming_tool_ctx` the same way).
  # `ReactLoop.run/1` runs INLINE in the `Loop` GenServer process, so the key
  # written here survives the unwind and is readable by the rescue arm.
  #
  # ABSOLUTE counters are stashed, not deltas. Re-merging an absolute snapshot
  # is idempotent, so a duplicated or out-of-order merge cannot double-bill;
  # merging deltas twice would.
  @partial_key :osa_turn_accounting

  # Exactly the keys `do_record/2` writes. A counter added to accounting and
  # not to this list would be silently dropped on a crashed turn, which is the
  # bug this whole mechanism exists to fix — so the two lists must stay
  # together, and `accounting_test.exs` pins that they do.
  @partial_keys [
    :session_cost_usd,
    :session_input_tokens,
    :session_output_tokens,
    :session_cache_creation_tokens,
    :session_cache_read_tokens,
    :last_input_tokens
  ]

  defp stash_partial(state) do
    Process.put(@partial_key, Map.take(state, @partial_keys))
    :ok
  end

  @doc """
  Drop any stashed partial accounting.

  Called by `Loop.run_and_reply/1` at the TOP of every turn. The `Loop`
  GenServer is long-lived and the process dictionary is not, so without this a
  turn that crashed before its first round-trip would adopt the PREVIOUS turn's
  snapshot and bill it a second time.
  """
  @spec forget_partial() :: :ok
  def forget_partial do
    Process.delete(@partial_key)
    :ok
  end

  @doc """
  Merge any accounting recorded during a crashed turn back onto the pre-turn
  state.

  Deliberately merges ONLY the accounting keys. `state.messages`,
  `state.iteration` and `state.total_tool_calls` from a half-crashed turn are
  not recovered here and should not be: a message list interrupted mid-cycle can
  be structurally invalid (an assistant tool-call block with no matching tool
  result), and merging it would poison the next request to the provider.
  Recovering history is a separate, larger problem. Recovering the money is not.

  A no-op when nothing was recorded, so it is safe on every path.
  """
  @spec adopt_partial(map()) :: map()
  def adopt_partial(state) do
    case Process.get(@partial_key) do
      snapshot when is_map(snapshot) and map_size(snapshot) > 0 ->
        Map.merge(state, snapshot)

      _ ->
        state
    end
  end

  @doc """
  Return a compact spend snapshot for a session state — used by `Loop.get_state`
  so the TUI / auto-mode can display live spend.

  Carries BOTH figures, explicitly named, because they answer different
  questions and collapsing them has already cost us once:

    * `:cost_usd` — this session NODE's own spend. What per-session display
      wants, and the only figure any rollup may read (a parent sums its
      children's node figures; a tree total in that slot double-counts).
    * `:tree_cost_usd` — this node PLUS every descendant fleet node. What
      "what did this task cost?" means once an arm delegates.
    * `:tree_cost_complete` — false when part of the tree's bill could not be
      read, in which case `:tree_cost_usd` is a LOWER BOUND. Display may show
      it with a `≥`; enforcement must not spend on the strength of it.
  """
  @spec snapshot(map()) :: map()
  def snapshot(state) do
    tree = safe_tree_spend(state)
    cost = get(state, :session_cost_usd, 0.0)
    # A completed task ≈ one user turn (each user message drives one turn to a
    # terminal answer). $/completed-task is the number Vetta-style comparisons
    # turn on, and it is the honest efficiency figure for long-running work:
    # total spend amortised over tasks actually finished. turn_count is 0 before
    # the first turn completes, so guard the divide.
    tasks = max(get(state, :turn_count, 0), 1)

    %{
      cost_usd: round6(cost),
      cost_per_task_usd: round6(cost / tasks),
      completed_tasks: get(state, :turn_count, 0),
      tree_cost_usd: tree.usd,
      tree_cost_complete: tree.complete,
      input_tokens: get(state, :session_input_tokens, 0),
      output_tokens: get(state, :session_output_tokens, 0),
      cache_creation_tokens: get(state, :session_cache_creation_tokens, 0),
      cache_read_tokens: get(state, :session_cache_read_tokens, 0),
      max_budget_usd: get(state, :max_budget_usd, nil)
    }
  end

  @doc """
  `tree_spend/1` that can never raise — for display and telemetry.

  Enforcement paths must keep calling `tree_spend/1` (and fail closed on
  `complete: false`); this one degrades to the node's own spend so a rollup
  failure cannot break rendering a status line.
  """
  @spec safe_tree_spend(map()) :: %{usd: float(), complete: boolean(), unknown: [term()]}
  def safe_tree_spend(state) when is_map(state) do
    tree_spend(state)
  rescue
    _ -> %{usd: own_cost(state), complete: false, unknown: [:rollup_failed]}
  catch
    _, _ -> %{usd: own_cost(state), complete: false, unknown: [:rollup_failed]}
  end

  def safe_tree_spend(_), do: %{usd: 0.0, complete: false, unknown: [:no_state]}

  # ══════════════════════════════════════════════════════════════════════
  # Fleet / tree budget rollup (W2)
  #
  # A `max_budget_usd` cap set on a parent must bound the WHOLE run tree — the
  # parent plus every descendant fleet node — not each node independently.
  # Otherwise N children each under their own (usually absent) cap can blow the
  # intended total (cap-defeat via fan-out).
  #
  # The rollup is READ-ONLY: it walks the run tree via `RunStore`
  # (`parent_session_id` links) and reads each descendant's persisted spend from
  # the durable `SessionPersistence` sidecar — the same sidecar `Checkpoint`
  # mirrors every tool cycle. Neither store is mutated here. Every read is
  # wrapped best-effort: a rollup failure degrades to the parent's own spend
  # rather than crashing the loop or wrongly reporting exhaustion.
  # ══════════════════════════════════════════════════════════════════════

  @doc """
  Total USD spend across the WHOLE run tree rooted at `state`'s session — the
  parent's own live `session_cost_usd` PLUS every descendant fleet node's
  persisted spend.

  This is what makes `max_budget_usd` bound the tree rather than each node. The
  parent's own spend is taken from the passed state (its live accumulator);
  descendant spend is summed read-only from `RunStore` + `SessionPersistence`,
  so a child's cost is never double-counted against the parent.
  """
  @spec tree_spend_usd(map()) :: float()
  def tree_spend_usd(state) when is_map(state), do: tree_spend(state).usd

  @doc """
  The whole-tree bill AND whether it is complete.

  `tree_spend_usd/1` answers with a float because its callers format and compare
  it. Enforcement needs the other half of the answer: a float alone cannot
  distinguish "this tree cost $0.00" from "we could not find out what this tree
  cost", and OSA collapsed the two everywhere — an absent spend sidecar, a
  failed rollup and a crashed read all produced `0.0`, which reads as "plenty of
  budget left" to every gate downstream.

  Returns `%{usd: float, complete: boolean, unknown: [term]}` where `:unknown`
  lists the nodes (or the failure marker) whose spend could not be established.
  `complete: false` means the number in `:usd` is a LOWER BOUND, and any gate
  that spends money on the strength of it must fail closed.
  """
  @spec tree_spend(map()) :: %{usd: float(), complete: boolean(), unknown: [term()]}
  def tree_spend(state) when is_map(state) do
    own = own_cost(state)
    {desc, unknown} = descendants_spend(Map.get(state, :session_id))

    %{usd: round6(own + desc), complete: unknown == [], unknown: Enum.reverse(unknown)}
  rescue
    e ->
      # We know the parent's own spend and NOTHING about the tree beneath it.
      # That is an incomplete bill, not a zero one.
      Logger.debug("[Accounting] tree_spend rollup failed: #{inspect(e)}")
      %{usd: own_cost(state), complete: false, unknown: [:rollup_failed]}
  end

  @doc """
  True when the session has a real (`> 0`) `max_budget_usd` cap and the rolled-up
  WHOLE-TREE spend has reached it.

  This is the helper fan_out (and any budget guard) checks BEFORE spawning a new
  node — when it returns true, spawning must STOP and the exhaustion be surfaced
  rather than silently overspending. An absent / non-positive cap is never
  exhausted (uncapped).
  """
  @spec budget_exhausted?(map()) :: boolean()
  def budget_exhausted?(state) when is_map(state) do
    max = Map.get(state, :max_budget_usd)

    if is_number(max) and max > 0 do
      spend = tree_spend(state)

      cond do
        spend.usd >= max ->
          true

        # FAIL CLOSED. A cap exists and part of the bill is unknowable, so we
        # cannot say the cap has room. Spending real money on the assumption
        # that an unreadable bill is a zero bill is the failure mode this guard
        # exists to prevent.
        not spend.complete ->
          Logger.warning(
            "[Accounting] tree spend for #{inspect(Map.get(state, :session_id))} is INCOMPLETE " <>
              "(#{inspect(spend.unknown)}) under a $#{max} cap — treating the budget as " <>
              "exhausted rather than assuming the missing spend was free"
          )

          true

        true ->
          false
      end
    else
      # No cap configured: nothing to enforce, so an unknown bill changes nothing.
      false
    end
  end

  @doc """
  Remaining tree budget in USD (`max_budget_usd` minus rolled-up tree spend,
  floored at 0.0), or `:infinity` when there is no positive cap.
  """
  @spec tree_budget_remaining(map()) :: float() | :infinity
  def tree_budget_remaining(state) when is_map(state) do
    max = Map.get(state, :max_budget_usd)

    if is_number(max) and max > 0 do
      spend = tree_spend(state)
      # An incomplete bill has no knowable remainder. Reporting one would be the
      # same lie `budget_exhausted?/1` refuses to tell.
      if spend.complete, do: max(0.0, round6(max - spend.usd)), else: 0.0
    else
      :infinity
    end
  end

  # Sum the persisted spend of every descendant of `root`, carrying the nodes
  # whose spend could NOT be established rather than folding them into the sum
  # as zeros. Returns `{usd, unknown_nodes}`.
  defp descendants_spend(nil), do: {0.0, []}

  defp descendants_spend(root) do
    root
    |> collect_descendants()
    |> Enum.reduce({0.0, []}, fn agent_id, {sum, unknown} ->
      case node_spend(agent_id) do
        {:ok, cost} -> {sum + cost, unknown}
        :unknown -> {sum, [agent_id | unknown]}
      end
    end)
  rescue
    _ -> {0.0, [:walk_failed]}
  end

  @doc false
  # Every descendant agent_id of `root`, walked over `RunStore.children_of/1`.
  #
  # This deliberately does NOT go through `RunStore.list/1`: that list is capped
  # AND machine-wide AND fed by a table `prune_terminal/0`
  # evicts from, so a wide fan-out would drop its own finished nodes out of the
  # rollup, unrelated sessions could evict tree members, and an exhausted budget
  # would flip back to "not exhausted" mid-spawn. The edge ledger is unpruned.
  def collect_descendants(root) do
    bfs([root], MapSet.new([root]), [])
  end

  # Iterative BFS with a SINGLE `seen` set threaded across the whole frontier.
  # The previous recursive form rebound `seen` inside the reduce closure, so the
  # guard was per-path: two sibling branches converging on the same node counted
  # that node's cost twice.
  defp bfs([], _seen, acc), do: Enum.reverse(acc)

  defp bfs([node | rest], seen, acc) do
    {next, seen} =
      node
      |> RunStore.children_of()
      |> Enum.reduce({[], seen}, fn child, {queued, seen} ->
        if MapSet.member?(seen, child) do
          {queued, seen}
        else
          {[child | queued], MapSet.put(seen, child)}
        end
      end)

    next = Enum.reverse(next)
    bfs(rest ++ next, seen, Enum.reverse(next, acc))
  end

  # A single node's real spend, from its durable sidecar (never raises).
  # `{:ok, usd}` when the bill is known, `:unknown` when it is not.
  defp node_spend(agent_id) when is_binary(agent_id) do
    case SessionPersistence.load_spend(agent_id) do
      %{cost_usd: c, complete: true} when is_number(c) and c >= 0 ->
        {:ok, c * 1.0}

      _ ->
        # No readable sidecar. Which of the two cases this is matters:
        #
        #   * still RUNNING — the node has not reached its first persist point.
        #     Its spend is bounded by the turn in flight and the next check will
        #     see it. Counting it as 0 here is a measurement, not a guess.
        #   * TERMINAL (or no run row at all) — it finished and left no record.
        #     Whatever it spent is unrecorded and unrecoverable. Unknown.
        if run_terminal?(agent_id), do: :unknown, else: {:ok, 0.0}
    end
  rescue
    _ -> :unknown
  end

  defp node_spend(_), do: :unknown

  defp run_terminal?(agent_id) do
    case RunStore.get(agent_id) do
      %{status: :running} -> false
      _ -> true
    end
  rescue
    _ -> true
  end

  defp own_cost(state) do
    case Map.get(state, :session_cost_usd, 0.0) do
      n when is_number(n) -> n * 1.0
      _ -> 0.0
    end
  end

  # --- Private ---

  defp emit_cost_update(state, norm, turn_cost, extra) do
    payload =
      %{
        event: :cost_update,
        session_id: Map.get(state, :session_id),
        model: Map.get(state, :model),
        turn_cost_usd: turn_cost,
        session_cost_usd: get(state, :session_cost_usd, 0.0),
        # The WHOLE-tree bill (this session plus every descendant fleet node).
        # `session_cost_usd` above is this node's own spend and stays that way —
        # every rollup reads node-local figures and would double-count a
        # tree-total masquerading as one. See `tree_spend/1`.
        tree_cost_usd: safe_tree_cost(state),
        max_budget_usd: get(state, :max_budget_usd, nil),
        usage: norm
      }
      |> Map.merge(extra)

    Bus.emit(:system_event, payload)

    if sid = Map.get(state, :session_id) do
      Phoenix.PubSub.broadcast(
        OptimalSystemAgent.PubSub,
        "osa:session:#{sid}",
        {:osa_event, Map.put(payload, :type, :cost_update)}
      )
    end

    :ok
  rescue
    e ->
      Logger.debug("[Accounting] emit_cost_update failed: #{inspect(e)}")
      :ok
  end

  # Bridge real usage into the global daily/monthly ledger when it is running.
  # Fire-and-forget; never let ledger bookkeeping crash the loop.
  #
  # `turn_cost` is the price `Pricing.cost/2` already computed for this exact
  # usage, and it is what gets recorded. This used to call
  # `Budget.record_cost/5` with `effective_input_tokens(norm)` — input PLUS
  # cache-write PLUS cache-read — which the ledger's own coarse provider table
  # then billed at the FULL input rate. Cache reads cost a tenth of the input
  # rate (`Pricing.@cache_read_multiplier`), so the same tokens were billed
  # twice over at up to 10x on the cached portion, and `/cost` printed that
  # inflated figure. One usage, one price, one engine.
  defp maybe_bridge_budget(state, norm, turn_cost) do
    if Process.whereis(OptimalSystemAgent.Budget) do
      OptimalSystemAgent.Budget.record_priced_cost(
        provider_atom(Map.get(state, :provider)),
        to_string(Map.get(state, :model)),
        turn_cost,
        effective_input_tokens(norm) + norm.output_tokens,
        Map.get(state, :session_id)
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  # Whole-tree bill for display/telemetry. Never raises, and never blocks the
  # turn on a rollup failure — it degrades to the node's own spend, which is a
  # lower bound. Enforcement must NOT use this: it cannot tell a complete bill
  # from a degraded one. `budget_exhausted?/1` uses `tree_spend/1` directly and
  # fails closed on incompleteness; that is deliberate and stays that way.
  #
  # Cheap for the common case: a session with no fleet children resolves to one
  # ETS lookup in `collect_descendants/1` plus the node's own float. Only a
  # parent that actually fanned out pays the per-descendant sidecar read.
  defp safe_tree_cost(state), do: safe_tree_spend(state).usd

  defp provider_atom(p) when is_atom(p) and not is_nil(p), do: p

  defp provider_atom(p) when is_binary(p) do
    String.to_existing_atom(p)
  rescue
    ArgumentError -> :default
  end

  defp provider_atom(_), do: :default

  defp maybe_put_last_input(state, input) when input > 0,
    do: put(state, :last_input_tokens, input)

  defp maybe_put_last_input(state, _), do: state

  defp fetch_tok(usage, key) do
    val = Map.get(usage, key) || Map.get(usage, Atom.to_string(key)) || 0
    if is_integer(val) and val >= 0, do: val, else: 0
  end

  defp zero_usage,
    do: %{
      input_tokens: 0,
      output_tokens: 0,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 0
    }

  defp get(state, key, default) do
    case Map.get(state, key, default) do
      nil -> default
      val -> val
    end
  end

  defp put(state, key, value), do: Map.put(state, key, value)

  defp round6(n) when is_float(n), do: Float.round(n, 6)
  defp round6(n), do: n

  defp maybe_record_trajectory(state, norm, turn_cost) do
    try do
      messages = Map.get(state, :messages, [])
      {last_assistant, tool_calls, tool_results} = extract_last_turn(messages)

      OptimalSystemAgent.Agent.Trajectory.record(%{
        session_id: Map.get(state, :session_id, ""),
        model: Map.get(state, :model, ""),
        input_tokens: norm.input_tokens,
        output_tokens: norm.output_tokens,
        cache_creation_tokens: Map.get(norm, :cache_creation_input_tokens, 0),
        cache_read_tokens: Map.get(norm, :cache_read_input_tokens, 0),
        # The instant that produced `cost_usd`. Without it the stored row can be
        # re-costed only against the wall clock, i.e. to a different number than
        # the one sitting next to it in the same row.
        requested_at: Map.get(norm, :requested_at),
        cost_usd: turn_cost,
        tool_calls: tool_calls,
        tool_results: tool_results,
        assistant_response: last_assistant,
        context_utilization: extract_utilization(state, messages),
        compaction_events: []
      })
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp extract_last_turn(messages) when is_list(messages) do
    # Walk backwards: find the last assistant message and any tool results after it
    reversed = Enum.reverse(messages)

    {assistant, tool_results} =
      Enum.reduce_while(reversed, {nil, []}, fn msg, {acc_asst, acc_tools} ->
        role = Map.get(msg, :role)

        cond do
          role == "assistant" and acc_asst == nil ->
            content = Map.get(msg, :content, "")
            {:halt, {content, acc_tools}}

          role == "tool" ->
            {:cont, {acc_asst, [Map.get(msg, :content, "") | acc_tools]}}

          true ->
            {:cont, {acc_asst, acc_tools}}
        end
      end)

    {assistant || "", extract_tool_calls_from_messages(reversed), tool_results}
  end

  defp extract_last_turn(_), do: {"", [], []}

  defp extract_tool_calls(nil), do: []

  defp extract_tool_calls(calls) when is_list(calls) do
    Enum.map(calls, fn tc ->
      %{name: Map.get(tc, :name, ""), arguments: Map.get(tc, :arguments, %{})}
    end)
  end

  defp extract_tool_calls(_), do: []

  # Extract tool calls from the last assistant message in the (reversed) list
  defp extract_tool_calls_from_messages([]), do: []

  defp extract_tool_calls_from_messages([msg | rest]) do
    case Map.get(msg, :role) do
      "assistant" ->
        extract_tool_calls(Map.get(msg, :tool_calls, []))

      _ ->
        extract_tool_calls_from_messages(rest)
    end
  end

  defp extract_utilization(state, _messages) do
    last_input = Map.get(state, :last_input_tokens, 0)

    if last_input > 0 do
      max_tokens = Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)
      Float.round(last_input / max_tokens * 100, 1)
    else
      0.0
    end
  end
end
