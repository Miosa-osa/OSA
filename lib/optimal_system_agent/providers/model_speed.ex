defmodule OptimalSystemAgent.Providers.ModelSpeed do
  @moduledoc """
  Per-model output speed (visible tokens/sec), measured from REAL turns —
  never a synthetic benchmark.

  ## Why real turns, not a probe

  A fixed-prompt speed probe lies for reasoning models: how much invisible
  `reasoning`/`<think>` decoding happens before the visible answer starts is
  prompt-dependent, and for several Surplus-hosted reasoning models an entire
  token budget can be spent on reasoning with NO visible answer at all (empirically
  confirmed — see the tok/s benchmark this feature was scoped from). A static
  number would confidently report a speed the model never delivers to a user.
  Sampling real turns instead means the metric only ever reflects turns that
  actually produced something visible, and naturally rotates with whatever
  backend Surplus' reseller catalog is fronting that day.

  ## What gets recorded (see `OpenAICompat.record_model_speed/4`)

  Only the WALL-CLOCK window between the first and the last visible
  `{:text_delta, _}` chunk of a stream, divided into an estimate of how many
  tokens that visible text took (not the provider's raw `completion_tokens`,
  which is inclusive of any invisible reasoning tokens — see
  `ReasoningContent`'s "Accounting" section). A turn that never emits a visible
  chunk contributes nothing.

  ## Storage: persistent_term cache + SQLite, mirrors `SurplusModels`

  Same two-tier shape `SurplusModels` already uses for its runtime rate card
  (`put_runtime_pricing/1` / `runtime_rate/1`): a `:persistent_term` map for the
  lock-free hot read (the model picker), backed by a SQLite table so the
  measurement survives process restarts instead of cold-starting every launch.
  """

  require Logger

  alias OptimalSystemAgent.Store.Repo

  @runtime_key {__MODULE__, :ema}
  @table_ready_key {__MODULE__, :table_ready}

  # Weight given to the newest sample. Skewed toward recent turns — Surplus is
  # a reseller whose backend for a given id can change under us — while still
  # smoothing out one noisy turn (cold start, a throttled request, etc.).
  @alpha 0.3

  @create_table """
  CREATE TABLE IF NOT EXISTS model_speed (
    id         TEXT PRIMARY KEY,
    tok_s      REAL NOT NULL,
    samples    INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL DEFAULT ''
  )
  """

  @doc """
  The namespaced key for a provider+model pair. Namespaced (not the bare model
  id) for the same reason `SurplusModels.key/1` namespaces prices: the same id
  can mean a different backend — and a different real speed — depending on
  which provider is serving it.
  """
  @spec key(atom() | String.t(), String.t()) :: String.t()
  def key(provider, model), do: "#{provider}/" <> String.downcase(to_string(model))

  @doc """
  Record one real turn's visible-content throughput for a provider+model pair.

  `tok_s` must be a positive, finite number — the caller (`OpenAICompat`) is
  responsible for only calling this when a visible-generation window with a
  positive token estimate actually exists. Never raises: a persistence failure
  here must not fail the turn that produced the measurement.
  """
  @spec record(atom() | String.t(), String.t(), number()) :: :ok
  def record(provider, model, tok_s) when is_number(tok_s) and tok_s > 0 do
    ensure_table!()
    k = key(provider, model)
    updated = ema_update(cache_get(k), tok_s / 1)
    put_cache(k, updated)
    persist(k, updated)
    :ok
  end

  def record(_provider, _model, _tok_s), do: :ok

  @doc "The current measured tok/s for a provider+model pair, or `nil` if never measured."
  @spec get(atom() | String.t(), String.t()) :: float() | nil
  def get(provider, model) do
    ensure_table!()
    provider |> key(model) |> cache_get() |> ema_value()
  end

  @doc false
  # Test seam — clears both the in-memory cache and the persisted table.
  @spec reset() :: :ok
  def reset do
    :persistent_term.put(@runtime_key, %{})

    if :persistent_term.get(@table_ready_key, false) do
      Repo.query("DELETE FROM model_speed")
    end

    :ok
  rescue
    _ -> :ok
  end

  # ── EMA ─────────────────────────────────────────────────────────────────
  # `{tok_s, samples}` — `samples` is persisted alongside the value so a future
  # confidence indicator (or a "still warming up" badge state) can distinguish
  # one lucky sample from a value averaged over many real turns, without
  # needing a second read.
  defp ema_update(nil, new_tok_s), do: {new_tok_s * 1.0, 1}

  defp ema_update({old, n}, new_tok_s),
    do: {@alpha * new_tok_s + (1 - @alpha) * old, n + 1}

  defp ema_value(nil), do: nil
  defp ema_value({tok_s, _n}), do: tok_s

  defp cache_get(k), do: Map.get(runtime_cache(), k)

  defp put_cache(k, value),
    do: :persistent_term.put(@runtime_key, Map.put(runtime_cache(), k, value))

  defp runtime_cache, do: :persistent_term.get(@runtime_key, %{})

  # Lazy, once-per-process: create the table (if missing) and warm the
  # in-memory cache from whatever was persisted by a previous run. Lazy rather
  # than an application-boot hook so this module has no coupling to the
  # supervision tree's start order — it works the first time anything calls
  # `record/3` or `get/2`, in any process that loads this module.
  defp ensure_table!() do
    if not :persistent_term.get(@table_ready_key, false) do
      case Repo.query(@create_table) do
        {:ok, _} ->
          load_into_cache()
          :persistent_term.put(@table_ready_key, true)

        {:error, reason} ->
          Logger.warning("[ModelSpeed] table init failed: #{inspect(reason)}")
      end
    end

    :ok
  rescue
    e ->
      Logger.warning("[ModelSpeed] ensure_table!/0 exception: #{Exception.message(e)}")
      :ok
  end

  defp persist(k, {tok_s, n}) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Repo.query(
      """
      INSERT INTO model_speed (id, tok_s, samples, updated_at)
      VALUES (?1, ?2, ?3, ?4)
      ON CONFLICT(id) DO UPDATE SET
        tok_s = excluded.tok_s,
        samples = excluded.samples,
        updated_at = excluded.updated_at
      """,
      [k, tok_s, n, now]
    )

    :ok
  rescue
    e ->
      Logger.warning("[ModelSpeed] persist/2 failed for #{k}: #{Exception.message(e)}")
      :ok
  end

  defp load_into_cache do
    case Repo.query("SELECT id, tok_s, samples FROM model_speed") do
      {:ok, %{rows: rows}} ->
        map =
          Enum.reduce(rows, %{}, fn [id, tok_s, samples], acc ->
            Map.put(acc, id, {tok_s, samples})
          end)

        :persistent_term.put(@runtime_key, map)

      {:error, reason} ->
        Logger.warning("[ModelSpeed] load_into_cache/0 failed: #{inspect(reason)}")
    end

    :ok
  rescue
    e ->
      Logger.warning("[ModelSpeed] load_into_cache/0 exception: #{Exception.message(e)}")
      :ok
  end
end
