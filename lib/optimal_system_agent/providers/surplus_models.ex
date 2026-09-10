defmodule OptimalSystemAgent.Providers.SurplusModels do
  @moduledoc """
  Curated Surplus Intelligence models for the normal provider picker.

  Surplus exposes a larger, changing catalog at `/v1/models`. This list is
  intentionally only the editorial shortlist used for defaults, tiers, and
  offline fallback. The onboarding picker prepends these models to the live
  catalog so users can still select any currently available model.
  """

  # Verified against Surplus' live catalog on 2026-09-07. Keep this list
  # deliberately small and frontier-only. It is not a dump of every model
  # Surplus sells; the live picker still exposes those on demand.
  @featured [
    {"claude-fable-5.1", "Claude Fable 5.1"},
    # Claude 5 family — frontier priority. Surplus relists these under Anthropic's
    # own ids; the capability-keyed cache gate ("claude" substring) and the
    # dotted→dashed context-window resolver handle them with no per-id wiring.
    {"claude-opus-5", "Claude Opus 5"},
    {"claude-opus-5-fast", "Claude Opus 5 Fast"},
    {"claude-sonnet-5", "Claude Sonnet 5"},
    {"claude-fable-5", "Claude Fable 5"},
    {"glm-5.3-flash", "GLM 5.3 Flash"},
    {"muse-spark-1.3-contributor", "Meta: Muse Spark 1.3 Contributor"},
    {"gpt-6-astra", "GPT-6 Astra"},
    {"gemini-3.8-flash", "Gemini 3.8 Flash"},
    {"kimi-k3", "Kimi K3"},
    {"kimi-k3-fast-api", "Kimi K3 Fast"},
    {"qwen3.8-flash", "Qwen3.8 Flash"},
    {"deepseek-v4-pro", "DeepSeek V4 Pro"},
    {"deepseek-v4.1-flash", "DeepSeek V4.1 Flash"},
    {"deepseek-v4-flash", "DeepSeek V4 Flash"},
    {"gpt-5.6-luna", "GPT-5.6 Luna"},
    {"minimax-m3", "MiniMax M3"},
    {"xiaomi-mimo-v2-5", "Xiaomi MiMo V2.5"},
    {"qwen3.8-2.4t-a95b", "Qwen3.8 2.4T A95B"},
    {"qwen3-coder-next", "Qwen3 Coder Next"},
    {"mistral-large-3", "Mistral Large 3"},
    {"deepseek-v3.1", "DeepSeek V3.1"},
    {"claude-opus-4.8", "Claude Opus 4.8"},
    {"gpt-5.6-sol-pro", "GPT-5.6 Sol Pro"},
    {"grok-4.6", "Grok 4.6"},
    {"glm-5.3", "GLM 5.3"},
    {"minimax-m2", "MiniMax M2"}
  ]

  @featured_ids Enum.map(@featured, &elem(&1, 0))

  # ── Runtime rate card ────────────────────────────────────────────────────
  #
  # Surplus is a margin-charging RESELLER: it relists other vendors' model ids
  # (`gpt-6-astra`, `claude-opus-4.8`, `grok-4.6`) at its own price, and shares
  # ids that name a completely different rate on the native vendor. `Pricing` is
  # keyed by model id alone, so without a surplus-specific rate card every
  # surplus turn either billed the upstream vendor's number at `:exact` (wrong
  # vendor's rate) or, for an id no catalog carries (`kimi-k3`), billed $0.00 —
  # blinding `max_budget_usd` to the spend entirely.
  #
  # Unlike `UncensoredModels`, surplus has no static card to transcribe: its
  # prices are DYNAMIC, published only on the live `/v1/models` catalog, and
  # there is no API key at build time. So the rate card is a RUNTIME map,
  # populated from the parsed catalog (`put_runtime_pricing/1`) whenever the app
  # fetches it, and consulted by `Pricing` for `surplus/<id>` keys. Until it is
  # populated (fresh process, no catalog fetched yet), `Pricing` falls back to a
  # conservative provider-level rate reported `:estimated` — never $0, never a
  # native vendor's `:exact` row — so budget enforcement holds regardless.
  #
  # `:persistent_term` because this is written once per catalog fetch and read
  # from the hot cost-accounting loop on every round-trip; a GenServer would be
  # a bottleneck and an ETS table needs an owner process this data does not.
  @runtime_key {__MODULE__, :runtime_pricing}
  @prefix "surplus/"

  # ── Static rate card: OFFLINE fallback for the frontier models we ship ─────
  #
  # Surplus prices are dynamic and the RUNTIME map above is authoritative — it
  # overrides any row here the moment the live `/v1/models` catalog is fetched.
  # This snapshot exists only so a model we KNOW the price of never falls to the
  # conservative `{2,10}` provider-level estimate before that first fetch (fresh
  # process, offline, no key). Transcribed from Surplus' published reseller rates
  # on 2026-09-14. `{input, output}` USD per 1M tokens; all 1M context.
  #
  # Deliberately only the Claude family we feature: these are the ids most likely
  # to be selected before a catalog fetch, and their price gap vs the {2,10}
  # estimate is the widest (claude-opus-5 is ~20x cheaper on input). A row that
  # goes stale is corrected by the next live fetch, never outlives one.
  @static_pricing %{
    "claude-fable-5.1" => {2.50, 12.50},
    "claude-fable-5" => {5.75, 28.75},
    "claude-opus-5" => {0.092, 0.46},
    "claude-opus-5-fast" => {3.00, 15.00},
    "claude-sonnet-5" => {0.50, 2.49},
    # Measured from the live catalog 2026-09-09: prompt $0.30/M,
    # completion $1.20/M, cache-read $0.006/M — 50x cheaper than a fresh
    # read, so the prompt cache is worth far more here than the headline.
    "deepseek-v4.1-flash" => {0.30, 1.20},
    # gpt-5.6-luna: 1.05M ctx at budget rates, cache-read $0.02/M.
    "gpt-5.6-luna" => {0.20, 1.20},
    # minimax-m3 supersedes the already-featured m2.
    "minimax-m3" => {0.30, 1.20},
    # xiaomi-mimo-v2-5: cheapest 1M window in the catalog, and its
    # cache read ($0.0028/M) is ~50x below its own prompt rate.
    "xiaomi-mimo-v2-5" => {0.14, 0.28}
  }

  @static_by_key Map.new(@static_pricing, fn {id, rate} -> {@prefix <> id, rate} end)

  @doc """
  The pricing-key prefix that namespaces a bare surplus id, so a surplus turn
  bills off surplus' own rate and never collides with the native vendor's row.
  """
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @doc """
  Store the surplus rate card parsed from the live catalog.

  Takes the output of `parse/1` (a list of model maps carrying `:cost`) and
  keeps the namespaced `{"surplus/<id>" => {input, output}}` rows that have a
  usable price. Rows with no price, or a `{0.0, 0.0}` price, are dropped so a
  missing catalog price falls to the conservative `:estimated` fallback in
  `Pricing` rather than being recorded as a real $0 rate.
  """
  @spec put_runtime_pricing([map()]) :: :ok
  def put_runtime_pricing(models) when is_list(models) do
    map =
      Enum.reduce(models, %{}, fn model, acc ->
        case pricing_tuple(model) do
          nil -> acc
          {_input, _output} = rate -> Map.put(acc, key(model.id), rate)
        end
      end)

    :persistent_term.put(@runtime_key, map)
    :ok
  end

  def put_runtime_pricing(_), do: :ok

  @doc "The namespaced pricing key for a bare surplus id (downcased to match `Pricing`)."
  @spec key(String.t() | atom()) :: String.t()
  def key(id), do: @prefix <> String.downcase(to_string(id))

  @doc "`%{\"surplus/<id>\" => {input, output}}` — the current runtime rate card."
  @spec runtime_pricing() :: %{String.t() => {number(), number()}}
  def runtime_pricing, do: :persistent_term.get(@runtime_key, %{})

  @doc """
  The `{input, output}` surplus rate for a NAMESPACED key, or nil when the
  runtime card has no row for it (catalog not fetched, or the row carried no
  price). Case-insensitive to match `Pricing`'s downcased lookups.
  """
  @spec runtime_rate(String.t() | nil) :: {number(), number()} | nil
  def runtime_rate(namespaced_id) when is_binary(namespaced_id),
    do: Map.get(runtime_pricing(), String.downcase(namespaced_id))

  def runtime_rate(_), do: nil

  @doc """
  A statically-known Surplus rate for a NAMESPACED key, or nil. This is the
  OFFLINE fallback for the featured frontier models; `runtime_rate/1` (the live
  catalog) takes precedence over it in `Pricing`. Case-insensitive.
  """
  @spec static_rate(String.t() | nil) :: {number(), number()} | nil
  def static_rate(namespaced_id) when is_binary(namespaced_id),
    do: Map.get(@static_by_key, String.downcase(namespaced_id))

  def static_rate(_), do: nil

  @doc false
  # Test seam — lets a test drive the empty-card fallback and a stubbed row
  # without leaking either across examples.
  @spec reset_runtime_pricing() :: :ok
  def reset_runtime_pricing do
    :persistent_term.put(@runtime_key, %{})
    :ok
  end

  # A parsed model prices only when both legs are real, non-zero numbers. A
  # partial or zero price is treated as "no price": billing a real $0 rate for
  # a paid reseller model is the exact under-count the runtime card exists to
  # prevent, so those fall through to the conservative estimate instead.
  defp pricing_tuple(%{cost: %{input: input, output: output}})
       when is_number(input) and is_number(output) and (input > 0 or output > 0),
       do: {input, output}

  defp pricing_tuple(_), do: nil

  @spec default_model() :: String.t()
  def default_model, do: "claude-fable-5.1"

  @spec ids() :: [String.t()]
  def ids, do: @featured_ids

  @spec picker_models() :: [map()]
  def picker_models do
    Enum.map(@featured, fn {id, name} ->
      %{id: id, name: name, ctx: 0, tools: true, recommended: true}
      |> with_speed()
    end)
  end

  @doc """
  Attach the measured tok/s for this row's model id, if any real turn has ever
  produced one (`OptimalSystemAgent.Providers.ModelSpeed`). `nil` — not the key
  absent — when unmeasured, so the picker can tell "no data yet" apart from a
  server payload that predates this field.

  Deliberately NOT folded into `parse/1`: `parse/1` stays a pure projection of
  one raw catalog entry, exactly like it was before this field existed; a
  stateful cache read is a separate enrichment step, same as how
  `put_runtime_pricing/1` attaches the live rate card as its own pass rather
  than reaching into `parse/1`.
  """
  @spec with_speed(map()) :: map()
  def with_speed(%{id: id} = model) do
    Map.put(model, :tok_s, OptimalSystemAgent.Providers.ModelSpeed.get(:surplus, id))
  end

  @spec featured?(String.t()) :: boolean()
  def featured?(id), do: id in @featured_ids

  @doc "Parse one model object returned by Surplus' OpenAI-compatible catalog."
  @spec parse(map()) :: map()
  def parse(model) when is_map(model) do
    supported_parameters = model["supported_parameters"] || []
    supported_features = model["supported_features"] || []
    pricing = model["pricing"] || %{}
    id = model["id"] || "unknown"

    %{
      id: id,
      name: model["name"] || id,
      ctx: model["context_length"] || model["context_window"] || 0,
      tools:
        "tools" in supported_parameters or "tool_choice" in supported_parameters or
          "tools" in supported_features,
      reasoning: "reasoning" in supported_features or "reasoning" in supported_parameters,
      owned_by: model["owned_by"],
      provider: model["provider"],
      modalities: model["modalities"],
      featured: featured?(id),
      cost: %{
        input: parse_price(pricing["prompt"] || pricing["input"]),
        output: parse_price(pricing["completion"] || pricing["output"])
      }
    }
  end

  @doc "Put the editorial shortlist first, then keep the remaining live catalog stable."
  @spec order_catalog([map()]) :: [map()]
  def order_catalog(models) do
    featured = Enum.filter(@featured_ids, fn id -> find_model(models, id) end)
    featured_models = Enum.map(featured, &Enum.find(models, fn model -> model.id == &1 end))
    remaining = Enum.reject(models, &featured?(&1.id)) |> Enum.sort_by(&String.downcase(&1.name))
    featured_models ++ remaining
  end

  defp find_model(models, id), do: Enum.any?(models, &(&1.id == id))

  defp parse_price(nil), do: nil
  defp parse_price(""), do: nil

  defp parse_price(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _} -> Float.round(number * 1_000_000, 4)
      :error -> nil
    end
  end

  defp parse_price(value) when is_number(value), do: Float.round(value * 1_000_000, 4)
  defp parse_price(_), do: nil
end
