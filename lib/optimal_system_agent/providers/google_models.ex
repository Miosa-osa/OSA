defmodule OptimalSystemAgent.Providers.GoogleModels do
  @moduledoc """
  **Single source of truth for the Google Gemini model catalog.**

  Mirrors `Providers.AnthropicModels` / `Providers.OpenAIModels`. Before this
  module, one Gemini id had to be edited into seven unrelated places — the
  provider's `available_models/0`, `Registry.@static_context_windows`,
  `ModelLimits.@static_max_output`, `Agent.Pricing.@static_pricing`,
  `Agent.Tier.@tier_models`, the `Catalog` overlay, and the onboarding picker —
  and a miss produced a *half-added* model that resolved in one surface and
  mis-budgeted in another. Everything except the tier map now derives from
  `models/0`.

  ## `:thinking` is load-bearing, not cosmetic

  Gemini 3.x **replaced the token budget with an effort enum**. The current
  models take `generationConfig.thinkingLevel` (`"minimal" | "low" | "medium" |
  "high"`); `thinkingBudget` is legacy, retained only for backward
  compatibility, and **the two are mutually exclusive — sending both is an
  error**. Only the 2.5 series ever took a raw token count.

  This mattered concretely: OSA decided "is this a thinking model?" with
  `String.contains?(name, "2.5")`. When the default moved to
  `gemini-3.6-flash`, that predicate went false, so OSA sent **no thinking
  configuration at all** and the entire `Agent.Effort` ladder was a silent
  no-op on Google — exactly the same class of gap as never sending
  `output_config.effort` to Anthropic.

  Note also that **thinking cannot be disabled on any Gemini 3 model**: the
  floor is `minimal`, and `gemini-3.1-pro-preview` does not even offer that —
  its lowest level is `low`. `thinking_level/2` clamps into each model's own
  supported set rather than emitting a value the vendor will reject.

  ## Adding a model

  1. Take `ctx` / `max_output` / pricing from Google's model page — never a
     blog post. Never add an id whose window you cannot source.
  2. Set `:thinking` to `:level` for 3.x, `:budget` for 2.5, `:none` if it has
     no thinking mode, and list the levels the model actually accepts.
  3. Record any published shutdown date in `Providers.Retirements`.
  4. `mix compile` + `mix test test/providers`.

  Sources: https://ai.google.dev/gemini-api/docs/models,
  https://ai.google.dev/gemini-api/docs/pricing,
  https://ai.google.dev/gemini-api/docs/thinking and
  https://ai.google.dev/gemini-api/docs/deprecations (all checked 2026-08-01).

  **Not verified against a live API.** No `GOOGLE_API_KEY` / `GEMINI_API_KEY`
  exists in this environment, so `GET /v1beta/models` — which is authoritative
  for both the id list and per-model limits — could not be called. Every number
  below is from Google's published model pages.
  """

  @typedoc "Which thinking dialect a Gemini model speaks."
  @type thinking :: :level | :budget | :none

  @typedoc "A single Gemini model offering."
  @type model :: %{
          id: String.t(),
          name: String.t(),
          ctx: pos_integer(),
          max_output: pos_integer(),
          thinking: thinking(),
          levels: [String.t()],
          default_level: String.t() | nil,
          vision: boolean(),
          audio: boolean(),
          tools: boolean(),
          pricing: {number(), number()} | nil,
          recommended: boolean(),
          preview: boolean(),
          legacy: boolean(),
          note: String.t()
        }

  @all_levels ["minimal", "low", "medium", "high"]

  # Display order: recommended default first, then cheaper/faster, then Pro.
  @models [
    %{
      id: "gemini-3.6-flash",
      name: "Gemini 3.6 Flash",
      ctx: 1_048_576,
      max_output: 65_536,
      thinking: :level,
      levels: @all_levels,
      default_level: "medium",
      vision: true,
      audio: true,
      tools: true,
      pricing: {1.50, 7.50},
      recommended: true,
      preview: false,
      legacy: false,
      note: "1M ctx — best agentic coding on Gemini. Default."
    },
    %{
      id: "gemini-3.5-flash",
      name: "Gemini 3.5 Flash",
      ctx: 1_048_576,
      max_output: 65_536,
      thinking: :level,
      levels: @all_levels,
      default_level: "medium",
      vision: true,
      audio: true,
      tools: true,
      # Same input price as 3.6 Flash but $9.00 output vs $7.50, and lower
      # agentic scores — kept for pinning, not recommended.
      pricing: {1.50, 9.00},
      recommended: false,
      preview: false,
      legacy: false,
      note: "1M ctx — previous Flash; 3.6 is cheaper on output and scores higher"
    },
    %{
      id: "gemini-3.5-flash-lite",
      name: "Gemini 3.5 Flash-Lite",
      ctx: 1_048_576,
      max_output: 65_536,
      thinking: :level,
      levels: @all_levels,
      # Lite defaults to minimal thinking, unlike full Flash.
      default_level: "minimal",
      vision: true,
      audio: true,
      tools: true,
      pricing: {0.30, 2.50},
      recommended: false,
      preview: false,
      legacy: false,
      note: "1M ctx — cheapest current Gemini, for high-volume simple work"
    },
    %{
      id: "gemini-3.1-flash-lite",
      name: "Gemini 3.1 Flash-Lite",
      ctx: 1_048_576,
      max_output: 65_536,
      thinking: :level,
      levels: @all_levels,
      default_level: "minimal",
      vision: true,
      audio: true,
      tools: true,
      pricing: {0.25, 1.50},
      recommended: false,
      preview: false,
      # Shutdown 2027-05-07 — well outside the 90-day guard, so still offerable.
      legacy: true,
      note: "1M ctx — cheapest overall; shuts down 2027-05-07"
    },
    %{
      id: "gemini-3.1-pro-preview",
      name: "Gemini 3.1 Pro (preview)",
      ctx: 1_048_576,
      max_output: 65_536,
      thinking: :level,
      # Pro has NO "minimal" level — its floor is "low".
      levels: ["low", "medium", "high"],
      default_level: "high",
      vision: true,
      audio: true,
      tools: true,
      # Google prices Pro in two tiers by prompt size: $2.00/$12.00 at or below
      # 200K input tokens, $4.00/$18.00 above it. We record the ≤200K tier, so a
      # long-context Pro turn UNDER-estimates cost by ~1.5x. Recorded rather than
      # averaged because most turns sit under 200K; the alternative (a fabricated
      # blended rate) would be wrong for every turn instead of some.
      pricing: {2.00, 12.00},
      recommended: false,
      preview: true,
      legacy: false,
      note: "1M ctx — strongest Gemini reasoning; preview, 1.3–2.7x the price"
    }
  ]

  # `gemini-2.5-pro` / `gemini-2.5-flash` / `gemini-2.5-flash-lite` are
  # DELIBERATELY ABSENT. They still serve today, but Google shuts all three down
  # on 2026-10-16 — inside the 90-day "too soon to offer" window. A model that
  # dies in ten weeks is not a safe fresh pick: the user selects it now and
  # breaks later, long after the choice that caused it. They remain in
  # `Providers.Retirements` so an existing pinned config is still *diagnosed*
  # correctly, they are just no longer offered.
  #
  # `gemini-2.0-flash` (shut down 2026-06-01) and the `gemini-3-*-preview` pair
  # are likewise absent — those are already dead.

  @by_id Map.new(@models, &{&1.id, &1})

  @doc "The full catalog, in picker display order."
  @spec models() :: [model()]
  def models, do: @models

  @doc "Look up one model by exact id. Returns nil for unknown ids."
  @spec model(String.t() | nil) :: model() | nil
  def model(id) when is_binary(id), do: Map.get(@by_id, id)
  def model(_), do: nil

  @doc """
  Look up a model by id, tolerating a suffix (e.g. a `-preview`/date variant or
  a `models/` path prefix). Longest id wins so a short id can never shadow a
  longer, more specific one.
  """
  @spec resolve(String.t() | nil) :: model() | nil
  def resolve(id) when is_binary(id) do
    down = id |> String.trim() |> String.downcase() |> String.replace_prefix("models/", "")

    case model(down) do
      nil ->
        @models
        |> Enum.filter(&String.starts_with?(down, &1.id))
        |> Enum.max_by(&String.length(&1.id), fn -> nil end)

      found ->
        found
    end
  end

  def resolve(_), do: nil

  @doc "The default Gemini model for a fresh install."
  @spec default_model() :: String.t()
  def default_model, do: "gemini-3.6-flash"

  @doc "Model ids in display order — what `Providers.Google.available_models/0` returns."
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

  @doc "Context window for a model, or nil when unknown."
  @spec context_window(String.t() | nil) :: pos_integer() | nil
  def context_window(id), do: with(%{ctx: c} <- resolve(id), do: c) |> nil_unless_int()

  @doc "Max output tokens for a model, or nil when unknown."
  @spec max_output(String.t() | nil) :: pos_integer() | nil
  def max_output(id), do: with(%{max_output: n} <- resolve(id), do: n) |> nil_unless_int()

  defp nil_unless_int(n) when is_integer(n), do: n
  defp nil_unless_int(_), do: nil

  @doc """
  Which thinking dialect this model speaks.

  `:level`  — send `generationConfig.thinkingLevel` (Gemini 3.x).
  `:budget` — send `generationConfig.thinkingConfig.thinkingBudget` (2.5 only).
  `:none`   — omit thinking configuration entirely.

  Unknown ids answer `:none`: an unrecognised model must not have a guessed
  thinking dialect forced onto it, because `thinkingLevel` and `thinkingBudget`
  are mutually exclusive and the wrong one is a hard request error.
  """
  @spec thinking_mode(String.t() | nil) :: thinking()
  def thinking_mode(id) do
    case resolve(id) do
      nil -> legacy_thinking_mode(id)
      m -> m.thinking
    end
  end

  # Ids this catalog no longer carries can still arrive from a pinned config.
  # The 2.5 family is the one family that genuinely takes a token budget.
  defp legacy_thinking_mode(id) when is_binary(id) do
    if String.contains?(String.downcase(id), "2.5"), do: :budget, else: :none
  end

  defp legacy_thinking_mode(_), do: :none

  @doc "True when this model takes `thinkingLevel` (Gemini 3.x)."
  @spec level_thinking?(String.t() | nil) :: boolean()
  def level_thinking?(id), do: thinking_mode(id) == :level

  @doc "True when this model takes a raw `thinkingBudget` token count (2.5 only)."
  @spec budget_thinking?(String.t() | nil) :: boolean()
  def budget_thinking?(id), do: thinking_mode(id) == :budget

  @doc """
  Map an OSA effort level onto this model's `thinkingLevel`, clamped into the
  set the model actually accepts.

  Returns `nil` for a model that does not take `thinkingLevel` at all.

  The clamp is why this is not a plain lookup table: `gemini-3.1-pro-preview`
  rejects `"minimal"`, so an `:off`/`:fast` turn on Pro must send `"low"` — the
  model's real floor — rather than a value the API refuses. Thinking cannot be
  switched off on any Gemini 3 model, so "off" means "as little as this model
  allows", not "absent".
  """
  @spec thinking_level(String.t() | nil, term()) :: String.t() | nil
  def thinking_level(id, effort) do
    case resolve(id) do
      %{thinking: :level, levels: levels} -> clamp_level(effort_to_level(effort), levels)
      _ -> nil
    end
  end

  defp effort_to_level(effort) do
    case effort |> to_string() |> String.trim() |> String.downcase() do
      "off" -> "minimal"
      "none" -> "minimal"
      "fast" -> "minimal"
      "low" -> "low"
      "medium" -> "medium"
      "high" -> "high"
      "xhigh" -> "high"
      "max" -> "high"
      "ultra" -> "high"
      # An unknown / corrupt persisted effort falls back to the middle of the
      # ladder rather than the floor — garbage config must not silently
      # DE-ESCALATE reasoning, only an explicit off/fast may do that.
      _ -> "medium"
    end
  end

  # Raise the requested level to the model's lowest supported one when the model
  # does not offer it; never lower a request.
  defp clamp_level(level, levels) do
    if level in levels do
      level
    else
      Enum.find(@all_levels, List.first(levels), fn l ->
        l in levels and rank(l) >= rank(level)
      end)
    end
  end

  defp rank(level), do: Enum.find_index(@all_levels, &(&1 == level)) || 0

  @doc "Capability lookup. Returns nil for an unknown model."
  @spec capability(String.t() | nil, :vision | :tools | :audio) :: boolean() | nil
  def capability(id, flag) when flag in [:vision, :tools, :audio] do
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
