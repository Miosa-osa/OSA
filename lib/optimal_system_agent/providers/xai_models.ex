defmodule OptimalSystemAgent.Providers.XAIModels do
  @moduledoc """
  **Single source of truth for the xAI (Grok) model catalog.**

  ## What was broken

  OSA's xAI default was the bare id `grok-4`, which **does not appear in xAI's
  model list and does not resolve**. `grok-3` was retired 2026-05-15.

  There is a nastier failure mode here than a 404, and it is worth stating
  because it defeats the usual "it errors, so we'd notice" assumption: xAI's
  retired slugs **still resolve and silently redirect**. `grok-3` now serves
  `grok-4.3` at `none` reasoning effort and bills at grok-4.3 rates. A config
  pinned to a retired id therefore keeps "working" while quietly running a
  different model with reasoning turned off. Only the *bare* `grok-4` fails
  outright.

  ## xAI publishes no max output tokens — for any model

  Deliberately unresolved. No xAI models table or model card carries a max
  output column. The only published figure is a *request-parameter default*:
  `max_completion_tokens` defaults to 128,000 when unset. That is a default,
  not a ceiling, so recording it as `max_output` would be a fabrication of
  exactly the kind this catalog exists to prevent.

  `max_output/1` therefore returns `nil` for every xAI model, which
  `ModelLimits.max_output/1` propagates as "unknown — use your own fallback".
  The practical effect is that OSA does not clamp output on xAI; xAI applies
  its own 128,000 default. Context windows ARE published and are recorded.

  ## Pricing has a retroactive tier cliff

  xAI bills the **whole request** at the higher rate once the prompt reaches
  200k tokens — not just the marginal tokens. The rates below are the sub-200k
  tier, so a long-context turn under-accounts by 2x. Recorded rather than
  blended because most turns sit under 200k, and a blended rate would be wrong
  for every turn instead of some. Re-confirmed 2026-08-15: the threshold is
  still 200k, still applies to **every** text model including the new 4.6, and
  the pricing page states it verbatim — "requests whose prompt reaches the
  listed token threshold are billed at the higher rate for all tokens in the
  request".

  ## The cached-input rate is published, and is NOT `input * 0.1`

  `Agent.Pricing` prices cache reads with a flat Anthropic-style `0.1x`
  multiplier. xAI publishes a real per-model figure and it does not agree:
  `grok-4.6` reads cache at **$0.50**/1M against a $2.00 input rate — `0.25x`,
  two and a half times what the multiplier assumes — while `grok-4.5`, at the
  same $2.00 input, reads at $0.30 (`0.15x`). Two models, same input price,
  different cache rates: no single multiplier can be right for both. Recorded
  as `:cache_read` so the number exists to be used; wiring it into the cost
  calculation is a `Pricing` change, not a catalog one.

  ## `reasoning_effort` is documented for grok-4.3 ONLY

  Verbatim from the chat API reference: "Constrains how hard a reasoning model
  thinks before responding. **Only supported by `grok-4.3`**. Possible values
  are `none` …, `low` (this is the default if not specified), `medium` and
  `high`."

  Every other model's page says "Reasoning: Yes" and publishes no vocabulary at
  all. So the `efforts` lists for 4.6 / 4.5 / 4.20 / build-0.1 below are
  **unverified against xAI** — they are what xAI's own OpenRouter endpoint
  advertises in `supported_parameters` and what the models accept in practice.
  They are kept because an ignored request field is harmless while a missing
  one silently costs the whole reasoning ladder *and* the 600s timeout, but the
  asymmetry is why they are labelled here rather than presented as published.

  Sources: https://docs.x.ai/developers/models,
  https://docs.x.ai/developers/pricing, the per-model pages under
  https://docs.x.ai/developers/models/<id>,
  https://docs.x.ai/developers/rest-api-reference/inference/chat and
  https://x.ai/news/grok-4-6 (all re-checked 2026-08-15), with context windows
  independently confirmed against the live OpenRouter endpoints API for xAI's
  own first-party endpoint.
  """

  @typedoc """
  A single xAI model offering. `max_output` is always nil — see moduledoc.

  `pricing` is the sub-200k `{input, output}` USD per 1M; `pricing_long` is the
  same pair above the 200k threshold, which xAI applies retroactively to the
  whole request. `cache_read` is xAI's published cached-input rate per 1M.
  """
  @type model :: %{
          id: String.t(),
          name: String.t(),
          ctx: pos_integer(),
          max_output: nil,
          reasoning: boolean(),
          efforts: [String.t()],
          vision: boolean(),
          tools: boolean(),
          pricing: {number(), number()} | nil,
          pricing_long: {number(), number()} | nil,
          cache_read: number() | nil,
          recommended: boolean(),
          note: String.t()
        }

  @models [
    %{
      id: "grok-4.6",
      name: "Grok 4.6",
      ctx: 500_000,
      max_output: nil,
      reasoning: true,
      # Unverified — see moduledoc. Mirrors 4.5: no documented "none".
      efforts: ["low", "medium", "high"],
      vision: true,
      tools: true,
      pricing: {2.00, 6.00},
      pricing_long: {4.00, 12.00},
      cache_read: 0.50,
      recommended: true,
      note: "500K ctx — xAI's newest flagship (released 2026-08-12). Default."
    },
    %{
      id: "grok-4.5",
      name: "Grok 4.5",
      ctx: 500_000,
      max_output: nil,
      reasoning: true,
      # 4.5 cannot disable reasoning — no "none". Unverified; see moduledoc.
      efforts: ["low", "medium", "high"],
      vision: true,
      tools: true,
      pricing: {2.00, 6.00},
      pricing_long: {4.00, 12.00},
      cache_read: 0.30,
      recommended: false,
      note: "500K ctx — previous flagship (aliases grok-4.5-latest, grok-build-latest)"
    },
    %{
      id: "grok-4.3",
      name: "Grok 4.3",
      ctx: 1_000_000,
      max_output: nil,
      reasoning: true,
      # The ONLY model whose effort vocabulary xAI actually documents.
      efforts: ["none", "low", "medium", "high"],
      vision: true,
      tools: true,
      pricing: {1.25, 2.50},
      pricing_long: {2.50, 5.00},
      cache_read: 0.20,
      recommended: false,
      note: "1M ctx — half the price of 4.6, strong tool calling"
    },
    %{
      id: "grok-4.20-0309-reasoning",
      name: "Grok 4.20 (reasoning)",
      ctx: 1_000_000,
      max_output: nil,
      reasoning: true,
      efforts: ["low", "medium", "high"],
      vision: true,
      tools: true,
      pricing: {1.25, 2.50},
      pricing_long: {2.50, 5.00},
      cache_read: 0.20,
      recommended: false,
      note: "1M ctx — function calling + structured outputs"
    },
    %{
      id: "grok-build-0.1",
      name: "Grok Build 0.1",
      ctx: 256_000,
      max_output: nil,
      reasoning: true,
      efforts: ["low", "medium", "high"],
      vision: true,
      tools: true,
      pricing: {1.00, 2.00},
      pricing_long: {2.00, 4.00},
      cache_read: 0.20,
      recommended: false,
      note: "256K ctx — cheapest coding option; previous generation"
    }
  ]

  # xAI's aliases are not all SUFFIXES of the canonical id, so `resolve/1`'s
  # prefix match cannot reach them. `grok-4.20` is the documented public id and
  # is SHORTER than the model it names (`grok-4.20-0309-reasoning`), so
  # `starts_with?/2` fails in the only direction that matters and the id
  # resolved to nothing — no context window, no pricing, straight to the
  # `@families` substring guess. Same for the coding line: `grok-code-fast-1`
  # is a live alias of `grok-build-0.1`, and xAI states plainly that such
  # aliases "help users automatically migrate", i.e. they serve a DIFFERENT
  # model than their name suggests while continuing to work.
  #
  # Only aliases xAI documents on the model pages are listed. The `-latest`
  # forms are omitted because the prefix match already handles them.
  @aliases %{
    "grok-4.20" => "grok-4.20-0309-reasoning",
    "grok-4.20-reasoning" => "grok-4.20-0309-reasoning",
    "grok-4.20-0309" => "grok-4.20-0309-reasoning",
    "grok-4.20-beta" => "grok-4.20-0309-reasoning",
    "grok-code-fast" => "grok-build-0.1",
    "grok-code-fast-1" => "grok-build-0.1",
    "grok-code-fast-1-0825" => "grok-build-0.1",
    "grok-build" => "grok-4.5",
    "grok-build-latest" => "grok-4.5"
  }

  @by_id Map.new(@models, &{&1.id, &1})

  @doc "The full catalog, in picker display order."
  @spec models() :: [model()]
  def models, do: @models

  @doc "Look up one model by exact id. Returns nil for unknown ids."
  @spec model(String.t() | nil) :: model() | nil
  def model(id) when is_binary(id), do: Map.get(@by_id, id)
  def model(_), do: nil

  @doc """
  Look up a model by id, tolerating the three decorations OSA actually sees:

    * a `-latest` / dated suffix — `grok-4.5-latest`, `grok-4.20-0309`
    * a gateway vendor prefix — `x-ai/grok-4.6`
    * a documented alias that is not a suffix of the canonical id —
      `grok-4.20`, `grok-code-fast-1` (see `@aliases`)

  The prefix arm runs on the vendor-stripped id, longest match wins, and it
  accepts a prefix only when what follows starts with `-` — a dated or named
  variant, never a version digit. A plain `String.starts_with?/2` would resolve
  a future `grok-4.55` onto `grok-4.5`, giving an unknown model a published
  window and price under an `:exact` confidence label. (The GLM catalog hit
  exactly this: `glm-5.3` resolved to `glm-5`.)
  """
  @spec resolve(String.t() | nil) :: model() | nil
  def resolve(id) when is_binary(id) do
    down = id |> String.trim() |> String.downcase()
    bare = down |> String.split("/") |> List.last()

    Enum.find_value([down, bare], fn key ->
      model(key) || model(Map.get(@aliases, key)) || prefix_match(key)
    end)
  end

  def resolve(_), do: nil

  defp prefix_match(key) do
    @models
    |> Enum.filter(&variant_of?(key, &1.id))
    |> Enum.max_by(&String.length(&1.id), fn -> nil end)
  end

  # See `ZaiModels.variant_of?/2` for why the digit-count floor exists: a `-`
  # only rule lets `Pricing`'s dotted-to-dashed retry turn a version bump into
  # what looks like a dated snapshot of its predecessor.
  defp variant_of?(candidate, id) do
    case String.split_at(candidate, String.length(id)) do
      {^id, "-" <> rest} -> variant_suffix?(rest)
      _ -> false
    end
  end

  defp variant_suffix?(""), do: false

  defp variant_suffix?(rest) do
    case Integer.parse(rest) do
      {_, ""} -> String.length(rest) >= 4
      _ -> not String.starts_with?(rest, ~w(0 1 2 3 4 5 6 7 8 9))
    end
  end

  @doc """
  The default xAI model for a fresh install.

  **Moved from `grok-4.5` to `grok-4.6` on 2026-08-15.** This is a behaviour
  change for existing xAI users who never pinned a model. It is made because
  4.6 is xAI's current flagship (released 2026-08-12), carries the same
  500K window and the **identical** `{2.00, 6.00}` price, and 4.5 is now the
  previous generation. The only regression is the cached-input rate, which is
  $0.50/1M on 4.6 against $0.30/1M on 4.5.
  """
  @spec default_model() :: String.t()
  def default_model, do: "grok-4.6"

  @doc "Model ids, in display order."
  @spec ids() :: [String.t()]
  def ids, do: Enum.map(@models, & &1.id)

  @doc "`%{model_id => context_window}` for merging into the Registry table."
  @spec context_windows() :: %{String.t() => pos_integer()}
  def context_windows, do: Map.new(@models, &{&1.id, &1.ctx})

  @doc """
  Always `%{}` — xAI publishes no max output token value for any model.

  Present so callers can merge this uniformly with the other catalogs without
  special-casing, and so the absence is explicit rather than an oversight.
  """
  @spec max_outputs() :: %{}
  def max_outputs, do: %{}

  @doc "`%{model_id => {input, output}}` USD per 1M tokens, sub-200k tier."
  @spec pricing() :: %{String.t() => {number(), number()}}
  def pricing do
    @models
    |> Enum.filter(& &1.pricing)
    |> Map.new(&{&1.id, &1.pricing})
  end

  @doc """
  `%{model_id => {input, output}}` USD per 1M for prompts **at or above** the
  200k threshold, which xAI applies retroactively to the entire request.

  Not merged into `Agent.Pricing`: `rates/1` keys on a model id alone and has
  no prompt size to switch on. Recorded so the 2x cliff is data rather than a
  paragraph, and so a caller that does know the prompt size can reach it.
  """
  @spec long_context_pricing() :: %{String.t() => {number(), number()}}
  def long_context_pricing do
    @models
    |> Enum.filter(& &1.pricing_long)
    |> Map.new(&{&1.id, &1.pricing_long})
  end

  @doc "The prompt size at which xAI rebills the whole request at `pricing_long/0`."
  @spec long_context_threshold() :: pos_integer()
  def long_context_threshold, do: 200_000

  @doc """
  xAI's published cached-input rate per 1M tokens, or nil when unknown.

  Explicitly NOT `input * 0.1`, the multiplier `Agent.Pricing` applies: 4.6 and
  4.5 share a $2.00 input rate and read cache at $0.50 and $0.30 respectively.
  """
  @spec cache_read_rate(String.t() | nil) :: number() | nil
  def cache_read_rate(id) do
    case resolve(id) do
      nil -> nil
      m -> m.cache_read
    end
  end

  @doc """
  Capability lookup, mirroring `OllamaCloud.capability/2`: `true`/`false` when
  this catalog knows the model, `nil` when it does not.

  Every current Grok text model takes image input, so the `:vision` answer is
  uniformly `true` — but it is recorded per-model rather than hardcoded,
  because `ImageBudget` now reads these flags and the first Grok that cannot
  see must be able to say so in one line.
  """
  @spec capability(String.t() | nil, :tools | :vision | :reasoning) :: boolean() | nil
  def capability(id, flag) when flag in [:tools, :vision, :reasoning] do
    case resolve(id) do
      nil -> nil
      m -> Map.get(m, flag)
    end
  end

  @doc "Context window for a model, or nil when unknown."
  @spec context_window(String.t() | nil) :: pos_integer() | nil
  def context_window(id) do
    case resolve(id) do
      nil -> nil
      m -> m.ctx
    end
  end

  @doc "Always nil — see the moduledoc. Never guess a ceiling xAI does not publish."
  @spec max_output(String.t() | nil) :: nil
  def max_output(_id), do: nil

  @doc "True when this model does chain-of-thought reasoning (all current ones do)."
  @spec reasoning?(String.t() | nil) :: boolean()
  def reasoning?(id) do
    case resolve(id) do
      nil -> false
      m -> m.reasoning
    end
  end

  @doc """
  Map an OSA effort level onto this model's `reasoning_effort`, clamped into the
  set the model accepts (`grok-4.5` has no `"none"`).

  Returns nil for a non-reasoning / unknown model.
  """
  @spec reasoning_effort(String.t() | nil, term()) :: String.t() | nil
  def reasoning_effort(id, effort) do
    case resolve(id) do
      %{reasoning: true, efforts: efforts} -> clamp(map_effort(effort), efforts)
      _ -> nil
    end
  end

  defp map_effort(effort) do
    case effort |> to_string() |> String.trim() |> String.downcase() do
      "off" -> "none"
      "none" -> "none"
      "fast" -> "low"
      "low" -> "low"
      "medium" -> "medium"
      "high" -> "high"
      "xhigh" -> "high"
      "max" -> "high"
      "ultra" -> "high"
      _ -> "high"
    end
  end

  @order ["none", "low", "medium", "high"]

  defp clamp(level, efforts) do
    if level in efforts do
      level
    else
      wanted = Enum.find_index(@order, &(&1 == level)) || 0

      Enum.find(@order, List.first(efforts), fn l ->
        l in efforts and (Enum.find_index(@order, &(&1 == l)) || 0) >= wanted
      end)
    end
  end
end
