defmodule OptimalSystemAgent.Signal.MessageClassifier do
  @moduledoc """
  Signal Theory message classification result struct and deterministic classifier.

  Classifies incoming messages into the Signal Theory 5-tuple:
  `(mode, genre, type, format, weight)`.

  ## Classification tiers

  1. **ETS cache** — 10-minute TTL keyed by `{message_hash, channel}`. Near-zero cost.
  2. **Deterministic** — regex pattern matching. Always < 1 ms. Confidence `:low`.
  3. **LLM enrichment** — async upgrade via `OptimalSystemAgent.Signal.Classifier`. Confidence `:high`.

  The deterministic path is always available. LLM enrichment is optional and
  fire-and-forget; it emits `:signal_classified` on the event bus when done.
  """

  @type signal_mode :: :execute | :build | :analyze | :maintain | :assist
  @type signal_genre :: :direct | :inform | :commit | :decide | :express
  @type signal_type :: String.t()
  @type signal_format ::
          :text
          | :code
          | :json
          | :markdown
          | :binary
          | :command
          | :message
          | :notification
          | :document
  @type confidence :: :high | :medium | :low

  @type t :: %__MODULE__{
          mode: signal_mode(),
          genre: signal_genre(),
          type: signal_type(),
          format: signal_format(),
          weight: float(),
          raw: String.t() | nil,
          channel: atom() | nil,
          timestamp: DateTime.t() | nil,
          confidence: confidence()
        }

  defstruct [
    :mode,
    :genre,
    :type,
    :format,
    :raw,
    :channel,
    :timestamp,
    :confidence,
    weight: 0.5
  ]

  @ets_table :osa_signal_cache
  @cache_ttl_seconds 600

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Fast ETS-cached classification. Falls through to deterministic on cache miss.

  Always returns `{:ok, t()}`. Confidence is `:low` (deterministic path).
  """
  @spec classify_fast(String.t(), atom()) :: {:ok, t()} | {:error, String.t()}
  def classify_fast(message, channel \\ :cli) do
    key = cache_key(message, channel)

    case ets_lookup(key) do
      {:hit, cached} ->
        {:ok, cached}

      :miss ->
        result = classify_deterministic(message, channel)

        case result do
          {:ok, signal} -> ets_put(key, signal)
          _ -> :ok
        end

        result
    end
  end

  @doc """
  Deterministic pattern-matching classification (no LLM).

  Always succeeds; confidence is `:low`.
  """
  @spec classify_deterministic(String.t(), atom()) :: {:ok, t()} | {:error, String.t()}
  def classify_deterministic(message, _channel) when is_binary(message) do
    msg = String.downcase(message)

    mode =
      cond do
        Regex.match?(
          ~r/\b(run|execute|send|deploy|delete|trigger|sync|import|export)\b/,
          msg
        ) ->
          :execute

        Regex.match?(
          ~r/\b(create|generate|write|scaffold|design|build|develop|make|implement)\b/,
          msg
        ) ->
          :build

        Regex.match?(
          ~r/\b(analyze|report|compare|metrics|trend|dashboard|review|kpi)\b/,
          msg
        ) ->
          :analyze

        Regex.match?(
          ~r/\b(fix|update|migrate|backup|restore|rollback|patch|upgrade|debug)\b/,
          msg
        ) ->
          :maintain

        true ->
          :assist
      end

    genre =
      cond do
        Regex.match?(~r/\b(please|can you|could you|do|make|create)\b/, msg) -> :direct
        Regex.match?(~r/\b(i will|i'll|let me|i can)\b/, msg) -> :commit
        Regex.match?(~r/\b(approve|reject|confirm|cancel|choose|decide)\b/, msg) -> :decide
        Regex.match?(~r/[!?]|great|thanks|thank you|sorry|frustrated/, msg) -> :express
        true -> :inform
      end

    weight = calculate_weight(message)

    {:ok,
     %__MODULE__{
       mode: mode,
       genre: genre,
       type: "general",
       format: :text,
       weight: weight,
       raw: message,
       channel: nil,
       timestamp: DateTime.utc_now(),
       confidence: :low
     }}
  end

  def classify_deterministic(_, _), do: {:error, "invalid message: must be a binary string"}

  @doc """
  Calculate signal weight (0.0 – 1.0) based on message length.

  Used as a simple proxy for informational density when LLM classification
  is unavailable. Score is capped at 1.0 for messages >= 500 chars.
  """
  @spec calculate_weight(String.t()) :: float()
  def calculate_weight(message) when is_binary(message) do
    len = String.length(message)
    Float.round(min(len / 500.0, 1.0), 2)
  end

  def calculate_weight(_), do: 0.5

  # ---------------------------------------------------------------------------
  # ETS cache helpers
  # ---------------------------------------------------------------------------

  defp cache_key(message, channel) do
    hash = :erlang.phash2({message, channel})
    {__MODULE__, hash}
  end

  defp ensure_table do
    if :ets.whereis(@ets_table) == :undefined do
      try do
        :ets.new(@ets_table, [:named_table, :set, :public, read_concurrency: true])
      rescue
        ArgumentError -> :already_exists
      end
    end
  end

  defp ets_lookup(key) do
    ensure_table()

    case :ets.lookup(@ets_table, key) do
      [{^key, signal, expires_at}] ->
        if System.monotonic_time(:second) < expires_at do
          {:hit, signal}
        else
          :ets.delete(@ets_table, key)
          :miss
        end

      [] ->
        :miss
    end
  rescue
    _ -> :miss
  end

  defp ets_put(key, signal) do
    ensure_table()
    expires_at = System.monotonic_time(:second) + @cache_ttl_seconds

    try do
      :ets.insert(@ets_table, {key, signal, expires_at})
    rescue
      _ -> :ok
    end
  end
end
