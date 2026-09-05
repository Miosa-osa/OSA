defmodule OptimalSystemAgent.Providers.OpenAIModels do
  @moduledoc """
  **Single source of truth for the OpenAI model catalog.**

  ## Why this module exists

  Adding one OpenAI model used to require edits in seven unrelated files, and
  every miss produced a *half-added* model. This was not hypothetical: before
  this module existed the onboarding picker offered `gpt-5.4-pro`,
  `gpt-5.2-pro` and `gpt-5.2-chat`, none of which appeared in any context-window
  table, max-output table, pricing table, or catalog. Selecting one gave you a
  context budget of the fabricated 128k default, no output ceiling, and $0.00
  cost accounting — the model *looked* supported and silently wasn't.

  The surfaces that used to need hand-editing:

    * `Providers.OpenAICompatProvider.@provider_configs` — `available_models`.
    * `Registry.@static_context_windows` — or the model is budgeted at the flat
      128k `:max_context_tokens` default.
    * `Providers.ModelLimits.@max_output` — or long answers truncate.
    * `Agent.Pricing.@pricing` — or every turn is accounted at $0.00.
    * `Providers.Catalog` embedded fallback — or the offline catalog lies.
    * `Onboarding.providers_list/0` — the picker.
    * `Agent.Tier.@tier_models` — an editorial decision, NOT derived from here.

  Everything except the tier map now DERIVES from `models/0` below.

  ## The `:reasoning` flag is load-bearing

  Reasoning models reject `temperature` and instead take a `reasoning_effort`
  parameter. `OpenAICompat` previously decided this with `String.starts_with?`
  prefix checks on `"o1"` / `"o3"` / `"o4"` — which silently fails for the
  GPT-5.x reasoning models, whose names begin with `gpt`. `reasoning?/1` here
  is the single answer, so temperature suppression and `reasoning_effort`
  injection can never disagree.

  ## How to add a new OpenAI model

  1. Take the numbers from OpenAI's model reference page — never a blog post.
  2. Set `:pricing` to `{input, output}` USD per 1M tokens, or `nil` rather
     than guessing (an unpriced model accounts at $0.00 and logs, which is
     honest; a guessed price is not).
  3. `mix compile` + `mix test test/providers`. Nothing else to touch.

  Sources: https://developers.openai.com/api/docs/models and
  https://developers.openai.com/api/docs/pricing (checked 2026-08-01).
  """

  @typedoc "A single OpenAI model offering."
  @type model :: %{
          id: String.t(),
          name: String.t(),
          ctx: pos_integer(),
          max_output: pos_integer(),
          reasoning: boolean(),
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
      id: "gpt-6-astra",
      name: "GPT-6 Astra",
      ctx: 1_050_000,
      max_output: 128_000,
      reasoning: true,
      vision: true,
      tools: true,
      pricing: {10.00, 50.00},
      recommended: false,
      legacy: false,
      note: "Responses API required for tools; availability depends on account access"
    },
    %{
      id: "gpt-5.6-terra",
      name: "GPT-5.6 Terra",
      ctx: 1_050_000,
      max_output: 128_000,
      reasoning: true,
      vision: true,
      tools: true,
      pricing: {2.00, 12.00},
      recommended: true,
      legacy: false,
      note: "1.05M ctx — best balance of capability and cost. Default."
    },
    %{
      id: "gpt-5.6-sol",
      name: "GPT-5.6 Sol",
      ctx: 1_050_000,
      max_output: 128_000,
      reasoning: true,
      vision: true,
      tools: true,
      pricing: {5.00, 30.00},
      recommended: false,
      legacy: false,
      note: "1.05M ctx — most capable, for the hardest reasoning work"
    },
    %{
      id: "gpt-5.6-luna",
      name: "GPT-5.6 Luna",
      ctx: 1_050_000,
      max_output: 128_000,
      reasoning: true,
      vision: true,
      tools: true,
      pricing: {0.20, 1.20},
      recommended: false,
      legacy: false,
      note: "1.05M ctx — cheapest 5.6; high-throughput and simple tasks"
    },
    # gpt-5.5 and the gpt-5.4 / gpt-5.2 families are deliberately NOT listed:
    # their pricing is published but their context windows are not confirmed in
    # the model reference, and this module's contract is that a listed model
    # carries real numbers. A guessed context window is worse than an absent
    # model — it silently mis-budgets every turn.
    %{
      id: "o3",
      name: "o3",
      ctx: 200_000,
      max_output: 100_000,
      reasoning: true,
      vision: true,
      tools: true,
      pricing: {2.00, 8.00},
      recommended: false,
      legacy: true,
      note: "Legacy reasoning model"
    },
    %{
      id: "gpt-4o",
      name: "GPT-4o",
      ctx: 128_000,
      max_output: 16_384,
      reasoning: false,
      vision: true,
      tools: true,
      pricing: {2.50, 10.00},
      recommended: false,
      legacy: true,
      note: "Legacy non-reasoning model"
    },
    %{
      id: "gpt-4o-mini",
      name: "GPT-4o mini",
      ctx: 128_000,
      max_output: 16_384,
      reasoning: false,
      vision: true,
      tools: true,
      pricing: {0.15, 0.60},
      recommended: false,
      legacy: true,
      note: "Legacy small non-reasoning model"
    }
  ]

  @by_id Map.new(@models, &{&1.id, &1})

  # OpenAI publishes `gpt-5.6` as an alias for the Sol flagship. Users type it,
  # so resolve it rather than reporting an unknown model.
  @aliases %{"gpt-5.6" => "gpt-5.6-sol"}

  @doc "The full catalog, in picker display order."
  @spec models() :: [model()]
  def models, do: @models

  @doc "Look up one model by exact id. Returns nil for unknown ids."
  @spec model(String.t() | nil) :: model() | nil
  def model(id) when is_binary(id), do: Map.get(@by_id, id)
  def model(_), do: nil

  @doc """
  Look up a model by id, tolerating a dated snapshot suffix
  (e.g. "gpt-4o-2024-08-06" resolves to "gpt-4o"). Longest id wins so
  "gpt-4o-mini" is never shadowed by "gpt-4o".
  """
  @spec resolve(String.t() | nil) :: model() | nil
  def resolve(id) when is_binary(id) do
    down = String.downcase(id)

    case model(down) || model(Map.get(@aliases, down)) do
      nil ->
        @models
        |> Enum.filter(&String.starts_with?(down, &1.id))
        |> Enum.max_by(&String.length(&1.id), fn -> nil end)

      found ->
        found
    end
  end

  def resolve(_), do: nil

  @doc "The default model for a fresh install."
  @spec default_model() :: String.t()
  def default_model, do: "gpt-5.6-terra"

  @doc "Model ids, in display order."
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

  @doc """
  True when this model is a reasoning model — it rejects `temperature` and
  accepts `reasoning_effort`.

  Unknown ids fall back to a prefix heuristic so a model that ships before
  this table is updated still behaves correctly.

  The heuristic covers `gpt-5*` as well as the o-series, and that is not
  cosmetic. `OpenAICompat` already carries a comment saying the o-series-only
  scan "silently missed the GPT-5.x reasoning models — whose names begin with
  gpt" — but the fix landed only in the *call site*, which then delegated back
  to a function that still had the o-series-only fallback. Every GPT-5.x id
  this table does not list (`gpt-5.1`, `gpt-5.2`, and the whole Codex
  line-up — `gpt-5.2-codex`, `gpt-5.1-codex-max`, `gpt-5.1-codex-mini`) still
  answered `false`, so OSA kept sending them `temperature`, which they reject,
  and never sent an effort.

  Deliberately NOT `gpt-4*` or a bare `gpt` prefix: those are the
  non-reasoning models, and a heuristic that swept them in would suppress
  `temperature` on models that need it.
  """
  @spec reasoning?(String.t() | nil) :: boolean()
  def reasoning?(id) when is_binary(id) do
    case resolve(id) do
      nil ->
        m = String.downcase(id)

        String.starts_with?(m, "o1") or String.starts_with?(m, "o3") or
          String.starts_with?(m, "o4") or String.starts_with?(m, "gpt-5")

      model ->
        model.reasoning
    end
  end

  def reasoning?(_), do: false

  @doc "Default output-token cap for a model. Falls back to 16k for unknown ids."
  @spec max_output(String.t() | nil) :: pos_integer()
  def max_output(id) do
    case resolve(id) do
      nil -> 16_384
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
  @spec capability(String.t() | nil, :vision | :tools | :reasoning) :: boolean() | nil
  def capability(id, flag) when flag in [:vision, :tools, :reasoning] do
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
