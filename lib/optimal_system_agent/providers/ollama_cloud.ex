defmodule OptimalSystemAgent.Providers.OllamaCloud do
  @moduledoc """
  **Single source of truth for the Ollama Cloud model catalog.**

  ## Why this module exists

  Adding one Ollama Cloud model used to be a scavenger hunt across six
  unrelated files, and every miss produced a *half-added* model that resolved
  in one surface and misbehaved in another:

    * `Onboarding.providers_list/0` — or the model never appears in the picker
      (TUI `/model` dialog, `osa setup`, `mix osa.setup.wizard`) and can only be
      used by typing its tag by hand.
    * `Registry.@fallback_context_windows` — or a probe-less boot silently
      budgets the model at the flat 128k `:max_context_tokens` default.
    * `Agent.Pricing.@pricing` — or every turn is accounted at $0.00.
    * `Providers.Ollama` tool/thinking heuristics — or a tool-calling model is
      gated off tools because its NAME doesn't start with a known prefix, and a
      reasoning model never gets `think: true`.
    * `Registry.ollama_cloud_model?/1` — cloud detection (see `cloud_tag?/1`).
    * `Agent.Tier.@tier_models` — only when the model should become a tier
      default; genuinely a separate editorial decision, so it is NOT derived
      from here.

  Everything except the tier map now DERIVES from `models/0` below. To add a
  model you edit exactly one list.

  ## How to add a new Ollama Cloud model

  1. Probe the real numbers — never copy them out of a blog post:

         curl -s http://localhost:11434/api/show -d '{"name":"<tag>"}'

     Read `model_info["<arch>.context_length"]` for `:ctx` and `capabilities`
     for `:tools` / `:thinking` / `:vision` / `:audio` (`completion` is noise).
     A signed-in local daemon proxies `:cloud` tags, so this works without an
     `OLLAMA_API_KEY`.
  2. Add one entry to `@models`. Set `:ctx_source` to `:probe` when the number
     came from step 1, `:docs` when you had to trust the vendor's page.
  3. Set `:pricing` only if the vendor publishes `{input, output}` USD per 1M
     tokens; leave it `nil` rather than guessing (an unpriced model accounts at
     $0.00 and logs, which is honest; a guessed price is not).
  4. Set `:requires_subscription` when the tag needs a paid Ollama plan. It is
     folded into the picker `:note` so a free-plan user sees the requirement
     BEFORE selecting it instead of hitting an opaque 4xx later.
  5. `mix compile` + `mix test test/providers`. Nothing else to touch.

  ## The `:ctx` value is a FALLBACK, not the truth

  At runtime `Registry.context_window/1` probes `/api/show` **first** for cloud
  tags and only falls back to this table when the probe fails (daemon down, not
  signed in, offline). So a slightly stale `:ctx` here degrades gracefully
  instead of overriding reality — but it is what a fresh install budgets
  against before the first successful probe, so keep it honest.
  """

  @typedoc "A single Ollama Cloud model offering."
  @type model :: %{
          id: String.t(),
          name: String.t(),
          ctx: pos_integer(),
          # `:static` is a real third provenance, not an oversight: it labels a
          # tag whose /api/show `model_info` carries no `context_length` at all
          # — so the probe CANNOT resolve it — and for which no vendor page
          # states the figure either. It was missing from this typespec while
          # `glm-4.7:cloud` used it and the catalog test asserted it, so the
          # data, the test and the type disagreed three ways.
          ctx_source: :probe | :docs | :static,
          tools: boolean(),
          thinking: boolean(),
          vision: boolean(),
          audio: boolean(),
          pricing: {number(), number()} | nil,
          recommended: boolean(),
          requires_subscription: String.t() | nil,
          note: String.t()
        }

  # Context windows and capability flags below were read live from
  # `/api/show` on 2026-08-01 through a signed-in local daemon (every entry is
  # `ctx_source: :probe`). `capabilities` reported by Ollama map 1:1 onto the
  # :tools / :thinking / :vision / :audio flags; the ubiquitous "completion"
  # capability carries no information and is ignored.
  #
  # ── 2026-08-15 pass: NOT re-probed ───────────────────────────────────────
  # The account was at its session usage limit, so `/api/show` could not be
  # called and no `ctx` below was re-verified. Contexts were instead sanity
  # checked against ollama.com's own library pages, which agree: the site
  # renders windows in binary K, so `glm-5.2:cloud` shows "976K" for the
  # 1,000,000 recorded here and `glm-5.1:cloud` shows "198K" for 202,752.
  #
  # The `pricing` values filled in on that pass (kimi-k2.6, kimi-k2.7-code,
  # minimax-m3, both deepseek-v4 tags) are the UPSTREAM VENDOR's published
  # per-token rate, read from each vendor's own first-party endpoint as
  # reported by OpenRouter's public endpoints API. That is the convention this
  # table already followed — `kimi-k3:cloud`'s {3.00, 15.00} is Moonshot's own
  # rate to the cent — and it is a per-token estimate of a tag that Ollama
  # itself bills against a subscription. It is the right number for comparing
  # models and the wrong one for predicting an Ollama invoice.
  #
  # Order is the picker's display order: flagship first, utility last.
  @models [
    %{
      id: "kimi-k3:cloud",
      name: "Kimi K3",
      ctx: 1_048_576,
      ctx_source: :probe,
      tools: true,
      thinking: true,
      vision: true,
      audio: false,
      pricing: {3.00, 15.00},
      # Listed FIRST (it is the most capable tag OSA offers) but deliberately
      # NOT `recommended` — `recommended` is the flag the picker pairs with
      # `default_model`, and defaulting every new install onto a tag that
      # requires a paid Ollama plan would break free-plan users on turn one.
      recommended: false,
      requires_subscription: "Ollama Pro or Max",
      note: "1M ctx, 2.8T MoE — vision + thinking, frontier agentic"
    },
    %{
      id: "glm-5.2:cloud",
      name: "GLM-5.2",
      ctx: 1_000_000,
      ctx_source: :probe,
      tools: true,
      thinking: true,
      vision: false,
      audio: false,
      # CORRECTED 2026-08-15 from {0.60, 2.20}, which is GLM-**4.7**'s rate
      # copied forward across two generations. Z.ai charges {1.40, 4.40} for
      # GLM-5.2 — stated on its own pricing page and matched to the cent by the
      # Z.AI first-party endpoint behind OpenRouter.
      #
      # This is the single worst number this catalog has carried: `glm-5.2:cloud`
      # is OSA's DEFAULT model, so every install accounted its own default at
      # 43% of input and 50% of output cost, and `Pricing.confidence/1`
      # returned `:exact` throughout because the wrong figure sat in an
      # exact-match table rather than falling to the family guess. Expect
      # reported spend on this tag to roughly double.
      pricing: {1.40, 4.40},
      recommended: true,
      requires_subscription: nil,
      note: "Z.ai flagship — long-horizon agentic + coding"
    },
    # GLM-5.3 - the bare flagship, now live on Ollama. Probed 2026-08-30 via a
    # signed-in local daemon: 1,048,576 ctx, tools + thinking, NO vision (the
    # Flash sibling below is the multimodal one); 753B glm_dsa_moe. The
    # 2026-08-01 pass recorded only a 404 here. Pricing left nil - Z.ai's
    # first-party list rate for the bare 5.3 is unconfirmed, and a guessed price
    # is worse than an honest $0.00 + a log.
    %{
      id: "glm-5.3:cloud",
      name: "GLM-5.3",
      ctx: 1_048_576,
      ctx_source: :probe,
      tools: true,
      thinking: true,
      vision: false,
      audio: false,
      pricing: nil,
      recommended: false,
      requires_subscription: nil,
      note: "1M ctx, 753B MoE - Z.ai flagship, long-horizon agentic coding"
    },
    # GLM-5.3-Flash - Ollama tag `glm-5.3-flash:cloud` (the bare `glm-5.3` now
    # ships too; see the entry above). The FIRST natively-multimodal
    # GLM text tag: image + video inline, unlike every glm-N text model before
    # it. 320B/18B MoE, 1M window, 131K output. ctx :static (from Ollama's
    # library page + Z.ai spec, not a live /api/show probe).
    %{
      id: "glm-5.3-flash:cloud",
      name: "GLM-5.3 Flash",
      ctx: 1_048_576,
      ctx_source: :static,
      tools: true,
      thinking: true,
      vision: true,
      audio: false,
      # Z.ai list price: $0.15 in / $0.50 out per 1M, cross-checked on Ollama's
      # model page and third-party trackers. A 50%-off launch promo
      # ($0.075 / $0.25) runs through 2026-09-09; the LIST rate is recorded so
      # spend is not under-counted once the promo lapses.
      pricing: {0.15, 0.50},
      recommended: true,
      requires_subscription: nil,
      note: "1M ctx, 320B/18B MoE - multimodal (image+video), flash-priced agentic"
    },
    # `glm-4.7:cloud` carries no `context_length` in Ollama's /api/show
    # model_info, so the probe cannot resolve it and it was absent here too —
    # which made `ContextWindow.resolve/1` return `:unknown` for a tag this
    # project has shipped as its configured model. The entry closes the hole
    # for THIS tag; `CompactionThresholds.fallback_window/0` is what keeps the
    # NEXT unenumerated tag safe without anyone editing this table.
    %{
      id: "glm-4.7:cloud",
      name: "GLM-4.7",
      ctx: 202_752,
      ctx_source: :static,
      tools: true,
      thinking: true,
      vision: false,
      audio: false,
      # {0.60, 2.20} is correct HERE — it is GLM-4.7's own published rate. It
      # was wrong on the 5.x rows above only because it was copied to them.
      pricing: {0.60, 2.20},
      recommended: false,
      requires_subscription: nil,
      # Ollama RETIRED this tag on 2026-07-15 — its library page states no
      # models pushed. Kept rather than deleted so a config still pinned to it
      # resolves a real window and a real price instead of falling through to
      # the family guess, but the picker now says so before it is chosen.
      note: "RETIRED on Ollama 2026-07-15 — previous-generation Z.ai flagship"
    },
    %{
      id: "glm-5.1:cloud",
      name: "GLM-5.1",
      ctx: 202_752,
      ctx_source: :probe,
      tools: true,
      thinking: true,
      vision: false,
      audio: false,
      # CORRECTED 2026-08-15 from {0.60, 2.20} — see `glm-5.2:cloud` above.
      # Z.ai prices 5.1 identically to 5.2 despite the fifth of the window.
      pricing: {1.40, 4.40},
      recommended: false,
      requires_subscription: nil,
      note: "200K ctx — same price as 5.2 for a fifth of the window"
    },
    %{
      id: "kimi-k2.7-code:cloud",
      name: "Kimi K2.7 Code",
      ctx: 262_144,
      ctx_source: :probe,
      tools: true,
      thinking: true,
      vision: true,
      audio: false,
      # Moonshot AI's own first-party endpoint rate. See the moduledoc note on
      # where these came from.
      pricing: {0.95, 4.00},
      recommended: false,
      requires_subscription: nil,
      note: "Moonshot coding-focused agentic"
    },
    %{
      id: "kimi-k2.6:cloud",
      name: "Kimi K2.6",
      ctx: 262_144,
      ctx_source: :probe,
      tools: true,
      thinking: true,
      vision: true,
      audio: false,
      pricing: {0.95, 4.00},
      recommended: false,
      requires_subscription: nil,
      note: "multimodal agentic, long-horizon coding"
    },
    %{
      id: "minimax-m3:cloud",
      name: "MiniMax M3",
      ctx: 524_288,
      ctx_source: :probe,
      tools: true,
      thinking: true,
      vision: true,
      audio: false,
      pricing: {0.30, 1.20},
      recommended: false,
      requires_subscription: nil,
      note: "512K ctx, native multimodal + agentic"
    },
    # MiniMax M2.7 - the M2-series predecessor to M3. Probed 2026-08-30 via a
    # signed-in local daemon: 196,608 ctx, tools + thinking, no vision (M3 is the
    # multimodal one); 229B, family minimax-m2. Pricing left nil - MiniMax's
    # first-party rate for this tag is unconfirmed (do NOT copy M3's).
    %{
      id: "minimax-m2.7:cloud",
      name: "MiniMax M2.7",
      ctx: 196_608,
      ctx_source: :probe,
      tools: true,
      thinking: true,
      vision: false,
      audio: false,
      pricing: nil,
      recommended: false,
      requires_subscription: nil,
      note: "192K ctx, 229B - M2-series coding + agentic"
    },
    %{
      id: "deepseek-v4-pro:cloud",
      name: "DeepSeek V4 Pro",
      ctx: 524_288,
      ctx_source: :probe,
      tools: true,
      thinking: true,
      vision: false,
      audio: false,
      # DeepSeek's published rate, already the source of truth in
      # `Providers.DeepSeekModels` for the un-tagged id.
      pricing: {0.435, 0.87},
      recommended: false,
      requires_subscription: nil,
      note: "512K ctx, frontier MoE, multiple reasoning modes"
    },
    %{
      id: "deepseek-v4-flash:cloud",
      name: "DeepSeek V4 Flash",
      ctx: 1_048_576,
      ctx_source: :probe,
      tools: true,
      thinking: true,
      vision: false,
      audio: false,
      pricing: {0.14, 0.28},
      recommended: false,
      requires_subscription: nil,
      note: "1M ctx, 284B MoE / 13B active — fast"
    },
    %{
      id: "gpt-oss:120b-cloud",
      name: "GPT-OSS 120B",
      ctx: 131_072,
      ctx_source: :probe,
      tools: true,
      thinking: true,
      vision: false,
      audio: false,
      pricing: nil,
      recommended: false,
      requires_subscription: nil,
      note: "OpenAI open-weight, strong reasoning"
    },
    %{
      id: "qwen3.5:cloud",
      name: "Qwen 3.5",
      ctx: 262_144,
      ctx_source: :probe,
      tools: true,
      thinking: true,
      vision: true,
      audio: false,
      pricing: nil,
      recommended: false,
      requires_subscription: nil,
      note: "multimodal, vision + tools"
    },
    %{
      id: "nemotron-3-super:cloud",
      name: "Nemotron 3 Super",
      ctx: 262_144,
      ctx_source: :probe,
      tools: true,
      thinking: true,
      vision: false,
      audio: false,
      pricing: nil,
      recommended: false,
      requires_subscription: nil,
      note: "262K ctx, 120B MoE — efficient agentic"
    },
    %{
      id: "gemma4:cloud",
      name: "Gemma 4",
      ctx: 262_144,
      ctx_source: :probe,
      tools: true,
      thinking: true,
      vision: true,
      # Ollama's own /api/show reports no "audio" capability for this tag even
      # though the model card lists audio input — trust the daemon, not the card.
      audio: false,
      pricing: nil,
      recommended: false,
      requires_subscription: nil,
      note: "262K ctx, frontier reasoning + vision"
    },
    %{
      id: "gemma4:31b-cloud",
      name: "Gemma 4 31B",
      ctx: 262_144,
      ctx_source: :probe,
      tools: true,
      thinking: true,
      vision: true,
      audio: false,
      pricing: nil,
      recommended: false,
      requires_subscription: nil,
      note: "262K ctx, pinned 31B tag of Gemma 4"
    },
    %{
      id: "gpt-oss:20b-cloud",
      name: "GPT-OSS 20B",
      ctx: 131_072,
      ctx_source: :probe,
      tools: true,
      thinking: true,
      vision: false,
      audio: false,
      pricing: nil,
      recommended: false,
      requires_subscription: nil,
      note: "OpenAI open-weight, fast — light utility tier"
    }
  ]

  @by_id Map.new(@models, &{&1.id, &1})

  @doc "Every Ollama Cloud model OSA offers, in picker display order."
  @spec models() :: [model()]
  def models, do: @models

  @doc "The catalog entry for an exact cloud tag, or nil."
  @spec model(String.t() | nil) :: model() | nil
  def model(id) when is_binary(id), do: Map.get(@by_id, id)
  def model(_), do: nil

  @doc """
  `true` when `model` is an Ollama Cloud tag.

  Ollama uses TWO suffix shapes for hosted models: a bare `":cloud"` tag
  (`glm-5.2:cloud`) and a size-qualified `"-cloud"` tag (`gpt-oss:120b-cloud`,
  `gemma4:31b-cloud`). A plain `String.contains?(model, ":cloud")` misses the
  second shape entirely, which silently demoted those models to "local": their
  context window got squeezed under the local `:ollama_num_ctx` KV-cache ceiling
  and `gpt-oss:120b-cloud` even resolved to the :openai provider by the
  `starts_with?("gpt")` heuristic. Matching the `-cloud` suffix as well fixes
  both, and keeps working for models this catalog has never heard of.
  """
  @spec cloud_tag?(String.t() | nil) :: boolean()
  def cloud_tag?(model) when is_binary(model) do
    m = String.downcase(model)
    String.contains?(m, ":cloud") or String.ends_with?(m, "-cloud")
  end

  def cloud_tag?(_), do: false

  @doc """
  `%{tag => context_window}` for merging into `Registry`'s static fallback
  table. Keys are EXACT cloud tags, so they win over the family-prefix rows
  without disturbing the same family's local/direct entries.
  """
  @spec context_windows() :: %{String.t() => pos_integer()}
  def context_windows, do: Map.new(@models, &{&1.id, &1.ctx})

  @doc "`%{tag => {input_usd_per_1m, output_usd_per_1m}}` for the models we have real prices for."
  @spec pricing() :: %{String.t() => {number(), number()}}
  def pricing do
    @models
    |> Enum.filter(&(&1.pricing != nil))
    |> Map.new(&{&1.id, &1.pricing})
  end

  @doc """
  Capability lookup for an exact cloud tag: `true` / `false` when this catalog
  knows the model, `nil` when it does not (callers then fall back to their own
  name heuristics).
  """
  @spec capability(String.t() | nil, :tools | :thinking | :vision | :audio) :: boolean() | nil
  def capability(id, flag) when flag in [:tools, :thinking, :vision, :audio] do
    case model(id) do
      nil -> nil
      m -> Map.get(m, flag)
    end
  end

  @doc """
  The onboarding / model-picker shape (`Onboarding.providers_list/0` →
  `GET /onboarding/status` → TUI model dialog, `osa setup`, `mix osa.setup.wizard`).

  Only the keys those surfaces render are emitted. A `:requires_subscription`
  is prefixed onto the note because `note` is the one free-text field every
  picker displays — that is how a free-plan user learns a tag needs Ollama Pro
  BEFORE selecting it, instead of discovering it as an opaque API failure.
  """
  @spec picker_models() :: [map()]
  def picker_models do
    Enum.map(@models, fn m ->
      %{
        id: m.id,
        name: m.name,
        ctx: m.ctx,
        tools: m.tools,
        recommended: m.recommended,
        note: picker_note(m)
      }
    end)
  end

  defp picker_note(%{requires_subscription: nil, note: note}), do: note

  defp picker_note(%{requires_subscription: plan, note: note}),
    do: "requires #{plan} (extra credits) · #{note}"
end
