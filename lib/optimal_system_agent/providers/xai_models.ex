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
  for every turn instead of some.

  Sources: https://docs.x.ai/developers/models,
  https://docs.x.ai/developers/pricing,
  https://docs.x.ai/developers/migration/may-15-retirement (checked
  2026-08-01), with context windows independently confirmed against the live
  OpenRouter endpoints API for xAI's own first-party endpoint.
  """

  @typedoc "A single xAI model offering. `max_output` is always nil — see moduledoc."
  @type model :: %{
          id: String.t(),
          name: String.t(),
          ctx: pos_integer(),
          max_output: nil,
          reasoning: boolean(),
          efforts: [String.t()],
          tools: boolean(),
          pricing: {number(), number()} | nil,
          recommended: boolean(),
          note: String.t()
        }

  @models [
    %{
      id: "grok-4.5",
      name: "Grok 4.5",
      ctx: 500_000,
      max_output: nil,
      reasoning: true,
      # 4.5 cannot disable reasoning — no "none".
      efforts: ["low", "medium", "high"],
      tools: true,
      pricing: {2.00, 6.00},
      recommended: true,
      note: "500K ctx — xAI's coding/agentic model (alias grok-build-latest). Default."
    },
    %{
      id: "grok-4.3",
      name: "Grok 4.3",
      ctx: 1_000_000,
      max_output: nil,
      reasoning: true,
      efforts: ["none", "low", "medium", "high"],
      tools: true,
      pricing: {1.25, 2.50},
      recommended: false,
      note: "1M ctx — half the price of 4.5, strong tool calling"
    },
    %{
      id: "grok-4.20-0309-reasoning",
      name: "Grok 4.20 (reasoning)",
      ctx: 1_000_000,
      max_output: nil,
      reasoning: true,
      efforts: ["low", "medium", "high"],
      tools: true,
      pricing: {1.25, 2.50},
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
      tools: true,
      pricing: {1.00, 2.00},
      recommended: false,
      note: "256K ctx — cheapest coding option; previous generation"
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

  @doc "Look up a model by id, tolerating a `-latest` / dated suffix."
  @spec resolve(String.t() | nil) :: model() | nil
  def resolve(id) when is_binary(id) do
    down = id |> String.trim() |> String.downcase()

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

  @doc "The default xAI model for a fresh install."
  @spec default_model() :: String.t()
  def default_model, do: "grok-4.5"

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
