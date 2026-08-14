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
    # GLM (Z.ai / Zhipu cloud) — OSA's default provider family
    "glm-4.7:cloud" => {0.60, 2.20},
    "glm-4.6:cloud" => {0.60, 2.20},
    "glm-4.6" => {0.60, 2.20},
    "glm-4.5" => {0.60, 2.20},

    # GLM reached through OpenRouter, which publishes its own rate for the
    # route. Keyed on the FULL gateway id so it applies to that route only —
    # the bare `glm-5.2` served elsewhere keeps whatever its own catalog says.
    # Observed on the OpenRouter model page 2026-08-14. Without this row the
    # route fell to the `glm` family guess of {0.60, 2.20}, which UNDER-billed
    # input by 5% and OVER-billed output by 11% (net −4.5% across the
    # or-glm52-full / or-glm52-nospec runs).
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
  def rates(nil), do: nil

  def rates(model) when is_atom(model), do: rates(Atom.to_string(model))

  def rates(model) when is_binary(model) do
    key = String.downcase(model)

    cond do
      # Local Ollama-hosted models (e.g. "ollama/llama3", "qwen2.5:7b") are free.
      ollama_local?(key) ->
        {0.0, 0.0}

      rate = Enum.find_value(lookup_keys(key), &exact_rate/1) ->
        rate

      true ->
        family_rate(key)
    end
  end

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
  defp ssot_rate(key) do
    case OptimalSystemAgent.Providers.AnthropicModels.resolve(key) do
      %{pricing: {_, _} = p} ->
        p

      _ ->
        case OptimalSystemAgent.Providers.OpenAIModels.resolve(key) do
          %{pricing: {_, _} = p} -> p
          _ -> nil
        end
    end
  end

  # Unexpected model type (number, map, tuple, …) — never guess a price and
  # never raise. A malformed loop state must not crash cost accounting in the
  # hot path; treat as unknown (nil → $0.0 in cost/2, same as an unknown name).
  def rates(_), do: nil

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
  def confidence(nil), do: :unknown
  def confidence(model) when is_atom(model), do: confidence(Atom.to_string(model))

  def confidence(model) when is_binary(model) do
    key = String.downcase(model)

    cond do
      ollama_local?(key) -> :exact
      Enum.find_value(lookup_keys(key), &exact_rate/1) -> :exact
      family_rate(key, log?: false) -> :estimated
      true -> :unknown
    end
  end

  def confidence(_), do: :unknown

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

  defp ollama_local?(key) do
    String.starts_with?(key, "ollama/") or
      (String.contains?(key, ":") and
         (String.contains?(key, "llama") or String.contains?(key, "qwen") or
            String.contains?(key, "mistral") or String.contains?(key, "gemma") or
            String.contains?(key, "phi")) and not String.contains?(key, "cloud"))
  end

  defp get_tok(usage, key) do
    Map.get(usage, key) || Map.get(usage, Atom.to_string(key)) || 0
  end
end
