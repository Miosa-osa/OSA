defmodule OptimalSystemAgent.Providers.AnthropicModels do
  @moduledoc """
  **Single source of truth for the Anthropic (Claude) model catalog.**

  ## Why this module exists

  Adding one Claude model used to be a scavenger hunt across ten unrelated
  files, and every miss produced a *half-added* model that resolved in one
  surface and misbehaved in another:

    * `Providers.Anthropic.available_models/0` — or the model can only be used
      by typing its id by hand.
    * `Providers.Anthropic.default_max_tokens/1` — or a 128k-output model is
      silently capped at 32k and long answers truncate mid-sentence.
    * `Registry.@static_context_windows` — or a probe-less boot budgets the
      model at the flat 128k `:max_context_tokens` default.
    * `Providers.ModelLimits.@max_output` — same truncation, different caller.
    * `Agent.Pricing.@pricing` — or every turn is accounted at $0.00.
    * `Providers.Catalog` embedded fallback — or the offline catalog lies.
    * `Onboarding.providers_list/0` — or the model never appears in the picker
      (TUI `/model` dialog, `osa setup`, `mix osa.setup.wizard`).
    * `Agent.Tier.@tier_models` — only when the model should become a tier
      default; genuinely a separate editorial decision, so it is NOT derived
      from here.

  Everything except the tier map now DERIVES from `models/0` below. To add a
  model you edit exactly one list.

  ## The `:thinking` flag is load-bearing, not cosmetic

  Anthropic **removed** the fixed thinking budget on the Claude 5 family and on
  Opus 4.7/4.8: sending `thinking: {type: "enabled", budget_tokens: N}` to
  `claude-opus-5` / `claude-sonnet-5` / `claude-fable-5` returns a **400**, not
  a degraded response. `:adaptive` models must be sent
  `thinking: {type: "adaptive"}` and steered with `output_config.effort`
  instead; only `:budget` models (Haiku 4.5 and older) still take a token
  count. `Agent.Loop.LLMClient.thinking_config/1` reads this flag so the two
  can never disagree.

  Likewise the Claude 5 family and Opus/Sonnet 4.6+ **reject** `temperature`,
  `top_p`, and `top_k` outright — the Anthropic provider deliberately never
  sends them.

  ## The `:prefill` flag is the same kind of load-bearing

  The same generation boundary removed **assistant message prefill**: a request
  whose final message has `role: "assistant"` returns a 400 on Opus/Sonnet 4.6
  and everything newer. `Providers.Anthropic` reads `:prefill` to decide whether
  to normalize a trailing assistant turn before dispatch — see
  `supports_prefill?/1`.

  ## How to add a new Claude model

  1. Take the numbers from Anthropic's published model docs — never a blog post.
     `ctx` is the context window, `max_output` the per-response output cap.
  2. Set `:thinking` to `:adaptive` for Claude 4.7+ and the 5 family,
     `:budget` for anything older that supports extended thinking, `:none` if
     it has no thinking mode at all. Set `:prefill` to `false` for Opus/Sonnet
     4.6 and newer (prefill removed), `true` only for Haiku 4.5 and older.
  3. Set `:pricing` to `{input, output}` USD per 1M tokens — **the rate the
     vendor bills today**, not a list price the vendor is currently discounting
     away from. Leave it `nil` rather than guessing: an unpriced model accounts
     at $0.00 and logs, which is honest; a guessed price is not. If the vendor
     publishes a date on which the rate changes, add the post-change rate to
     `pricing_schedule/0` instead of picking one of the two — see there.
  4. `mix compile` + `mix test test/providers`. Nothing else to touch.

  Sources: https://platform.claude.com/docs/en/about-claude/models/overview and
  https://platform.claude.com/docs/en/pricing (checked 2026-08-01).
  """

  @typedoc "A single Anthropic model offering."
  @type model :: %{
          id: String.t(),
          name: String.t(),
          ctx: pos_integer(),
          max_output: pos_integer(),
          thinking: :adaptive | :budget | :none,
          effort: :full | :no_xhigh | :none,
          prefill: boolean(),
          vision: boolean(),
          tools: boolean(),
          pricing: {number(), number()} | nil,
          recommended: boolean(),
          legacy: boolean(),
          note: String.t()
        }

  # Order is the picker's display order: flagship first, legacy last.
  @models [
    %{
      id: "claude-opus-5",
      name: "Claude Opus 5",
      ctx: 1_000_000,
      max_output: 128_000,
      thinking: :adaptive,
      effort: :full,
      prefill: false,
      vision: true,
      tools: true,
      pricing: {5.00, 25.00},
      recommended: true,
      legacy: false,
      note: "1M ctx — best agentic coding + deep reasoning. Default."
    },
    %{
      id: "claude-sonnet-5",
      name: "Claude Sonnet 5",
      ctx: 1_000_000,
      max_output: 128_000,
      thinking: :adaptive,
      effort: :full,
      prefill: false,
      vision: true,
      tools: true,
      # $3/$15 list, with an introductory $2/$10 in force through 2026-08-31.
      # `:pricing` is the rate BILLED TODAY; the list rate lives in
      # `pricing_schedule/0` and takes over on 2026-09-01 by itself.
      #
      # This row previously carried the list rate on a "never under-estimate"
      # policy, and that policy is what made it wrong: an 8-task benchmark arm
      # billed $52.73 at OpenRouter and reconciled to $52.31 against $2/$10
      # (0.8%), while OSA reported $78.55 — exactly 1.50x, the ratio of the two
      # rates. An estimate deliberately biased away from the invoice cannot
      # reconcile against it, which is the one job a cost figure has.
      pricing: {2.00, 10.00},
      recommended: false,
      legacy: false,
      note: "1M ctx — near-Opus quality at Sonnet cost, best speed/intelligence"
    },
    %{
      id: "claude-fable-5",
      name: "Claude Fable 5",
      ctx: 1_000_000,
      max_output: 128_000,
      thinking: :adaptive,
      effort: :full,
      prefill: false,
      vision: true,
      tools: true,
      pricing: {10.00, 50.00},
      recommended: false,
      legacy: false,
      note: "1M ctx — most capable; hardest long-horizon work. Premium pricing."
    },
    %{
      id: "claude-haiku-4-5",
      name: "Claude Haiku 4.5",
      ctx: 200_000,
      max_output: 64_000,
      # Haiku 4.5 predates adaptive thinking — it still takes a token budget.
      thinking: :budget,
      effort: :none,
      # ...and predates the prefill removal: a trailing assistant turn is a
      # legitimate prefill here, so the provider must NOT normalize it away.
      prefill: true,
      vision: true,
      tools: true,
      pricing: {1.00, 5.00},
      recommended: false,
      legacy: false,
      note: "200K ctx — fastest and cheapest, for simple high-volume tasks"
    },
    %{
      id: "claude-opus-4-8",
      name: "Claude Opus 4.8",
      ctx: 1_000_000,
      max_output: 128_000,
      thinking: :adaptive,
      effort: :full,
      prefill: false,
      vision: true,
      tools: true,
      pricing: {5.00, 25.00},
      recommended: false,
      legacy: true,
      note: "Previous-generation Opus — pin only for reproducibility"
    },
    %{
      id: "claude-opus-4-7",
      name: "Claude Opus 4.7",
      ctx: 1_000_000,
      max_output: 128_000,
      thinking: :adaptive,
      effort: :full,
      prefill: false,
      vision: true,
      tools: true,
      pricing: {5.00, 25.00},
      recommended: false,
      legacy: true,
      note: "Previous-generation Opus — pin only for reproducibility"
    },
    %{
      id: "claude-opus-4-6",
      name: "Claude Opus 4.6",
      ctx: 1_000_000,
      max_output: 128_000,
      # 4.6 still accepts budget_tokens (deprecated) but adaptive is correct.
      thinking: :adaptive,
      effort: :no_xhigh,
      prefill: false,
      vision: true,
      tools: true,
      pricing: {5.00, 25.00},
      recommended: false,
      legacy: true,
      note: "Previous-generation Opus — pin only for reproducibility"
    },
    %{
      id: "claude-sonnet-4-6",
      name: "Claude Sonnet 4.6",
      ctx: 1_000_000,
      max_output: 128_000,
      # 4.6 still accepts budget_tokens (deprecated) but adaptive is correct.
      thinking: :adaptive,
      effort: :no_xhigh,
      prefill: false,
      vision: true,
      tools: true,
      pricing: {3.00, 15.00},
      recommended: false,
      legacy: true,
      note: "Previous-generation Sonnet — pin only for reproducibility"
    }
  ]

  @by_id Map.new(@models, &{&1.id, &1})

  # ── Retirement schedule ──────────────────────────────────────────────────
  #
  # A retired model in the picker is worse than a missing one: it resolves,
  # the user selects it, and every request 404s. `@retirements` is the guard —
  # `model_catalog_ssot_test.exs` asserts no id in `@models` appears here with
  # a date in the past, so a model that has been sunset can never sit in the
  # picker unnoticed.
  #
  # Dates are Anthropic's published retirement dates for Anthropic-operated
  # platforms (Claude API, Claude Platform on AWS, Microsoft Foundry). Partner
  # platforms (Amazon Bedrock, Google Cloud) set their own schedules.
  #
  # Source: https://platform.claude.com/docs/en/about-claude/model-deprecations
  # (checked 2026-08-01).
  @retirements %{
    # Deprecated 2026-06-05, retires in four days. Replacement: claude-opus-4-8
    # (or claude-opus-5). Deliberately NOT in @models.
    "claude-opus-4-1-20250805" => ~D[2026-08-05],
    "claude-opus-4-20250514" => ~D[2026-06-15],
    "claude-sonnet-4-20250514" => ~D[2026-06-15],
    "claude-3-haiku-20240307" => ~D[2026-04-20],
    "claude-3-7-sonnet-20250219" => ~D[2026-02-19],
    "claude-3-5-haiku-20241022" => ~D[2026-02-19],
    "claude-3-opus-20240229" => ~D[2026-01-05],
    "claude-3-5-sonnet-20241022" => ~D[2025-10-28],
    "claude-3-5-sonnet-20240620" => ~D[2025-10-28],
    "claude-3-sonnet-20240229" => ~D[2025-07-21],
    "claude-2.1" => ~D[2025-07-21],
    "claude-2.0" => ~D[2025-07-21]
  }

  @doc """
  Known retirement dates, keyed by exact Anthropic model id.

  Only models Anthropic has published a retirement date for appear here; an
  absent id means "no announced retirement", not "safe forever".
  """
  @spec retirements() :: %{String.t() => Date.t()}
  def retirements, do: @retirements

  @doc """
  The retirement date for a model id, or nil when none is announced.

  Matches the dated snapshot id and any alias that prefixes it, so both
  `claude-opus-4-1` and `claude-opus-4-1-20250805` resolve.
  """
  @spec retirement_date(String.t() | nil) :: Date.t() | nil
  def retirement_date(id) when is_binary(id) do
    down = String.downcase(id)

    Enum.find_value(@retirements, fn {retired_id, date} ->
      if down == retired_id or String.starts_with?(retired_id, down) or
           String.starts_with?(down, retired_id),
         do: date
    end)
  end

  def retirement_date(_), do: nil

  @doc """
  True when this model id is past its published retirement date — requests to
  it will fail. `today` is injectable so the check is testable without a clock.
  """
  @spec retired?(String.t() | nil, Date.t()) :: boolean()
  def retired?(id, today \\ Date.utc_today()) do
    case retirement_date(id) do
      nil -> false
      date -> Date.compare(today, date) != :lt
    end
  end

  @doc "The full catalog, in picker display order."
  @spec models() :: [model()]
  def models, do: @models

  @doc "Look up one model by exact id. Returns nil for unknown ids."
  @spec model(String.t() | nil) :: model() | nil
  def model(id) when is_binary(id), do: Map.get(@by_id, id)
  def model(_), do: nil

  # Bare aliases the Claude Code CLI accepts for `--model`, mapped to the
  # catalogue id each names.
  #
  # A subscriber on the `claude_cli` provider selects "fable", not
  # "claude-fable-5" — that is the vocabulary `claude --help` documents and what
  # OSA passes through to `--model`. Nothing downstream recognised the bare
  # form, so `resolve/1` returned nil and every lookup keyed on it fell through:
  # `Registry.context_window/1` missed the catalogue, then PROBED OLLAMA for the
  # window of a Claude model, and the TUI divided real usage by a denominator
  # belonging to no model at all — a fresh session opened at "36% ctx".
  #
  # Deliberately the undated FAMILY id, never a dated snapshot. Which concrete
  # snapshot an alias resolves to is Claude Code's decision and changes without
  # OSA being involved (see `Providers.ClaudeCLI`), so a dated mapping here
  # would be a confident lie the first time Anthropic ships a new one. The
  # family id is stable and is what the catalogue is keyed by. For the exact
  # snapshot actually served, `ClaudeCLI.last_resolved_model/0` reports what
  # came back on `message_start`.
  @cli_aliases %{
    "fable" => "claude-fable-5",
    "opus" => "claude-opus-5",
    "sonnet" => "claude-sonnet-5",
    "haiku" => "claude-haiku-4-5"
  }

  @doc "The bare `--model` aliases this catalogue understands."
  @spec cli_aliases() :: %{String.t() => String.t()}
  def cli_aliases, do: @cli_aliases

  @doc """
  Look up a model by id, tolerating a dated snapshot suffix.

  Haiku 4.5 is the one current model whose canonical Claude API ID carries a
  date (`claude-haiku-4-5-20251001`); the bare `claude-haiku-4-5` alias is
  equally valid and is what OSA offers. Both resolve here. Longest id wins so a
  short id can never shadow a longer, more specific one.
  """
  @spec resolve(String.t() | nil) :: model() | nil
  def resolve(id) when is_binary(id) do
    case model(id) do
      nil ->
        down = String.downcase(id)

        prefix_match =
          @models
          |> Enum.filter(&String.starts_with?(down, &1.id))
          |> Enum.max_by(&String.length(&1.id), fn -> nil end)

        # Alias last: a real id, and the dated-suffix match above, must always
        # win over the alias table.
        prefix_match || alias_match(down)

      found ->
        found
    end
  end

  def resolve(_), do: nil

  defp alias_match(down) do
    case Map.fetch(@cli_aliases, down) do
      {:ok, canonical} -> model(canonical)
      :error -> nil
    end
  end

  @doc "The default model for a fresh install."
  @spec default_model() :: String.t()
  def default_model, do: "claude-opus-5"

  @doc "Model ids, in display order — what `Anthropic.available_models/0` returns."
  @spec ids() :: [String.t()]
  def ids, do: Enum.map(@models, & &1.id)

  @doc "`%{model_id => context_window}` for merging into the Registry table."
  @spec context_windows() :: %{String.t() => pos_integer()}
  def context_windows, do: Map.new(@models, &{&1.id, &1.ctx})

  @doc "`%{model_id => max_output_tokens}` for merging into ModelLimits."
  @spec max_outputs() :: %{String.t() => pos_integer()}
  def max_outputs, do: Map.new(@models, &{&1.id, &1.max_output})

  @doc "`%{model_id => {input, output}}` USD per 1M tokens, unpriced models omitted."
  @spec pricing() :: %{String.t() => {number(), number()}}
  def pricing do
    @models
    |> Enum.filter(& &1.pricing)
    |> Map.new(&{&1.id, &1.pricing})
  end

  # ── Dated rate changes ───────────────────────────────────────────────────
  #
  # A vendor price is not always a constant, and encoding it as one is how two
  # separate 1.5x-2x accounting errors shipped: `claude-sonnet-5` carried the
  # $3/$15 list rate through an introductory $2/$10 period (1.50x over), and
  # `gemini-3.6-flash` did the same thing in `GoogleModels` (2x over). Both
  # were reported as `:exact` the whole time, because an exact table has no way
  # to say "correct until".
  #
  # So a row whose rate has a PUBLISHED change date carries the change here.
  # `:pricing` above is the rate in force now; each entry is `{effective_from,
  # rate}` and takes over on that date. `Agent.Pricing` resolves this at
  # RUNTIME against the turn's own date — deliberately not at compile time,
  # because a release built during a promo would otherwise carry the promo
  # rate for the rest of its life.
  #
  # The mechanism, not the date, is what the tests pin: they resolve against
  # injected dates on both sides of the boundary, so no test expires and
  # 2026-09-01 arrives with the rate already correct rather than with a red
  # suite telling someone to go fix it.
  @pricing_schedule %{
    # The introductory rate lapses; list price resumes.
    # Source: https://platform.claude.com/docs/en/pricing (checked 2026-08-16).
    "claude-sonnet-5" => [{~D[2026-09-01], {3.00, 15.00}}]
  }

  @doc """
  Published rate changes, as `%{model_id => [{effective_from, {input, output}}]}`.

  An id absent here has no announced change — its `:pricing` is simply the
  rate. An id present here is priced at `:pricing` until the first date, then
  at that entry's rate. Entries are resolved by `Agent.Pricing` at request
  time, never baked into the build.
  """
  @spec pricing_schedule() :: %{String.t() => [{Date.t(), {number(), number()}}]}
  def pricing_schedule, do: @pricing_schedule

  @doc """
  Which thinking dialect this model speaks.

  `:adaptive` — send `%{type: "adaptive"}`; `budget_tokens` is a 400.
  `:budget`   — send `%{type: "enabled", budget_tokens: N}`.
  `:none`     — omit `thinking` entirely.

  Unknown models default to `:adaptive`, which is the safe choice: it is what
  every current model accepts, and a wrong `:budget` guess is a hard 400.
  """
  @spec thinking_mode(String.t() | nil) :: :adaptive | :budget | :none
  def thinking_mode(id) do
    case resolve(id) do
      nil -> :adaptive
      m -> m.thinking
    end
  end

  @doc "True when this model takes `thinking: {type: \"adaptive\"}`."
  @spec adaptive_thinking?(String.t() | nil) :: boolean()
  def adaptive_thinking?(id), do: thinking_mode(id) == :adaptive

  # ── Effort (`output_config.effort`) ──────────────────────────────────────
  #
  # On every adaptive-thinking model the thinking BLOCK carries no depth
  # information — `%{type: "adaptive"}` is the same payload at every tier. Depth
  # is steered by a separate top-level `output_config.effort`, and OSA sent that
  # field nowhere, so the whole `Agent.Effort` ladder was inert on Anthropic's
  # current models: `/effort fast` and `/effort ultra` produced byte-identical
  # requests.
  #
  # Support is per-model and NOT uniform:
  #
  #   * `:full`     — low | medium | high | xhigh | max  (Claude 5 family, Opus 4.7/4.8)
  #   * `:no_xhigh` — low | medium | high | max          (Opus 4.6, Sonnet 4.6;
  #                   `xhigh` was introduced with Opus 4.7 and is rejected here)
  #   * `:none`     — the field errors on this model      (Haiku 4.5 and older)
  #
  # Source: https://platform.claude.com/docs/en/build-with-claude/effort
  @effort_ladders %{
    full: ~w(low medium high xhigh max),
    no_xhigh: ~w(low medium high max),
    none: []
  }

  @doc """
  Which `output_config.effort` levels this model accepts, lowest→highest.

  `[]` means the model has no effort parameter and the field must be omitted —
  sending it is a request error, not a degraded response.
  """
  @spec effort_levels(String.t() | nil) :: [String.t()]
  def effort_levels(id) do
    mode =
      case resolve(id) do
        # An unknown id is assumed current-generation, matching `thinking_mode/1`.
        nil -> :full
        m -> Map.get(m, :effort, :full)
      end

    Map.get(@effort_ladders, mode, [])
  end

  @doc """
  Map an OSA effort level onto the wire value for `output_config.effort`.

  Returns `nil` when nothing should be sent — either the model has no effort
  parameter, or the level is unrecognised. **A corrupt or unknown level omits
  the field rather than guessing**, so the model runs at its own documented
  default (`high`) and the run is honestly recorded as unpinned.

  The ladder maps one-to-one onto Anthropic's, with `:ultra` — OSA's top rung —
  landing on `max`:

      fast → low    medium → medium    high → high    xhigh → xhigh    ultra → max

  Legacy OSA names route through `Agent.Effort.normalize/1` first, so `:low`
  becomes `low` and `:max` becomes `xhigh` (OSA renamed `:max` to `:xhigh`; the
  rung that means "spend everything" is `:ultra`).

  On a `:no_xhigh` model an `xhigh` request **clamps down to `high`**, not up to
  `max` — a level the model does not accept must not silently become a more
  expensive one.
  """
  @spec effort_value(String.t() | nil, atom() | String.t() | nil) :: String.t() | nil
  def effort_value(model, level) do
    levels = effort_levels(model)

    with false <- levels == [],
         wire when is_binary(wire) <- ladder_value(level) do
      clamp_effort(wire, levels)
    else
      _ -> nil
    end
  end

  defp ladder_value(nil), do: nil

  defp ladder_value(level) do
    case OptimalSystemAgent.Agent.Effort.normalize(level) do
      :fast -> "low"
      :medium -> "medium"
      :high -> "high"
      :xhigh -> "xhigh"
      :ultra -> "max"
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Clamp DOWN to the nearest accepted level. `xhigh` on a model that predates
  # it becomes `high`, never `max`.
  defp clamp_effort(wire, levels) do
    if wire in levels do
      wire
    else
      order = @effort_ladders.full
      idx = Enum.find_index(order, &(&1 == wire))

      order
      |> Enum.take(idx || 0)
      |> Enum.reverse()
      |> Enum.find(&(&1 in levels))
    end
  end

  @doc """
  True when this model accepts a request whose last message is `assistant`
  (an "assistant message prefill").

  Anthropic **removed** prefill on Opus/Sonnet 4.6 and everything newer,
  including the whole Claude 5 family: a request whose final message is an
  assistant turn returns a **400**

      This model does not support assistant message prefill.
      The conversation must end with a user message.

  Only Haiku 4.5 and older still accept it. `Providers.Anthropic` reads this
  flag to decide whether to normalize a trailing assistant message before
  dispatch, so 4.5-era behaviour stays byte-for-byte unchanged.

  Unknown models default to `false`, which is the safe direction: normalizing
  a prefill a model would have accepted costs one extra user turn, while
  sending one it rejects is a hard 400 that kills the turn.
  """
  @spec supports_prefill?(String.t() | nil) :: boolean()
  def supports_prefill?(id) do
    case resolve(id) do
      nil -> false
      m -> Map.get(m, :prefill, false)
    end
  end

  @doc "Default output-token cap for a model. Falls back to 32k for unknown ids."
  @spec max_output(String.t() | nil) :: pos_integer()
  def max_output(id) do
    case resolve(id) do
      nil -> 32_000
      m -> m.max_output
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

  @doc "Capability lookup. Returns nil for an unknown model."
  @spec capability(String.t() | nil, :vision | :tools) :: boolean() | nil
  def capability(id, flag) when flag in [:vision, :tools] do
    case resolve(id) do
      nil -> nil
      m -> Map.get(m, flag)
    end
  end

  @doc "Picker entries for the onboarding / `/model` dialogs."
  @spec picker_models() :: [map()]
  def picker_models do
    @models
    |> Enum.reject(& &1.legacy)
    |> Enum.map(fn m ->
      %{
        id: m.id,
        name: m.name,
        ctx: m.ctx,
        tools: m.tools,
        recommended: m.recommended,
        note: m.note
      }
    end)
  end
end
