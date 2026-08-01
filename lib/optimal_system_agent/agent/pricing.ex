defmodule OptimalSystemAgent.Agent.Pricing do
  @moduledoc """
  Per-model token pricing table for real cost accounting (primitive #29).

  Prices are quoted in **USD per 1,000,000 tokens** as `{input_rate, output_rate}`.
  Cache tokens are priced off the input rate using the standard Anthropic-style
  multipliers:

    * cache **write** (`cache_creation_input_tokens`) → `input_rate * 1.25`
    * cache **read**  (`cache_read_input_tokens`)     → `input_rate * 0.1`

  Model lookup is: exact (case-insensitive) match first, then a family
  substring match. An **unknown model prices at `$0.0` and is logged** — we
  never guess a price, so cost accounting stays honest and a mispriced model
  can be spotted in the logs and added to the table.

  This is deliberately a plain data module (no process, no state) so it can be
  called from the hot loop without contention.
  """
  require Logger

  @cache_write_multiplier 1.25
  @cache_read_multiplier 0.1

  # Exact model → {input $/1M, output $/1M}
  #
  # Ollama Cloud tags are NOT listed here: they are merged in below from
  # `Providers.OllamaCloud`, the single source of truth for that catalog. Add a
  # new cloud model's price THERE (leave it nil if the vendor publishes none —
  # an unpriced model accounts at $0.00 and logs, which is honest).
  @static_pricing %{
    # GLM (Z.ai / Zhipu cloud) — OSA's default provider family
    "glm-4.7:cloud" => {0.60, 2.20},
    "glm-4.6:cloud" => {0.60, 2.20},
    "glm-4.6" => {0.60, 2.20},
    "glm-4.5" => {0.60, 2.20},

    # Anthropic Claude
    "claude-3-5-sonnet" => {3.0, 15.0},
    "claude-3-7-sonnet" => {3.0, 15.0},
    "claude-sonnet-4" => {3.0, 15.0},
    "claude-3-opus" => {15.0, 75.0},
    "claude-opus-4" => {15.0, 75.0},
    "claude-3-5-haiku" => {0.80, 4.0},
    "claude-3-haiku" => {0.25, 1.25},

    # OpenAI
    "gpt-4o" => {2.5, 10.0},
    "gpt-4o-mini" => {0.15, 0.60},
    "gpt-4.1" => {2.0, 8.0},
    "gpt-4.1-mini" => {0.40, 1.60},
    "gpt-4.1-nano" => {0.10, 0.40},
    "o1" => {15.0, 60.0},
    "o3" => {2.0, 8.0},
    "o3-mini" => {1.10, 4.40},
    "gpt-3.5-turbo" => {0.50, 1.50},

    # DeepSeek
    "deepseek-chat" => {0.27, 1.10},
    "deepseek-reasoner" => {0.55, 2.19}
  }

  @pricing Map.merge(
             @static_pricing,
             OptimalSystemAgent.Providers.OllamaCloud.pricing()
           )

  # Ordered family fallbacks — first substring match wins. Checked only when
  # there is no exact hit. Keep specific families before generic ones.
  @families [
    {"glm", {0.60, 2.20}},
    {"claude-3-opus", {15.0, 75.0}},
    {"claude-opus", {15.0, 75.0}},
    {"claude-3-5-haiku", {0.80, 4.0}},
    {"claude-haiku", {0.80, 4.0}},
    {"claude-3-haiku", {0.25, 1.25}},
    {"claude-sonnet", {3.0, 15.0}},
    {"claude", {3.0, 15.0}},
    {"gpt-4o-mini", {0.15, 0.60}},
    {"gpt-4o", {2.5, 10.0}},
    {"gpt-4.1", {2.0, 8.0}},
    {"gpt-4", {2.5, 10.0}},
    {"gpt-3.5", {0.50, 1.50}},
    {"deepseek", {0.27, 1.10}}
  ]

  @doc """
  Return `{input_rate, output_rate}` (USD per 1M tokens) for a model, or `nil`
  when the model is not in the pricing table.

  Local/self-hosted models served via Ollama are free and return `{0.0, 0.0}`.
  """
  @spec rates(String.t() | atom() | nil) :: {number(), number()} | nil
  def rates(nil), do: nil

  def rates(model) when is_atom(model), do: rates(Atom.to_string(model))

  def rates(model) when is_binary(model) do
    key = String.downcase(model)

    cond do
      # Local Ollama-hosted models (e.g. "ollama/llama3", "qwen2.5:7b") are free.
      ollama_local?(key) -> {0.0, 0.0}
      Map.has_key?(@pricing, key) -> Map.fetch!(@pricing, key)
      true -> family_rate(key)
    end
  end

  # Unexpected model type (number, map, tuple, …) — never guess a price and
  # never raise. A malformed loop state must not crash cost accounting in the
  # hot path; treat as unknown (nil → $0.0 in cost/2, same as an unknown name).
  def rates(_), do: nil

  @doc """
  Compute the USD cost for one turn's usage against `model`.

  `usage` is a normalized map (see `Loop.Accounting.normalize_usage/1`) with
  `:input_tokens`, `:output_tokens`, `:cache_creation_input_tokens`, and
  `:cache_read_input_tokens`. Unknown models cost `0.0` and are logged.
  """
  @spec cost(String.t() | atom() | nil, map()) :: float()
  def cost(model, usage) when is_map(usage) do
    case rates(model) do
      {input_rate, output_rate} ->
        input = get_tok(usage, :input_tokens)
        output = get_tok(usage, :output_tokens)
        cache_write = get_tok(usage, :cache_creation_input_tokens)
        cache_read = get_tok(usage, :cache_read_input_tokens)

        raw =
          (input * input_rate +
             cache_write * input_rate * @cache_write_multiplier +
             cache_read * input_rate * @cache_read_multiplier +
             output * output_rate) / 1_000_000

        Float.round(raw, 6)

      nil ->
        Logger.warning(
          "[Pricing] No price for model #{inspect(model)} — cost recorded as $0.0 " <>
            "(add it to OptimalSystemAgent.Agent.Pricing)"
        )

        0.0
    end
  end

  # --- Private ---

  defp family_rate(key) do
    Enum.find_value(@families, fn {needle, rate} ->
      if String.contains?(key, needle), do: rate
    end)
  end

  defp ollama_local?(key) do
    String.starts_with?(key, "ollama/") or
      (String.contains?(key, ":") and
         (String.contains?(key, "llama") or String.contains?(key, "qwen") or
            String.contains?(key, "mistral") or String.contains?(key, "gemma") or
            String.contains?(key, "phi")) and not String.contains?(key, "cloud"))
  end

  defp get_tok(usage, key) do
    Map.get(usage, key) || Map.get(usage, Atom.to_string(key)) || 0
  end
end
