defmodule OptimalSystemAgent.Providers.DeepSeekModels do
  @moduledoc """
  **Single source of truth for the DeepSeek model catalog.**

  ## What was broken

  `deepseek-chat` and `deepseek-reasoner` were **fully retired** on
  2026-07-24 — not deprecated, "retired and inaccessible". They were OSA's
  DeepSeek default *and* both reasoning tiers, so every DeepSeek request failed.
  The replacements are `deepseek-v4-flash` and `deepseek-v4-pro`.

  ## The behaviour change: thinking is a PARAMETER, not a model id

  This is the part that a pure catalog edit would have missed. Under the old
  API, "reasoning" was a *different model* — you selected `deepseek-reasoner`.
  OSA encoded that as a literal id comparison in
  `OpenAICompat.reasoning_model?/1`:

      name == "deepseek-reasoner"

  DeepSeek V4 moved thinking onto the request body:

      {"model": "deepseek-v4-pro",
       "thinking": {"type": "enabled"},
       "reasoning_effort": "high"}

  So with the old code the id never matches, `reasoning_model?/1` goes false,
  and OSA silently loses the 600-second reasoning timeout *and* never sends the
  `thinking` object at all. `thinking_params/2` below is what the OpenAI-compat
  request builder calls instead.

  Note `"type"` defaults to `"enabled"` — thinking is **on by default** on both
  V4 models, so an OSA "off" effort must send `{"type": "disabled"}` explicitly
  rather than omitting the object.

  ### A documented conflict, resolved deliberately

  DeepSeek's API *reference* nests `reasoning_effort` INSIDE the `thinking`
  object; DeepSeek's reasoning *guide* puts it at top level in both its curl and
  its Python sample. `thinking_params/2` emits it **both** places. That is not
  indecision: the two are consistent in value, an unknown top-level key is
  ignored by OpenAI-compatible servers, and this way the request is correct
  whichever reading is right. Collapse it once a live call proves which wins.

  ## Where the context window came from

  DeepSeek publishes limits only as prose — the pricing page literally renders
  `1M` and `MAXIMUM: 384K`, and no page states the integer. `1M` could be
  1,000,000 or 1,048,576, and `384K` could be 384,000 or 393,216; guessing
  mis-budgets every turn.

  Resolved by **live API query**: OpenRouter's public
  `GET /api/v1/models/deepseek/deepseek-v4-flash/endpoints` reports what each
  upstream actually serves, and its **DeepSeek first-party** endpoint returns
  `context_length: 1048576, max_completion_tokens: 384000` for both V4 models.
  So the window is binary (1,048,576) while the output cap is decimal
  (384,000) — a mixed pair no reasonable guess would have produced.

  ## Pricing is no longer a constant: it varies by HOUR OF DAY

  From **16:00 UTC on 2026-08-16** DeepSeek bills peak/off-peak. Peak is
  `01:00–04:00` and `06:00–10:00` UTC; every other hour is off-peak at half the
  peak rate. Both tiers are *above* the flat rate they replace, so the flat
  `:pricing` rows below under-bill by 1.6x (flash off-peak) to 4.7x (pro peak)
  once the change lands.

  There is no single number to encode here, and encoding one anyway — with a
  comment about the other — is precisely how the `claude-sonnet-5` 1.50x
  over-report and the `gemini-3.6-flash` 2x over-report shipped, both labelled
  `:exact`. So the *window* is the data: `pricing_windows/0` publishes both
  tiers plus the hours, and `Agent.Pricing` resolves it against the instant the
  request was issued.

  ## Cache hits have a PUBLISHED price, not a multiplier

  DeepSeek quotes input twice — "cache hit" and "cache miss" — as its own
  column, and the ratio is nothing like the Anthropic-style `input * 0.1` that
  `Agent.Pricing` applies by default: flash reads cache at `$0.0028` against a
  `$0.14` miss rate, which is `0.02x`, five times cheaper than the multiplier
  assumes. `:pricing` records the MISS rate (the rate for tokens that actually
  had to be processed); `:cache_read` records the hit rate, and the windows
  carry their own hit rates because those move with the hour too.

  Sources: https://api-docs.deepseek.com/quick_start/pricing (re-checked
  2026-08-16, twice, for the peak/off-peak table and its 16:00 UTC effective
  time), https://api-docs.deepseek.com/guides/reasoning_model,
  https://api-docs.deepseek.com/api/create-chat-completion (checked 2026-08-01)
  and the live OpenRouter endpoints API (queried 2026-08-01).
  """

  @typedoc "A single DeepSeek model offering."
  @type model :: %{
          id: String.t(),
          name: String.t(),
          ctx: pos_integer(),
          max_output: pos_integer(),
          efforts: [String.t()],
          default_effort: String.t(),
          tools: boolean(),
          pricing: {number(), number()} | nil,
          cache_read: number() | nil,
          recommended: boolean(),
          note: String.t()
        }

  @models [
    %{
      id: "deepseek-v4-flash",
      name: "DeepSeek V4 Flash",
      ctx: 1_048_576,
      max_output: 384_000,
      efforts: ["low", "high", "max"],
      default_effort: "high",
      tools: true,
      pricing: {0.14, 0.28},
      cache_read: 0.0028,
      recommended: true,
      note: "1M ctx — 284B/13B active MoE; very cheap. Default."
    },
    %{
      id: "deepseek-v4-pro",
      name: "DeepSeek V4 Pro",
      ctx: 1_048_576,
      max_output: 384_000,
      # Pro does NOT accept "low" — its floor is "high".
      efforts: ["high", "max"],
      default_effort: "high",
      tools: true,
      pricing: {0.435, 0.87},
      cache_read: 0.003625,
      recommended: false,
      note: "1M ctx — strongest DeepSeek reasoning"
    }
  ]

  @by_id Map.new(@models, &{&1.id, &1})

  # ── Peak / off-peak ───────────────────────────────────────────────────────
  #
  # UTC hours at which DeepSeek bills the peak tier, as HALF-OPEN intervals
  # `[from, until)` on the hour. DeepSeek writes "01:00 - 04:00"; half-open is
  # the reading OSA commits to, so 01:00:00.0 is peak and 04:00:00.0 is not,
  # and the two windows can never both claim an instant. Stated once, here,
  # rather than left for each caller to interpret.
  @peak_hours [{1, 4}, {6, 10}]

  # DeepSeek's announcement gives a TIME, not just a date: "the new prices take
  # effect at 16:00 UTC on August 16, 2026". Recorded to the hour because this
  # module is about to start caring about hours — rounding it to a date would
  # re-price every turn taken earlier that same day.
  @dynamic_from ~U[2026-08-16 16:00:00Z]

  @pricing_windows %{
    "deepseek-v4-flash" => %{
      effective_from: @dynamic_from,
      peak_hours: @peak_hours,
      peak: %{pricing: {0.44, 1.32}, cache_read: 0.014},
      off_peak: %{pricing: {0.22, 0.66}, cache_read: 0.007}
    },
    "deepseek-v4-pro" => %{
      effective_from: @dynamic_from,
      peak_hours: @peak_hours,
      peak: %{pricing: {1.32, 3.96}, cache_read: 0.044},
      off_peak: %{pricing: {0.66, 1.98}, cache_read: 0.022}
    }
  }

  @typedoc """
  One model's time-of-day rate card.

  `:peak`/`:off_peak` each carry the `{input, output}` pair and the published
  cache-hit rate for that tier, all USD per 1M tokens. `:effective_from` is the
  instant the card replaces the model's flat `:pricing`; before it, `:pricing`
  is the rate.
  """
  @type pricing_window :: %{
          effective_from: DateTime.t(),
          peak_hours: [{0..23, 1..24}],
          peak: %{pricing: {number(), number()}, cache_read: number() | nil},
          off_peak: %{pricing: {number(), number()}, cache_read: number() | nil}
        }

  @doc """
  Time-of-day rate cards, as `%{model_id => pricing_window()}`.

  A model absent here is priced by a constant. A model present here has NO
  single rate: `Agent.Pricing` resolves it against the instant the request was
  issued, and refuses to call a guessed hour `:exact`.

  Like `pricing_schedule/0` elsewhere, this is compile-time DATA and runtime
  RESOLUTION — a release built during off-peak must not carry the off-peak rate
  into the next peak window.
  """
  @spec pricing_windows() :: %{String.t() => pricing_window()}
  def pricing_windows, do: @pricing_windows

  @doc """
  DeepSeek's published cache-HIT rate per 1M tokens for the flat era, or nil.

  Explicitly not `input * 0.1`: flash reads cache at `0.0028` against a `0.14`
  miss rate (`0.02x`). Once `pricing_windows/0` takes effect the hit rate moves
  with the hour and comes from there instead.
  """
  @spec cache_read_rate(String.t() | nil) :: number() | nil
  def cache_read_rate(id) do
    case resolve(id) do
      nil -> nil
      m -> Map.get(m, :cache_read)
    end
  end

  @doc "The full catalog, in picker display order."
  @spec models() :: [model()]
  def models, do: @models

  @doc "Look up one model by exact id. Returns nil for unknown ids."
  @spec model(String.t() | nil) :: model() | nil
  def model(id) when is_binary(id), do: Map.get(@by_id, id)
  def model(_), do: nil

  @doc "Look up a model by id, tolerating a dated snapshot suffix (`-0731`)."
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

  @doc "The default DeepSeek model for a fresh install."
  @spec default_model() :: String.t()
  def default_model, do: "deepseek-v4-flash"

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

  @doc """
  True when this id is a DeepSeek model that takes the `thinking` request
  parameter — i.e. a V4 model.

  This is what replaces the old `name == "deepseek-reasoner"` identity test.
  Every V4 model supports thinking, so reasoning is now a property of the
  REQUEST, not of the model choice.
  """
  @spec thinking_model?(String.t() | nil) :: boolean()
  def thinking_model?(id), do: resolve(id) != nil

  @doc """
  Build the DeepSeek-specific thinking parameters for a model + OSA effort.

  Returns a map to merge into the top-level request body, or `%{}` for a model
  that is not a DeepSeek V4 model (so it is safe to call unconditionally from
  the shared OpenAI-compatible request builder).

  An "off"/"none" effort produces `%{"thinking" => %{"type" => "disabled"}}` —
  **not** an empty map — because DeepSeek defaults `type` to `"enabled"`, so
  omitting the object leaves thinking ON.
  """
  @spec thinking_params(String.t() | nil, term()) :: map()
  def thinking_params(id, effort) do
    case resolve(id) do
      nil ->
        %{}

      m ->
        case normalize_effort(effort) do
          :disabled ->
            %{"thinking" => %{"type" => "disabled"}}

          level ->
            level = clamp_effort(level, m)

            %{
              # Emitted in BOTH positions — see the moduledoc: the API
              # reference nests it, the guide's own samples do not.
              "thinking" => %{"type" => "enabled", "reasoning_effort" => level},
              "reasoning_effort" => level
            }
        end
    end
  end

  # OSA's effort ladder → DeepSeek's low/high/max. DeepSeek has no "medium",
  # so the middle of OSA's ladder maps to "high" (its documented default)
  # rather than being invented.
  defp normalize_effort(effort) do
    case effort |> to_string() |> String.trim() |> String.downcase() do
      "off" -> :disabled
      "none" -> :disabled
      "fast" -> "low"
      "low" -> "low"
      "medium" -> "high"
      "high" -> "high"
      "xhigh" -> "max"
      "max" -> "max"
      "ultra" -> "max"
      # A corrupt persisted effort must not silently disable reasoning; fall
      # back to DeepSeek's own default rather than to :disabled.
      _ -> "high"
    end
  end

  # Raise into the model's supported set — `deepseek-v4-pro` rejects "low".
  defp clamp_effort(level, %{efforts: efforts}) do
    if level in efforts do
      level
    else
      order = ["low", "high", "max"]
      wanted = Enum.find_index(order, &(&1 == level)) || 1

      Enum.find(order, List.first(efforts), fn l ->
        l in efforts and (Enum.find_index(order, &(&1 == l)) || 0) >= wanted
      end)
    end
  end
end
