defmodule OptimalSystemAgent.Agent.Pricing do
  @moduledoc """
  Per-model token pricing table for real cost accounting (primitive #29).

  Prices are quoted in **USD per 1,000,000 tokens** as `{input_rate, output_rate}`.
  Cache tokens are priced off the input rate using the standard Anthropic-style
  multipliers:

    * cache **write** (`cache_creation_input_tokens`) → `input_rate * 1.25`
    * cache **read**  (`cache_read_input_tokens`)     → `input_rate * 0.1`

  Model lookup is: exact (case-insensitive) match first — the hand-written
  table, then each provider's own catalog — then a family SUBSTRING GUESS, then
  nothing.

  Three outcomes, and callers that publish a dollar figure must not treat them
  alike (`confidence/1` / `cost_with_confidence/2` return which one fired):

    * `:exact` — a published rate. Trust it.
    * `:estimated` — the `@families` substring fallback matched. This is a
      guess by construction: `"claude-opus" => {15, 75}` was right for Claude 3
      Opus and is 3x wrong for Opus 5, and that one row is the entire 2.487x by
      which a benchmark run over-reported its own spend. The guess is still
      emitted (an over-estimate is more useful to a budget cap than `$0.00`, and
      the table is chosen to over- rather than under-state) but it is LOUD: the
      model is named at `:warning`, once per model per node.
    * `:unknown` — no rate at all. Costs `$0.0` and is logged. A known-unknown,
      not a claim that the call was free.


  This is deliberately a plain data module (no process, no state) so it can be
  called from the hot loop without contention.
  """
  require Logger

  @cache_write_multiplier 1.25
  @cache_read_multiplier 0.1

  # Exact model → {input $/1M, output $/1M}
  #
  # Ollama Cloud tags are NOT listed here: they are merged in below from
  # `Providers.OllamaCloud`, the single source of truth for that catalog. Add a
  # new cloud model's price THERE (leave it nil if the vendor publishes none —
  # an unpriced model accounts at $0.00 and logs, which is honest).
  @static_pricing %{
    # GLM (Z.ai / Zhipu cloud) — OSA's default provider family.
    #
    # Current GLM ids are NOT listed here: they come from
    # `Providers.ZaiModels`, the single source of truth for that catalog,
    # merged in below. Only the two legacy ids that catalog does not carry
    # survive as hand-written rows, so a config still pinned to one accounts at
    # the rate it was actually billed rather than at a family guess.
    # `glm-4.6:cloud` is here rather than in `OllamaCloud` because Ollama no
    # longer serves that tag, so it has no catalog row to inherit from.
    "glm-4.6:cloud" => {0.60, 2.20},
    "glm-4.6" => {0.60, 2.20},
    "glm-4.5" => {0.60, 2.20},

    # GLM reached through OpenRouter, which prices the ROUTE, not the model —
    # and OpenRouter picks among ~30 upstreams for this id whose rates span
    # {0.448, 1.408} (StreamLake) to {2.31, 7.26} (Alibaba), a 5x spread. Z.ai's
    # own endpoint sits at {1.40, 4.40}, the rate `ZaiModels` records for the
    # bare id.
    #
    # This row therefore cannot be "correct" — it can only track whichever
    # upstream OpenRouter is defaulting to. It is kept, keyed on the FULL
    # gateway id so it applies to that route alone, because the alternative is
    # the `glm` family guess. Observed on the OpenRouter model page 2026-08-14;
    # the default route had already moved to {0.462, 1.452} by 2026-08-15.
    # Deliberately NOT updated to chase that: the benchmark arms that ran
    # against it (or-glm52-full / or-glm52-nospec) are costed with this number,
    # and a rate that changes under them retroactively is worse than one that
    # is stably approximate.
    "z-ai/glm-5.2" => {0.63, 1.98},

    # Anthropic Claude
    "claude-3-5-sonnet" => {3.0, 15.0},
    "claude-3-7-sonnet" => {3.0, 15.0},
    "claude-sonnet-4" => {3.0, 15.0},
    "claude-3-opus" => {15.0, 75.0},
    "claude-opus-4" => {15.0, 75.0},
    "claude-3-5-haiku" => {0.80, 4.0},
    "claude-3-haiku" => {0.25, 1.25},

    # OpenAI
    "gpt-4o" => {2.5, 10.0},
    "gpt-4o-mini" => {0.15, 0.60},
    "gpt-4.1" => {2.0, 8.0},
    "gpt-4.1-mini" => {0.40, 1.60},
    "gpt-4.1-nano" => {0.10, 0.40},
    "o1" => {15.0, 60.0},
    "o3" => {2.0, 8.0},
    "o3-mini" => {1.10, 4.40},
    "gpt-3.5-turbo" => {0.50, 1.50},

    # DeepSeek — RETIRED 2026-07-24. Kept so an unmigrated pinned config still
    # accounts at the rate it was actually billed, rather than at $0.00. The V4
    # replacements come from Providers.DeepSeekModels, merged below.
    "deepseek-chat" => {0.27, 1.10},
    "deepseek-reasoner" => {0.55, 2.19}
  }

  # Hosted-provider catalogs win over the hand-written rows above, so a current
  # model can never fall through to the `@families` substring guess (which is
  # how claude-opus-5 would otherwise have been billed at Sonnet rates, and how
  # gpt-5.6-* would have accounted at $0.00).
  @pricing @static_pricing
           |> Map.merge(OptimalSystemAgent.Providers.OllamaCloud.pricing())
           |> Map.merge(OptimalSystemAgent.Providers.AnthropicModels.pricing())
           |> Map.merge(OptimalSystemAgent.Providers.OpenAIModels.pricing())
           |> Map.merge(OptimalSystemAgent.Providers.GoogleModels.pricing())
           |> Map.merge(OptimalSystemAgent.Providers.DeepSeekModels.pricing())
           # GLM. Until 2026-08-15 there was no Z.ai catalog at all, so
           # `glm-5.2` — OSA's DEFAULT model — reached the `{"glm", …}` family
           # substring guess of {0.60, 2.20}. That is GLM-4.7's rate; Z.ai
           # charges {1.40, 4.40}, so the default model under-billed by 2.4x on
           # input and 2x on output. Unlike the claude-opus-5 incident this one
           # under-stated, which is the direction that flatters us.
           |> Map.merge(OptimalSystemAgent.Providers.ZaiModels.pricing())
           # xAI and Gemini 3.1 Pro bill the WHOLE request at a higher rate once
           # the prompt crosses a threshold (200k for both). These are the
           # sub-threshold rates, so a long-context turn under-accounts by
           # ~1.5–2x. Recorded rather than blended: most turns sit under the
           # threshold, and a blended rate would be wrong for every turn.
           |> Map.merge(OptimalSystemAgent.Providers.XAIModels.pricing())
           |> Map.merge(OptimalSystemAgent.Providers.MistralModels.pricing())

  # Ordered family fallbacks — first substring match wins. Checked only when
  # there is no exact hit. Keep specific families before generic ones.
  @families [
    {"glm", {0.60, 2.20}},
    {"claude-3-opus", {15.0, 75.0}},
    {"claude-opus", {15.0, 75.0}},
    {"claude-3-5-haiku", {0.80, 4.0}},
    {"claude-haiku", {0.80, 4.0}},
    {"claude-3-haiku", {0.25, 1.25}},
    {"claude-sonnet", {3.0, 15.0}},
    {"claude", {3.0, 15.0}},
    {"gpt-4o-mini", {0.15, 0.60}},
    {"gpt-4o", {2.5, 10.0}},
    {"gpt-4.1", {2.0, 8.0}},
    {"gpt-4", {2.5, 10.0}},
    {"gpt-3.5", {0.50, 1.50}},
    {"deepseek", {0.27, 1.10}}
  ]

  @doc """
  Return `{input_rate, output_rate}` (USD per 1M tokens) for a model, or `nil`
  when the model is not in the pricing table.

  Local/self-hosted models served via Ollama are free and return `{0.0, 0.0}`.
  """
  @spec rates(String.t() | atom() | nil) :: {number(), number()} | nil
  def rates(model), do: rates(model, Date.utc_today())

  @doc """
  `rates/1` against an explicit date.

  `today` exists because some published rates are DATED (see
  `@pricing_schedules`), and a date-dependent price whose only clock is
  `Date.utc_today/0` cannot be tested on both sides of its own boundary
  without waiting for the calendar. Mirrors `AnthropicModels.retired?/2`.
  """
  @spec rates(String.t() | atom() | nil, Date.t()) :: {number(), number()} | nil
  def rates(nil, _today), do: nil

  def rates(model, today) when is_atom(model), do: rates(Atom.to_string(model), today)

  def rates(model, today) when is_binary(model) do
    key = String.downcase(model)

    cond do
      # Local Ollama-hosted models (e.g. "ollama/llama3", "qwen2.5:7b") are free.
      ollama_local?(key) ->
        {0.0, 0.0}

      # Checked BEFORE the exact table: a scheduled rate supersedes the
      # catalog's `:pricing` once its date arrives, and the exact table would
      # otherwise keep returning the pre-change rate forever.
      rate = scheduled_rate(key, today) ->
        rate

      rate = Enum.find_value(lookup_keys(key), &exact_rate/1) ->
        rate

      true ->
        family_rate(key)
    end
  end

  # Unexpected model type (number, map, tuple, …) — never guess a price and
  # never raise. A malformed loop state must not crash cost accounting in the
  # hot path; treat as unknown (nil → $0.0 in cost/2, same as an unknown name).
  def rates(_, _), do: nil

  # A gateway names a model `<vendor>/<id>` — `anthropic/claude-opus-5`,
  # `z-ai/glm-5.2`, `openai/gpt-5.6-sol` — and that is the form OSA actually
  # sends when it runs through OpenRouter, which is how the benchmarks run.
  # None of those strings is a key in any catalog, so every one of them missed
  # BOTH the exact map and the SSOT resolvers and fell through to the coarse
  # `@families` substring table. Measured consequences, all live:
  #
  #   anthropic/claude-opus-5  → "claude-opus" → {15.0, 75.0} vs the real
  #                              {5.00, 25.00}. Exactly 3x, and it is the whole
  #                              of the ~2.5x by which the benchmark run
  #                              over-reported its own spend.
  #   openai/gpt-5.6-sol       → no family matches → nil → $0.00. Under-count.
  #   deepseek/deepseek-v4-pro → "deepseek" → {0.27, 1.10} vs {1.17, 2.34},
  #                              the RETIRED V3 rate. Under-count.
  #
  # So the vendor prefix is stripped and the bare id retried against the same
  # tables before any family guess is allowed. Ordered longest-first, so a
  # catalog that ever does key a slashed id keeps winning on the full string.
  #
  # Routing suffixes (`:free`, `:nitro`, …) are OpenRouter routing directives,
  # not model identity, and are tried LAST so a real `:cloud`-tagged id
  # (`glm-5.2:cloud`, a genuine distinct key) still matches on the full string
  # first.
  @routing_suffixes ~w(free nitro floor online extended beta thinking exacto)

  defp lookup_keys(key) do
    bare = key |> String.split("/") |> List.last()

    literal =
      [key, bare]
      |> Enum.flat_map(&[&1, strip_routing_suffix(&1)])

    (literal ++ Enum.map(literal, &dotted_version_to_dashed/1))
    |> Enum.reject(&(&1 == "" or is_nil(&1)))
    |> Enum.uniq()
  end

  # A gateway spells a model VERSION with a dot where the vendor catalog spells
  # it with a dash. OpenRouter's live id is `anthropic/claude-haiku-4.5`; the
  # Anthropic catalog keys `claude-haiku-4-5`. `resolve/1` matches on a prefix,
  # so the dotted form matched neither the exact map nor the SSOT and fell to
  # the `@families` guess "claude-haiku" => {0.80, 4.0} — the retired Haiku 3.5
  # rate — where the published Haiku 4.5 rate is {1.00, 5.00}. Every cost
  # figure on that route came out 20% LOW, which is the direction that flatters
  # us, and that route is how the Anthropic benchmark arm runs.
  #
  # Tried LAST, after every literal spelling, so a key that genuinely contains
  # a dotted version (`z-ai/glm-5.2`, `openai/gpt-4.1`) still resolves on its
  # own spelling first and nothing that prices correctly today can move.
  defp dotted_version_to_dashed(key), do: String.replace(key, ~r/(\d)\.(\d)/, "\\1-\\2")

  defp strip_routing_suffix(key) do
    case String.split(key, ":") do
      [base, suffix] when base != "" ->
        if suffix in @routing_suffixes, do: base, else: key

      _ ->
        key
    end
  end

  defp exact_rate(key) do
    case Map.fetch(@pricing, key) do
      {:ok, rate} -> rate
      :error -> ssot_rate(key)
    end
  end

  # Exact-key lookup happens above; this catches DATED SNAPSHOT ids that the
  # exact map has no row for — e.g. "claude-haiku-4-5-20251001", which
  # otherwise fell through to the `@families` substring table and matched
  # "claude-haiku" => {0.80, 4.0}, billing Haiku 4.5 at the retired Haiku 3.5
  # rate instead of its real {1.00, 5.00}.
  #
  # `ZaiModels` is consulted here as well as merged above because its
  # `resolve/1` strips the decorations GLM ids actually arrive with — a vendor
  # prefix, an Ollama `:cloud` tag, an OpenRouter routing suffix — so a
  # spelling no exact key covers still lands on a published rate instead of the
  # `{"glm", {0.60, 2.20}}` family guess. It is tried LAST so nothing that
  # prices correctly today can move.
  # `XAIModels` earns its place here for the ALIAS arm specifically. xAI
  # documents `grok-4.20` and `grok-code-fast-1` as live public ids that serve
  # `grok-4.20-0309-reasoning` and `grok-build-0.1`. Neither string is a key in
  # any pricing map and neither is a prefix of the model it names, so both
  # resolved to `:unknown` and every turn on them was costed at $0.00 — a
  # silent under-count on ids xAI actively steers users toward.
  @ssot_price_modules [
    OptimalSystemAgent.Providers.AnthropicModels,
    OptimalSystemAgent.Providers.OpenAIModels,
    OptimalSystemAgent.Providers.XAIModels,
    OptimalSystemAgent.Providers.ZaiModels
  ]

  defp ssot_rate(key) do
    Enum.find_value(@ssot_price_modules, fn mod ->
      case mod.resolve(key) do
        %{pricing: {_, _} = p} -> p
        _ -> nil
      end
    end)
  end

  # ── Dated rates ──────────────────────────────────────────────────────────
  #
  # Some vendor prices are not constants. `claude-sonnet-5` ran an
  # introductory $2/$10 through 2026-08-31 against a $3/$15 list, and both
  # Gemini Flash models run an introductory rate through 2026-12-31. Encoding
  # one of the two numbers and a comment about the other is exactly how the
  # 1.50x sonnet-5 over-report and the 2x gemini-3.6 over-report shipped —
  # both labelled `:exact`.
  #
  # The SCHEDULE is compile-time data (dates do not change). The RESOLUTION is
  # runtime, against the caller's date: a release built during a promo must not
  # carry the promo rate past its expiry, which is precisely what merging a
  # resolved rate into `@pricing` at compile time would do.
  @scheduled_price_modules [
    OptimalSystemAgent.Providers.AnthropicModels,
    OptimalSystemAgent.Providers.GoogleModels
  ]

  @pricing_schedules Enum.reduce(@scheduled_price_modules, %{}, fn mod, acc ->
                       Map.merge(acc, mod.pricing_schedule())
                     end)

  @doc false
  # Test seam: lets a ratchet assert the schedule is non-empty and well-formed
  # without reaching into each catalog.
  @spec pricing_schedules() :: %{String.t() => [{Date.t(), {number(), number()}}]}
  def pricing_schedules, do: @pricing_schedules

  # The latest scheduled rate whose date has ARRIVED, or nil while the model's
  # own `:pricing` is still in force. Tried against the same decorated
  # spellings as every other lookup, so `anthropic/claude-sonnet-5` and
  # `claude-sonnet-5:nitro` follow the schedule too — the vendor-prefix miss is
  # the exact shape that billed Opus 5 at Claude 3 Opus rates.
  defp scheduled_rate(key, today) do
    Enum.find_value(lookup_keys(key), fn k ->
      case Map.fetch(@pricing_schedules, k) do
        {:ok, entries} -> effective_rate(entries, today)
        :error -> nil
      end
    end)
  end

  defp effective_rate(entries, today) do
    entries
    |> Enum.filter(fn {from, _rate} -> Date.compare(today, from) != :lt end)
    |> Enum.max_by(fn {from, _rate} -> Date.to_gregorian_days(from) end, fn -> nil end)
    |> case do
      {_from, rate} -> rate
      nil -> nil
    end
  end

  @doc """
  Compute the USD cost for one turn's usage against `model`.

  `usage` is a normalized map (see `Loop.Accounting.normalize_usage/1`) with
  `:input_tokens`, `:output_tokens`, `:cache_creation_input_tokens`, and
  `:cache_read_input_tokens`. Unknown models cost `0.0` and are logged.
  """
  @spec cost(String.t() | atom() | nil, map()) :: float()
  def cost(model, usage) when is_map(usage) do
    {cost, _confidence} = cost_with_confidence(model, usage)
    cost
  end

  @doc """
  `cost/2` plus how much the number is worth: `{usd, :exact | :estimated |
  :unknown}` (see `confidence/1`).

  Use this wherever the figure is going to be published. `$/task` is a headline
  metric now, and a `:estimated` dollar figure printed next to an `:exact` one
  with no distinction is how a 3x pricing error survived a whole benchmark run.
  """
  @spec cost_with_confidence(String.t() | atom() | nil, map()) ::
          {float(), :exact | :estimated | :unknown}
  def cost_with_confidence(model, usage) when is_map(usage) do
    {do_cost(model, usage), confidence(model)}
  end

  defp do_cost(model, usage) do
    case rates(model) do
      {input_rate, output_rate} ->
        input = get_tok(usage, :input_tokens)
        output = get_tok(usage, :output_tokens)
        cache_write = get_tok(usage, :cache_creation_input_tokens)
        cache_read = get_tok(usage, :cache_read_input_tokens)

        raw =
          (input * input_rate +
             cache_write * input_rate * @cache_write_multiplier +
             cache_read * input_rate * @cache_read_multiplier +
             output * output_rate) / 1_000_000

        Float.round(raw, 6)

      nil ->
        Logger.warning(
          "[Pricing] No price for model #{inspect(model)} — cost recorded as $0.0 " <>
            "(add it to OptimalSystemAgent.Agent.Pricing)"
        )

        0.0
    end
  end

  @doc """
  Is `model`'s price a real catalog rate, or a `@families` substring GUESS?

  Returns `:exact` (a catalog / SSOT / free-local hit), `:estimated` (the
  family fallback fired — the number is a guess and may be wrong by a large
  multiple), or `:unknown` (no price at all; `cost/2` returns 0.0).

  Every consumer that publishes a dollar figure should carry this qualifier
  with it. A cost we know we do not know is far better than one that is quietly
  3x off — the latter is what invalidated a whole benchmark run's conclusions.
  """
  @spec confidence(String.t() | atom() | nil) :: :exact | :estimated | :unknown
  def confidence(model), do: confidence(model, Date.utc_today())

  @doc "`confidence/1` against an explicit date. See `rates/2`."
  @spec confidence(String.t() | atom() | nil, Date.t()) :: :exact | :estimated | :unknown
  def confidence(nil, _today), do: :unknown
  def confidence(model, today) when is_atom(model), do: confidence(Atom.to_string(model), today)

  def confidence(model, today) when is_binary(model) do
    key = String.downcase(model)

    cond do
      ollama_local?(key) -> :exact
      # A scheduled rate is a PUBLISHED rate with a published start date, not a
      # guess — same standing as the exact table it supersedes.
      scheduled_rate(key, today) -> :exact
      Enum.find_value(lookup_keys(key), &exact_rate/1) -> :exact
      family_rate(key, log?: false) -> :estimated
      true -> :unknown
    end
  end

  def confidence(_, _), do: :unknown

  # --- Private ---

  # The family table is a GUESS BY CONSTRUCTION. `"claude-opus" => {15, 75}` was
  # right for Claude 3 Opus and is 3x wrong for Opus 5 — and that single row is
  # the whole of the 2.487x by which a benchmark run over-reported its own
  # spend, because `anthropic/claude-opus-5` reached it through the vendor
  # prefix. `lookup_keys/1` closed that particular door; it did not, and cannot,
  # close the door for the NEXT unknown `claude-opus-N`.
  #
  # So the table stays (an over-estimate on a known family is still the
  # never-underestimate policy this module documents, and is more useful to a
  # budget cap than $0.00), but it can no longer be SILENT. Every fall-through
  # names the model at :warning, states the rate it guessed, and says what to do
  # about it. `confidence/1` exposes the same fact structurally so a published
  # `$/task` can be labelled rather than trusted.
  defp family_rate(key, opts \\ []) do
    match =
      Enum.find(@families, fn {needle, _rate} ->
        String.contains?(key, needle)
      end)

    case match do
      {needle, {in_rate, out_rate} = rate} ->
        if Keyword.get(opts, :log?, true) and warn_once?(key) do
          Logger.warning(
            "[Pricing] ESTIMATED price for unknown model #{inspect(key)} — matched the " <>
              "#{inspect(needle)} family fallback at {$#{in_rate}, $#{out_rate}}/1M. " <>
              "This is a SUBSTRING GUESS, not a published rate, and has been wrong by 3x " <>
              "before (claude-opus-5 billed at Claude 3 Opus rates). Any cost derived from " <>
              "it is an upper-bound estimate — add the real rate to " <>
              "OptimalSystemAgent.Agent.Pricing (or the provider's model catalog)."
          )
        end

        rate

      nil ->
        nil
    end
  end

  # Loud, but once per model per node — this fires from the hot loop on every
  # round-trip, and a warning repeated 400 times a session is noise nobody
  # reads, which is functionally the same as being silent.
  @warned_key {__MODULE__, :family_warned}

  defp warn_once?(key) do
    seen = :persistent_term.get(@warned_key, MapSet.new())

    if MapSet.member?(seen, key) do
      false
    else
      :persistent_term.put(@warned_key, MapSet.put(seen, key))
      true
    end
  rescue
    _ -> true
  end

  @doc false
  # Test seam — lets a test assert the warning fires without leaking the
  # "already warned" set across examples.
  @spec reset_family_warnings() :: :ok
  def reset_family_warnings do
    :persistent_term.put(@warned_key, MapSet.new())
    :ok
  rescue
    _ -> :ok
  end

  # "Is this a free, locally-hosted model?" — answered from the id's SHAPE: a
  # `name:tag` spelling is Ollama's, and the family substrings are the ones
  # that actually ship as local weights.
  #
  # The `:tag` half of that heuristic collides with OpenRouter's ROUTING
  # SUFFIXES, and the collision was live: `mistral-large-latest:free` contains
  # a colon and the substring "mistral", so every Mistral model reached through
  # a gateway with a routing directive was priced at {0.0, 0.0} — free — and
  # `confidence/1` called it `:exact`. Silent, exact-labelled, and wrong in the
  # direction that flatters us, which is the same shape as the three pricing
  # defects the class ratchet in `silent_capability_loss_test.exs` exists for.
  # (Found BY that ratchet, on its first run.)
  #
  # So the routing directive is stripped before the shape is judged. A genuine
  # local tag is untouched: `qwen2.5:7b` keeps its `:7b` (not a routing
  # suffix), `ollama/llama3` still matches on its prefix, and a `:cloud` tag is
  # still excluded as hosted.
  defp ollama_local?(key) do
    bare = strip_routing_suffix(key)

    String.starts_with?(bare, "ollama/") or
      (String.contains?(bare, ":") and
         (String.contains?(bare, "llama") or String.contains?(bare, "qwen") or
            String.contains?(bare, "mistral") or String.contains?(bare, "gemma") or
            String.contains?(bare, "phi")) and not String.contains?(bare, "cloud"))
  end

  defp get_tok(usage, key) do
    Map.get(usage, key) || Map.get(usage, Atom.to_string(key)) || 0
  end
end
