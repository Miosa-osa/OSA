defmodule OptimalSystemAgent.Providers.Retirements do
  @moduledoc """
  **Cross-provider model retirement schedule.**

  ## Why this exists

  `Providers.AnthropicModels` already carries its own `@retirements` map and a
  test that asserts no offered Claude model is retired — or retires within 90
  days. That guard caught real breakage, but it only ever looked at Anthropic.
  Every other provider was unguarded, and every other provider had rotted:

    * **Google** shut down `gemini-2.0-flash` on 2026-06-01 — it was OSA's
      Google default for two months of 404s.
    * **Groq** shut down `mixtral-8x7b-32768` on 2025-03-20 and has both
      Llama ids scheduled for 2026-08-16 — *fifteen days from now*.
    * **DeepSeek** fully retired `deepseek-chat` / `deepseek-reasoner` on
      2026-07-24 — OSA's DeepSeek default and BOTH reasoning tiers.
    * **Cohere** shut down the undated `command-r-plus` / `command-r` aliases
      on 2025-09-15 — all three Cohere tiers were dead ids.
    * **xAI** retired `grok-3` on 2026-05-15.

  This module is the provider-agnostic half of that guard. Anthropic keeps its
  own map (it is large, well-documented, and already load-bearing); everything
  else lands here. `model_retirement_test.exs` walks every *offered* model on
  every provider surface — picker lists, tier defaults, provider
  `available_models/0` — and fails if any is past its date or within 90 days of
  it.

  ## The 90-day rule

  A model retiring next month is not a safe fresh pick: the user selects it
  today and breaks in weeks, long after the choice that caused it. So the guard
  is deliberately stricter than "is it dead right now". Groq's 2026-08-16 Llama
  shutdown and Google's 2026-10-16 Gemini 2.5 shutdown both trip it, which is
  the intended behaviour — both must be off the offered lists before then.

  ## Adding a date

  Only record dates the **vendor has published**. An absent id means "no
  announced retirement", NOT "safe forever" — the map is a floor on what we
  know, never a claim of completeness. Cite the source next to the entry.
  """

  @typedoc "Provider atom a retirement belongs to."
  @type provider :: atom()

  # ── The schedule ─────────────────────────────────────────────────────────
  #
  # Keyed by exact vendor model id. Anthropic is deliberately NOT duplicated
  # here — `Providers.AnthropicModels.retirements/0` owns that provider.
  @retirements %{
    # ── Google / Gemini ───────────────────────────────────────────────────
    # Source: https://ai.google.dev/gemini-api/docs/deprecations (2026-08-01)
    #
    # Already shut down. `gemini-2.0-flash` was OSA's Google default and 404'd
    # for two months before this pass.
    "gemini-2.0-flash" => ~D[2026-06-01],
    "gemini-2.0-flash-lite" => ~D[2026-06-01],
    "gemini-1.5-pro" => ~D[2025-09-24],
    "gemini-1.5-flash" => ~D[2025-09-24],
    # Deprecated, still serving. These MUST leave the offered lists before the
    # date — the 90-day guard already fails on them, which is why the tier map
    # and picker no longer point at them.
    "gemini-2.5-pro" => ~D[2026-10-16],
    "gemini-2.5-flash" => ~D[2026-10-16],
    "gemini-2.5-flash-lite" => ~D[2026-10-16],
    "gemini-2.5-flash-image" => ~D[2026-10-02],
    # Preview models that were already shut down.
    "gemini-3-flash-preview" => ~D[2025-12-17],
    "gemini-3-pro-preview" => ~D[2026-03-09],
    # Announced far out; recorded so the 90-day guard picks it up automatically
    # when the time comes rather than needing someone to remember.
    "gemini-3.1-flash-lite" => ~D[2027-05-07],

    # ── Groq ──────────────────────────────────────────────────────────────
    # Source: https://console.groq.com/docs/deprecations (2026-08-01)
    "mixtral-8x7b-32768" => ~D[2025-03-20],
    "llama-3.3-70b-versatile" => ~D[2026-08-16],
    "llama-3.1-8b-instant" => ~D[2026-08-16],
    "qwen-qwq-32b" => ~D[2025-08-29],

    # ── DeepSeek ──────────────────────────────────────────────────────────
    # Source: https://api-docs.deepseek.com/quick_start/pricing +
    # DeepSeek's V4 migration notice (2026-08-01). Both ids were fully retired
    # — not deprecated — on 2026-07-24, and thinking moved from a separate
    # model id onto a request parameter. See `Providers.DeepSeekModels`.
    "deepseek-chat" => ~D[2026-07-24],
    "deepseek-reasoner" => ~D[2026-07-24],

    # ── Cohere ────────────────────────────────────────────────────────────
    # Source: https://docs.cohere.com/docs/deprecations (2026-08-01).
    # The UNDATED aliases were shut down; the dated snapshots below still serve.
    "command-r-plus" => ~D[2025-09-15],
    "command-r" => ~D[2025-09-15],
    "command-nightly" => ~D[2025-09-15],

    # ── xAI ───────────────────────────────────────────────────────────────
    # Source: https://docs.x.ai/docs/models (2026-08-01).
    "grok-3" => ~D[2026-05-15],
    "grok-3-mini" => ~D[2026-05-15],
    "grok-2" => ~D[2025-09-15],
    "grok-2-vision" => ~D[2025-09-15],

    # ── Cerebras ──────────────────────────────────────────────────────────
    # Source: https://inference-docs.cerebras.ai/support/deprecation (2026-08-01)
    "llama3.1-8b" => ~D[2026-05-27],
    "qwen-3-235b-a22b-instruct-2507" => ~D[2026-05-27],
    "llama-3.3-70b" => ~D[2026-02-16],
    "qwen-3-32b" => ~D[2026-02-16],
    # Deprecates in 16 days — deliberately never offered.
    "zai-glm-4.7" => ~D[2026-08-17],

    # ── Mistral ───────────────────────────────────────────────────────────
    # Source: https://docs.mistral.ai/models/overview (2026-08-01).
    # The Magistral and Devstral lines are ENTIRELY retired — reasoning folded
    # into Mistral Small 4, coding-agent work into Mistral Medium 3.5. They
    # still appear on Mistral's PRICING page, which makes them look alive.
    "magistral-medium-2509" => ~D[2026-07-31],
    "magistral-small-2509" => ~D[2026-07-31],
    "devstral-2512" => ~D[2026-07-31],
    "devstral-medium-latest" => ~D[2026-07-31],
    "open-mistral-nemo-2407" => ~D[2026-07-31],
    "mistral-small-2506" => ~D[2026-07-31],
    # Retires 2026-08-31 — thirty days out.
    "mistral-medium-2508" => ~D[2026-08-31],
    "mistral-large-2411" => ~D[2026-05-31],
    "labs-leanstral-1-5" => ~D[2026-09-30],
    "open-mixtral-8x7b" => ~D[2025-03-30],
    "open-mixtral-8x22b" => ~D[2025-03-30],
    "codestral-2501" => ~D[2025-11-30]
  }

  @doc """
  The full cross-provider retirement schedule, keyed by exact vendor model id.

  Anthropic is not included — see `Providers.AnthropicModels.retirements/0`.
  """
  @spec retirements() :: %{String.t() => Date.t()}
  def retirements, do: @retirements

  @doc """
  The retirement date for a model id, or `nil` when none is announced.

  Consults this module first, then `Providers.AnthropicModels`, so a caller can
  ask one function about any provider's model.

  Matching is exact-first, then bidirectional prefix, so an undated alias and a
  dated snapshot of the same model both resolve (`command-r-plus` vs
  `command-r-plus-04-2024`). Longest match wins so a short id can never shadow
  a longer, more specific one — without that, `command-r` (retired) would
  swallow `command-r-08-2024` (live) and the guard would reject a good model.
  """
  @spec retirement_date(String.t() | nil) :: Date.t() | nil
  def retirement_date(id) when is_binary(id) do
    down = id |> String.trim() |> String.downcase()

    exact_or_prefix(down) || OptimalSystemAgent.Providers.AnthropicModels.retirement_date(down)
  end

  def retirement_date(_), do: nil

  defp exact_or_prefix(down) do
    case Map.get(@retirements, down) do
      %Date{} = d ->
        d

      nil ->
        # Only treat a retired id as matching when the live id is a prefix of
        # it (alias → dated snapshot). The reverse (`command-r` matching
        # `command-r-08-2024`) would wrongly condemn a live dated model, so it
        # is NOT allowed here.
        @retirements
        |> Enum.filter(fn {retired_id, _} -> String.starts_with?(retired_id, down) end)
        |> Enum.max_by(fn {retired_id, _} -> String.length(retired_id) end, fn -> nil end)
        |> case do
          {_id, date} -> date
          nil -> nil
        end
    end
  end

  @doc """
  True when `id` is at or past its published retirement date.

  `today` is injectable so the check is testable without a clock, and so the
  90-day "retires soon" guard can be expressed as `retired?(id, today + 90)`.
  """
  @spec retired?(String.t() | nil, Date.t()) :: boolean()
  def retired?(id, today \\ Date.utc_today()) do
    case retirement_date(id) do
      nil -> false
      date -> Date.compare(today, date) != :lt
    end
  end

  @doc """
  True when `id` retires within `days` (default 90) — i.e. it is too close to
  sunset to be offered as a fresh pick, even though it still works today.
  """
  @spec retiring_soon?(String.t() | nil, pos_integer()) :: boolean()
  def retiring_soon?(id, days \\ 90) do
    retired?(id, Date.add(Date.utc_today(), days))
  end
end
