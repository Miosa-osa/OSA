defmodule OptimalSystemAgent.Providers.MistralModels do
  @moduledoc """
  **Single source of truth for the Mistral model catalog.**

  ## What was wrong

  OSA recorded `mistral-large-latest` / `mistral-small-latest` at **128,000**
  context and an **8,192** max output. Both numbers were wrong in different
  ways:

    * The aliases had moved. `mistral-large-latest` now resolves to Mistral
      **Large 3** (`mistral-large-2512`) and `mistral-small-latest` to Mistral
      **Small 4** (`mistral-small-2603`), both of which are **256k**, not 128k.
      OSA was budgeting half the real window on every turn.
    * The 8,192 max output was **never a Mistral number at all**. Mistral
      publishes no max output for any model; its chat API states only the
      relative constraint that prompt + `max_tokens` must fit the context
      window. So 8,192 was a fabricated ceiling that silently truncated long
      answers.

  `mistral-medium-latest` was OSA's `:specialist` tier and is genuinely current
  (Medium 3.5), so it stays.

  ## Where 262,144 came from

  Mistral publishes the window as the string `256k` and never as an integer, so
  256,000 vs 262,144 was unresolvable from the docs — and the two differ by
  6,144 tokens, enough to overflow a context-full turn.

  Resolved by **live API query**: OpenRouter's public endpoints API reports
  what each upstream actually serves, and the **Mistral first-party** endpoint
  returns `context_length: 262144` for both `mistral-large-2512` and
  `mistral-small-2603`. The same response returns
  `max_completion_tokens: null`, independently confirming that Mistral
  publishes no output ceiling.

  ## Max output is deliberately absent

  `max_output/1` returns `nil` for every Mistral model, which
  `ModelLimits.max_output/1` propagates as "unknown — use your own fallback".
  OSA therefore does not clamp output on Mistral. That is correct: the real
  constraint is `prompt + max_tokens <= context`, which the context budgeter
  already enforces, and inventing a second, smaller ceiling is what caused the
  truncation.

  ## Do NOT add Magistral or Devstral

  Both lines were **retired 2026-07-31**. Reasoning folded into Mistral Small 4;
  coding-agent work folded into Mistral Medium 3.5. They still appear on
  Mistral's pricing page, which makes them look alive — they are not.

  Sources: https://docs.mistral.ai/models/overview,
  https://docs.mistral.ai/models/model-cards/mistral-large-3-25-12,
  https://docs.mistral.ai/models/model-cards/mistral-small-4-0-26-03,
  https://mistral.ai/pricing/api (checked 2026-08-01), with the exact context
  integer from the live OpenRouter endpoints API (queried 2026-08-01).
  """

  @typedoc "A single Mistral model offering. `max_output` is always nil — see moduledoc."
  @type model :: %{
          id: String.t(),
          name: String.t(),
          ctx: pos_integer(),
          max_output: nil,
          reasoning: boolean(),
          tools: boolean(),
          pricing: {number(), number()} | nil,
          recommended: boolean(),
          note: String.t()
        }

  @models [
    %{
      id: "mistral-medium-latest",
      name: "Mistral Medium 3.5",
      ctx: 262_144,
      max_output: nil,
      # Medium 3.5 exposes adjustable reasoning via reasoning_effort.
      reasoning: true,
      tools: true,
      pricing: {1.50, 7.50},
      recommended: true,
      note: "256K ctx — frontier agentic + coding, adjustable reasoning. Default."
    },
    %{
      id: "mistral-large-latest",
      name: "Mistral Large 3",
      ctx: 262_144,
      max_output: nil,
      reasoning: false,
      tools: true,
      pricing: {0.50, 1.50},
      recommended: false,
      note: "256K ctx — 675B/41B active MoE; cheaper than Medium 3.5"
    },
    %{
      id: "mistral-small-latest",
      name: "Mistral Small 4",
      ctx: 262_144,
      max_output: nil,
      # Small 4 is a hybrid instruct + reasoning + coding model.
      reasoning: true,
      tools: true,
      pricing: {0.15, 0.60},
      recommended: false,
      note: "256K ctx — hybrid instruct/reasoning/coding, very cheap"
    },
    %{
      id: "codestral-latest",
      name: "Codestral",
      ctx: 131_072,
      max_output: nil,
      reasoning: false,
      tools: true,
      pricing: {0.30, 0.90},
      recommended: false,
      # Mistral publishes Codestral's window as "128k"; unlike the 256k models
      # this one has no live first-party endpoint on OpenRouter to disambiguate,
      # so 131_072 is the binary reading, consistent with every other vendor's
      # use of "128k". Flagged rather than silently assumed.
      note: "128K ctx — fill-in-the-middle + code completion"
    }
  ]

  @by_id Map.new(@models, &{&1.id, &1})

  # Dated snapshot ids the `-latest` aliases currently resolve to. Recorded so a
  # user who pins a dated id gets the same window as the alias instead of
  # falling through to the flat 128k default.
  @aliases %{
    "mistral-large-2512" => "mistral-large-latest",
    "mistral-small-2603" => "mistral-small-latest",
    "codestral-2508" => "codestral-latest"
  }

  @doc "The full catalog, in picker display order."
  @spec models() :: [model()]
  def models, do: @models

  @doc "Look up one model by exact id. Returns nil for unknown ids."
  @spec model(String.t() | nil) :: model() | nil
  def model(id) when is_binary(id), do: Map.get(@by_id, id)
  def model(_), do: nil

  @doc "Look up a model by alias or dated snapshot id."
  @spec resolve(String.t() | nil) :: model() | nil
  def resolve(id) when is_binary(id) do
    down = id |> String.trim() |> String.downcase()

    case model(down) do
      nil -> @aliases |> Map.get(down) |> model()
      found -> found
    end
  end

  def resolve(_), do: nil

  @doc "The default Mistral model for a fresh install."
  @spec default_model() :: String.t()
  def default_model, do: "mistral-medium-latest"

  @doc "Model ids, in display order."
  @spec ids() :: [String.t()]
  def ids, do: Enum.map(@models, & &1.id)

  @doc """
  `%{model_id => context_window}` for merging into the Registry table.

  Includes the dated snapshot ids as well as the `-latest` aliases, so a pinned
  `mistral-large-2512` budgets identically to `mistral-large-latest`.
  """
  @spec context_windows() :: %{String.t() => pos_integer()}
  def context_windows do
    base = Map.new(@models, &{&1.id, &1.ctx})

    Enum.reduce(@aliases, base, fn {dated, target}, acc ->
      case Map.get(base, target) do
        nil -> acc
        ctx -> Map.put(acc, dated, ctx)
      end
    end)
  end

  @doc """
  Always `%{}` — Mistral publishes no max output token value for any model.

  Present so callers can merge this uniformly with the other catalogs, and so
  the absence is explicit rather than an oversight. The 8,192 that used to sit
  here was invented.
  """
  @spec max_outputs() :: %{}
  def max_outputs, do: %{}

  @doc "`%{model_id => {input, output}}` USD per 1M tokens, aliases and dated ids."
  @spec pricing() :: %{String.t() => {number(), number()}}
  def pricing do
    base =
      @models
      |> Enum.filter(& &1.pricing)
      |> Map.new(&{&1.id, &1.pricing})

    Enum.reduce(@aliases, base, fn {dated, target}, acc ->
      case Map.get(base, target) do
        nil -> acc
        rates -> Map.put(acc, dated, rates)
      end
    end)
  end

  @doc "Context window for a model, or nil when unknown."
  @spec context_window(String.t() | nil) :: pos_integer() | nil
  def context_window(id) do
    case resolve(id) do
      nil -> nil
      m -> m.ctx
    end
  end

  @doc "Always nil — see the moduledoc. Mistral publishes no output ceiling."
  @spec max_output(String.t() | nil) :: nil
  def max_output(_id), do: nil

  @doc "True when this model supports adjustable reasoning."
  @spec reasoning?(String.t() | nil) :: boolean()
  def reasoning?(id) do
    case resolve(id) do
      nil -> false
      m -> m.reasoning
    end
  end
end
