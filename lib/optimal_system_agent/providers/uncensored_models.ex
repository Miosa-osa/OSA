defmodule OptimalSystemAgent.Providers.UncensoredModels do
  @moduledoc """
  **Single source of truth for what `api.uncensored.com` charges.**

  This is a PRICE list, not a model catalog. Every other catalog in this
  directory (`AnthropicModels`, `ZaiModels`, …) describes models a vendor
  built: context window, vision, reasoning vocabulary. This one describes a
  RESELLER's rate card for models other vendors built, and carries nothing but
  the rates, because the gateway publishes nothing but the rates. Windows and
  capabilities still resolve from the upstream vendor's catalog on the bare id,
  which is correct — the gateway serves the same models.

  ## Why it has to exist: an id collision that bills the wrong number

  The gateway relists its upstreams under the upstreams' OWN ids —
  `claude-opus-5`, `glm-5.2`, `grok-4-6`, `gpt-4o` — and charges its own
  prices for them. `Agent.Pricing` is keyed by model id alone, so before this
  module every uncensored turn exact-matched the VENDOR's rate card and billed
  the vendor's number, with `Pricing.confidence/1` reporting `:exact`. Measured
  on 2026-08-16, against the gateway's published rates:

      claude-opus-5    OSA billed {5.000, 25.00}  gateway charges {6.00, 30.00}
      glm-5.2          OSA billed {1.400,  4.40}  gateway charges {1.68,  5.28}
      deepseek-v4-pro  OSA billed {0.435,  0.87}  gateway charges {1.84,  3.66}

  All three under-billed — the direction that flatters us — and all three
  reported `:exact`. The gateway also serves ids no vendor catalog spells the
  same way: `grok-4-6` against xAI's `grok-4.6`, plus `qwen3-coder` and
  `hermes-3-llama-3.1-405b`, which no OSA catalog carries at all. Those did not
  mis-price so much as not price — `nil` rate, `:unknown`, $0.00 a turn.

  A wrong number reached by an exact path, flagged authoritative — the same
  shape as the pricing defects the class ratchet in
  `test/providers/silent_capability_loss_test.exs` exists for, and the reason
  this is a catalog rather than a special case in `Pricing`.

  ## The ids are namespaced, and that is the whole mechanism

  Each row is keyed `"uncensored/<gateway id>"`. `Pricing.lookup_keys/1` already
  tries the FULL id before it strips a vendor prefix — a property that module
  documents and relies on ("a catalog that ever does key a slashed id keeps
  winning on the full string"). So a namespaced key resolves here, and the bare
  id keeps resolving to the vendor, with no new lookup path and no provider
  argument threaded through the pricing API.

  `Agent.Loop.Accounting` composes that key through `Pricing.qualify/2`, which
  is the only place the provider is consulted.

  A model the gateway adds but this table does not carry still falls through to
  the bare id and the vendor's rate — the vendor's number, not a guess, and the
  best available answer until the row is added here.

  ## Provenance

  Every rate below is transcribed mechanically from the gateway's own public
  model list (`GET https://api.uncensored.com/api/v1/models`, no key required)
  as it stood on **2026-08-16**: 82 models, all of them priced. The endpoint
  quotes USD **per token**; the rates here are USD **per 1M tokens**, the unit
  `Pricing` works in. `cache_read` is the endpoint's `input_cache_read` column
  where it publishes one and `nil` where it does not, in which case `Pricing`
  falls back to its documented `input * 0.1` and reports `:multiplier`.

  > #### No live call has ever been made to this gateway {: .warning}
  >
  > There are no `api.uncensored.com` credentials on the machine this was
  > built on. The rates are the gateway's own published figures and the wiring
  > is covered by tests, but no request OSA builds for this provider has been
  > sent, and no bill has been reconciled against these numbers.
  """

  @type model :: %{
          gateway_id: String.t(),
          owned_by: String.t(),
          pricing: {number(), number()} | nil,
          cache_read: number() | nil
        }

  @raw [
    %{
      gateway_id: "aion-labs.aion-2-0",
      owned_by: "Aion Labs",
      pricing: {0.8, 1.6},
      cache_read: 0.2
    },
    %{
      gateway_id: "qwen-3-6-35b-a3b",
      owned_by: "Alibaba",
      pricing: {0.18, 1.2},
      cache_read: 0.06
    },
    %{
      gateway_id: "qwen-3-8-2-4t-a95b",
      owned_by: "Alibaba",
      pricing: {2.4, 7.2},
      cache_read: 0.3
    },
    %{gateway_id: "qwen-3-8-max", owned_by: "Alibaba", pricing: {2.4, 7.2}, cache_read: 0.3},
    %{
      gateway_id: "qwen3-235b-a22b-2507",
      owned_by: "Alibaba",
      pricing: {0.071, 0.1},
      cache_read: nil
    },
    %{
      gateway_id: "qwen3-235b-a22b-thinking-2507",
      owned_by: "Alibaba",
      pricing: {0.15, 1.495},
      cache_read: nil
    },
    %{gateway_id: "qwen3-30b-a3b", owned_by: "Alibaba", pricing: {0.09, 0.45}, cache_read: nil},
    %{
      gateway_id: "qwen3-5-35b-a3b",
      owned_by: "Alibaba",
      pricing: {0.163, 1.3},
      cache_read: 0.05
    },
    %{gateway_id: "qwen3-5-9b", owned_by: "Alibaba", pricing: {0.1, 0.15}, cache_read: nil},
    %{gateway_id: "qwen3-coder", owned_by: "Alibaba", pricing: {0.22, 1.8}, cache_read: 0.022},
    %{
      gateway_id: "qwen3-next-80b-a3b-instruct",
      owned_by: "Alibaba",
      pricing: {0.15, 1.5},
      cache_read: nil
    },
    %{
      gateway_id: "qwen3-vl-235b-a22b-thinking",
      owned_by: "Alibaba",
      pricing: {0.4, 4.0},
      cache_read: nil
    },
    %{
      gateway_id: "qwen3-vl-30b-a3b-thinking",
      owned_by: "Alibaba",
      pricing: {0.2, 1.56},
      cache_read: nil
    },
    %{
      gateway_id: "qwen3.5-397b-a17b",
      owned_by: "Alibaba",
      pricing: {0.6, 3.6},
      cache_read: 0.195
    },
    %{gateway_id: "qwen3.5-flash", owned_by: "Alibaba", pricing: {0.1, 0.4}, cache_read: nil},
    %{gateway_id: "qwen3.5-plus", owned_by: "Alibaba", pricing: {0.4, 2.4}, cache_read: nil},
    %{gateway_id: "qwen3.6-27b", owned_by: "Alibaba", pricing: {0.6, 3.6}, cache_read: nil},
    %{
      gateway_id: "claude-fable-5",
      owned_by: "Anthropic",
      pricing: {12.0, 60.0},
      cache_read: 1.2
    },
    %{
      gateway_id: "claude-haiku-4.5",
      owned_by: "Anthropic",
      pricing: {1.0, 5.0},
      cache_read: 0.1
    },
    %{
      gateway_id: "claude-opus-4.5",
      owned_by: "Anthropic",
      pricing: {5.0, 25.0},
      cache_read: 0.5
    },
    %{
      gateway_id: "claude-opus-4.6",
      owned_by: "Anthropic",
      pricing: {4.8, 23.8},
      cache_read: 0.5
    },
    %{
      gateway_id: "claude-opus-4.7",
      owned_by: "Anthropic",
      pricing: {4.8, 23.8},
      cache_read: 0.5
    },
    %{
      gateway_id: "claude-opus-4.8",
      owned_by: "Anthropic",
      pricing: {6.0, 30.0},
      cache_read: 0.5
    },
    %{gateway_id: "claude-opus-5", owned_by: "Anthropic", pricing: {6.0, 30.0}, cache_read: 0.6},
    %{
      gateway_id: "claude-opus-5-fast",
      owned_by: "Anthropic",
      pricing: {12.0, 60.0},
      cache_read: 1.2
    },
    %{
      gateway_id: "claude-sonnet-4.5",
      owned_by: "Anthropic",
      pricing: {3.0, 15.0},
      cache_read: 0.3
    },
    %{
      gateway_id: "claude-sonnet-4.6",
      owned_by: "Anthropic",
      pricing: {2.85, 14.3},
      cache_read: 0.3
    },
    %{gateway_id: "deepseek-r1", owned_by: "DeepSeek", pricing: {0.7, 2.5}, cache_read: nil},
    %{
      gateway_id: "deepseek-v3.2",
      owned_by: "DeepSeek",
      pricing: {0.26, 0.38},
      cache_read: 0.026
    },
    %{
      gateway_id: "deepseek-v4-flash",
      owned_by: "DeepSeek",
      pricing: {0.17, 0.34},
      cache_read: 0.028
    },
    %{
      gateway_id: "deepseek-v4-flash-0731",
      owned_by: "DeepSeek",
      pricing: {0.096, 0.216},
      cache_read: 0.019
    },
    %{
      gateway_id: "deepseek-v4-pro",
      owned_by: "DeepSeek",
      pricing: {1.84, 3.66},
      cache_read: 0.13
    },
    %{gateway_id: "gemini-2.5-flash", owned_by: "Google", pricing: {0.3, 2.5}, cache_read: 0.03},
    %{gateway_id: "gemini-2.5-pro", owned_by: "Google", pricing: {1.25, 10.0}, cache_read: nil},
    %{gateway_id: "gemini-3-6-flash", owned_by: "Google", pricing: {1.8, 9.0}, cache_read: 0.18},
    %{
      gateway_id: "gemini-3-flash-preview",
      owned_by: "Google",
      pricing: {0.5, 3.0},
      cache_read: 0.05
    },
    %{
      gateway_id: "gemini-3.1-flash-lite",
      owned_by: "Google",
      pricing: {0.25, 1.5},
      cache_read: 0.025
    },
    %{
      gateway_id: "gemini-3.1-pro-preview",
      owned_by: "Google",
      pricing: {2.0, 12.0},
      cache_read: 0.2
    },
    %{gateway_id: "gemma-3-27b-it", owned_by: "Google", pricing: {0.08, 0.16}, cache_read: nil},
    %{
      gateway_id: "llama-3.2-3b-instruct",
      owned_by: "Meta",
      pricing: {0.051, 0.34},
      cache_read: nil
    },
    %{
      gateway_id: "llama-3.3-70b-instruct",
      owned_by: "Meta",
      pricing: {0.1, 0.32},
      cache_read: nil
    },
    %{gateway_id: "minimax-m2.1", owned_by: "MiniMax", pricing: {0.3, 1.2}, cache_read: 0.03},
    %{gateway_id: "minimax-m2.5", owned_by: "MiniMax", pricing: {0.3, 1.2}, cache_read: 0.03},
    %{gateway_id: "minimax-m2.7", owned_by: "MiniMax", pricing: {0.3, 1.2}, cache_read: nil},
    %{gateway_id: "mistral-large", owned_by: "Mistral", pricing: {2.0, 6.0}, cache_read: 0.2},
    %{
      gateway_id: "mistral-small-3.2-24b-instruct",
      owned_by: "Mistral",
      pricing: {0.075, 0.2},
      cache_read: nil
    },
    %{gateway_id: "kimi-k2", owned_by: "Moonshot AI", pricing: {0.57, 2.3}, cache_read: nil},
    %{
      gateway_id: "kimi-k2-thinking",
      owned_by: "Moonshot AI",
      pricing: {0.6, 2.5},
      cache_read: 0.15
    },
    %{gateway_id: "kimi-k2.5", owned_by: "Moonshot AI", pricing: {0.6, 3.0}, cache_read: 0.1},
    %{gateway_id: "kimi-k2.6", owned_by: "Moonshot AI", pricing: {0.95, 4.0}, cache_read: 0.16},
    %{gateway_id: "kimi-k3", owned_by: "Moonshot AI", pricing: {3.6, 18.0}, cache_read: 0.36},
    %{
      gateway_id: "nvidia-nemotron-3-5-lightning-30b-a3b",
      owned_by: "NVIDIA",
      pricing: {0.12, 0.3},
      cache_read: 0.06
    },
    %{
      gateway_id: "nvidia-nemotron-3-nano-30b-a3b",
      owned_by: "NVIDIA",
      pricing: {0.05, 0.2},
      cache_read: nil
    },
    %{
      gateway_id: "hermes-3-llama-3.1-405b",
      owned_by: "Nous Research",
      pricing: {1.0, 1.0},
      cache_read: nil
    },
    %{gateway_id: "gpt-4o", owned_by: "OpenAI", pricing: {2.5, 10.0}, cache_read: nil},
    %{gateway_id: "gpt-4o-mini", owned_by: "OpenAI", pricing: {0.15, 0.6}, cache_read: 0.075},
    %{gateway_id: "gpt-5-mini", owned_by: "OpenAI", pricing: {0.25, 2.0}, cache_read: 0.025},
    %{gateway_id: "gpt-5-nano", owned_by: "OpenAI", pricing: {0.05, 0.4}, cache_read: 0.01},
    %{gateway_id: "gpt-5.2", owned_by: "OpenAI", pricing: {1.75, 14.0}, cache_read: 0.175},
    %{gateway_id: "gpt-5.2-codex", owned_by: "OpenAI", pricing: {1.75, 14.0}, cache_read: nil},
    %{gateway_id: "gpt-5.3-codex", owned_by: "OpenAI", pricing: {1.75, 14.0}, cache_read: 0.175},
    %{gateway_id: "gpt-5.4", owned_by: "OpenAI", pricing: {2.5, 15.0}, cache_read: nil},
    %{gateway_id: "gpt-5.4-mini", owned_by: "OpenAI", pricing: {0.75, 4.5}, cache_read: 0.075},
    %{gateway_id: "gpt-5.4-nano", owned_by: "OpenAI", pricing: {0.2, 1.25}, cache_read: 0.02},
    %{gateway_id: "gpt-5.4-pro", owned_by: "OpenAI", pricing: {30.0, 180.0}, cache_read: nil},
    %{gateway_id: "gpt-5.5", owned_by: "OpenAI", pricing: {5.0, 30.0}, cache_read: nil},
    %{gateway_id: "gpt-5.5-pro", owned_by: "OpenAI", pricing: {30.0, 180.0}, cache_read: nil},
    %{gateway_id: "gpt-5.6-luna", owned_by: "OpenAI", pricing: {1.2, 7.2}, cache_read: 0.12},
    %{gateway_id: "gpt-5.6-sol", owned_by: "OpenAI", pricing: {6.0, 36.0}, cache_read: 0.6},
    %{gateway_id: "gpt-5.6-terra", owned_by: "OpenAI", pricing: {3.0, 18.0}, cache_read: 0.3},
    %{
      gateway_id: "openai-gpt-oss-120b",
      owned_by: "OpenAI",
      pricing: {0.15, 0.6},
      cache_read: nil
    },
    %{
      gateway_id: "inkling",
      owned_by: "Thinking Machines",
      pricing: {1.14, 4.86},
      cache_read: 0.192
    },
    %{gateway_id: "glm-4.6", owned_by: "Z.ai", pricing: {0.43, 1.9}, cache_read: nil},
    %{gateway_id: "glm-4.7", owned_by: "Z.ai", pricing: {0.4, 1.75}, cache_read: nil},
    %{gateway_id: "glm-4.7-flash", owned_by: "Z.ai", pricing: {0.06, 0.4}, cache_read: nil},
    %{gateway_id: "glm-5", owned_by: "Z.ai", pricing: {0.72, 2.3}, cache_read: 0.12},
    %{gateway_id: "glm-5.1", owned_by: "Z.ai", pricing: {1.4, 4.4}, cache_read: 0.26},
    %{gateway_id: "glm-5.2", owned_by: "Z.ai", pricing: {1.68, 5.28}, cache_read: 0.26},
    %{gateway_id: "grok-4-6", owned_by: "xAI", pricing: {4.8, 14.4}, cache_read: 1.2},
    %{gateway_id: "grok-4.20-beta", owned_by: "xAI", pricing: {2.0, 6.0}, cache_read: 0.2},
    %{gateway_id: "grok-4.3", owned_by: "xAI", pricing: {1.25, 2.5}, cache_read: 0.2},
    %{gateway_id: "grok-4.5", owned_by: "xAI", pricing: {2.4, 7.2}, cache_read: nil}
  ]

  @prefix "uncensored/"

  @models Enum.map(@raw, &Map.put(&1, :id, @prefix <> &1.gateway_id))

  @by_id Map.new(@models, &{&1.id, &1})

  @doc "The full rate card. Each row's `:id` is the namespaced pricing key."
  @spec models() :: [model()]
  def models, do: @models

  @doc """
  The bare ids the gateway serves, in the spelling it expects on the wire.

  This is what `OpenAICompatProvider` advertises as the provider's model list,
  so the picker and the rate card cannot drift apart.
  """
  @spec gateway_ids() :: [String.t()]
  def gateway_ids, do: Enum.map(@models, & &1.gateway_id)

  @doc """
  The subset of `gateway_ids/0` worth OFFERING as a fresh pick — everything the
  gateway sells, minus what is at or within 90 days of its vendor's published
  retirement date.

  The gateway relists models past the point their vendors are steering people
  away from them (`gemini-2.5-flash`, retiring 2026-10-16, among others). Every
  other provider list in `OpenAICompatProvider` was pruned of those by hand;
  this one is derived from a live catalog and gets the same treatment
  mechanically.

  Resolved against **today**, not against the build date. A model dropping off
  this list does not drop off the rate card above: a session already pinned to
  one keeps billing at the price it is actually charged.
  """
  @spec offerable_ids() :: [String.t()]
  def offerable_ids do
    Enum.reject(gateway_ids(), &OptimalSystemAgent.Providers.Retirements.retiring_soon?/1)
  end

  @doc """
  The namespaced pricing key for a bare gateway id.

  Unconditional: an id this table does not carry still gets namespaced, so it
  resolves through `Pricing`'s normal prefix-stripping ladder to the vendor's
  rate rather than silently borrowing another uncensored model's price.
  """
  @spec key(String.t()) :: String.t()
  def key(gateway_id) when is_binary(gateway_id), do: @prefix <> gateway_id

  @doc """
  Look up one row by its NAMESPACED id. Exact match only.

  Deliberately not prefix- or decoration-tolerant, and never matches a bare
  vendor id: a `resolve/1` that answered for `"claude-opus-5"` would hand
  Anthropic's own turns this gateway's resale price.
  """
  @spec model(String.t() | nil) :: model() | nil
  def model(id) when is_binary(id), do: Map.get(@by_id, id)
  def model(_), do: nil

  @doc "`%{namespaced_id => {input, output}}` USD per 1M tokens."
  @spec pricing() :: %{String.t() => {number(), number()}}
  def pricing do
    @models
    |> Enum.filter(& &1.pricing)
    |> Map.new(&{&1.id, &1.pricing})
  end

  @doc """
  The gateway's published cached-input rate per 1M tokens for a NAMESPACED id,
  or nil when it publishes none (31 of the 82 do not).
  """
  @spec cache_read_rate(String.t() | nil) :: number() | nil
  def cache_read_rate(id) do
    case model(id) do
      nil -> nil
      m -> m.cache_read
    end
  end
end
