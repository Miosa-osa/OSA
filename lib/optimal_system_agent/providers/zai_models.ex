defmodule OptimalSystemAgent.Providers.ZaiModels do
  @moduledoc """
  **Single source of truth for the Z.ai (GLM / Zhipu) model catalog.**

  ## Why this module did not exist, and what that cost

  GLM is OSA's *default model family* — a fresh install runs `glm-5.2:cloud` —
  and it was the only major family with no catalog of its own. Its facts were
  scattered across three places that each knew a fragment:

    * `Agent.Pricing.@static_pricing` — four hand-written rows
      (`glm-4.7:cloud`, `glm-4.6:cloud`, `glm-4.6`, `glm-4.5`), all at
      `{0.60, 2.20}`.
    * `Agent.Pricing.@families` — `{"glm", {0.60, 2.20}}`, the substring guess
      that caught **everything else**, including `glm-5.2`.
    * `Providers.ModelLimits.@static_max_output` — three rows, no 5.x entry
      except `glm-5.2 => 128_000`.

  Two measured consequences:

  **1. OSA under-billed its own default model by 2.4x.** `{0.60, 2.20}` is
  GLM-**4.7**'s published rate. Z.ai charges `{1.40, 4.40}` for GLM-5.2 and
  GLM-5.1 — confirmed twice over, on Z.ai's own pricing page and on the Z.AI
  first-party endpoint behind OpenRouter. Every `glm-5.2:cloud` turn OSA has
  ever accounted came out at 43% of input and 50% of output cost, and
  `confidence/1` reported `:exact` for it because the wrong number was sitting
  in an exact-match table. That is worse than the `claude-opus-5` incident: that
  one at least over-stated, and this one is the *default*.

  **2. `reasoning_model?/1` cannot see GLM by name.** `OpenAICompat`'s name
  tables consult `OpenAIModels`, `DeepSeekModels`, `XAIModels` and a literal
  `String.contains?(name, "kimi")`. Nothing there matches `z-ai/glm-5.2`, so
  reasoning recognition falls entirely to `Catalog`, an ETS table that is
  **empty under `mix test`, empty before its GenServer boots, and empty for any
  consumer that never starts the supervision tree**. GLM reasons, and takes a
  richer `reasoning_effort` vocabulary than any other vendor OSA serves.
  `reasoning?/1` and `reasoning_effort/2` below are compile-time data that
  cannot be unavailable; wiring them into `OpenAICompat.name_reasoning?/1` is
  the remaining step (deliberately not done in this commit — that file was
  under concurrent edit).

  ## GLM-5.3: the Flash line shipped; the bare `glm-5.3` still has not

  As of 2026-08-27 the **Flash** variant is servable and is enumerated below as
  `glm-5.3-flash` — Ollama publishes `ollama.com/library/glm-5.3-flash` with a
  `glm-5.3-flash:cloud` tag, and Z.ai lists a price ($0.15/$0.50 per 1M) and a
  low/high/max reasoning-effort ladder. It is the first natively-multimodal GLM
  text tag (image + video), 320B/18B MoE, 1M window, 131K output cap.

  The BARE `glm-5.3` remains unshipped: `ollama.com/library/glm-5.3` is still a
  404 and Z.ai's own docs still say **"The GLM-5.3 API is coming soon"** with no
  API model id or pricing for the non-Flash line. A model with no id and no
  published price is exactly what the family-substring guess would mis-bill, so
  the bare tag goes in the day Z.ai ships its id — not before. Only the Flash
  tag, which HAS both, is present.

  ## The effort vocabulary is per-model, and only 5.2 has one

  `reasoning_effort` is documented as **"only supported by GLM-5.2"**. GLM-5.1
  and earlier take only `thinking: {type: "enabled" | "disabled"}` — sending
  them an effort is at best ignored. `reasoning_effort/2` returns `nil` for
  those models for that reason, and `thinking_params/2` emits the shape each
  model actually accepts.

  GLM-5.2's ladder is unusually long — `minimal` and `xhigh` are rungs no other
  vendor OSA serves offers — so OSA's ladder maps onto it 1:1 instead of being
  collapsed into low/medium/high.

  ## Vision is a SEPARATE model line

  No `glm-N` text model takes images. Vision lives in the `v`-suffixed line
  (`glm-5v-turbo`, `glm-4.6v`, `glm-4.5v`). Recording `vision: false` on the
  text models is load-bearing now that `ImageBudget.vision_capable?/2` reads
  these flags: an image attached to `glm-5.2` is sent to a model that cannot
  see it.

  Sources: https://docs.z.ai/guides/overview/pricing,
  https://docs.z.ai/guides/llm/glm-5.2, https://docs.z.ai/guides/llm/glm-5.1,
  https://docs.z.ai/guides/llm/glm-5.3,
  https://docs.z.ai/api-reference/llm/chat-completion (all checked 2026-08-15),
  cross-checked against the **Z.AI first-party endpoint** reported by
  OpenRouter's public `GET /api/v1/models/z-ai/glm-5.2/endpoints`, which returns
  `context_length: 1048576, max_completion_tokens: 131072` and prices of
  `{1.40, 4.40}` with a `0.26` cached-input rate — agreeing with the vendor page
  to the cent.
  """

  @typedoc """
  A single Z.ai model offering.

  `pricing` is `{input, output}` USD per 1M tokens; `cache_read` is the
  cached-input rate per 1M, published separately by Z.ai rather than derived
  from a multiplier. `efforts` is `[]` for a model that takes no
  `reasoning_effort` at all — which is every GLM except 5.2.
  """
  @type model :: %{
          id: String.t(),
          name: String.t(),
          ctx: pos_integer(),
          max_output: pos_integer(),
          reasoning: boolean(),
          efforts: [String.t()],
          default_effort: String.t() | nil,
          vision: boolean(),
          tools: boolean(),
          caching: boolean(),
          pricing: {number(), number()} | nil,
          cache_read: number() | nil,
          recommended: boolean(),
          note: String.t()
        }

  # Z.ai's ladder, cheapest reasoning first. Only GLM-5.2 accepts it.
  @glm52_efforts ~w(none minimal low medium high xhigh max)

  @models [
    %{
      id: "glm-5.2",
      name: "GLM-5.2",
      ctx: 1_048_576,
      max_output: 131_072,
      reasoning: true,
      efforts: @glm52_efforts,
      default_effort: "high",
      vision: false,
      tools: true,
      caching: true,
      pricing: {1.40, 4.40},
      cache_read: 0.26,
      recommended: true,
      note: "1M ctx — Z.ai flagship, long-horizon agentic + coding. Default."
    },
    %{
      id: "glm-5.3-flash",
      name: "GLM-5.3 Flash",
      ctx: 1_048_576,
      max_output: 131_072,
      reasoning: true,
      # Reasoning is ALWAYS on and tunable across low/high/max only — not 5.2's
      # longer none..xhigh..max ladder. `clamp/2` maps OSA's rungs onto these.
      efforts: ~w(low high max),
      default_effort: "high",
      # FIRST natively-multimodal GLM text tag: accepts image AND video inline.
      # Every glm-N text model before it is vision: false; this one is not.
      vision: true,
      tools: true,
      caching: true,
      # Z.ai list price: $0.15 in / $0.50 out per 1M, cached input $0.03 —
      # published on Z.ai's page and cross-checked on multiple trackers. A
      # 50%-off launch promo ($0.075 / $0.25, cached $0.015) runs through
      # 2026-09-09; the LIST rate is recorded so spend is not under-counted once
      # the promo lapses.
      pricing: {0.15, 0.50},
      cache_read: 0.03,
      recommended: true,
      note: "1M ctx — multimodal (image+video) GLM-5 at flash price; long agent tasks"
    },
    %{
      id: "glm-5.1",
      name: "GLM-5.1",
      # 200K, NOT 1M — the jump to a megatoken window is what 5.2 added.
      ctx: 204_800,
      max_output: 131_072,
      reasoning: true,
      # Thinking is on/off only. `reasoning_effort` is 5.2-exclusive.
      efforts: [],
      default_effort: nil,
      vision: false,
      tools: true,
      caching: true,
      pricing: {1.40, 4.40},
      cache_read: 0.26,
      recommended: false,
      note: "200K ctx — same price as 5.2 for a fifth of the window"
    },
    %{
      id: "glm-5-turbo",
      name: "GLM-5 Turbo",
      ctx: 202_752,
      max_output: 131_072,
      reasoning: true,
      efforts: [],
      default_effort: nil,
      vision: false,
      tools: true,
      caching: true,
      pricing: {1.20, 4.00},
      cache_read: 0.24,
      recommended: false,
      note: "198K ctx — latency-tuned GLM-5"
    },
    %{
      id: "glm-5",
      name: "GLM-5",
      ctx: 204_800,
      max_output: 128_000,
      reasoning: true,
      efforts: [],
      default_effort: nil,
      vision: false,
      tools: true,
      caching: true,
      pricing: {1.00, 3.20},
      cache_read: 0.20,
      recommended: false,
      note: "200K ctx — first GLM-5 generation"
    },
    %{
      id: "glm-4.7",
      name: "GLM-4.7",
      ctx: 202_752,
      max_output: 131_072,
      reasoning: true,
      efforts: [],
      default_effort: nil,
      vision: false,
      tools: true,
      caching: true,
      pricing: {0.60, 2.20},
      cache_read: 0.11,
      recommended: false,
      note: "198K ctx — previous-generation flagship; cheapest paid GLM"
    },
    %{
      id: "glm-4.7-flash",
      name: "GLM-4.7 Flash",
      ctx: 202_752,
      max_output: 16_384,
      reasoning: true,
      efforts: [],
      default_effort: nil,
      vision: false,
      tools: true,
      caching: true,
      # Z.ai publishes this model as FREE. `{0.0, 0.0}` is a published rate, not
      # a missing one, so it is `:exact` — unlike `nil`, which would mean "no
      # price known" and would be indistinguishable from an oversight.
      pricing: {0.0, 0.0},
      cache_read: 0.0,
      recommended: false,
      note: "198K ctx — free tier; 16K output cap"
    },
    # ── Vision line ───────────────────────────────────────────────────────
    # Listed so `vision: true` is reachable for the models that genuinely have
    # it. Without these rows a `glm-*v*` id would fall to the text models'
    # `vision: false` via `resolve/1`'s prefix match and lose its images.
    %{
      id: "glm-5v-turbo",
      name: "GLM-5V Turbo",
      ctx: 202_752,
      max_output: 131_072,
      reasoning: true,
      efforts: [],
      default_effort: nil,
      vision: true,
      tools: true,
      caching: true,
      pricing: {1.20, 4.00},
      cache_read: 0.24,
      recommended: false,
      note: "198K ctx — multimodal (image + video) GLM-5"
    },
    %{
      id: "glm-4.6v",
      name: "GLM-4.6V",
      ctx: 131_072,
      max_output: 32_768,
      reasoning: true,
      efforts: [],
      default_effort: nil,
      vision: true,
      tools: true,
      caching: true,
      pricing: {0.30, 0.90},
      # Z.ai publishes $0.05, not $0.055. The `0.055` this row carried was
      # `input * 0.185` — GLM-5.2's ratio, applied to a model that does not
      # share it — i.e. a derived number wearing a published one's clothes.
      # 10% high, and it became live the moment cache reads stopped going
      # through the flat multiplier. Re-checked against
      # https://docs.z.ai/guides/overview/pricing on 2026-08-16.
      cache_read: 0.05,
      recommended: false,
      note: "128K ctx — cheap multimodal (image + video)"
    }
  ]

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

    * a vendor prefix — `z-ai/glm-5.2`, `accounts/fireworks/models/glm-5.2`
    * an Ollama Cloud tag — `glm-5.2:cloud`
    * an OpenRouter routing suffix — `glm-5.2:free`, `:nitro`

  The prefix match is applied to the DECORATION-STRIPPED id only, and it
  accepts a prefix **only when what follows it starts with `-`** — i.e. only a
  dated or named variant suffix, never a version digit.

  That restriction is the whole of this function's difficulty, and it was got
  wrong first: a plain `String.starts_with?/2` resolves **`glm-5.3` to
  `glm-5`**, handing an unreleased model GLM-5's 200K window and $1.00/$3.20
  price under a `:exact` confidence label. The same rule keeps `glm-4.6v` from
  collapsing into `glm-4.6` and losing `vision: true`, while still resolving
  the case the prefix arm exists for — a dated snapshot like
  `glm-5.2-0715` onto `glm-5.2`.
  """
  @spec resolve(String.t() | nil) :: model() | nil
  def resolve(id) when is_binary(id) do
    bare =
      id
      |> String.trim()
      |> String.downcase()
      |> String.split("/")
      |> List.last()
      |> String.split(":")
      |> List.first()

    case model(bare) do
      nil ->
        @models
        |> Enum.filter(&variant_of?(bare, &1.id))
        |> Enum.max_by(&String.length(&1.id), fn -> nil end)

      found ->
        found
    end
  end

  def resolve(_), do: nil

  # A prefix is accepted only when the remainder is a real variant suffix:
  #
  #   * `-` + something alphabetic  — `-latest`, `-flash`, `-turbo`
  #   * `-` + FOUR OR MORE digits   — a date stamp, `-0715`, `-20251001`
  #
  # The digit-count floor is the part that is not obvious, and it is load
  # bearing. `Agent.Pricing` retries every lookup with dots rewritten as dashes
  # (`dotted_version_to_dashed/1`, which exists because gateways spell
  # `claude-haiku-4.5` where the catalog keys `claude-haiku-4-5`). That rewrite
  # turns `glm-5.3` into `glm-5-3` — which is indistinguishable from a dated
  # variant of `glm-5` under a `-`-only rule, and so priced the unreleased
  # GLM-5.3 at GLM-5's $1.00/$3.20 with `confidence/1` reporting `:exact`.
  #
  # No vendor stamps a snapshot with fewer than four digits, and no version
  # fragment has four, so the two are separable on length alone.
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

  @doc "The default Z.ai model for a fresh install."
  @spec default_model() :: String.t()
  def default_model, do: "glm-5.2"

  @doc "Model ids, in display order."
  @spec ids() :: [String.t()]
  def ids, do: Enum.map(@models, & &1.id)

  @doc "`%{model_id => context_window}` for merging into the Registry table."
  @spec context_windows() :: %{String.t() => pos_integer()}
  def context_windows, do: Map.new(@models, &{&1.id, &1.ctx})

  @doc "`%{model_id => max_output_tokens}` for merging into ModelLimits."
  @spec max_outputs() :: %{String.t() => pos_integer()}
  def max_outputs, do: Map.new(@models, &{&1.id, &1.max_output})

  @doc "`%{model_id => {input, output}}` USD per 1M tokens."
  @spec pricing() :: %{String.t() => {number(), number()}}
  def pricing do
    @models
    |> Enum.filter(& &1.pricing)
    |> Map.new(&{&1.id, &1.pricing})
  end

  @doc """
  Z.ai's published cached-input rate per 1M tokens, or nil when unknown.

  Z.ai publishes this as its own column rather than as a multiple of the input
  rate, and it is NOT the Anthropic-style `input * 0.1`: GLM-5.2 reads cache at
  `0.26` against a `1.40` input rate, which is `0.186x`, nearly double what the
  generic multiplier assumes.
  """
  @spec cache_read_rate(String.t() | nil) :: number() | nil
  def cache_read_rate(id) do
    case resolve(id) do
      nil -> nil
      m -> m.cache_read
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

  @doc "Max output tokens for a model, or nil when unknown."
  @spec max_output(String.t() | nil) :: pos_integer() | nil
  def max_output(id) do
    case resolve(id) do
      nil -> nil
      m -> m.max_output
    end
  end

  @doc "True when this is a GLM model that reasons. Every current GLM does."
  @spec reasoning?(String.t() | nil) :: boolean()
  def reasoning?(id) do
    case resolve(id) do
      nil -> false
      m -> m.reasoning
    end
  end

  @doc """
  Capability lookup, mirroring `OllamaCloud.capability/2`: `true`/`false` when
  this catalog knows the model, `nil` when it does not — so a caller can tell
  "GLM cannot see images" apart from "no idea what this model is".
  """
  @spec capability(String.t() | nil, :tools | :vision | :thinking | :caching) :: boolean() | nil
  def capability(id, flag) when flag in [:tools, :vision, :thinking, :caching] do
    key = if flag == :thinking, do: :reasoning, else: flag

    case resolve(id) do
      nil -> nil
      m -> Map.get(m, key)
    end
  end

  @doc """
  Map an OSA effort level onto this model's `reasoning_effort`.

  Returns `nil` for every GLM except 5.2 — not because those models do not
  reason, but because Z.ai documents `reasoning_effort` as **5.2-only**. They
  take `thinking_params/2` instead. Returning a level here for a model that
  ignores it would make the effort ladder look wired when it is not.
  """
  @spec reasoning_effort(String.t() | nil, term()) :: String.t() | nil
  def reasoning_effort(id, effort) do
    case resolve(id) do
      %{reasoning: true, efforts: [_ | _] = efforts} -> clamp(map_effort(effort), efforts)
      _ -> nil
    end
  end

  # OSA's ladder onto Z.ai's. GLM-5.2 is the only vendor model OSA serves whose
  # vocabulary covers every rung OSA has, so this is 1:1 rather than a
  # collapse — "xhigh" stays "xhigh" instead of being flattened into "high".
  defp map_effort(effort) do
    case effort |> to_string() |> String.trim() |> String.downcase() do
      "off" -> "none"
      "none" -> "none"
      "minimal" -> "minimal"
      "fast" -> "low"
      "low" -> "low"
      "medium" -> "medium"
      "high" -> "high"
      "xhigh" -> "xhigh"
      "max" -> "max"
      "ultra" -> "max"
      # A corrupt persisted effort must not silently disable reasoning.
      _ -> "high"
    end
  end

  defp clamp(level, efforts) do
    if level in efforts do
      level
    else
      wanted = Enum.find_index(@glm52_efforts, &(&1 == level)) || 0

      Enum.find(@glm52_efforts, List.first(efforts), fn l ->
        l in efforts and (Enum.find_index(@glm52_efforts, &(&1 == l)) || 0) >= wanted
      end)
    end
  end

  @doc """
  Build Z.ai's thinking parameters for a model + OSA effort, as a map to merge
  into the top-level request body. `%{}` for a non-GLM id, so it is safe to
  call unconditionally.

  Two shapes, because Z.ai has two:

    * every GLM — `%{"thinking" => %{"type" => "enabled" | "disabled"}}`
    * GLM-5.2 only — plus a top-level `"reasoning_effort"`

  An "off" effort emits `"disabled"` **explicitly** rather than omitting the
  object, for the same reason DeepSeek does: `type` defaults to `enabled`, so
  omission leaves thinking ON.
  """
  @spec thinking_params(String.t() | nil, term()) :: map()
  def thinking_params(id, effort) do
    case resolve(id) do
      nil ->
        %{}

      %{reasoning: false} ->
        %{}

      m ->
        level = reasoning_effort(id, effort)
        off? = map_effort(effort) == "none"

        base = %{"thinking" => %{"type" => if(off?, do: "disabled", else: "enabled")}}

        if level && m.efforts != [] && not off? do
          Map.put(base, "reasoning_effort", level)
        else
          base
        end
    end
  end
end
