defmodule OptimalSystemAgent.Providers.Catalog do
  @moduledoc """
  models.dev-style model catalog — a single, refreshable source of truth for
  model metadata (context window, output limit, tool-calling / reasoning support,
  modalities, and pricing).

  ## Design

  A `GenServer` owns a public ETS table (`:osa_models_catalog`) — the same
  pattern as the `:osa_context_cache` table — so lookups are lock-free reads
  from any process and the module's public API never has to round-trip through
  the GenServer.

  ## 3-tier load (fastest fresh source wins, network is authoritative)

    1. `~/.osa/cache/models.json` — a previously-fetched snapshot, used when
       it is fresh (mtime within `@cache_ttl_ms`, default 24h).
    2. Bundled `priv/catalog/models_dev.json` — always present, so the catalog
       is populated offline. Ships context windows + capability flags but NO
       pricing (the live source is authoritative for pricing).
    3. Network `https://models.dev/api.json` — fetched in the background on
       boot, on `refresh/0`, and on a ~60-min periodic timer (skipped while the
       cache file is still "hot", < 5 min old) unless disabled. Fetches use a
       best-effort cross-process lock (advisory lock file), exponential-backoff
       retry, and an atomic temp+rename cache write, then swap into ETS.

  If every local source is missing, a small inline `baked_snapshot/0` (the
  glm / anthropic / openai / ollama families OSA uses) is loaded so lookups
  ALWAYS resolve something offline. The catalog never crashes when models.dev
  is unreachable.

  ## Env flags

    * `OSA_MODELS_URL`          — override the network source URL.
    * `OSA_MODELS_PATH`         — override the bundled snapshot path.
    * `OSA_DISABLE_MODELS_FETCH` — set to disable the background network fetch.

  ## Public API

      Catalog.providers()                 # => ["openai", "anthropic", ...]
      Catalog.models("openai")            # => [%Catalog.Model{}, ...]
      Catalog.model("openai", "gpt-4o")   # => %Catalog.Model{} | nil
      Catalog.context_window("gpt-4o")    # => 128_000 | nil
      Catalog.context_window("openai", "gpt-4o")
      Catalog.refresh()                   # => :ok | {:ok, :disabled} | {:error, term}
  """

  use GenServer
  require Logger

  @table :osa_models_catalog
  # Single ETS row holding the whole normalized catalog map. The catalog is
  # small (routed providers only) so a single atomic row is simplest + safe.
  @data_key :data
  @meta_key :meta

  @default_url "https://models.dev/api.json"
  # Disk cache is considered usable (loaded at boot, no re-fetch needed) for 24h.
  @cache_ttl_ms 24 * 60 * 60 * 1000
  # "Hot" window: a periodic refresh skips the network when the cache file is
  # fresher than this (mirrors opencode's 5-min freshness gate).
  @hot_ttl_ms 5 * 60 * 1000
  # Background refresh cadence (opencode uses a 60-min spaced schedule).
  @refresh_interval_ms 60 * 60 * 1000

  # Cheap/fast "small" model name signal (verbatim from opencode's SMALL_MODEL_RE).
  @small_model_re ~r/\b(nano|flash|lite|mini|haiku|small|fast)\b/

  defmodule Model do
    @moduledoc "Normalized catalog entry for a single model."
    @enforce_keys [:provider_id, :model_id]
    defstruct provider_id: nil,
              model_id: nil,
              name: nil,
              ctx: nil,
              max_output: nil,
              tool_call: false,
              reasoning: false,
              attachment: false,
              structured_output: false,
              release_date: nil,
              cost: nil,
              modalities: %{input: [], output: []}

    @type t :: %__MODULE__{}
  end

  # ── Public API ─────────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "List provider ids present in the catalog."
  @spec providers() :: [String.t()]
  def providers do
    data() |> Map.keys() |> Enum.sort()
  end

  @doc "Return all `%Model{}` entries for a provider id (empty list if unknown)."
  @spec models(String.t() | atom()) :: [Model.t()]
  def models(provider_id) do
    pid = to_string(provider_id)

    data()
    |> Map.get(pid, %{})
    |> Map.values()
    |> Enum.sort_by(& &1.model_id)
  end

  @doc "Return a single `%Model{}` for `provider_id`/`model_id`, or nil."
  @spec model(String.t() | atom(), String.t()) :: Model.t() | nil
  def model(provider_id, model_id) do
    data()
    |> Map.get(to_string(provider_id), %{})
    |> Map.get(model_id)
  end

  @doc "Context window for a model within a provider, or nil if unknown."
  @spec context_window(String.t() | atom(), String.t()) :: pos_integer() | nil
  def context_window(provider_id, model_id) do
    case model(provider_id, model_id) do
      %Model{ctx: ctx} when is_integer(ctx) and ctx > 0 -> ctx
      _ -> nil
    end
  end

  @doc """
  Context window for a model looked up across all providers (first match wins).

  Returns nil when the model is not in the catalog — callers fall back to their
  own resolution (e.g. Ollama `/api/show`, config default).
  """
  @spec context_window(String.t()) :: pos_integer() | nil
  def context_window(model_id) when is_binary(model_id) do
    data()
    |> Enum.find_value(fn {_pid, models} ->
      case Map.get(models, model_id) do
        %Model{ctx: ctx} when is_integer(ctx) and ctx > 0 -> ctx
        _ -> nil
      end
    end)
  end

  def context_window(_), do: nil

  @doc """
  Cost map for a model looked up across all providers (first match wins), or nil
  when the model is unknown or carries no pricing (e.g. the bundled snapshot,
  which ships no cost data). Shape: `%{input:, output:, cache_read:, cache_write:}`
  in USD per 1M tokens.
  """
  @spec cost(String.t()) :: map() | nil
  def cost(model_id) when is_binary(model_id) do
    data()
    |> Enum.find_value(fn {_pid, models} ->
      case Map.get(models, model_id) do
        %Model{cost: %{} = c} -> c
        _ -> nil
      end
    end)
  end

  def cost(_), do: nil

  @doc "Alias for `cost/1` — per-1M-token USD pricing map, or nil when unknown."
  @spec pricing(String.t()) :: map() | nil
  def pricing(model_id), do: cost(model_id)

  @doc "Provider-scoped pricing map for a model, or nil."
  @spec pricing(String.t() | atom(), String.t()) :: map() | nil
  def pricing(provider_id, model_id) do
    case model(provider_id, model_id) do
      %Model{cost: %{} = c} -> c
      _ -> nil
    end
  end

  @doc """
  Input/output modalities for a model within a provider, or nil if unknown.
  Shape: `%{input: [..], output: [..]}` (e.g. `["text", "image"]`).
  """
  @spec modalities(String.t() | atom(), String.t()) :: map() | nil
  def modalities(provider_id, model_id) do
    case model(provider_id, model_id) do
      %Model{modalities: %{} = m} -> m
      _ -> nil
    end
  end

  @doc "Modalities for a model looked up across all providers (first match wins), or nil."
  @spec modalities(String.t()) :: map() | nil
  def modalities(model_id) when is_binary(model_id) do
    case find(model_id) do
      %Model{modalities: %{} = m} -> m
      _ -> nil
    end
  end

  def modalities(_), do: nil

  @doc """
  Heuristic pick of a cheap/fast "small" model for `provider_id` — mirrors
  opencode's `catalog.ts` `small()`. Scores text-capable candidates by
  `cost * 0.8 + age * 0.2` (both normalized), preferring ids/names that match
  `#{inspect(@small_model_re)}`. When no pricing is available (offline / the
  bundled snapshot ships no cost), it degrades to a name-regex + recency pick so
  it STILL returns a model rather than nil. Returns a `%Model{}` or nil when the
  provider has no usable text model.
  """
  @spec small_model(String.t() | atom()) :: Model.t() | nil
  def small_model(provider_id) do
    candidates =
      provider_id
      |> models()
      |> Enum.filter(&text_io?/1)
      |> Enum.map(fn m ->
        %{
          model: m,
          cost: cost_sum(m),
          age: age_months(m),
          small: Regex.match?(@small_model_re, small_key(m))
        }
      end)

    # opencode's filter: only priced, reasonably-recent models are scored.
    priced = Enum.filter(candidates, fn c -> c.cost > 0 and c.age <= 18 end)

    cond do
      priced != [] -> pick_by_score(priced)
      candidates != [] -> pick_offline(candidates)
      true -> nil
    end
  end

  defp small_key(%Model{model_id: id, name: name}) do
    String.downcase("#{id} #{name}")
  end

  # A model usable for plain text chat: text (or unknown) input AND output.
  defp text_io?(%Model{modalities: %{input: inp, output: out}}) do
    text_ok?(inp) and text_ok?(out)
  end

  defp text_io?(_), do: true

  defp text_ok?(mods) when is_list(mods) do
    mods == [] or Enum.any?(mods, &String.starts_with?(to_string(&1), "text"))
  end

  defp text_ok?(_), do: true

  defp cost_sum(%Model{cost: %{input: i, output: o}}) when is_number(i) and is_number(o),
    do: i + o

  defp cost_sum(_), do: 0

  # Age in ~months since release. Unknown release_date sorts as "old" (999) so a
  # dated model is preferred, and so undated models never pass the `age <= 18`
  # priced filter on ambiguous data.
  defp age_months(%Model{release_date: %Date{} = d}) do
    max(Date.diff(Date.utc_today(), d), 0) / 30.0
  end

  defp age_months(_), do: 999.0

  # opencode scoring: normalize cost + age, weight 0.8/0.2, prefer small-named.
  defp pick_by_score(items) do
    max_cost = items |> Enum.map(& &1.cost) |> Enum.max() |> max(0.01)
    max_age = items |> Enum.map(& &1.age) |> Enum.max() |> max(0.01)
    small = Enum.filter(items, & &1.small)
    pool = if small != [], do: small, else: items

    pool
    |> Enum.min_by(fn c -> c.cost / max_cost * 0.8 + c.age / max_age * 0.2 end)
    |> Map.fetch!(:model)
  end

  # Offline fallback (no pricing): prefer small-named, then youngest, then id.
  defp pick_offline(items) do
    small = Enum.filter(items, & &1.small)
    pool = if small != [], do: small, else: items

    pool
    |> Enum.sort_by(fn c -> {c.age, c.model.model_id} end)
    |> List.first()
    |> Map.fetch!(:model)
  end

  @doc """
  Max output tokens for a model looked up across all providers (first match
  wins), or nil when unknown. Sourced from models.dev `limit.output`.
  """
  @spec max_output(String.t()) :: pos_integer() | nil
  def max_output(model_id) when is_binary(model_id) do
    data()
    |> Enum.find_value(fn {_pid, models} ->
      case Map.get(models, model_id) do
        %Model{max_output: n} when is_integer(n) and n > 0 -> n
        _ -> nil
      end
    end)
  end

  def max_output(_), do: nil

  @doc """
  First `%Model{}` matching `model_id` across all providers, or nil. Used by
  callers that need the full capability record (tool_call / reasoning / limits)
  without knowing the owning provider up front.
  """
  @spec find(String.t()) :: Model.t() | nil
  def find(model_id) when is_binary(model_id) do
    data()
    |> Enum.find_value(fn {_pid, models} -> Map.get(models, model_id) end)
  end

  def find(_), do: nil

  @doc "Trigger a foreground network refresh (respects the disable flag)."
  @spec refresh() :: :ok | {:ok, :disabled} | {:error, term()}
  def refresh do
    case GenServer.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      _ -> GenServer.call(__MODULE__, :refresh, 30_000)
    end
  end

  @doc "Metadata about the currently-loaded catalog (source + counts)."
  @spec info() :: map()
  def info do
    meta =
      case ets_lookup(@meta_key) do
        {:ok, m} -> m
        _ -> %{source: :none}
      end

    Map.merge(meta, %{
      providers: length(providers()),
      models: data() |> Enum.reduce(0, fn {_p, m}, acc -> acc + map_size(m) end)
    })
  end

  # ── GenServer ──────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    ensure_table()

    # Tier 1/2: load the freshest local source synchronously so the catalog is
    # usable the moment the process is alive.
    load_local()

    # Tier 3: kick a background network refresh (unless disabled) to supersede
    # the local snapshot with authoritative data (incl. pricing).
    {:ok, %{}, {:continue, :maybe_refresh}}
  end

  @impl true
  def handle_continue(:maybe_refresh, state) do
    if fetch_disabled?() do
      Logger.debug("[Catalog] Network fetch disabled — using local snapshot")
    else
      parent = self()
      Task.start(fn -> send(parent, :do_refresh) end)
      schedule_periodic_refresh()
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:do_refresh, state) do
    _ = fetch_and_store()
    {:noreply, state}
  end

  # Periodic background refresh (~60 min). Skips the network entirely when the
  # cache file is still "hot" (fresher than @hot_ttl_ms), so several OSA
  # processes on one box don't all hammer models.dev.
  def handle_info(:periodic_refresh, state) do
    unless fetch_disabled?() or cache_fresh?(cache_path(), @hot_ttl_ms) do
      _ = fetch_and_store()
    end

    schedule_periodic_refresh()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_periodic_refresh do
    Process.send_after(self(), :periodic_refresh, @refresh_interval_ms)
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    reply =
      if fetch_disabled?() do
        {:ok, :disabled}
      else
        fetch_and_store()
      end

    {:reply, reply, state}
  end

  # ── Loading / normalization ────────────────────────────────────────────

  defp load_local do
    {raw, source} = load_chain(cache_path(), bundled_path())
    store(raw, source)
  rescue
    e ->
      Logger.warning("[Catalog] Local load failed: #{Exception.message(e)}")
      store(baked_snapshot(), :baked)
  end

  @doc false
  # Deterministic boot source-selection chain (fastest fresh local source wins):
  #   1. `cache_path` when fresh (mtime within `ttl_ms`)
  #   2. bundled `priv/catalog/models_dev.json`
  #   3. inline `baked_snapshot/0` — so the catalog ALWAYS resolves offline.
  # Returns `{raw_models_dev_map, source_atom}`. Pure w.r.t. ETS (testable).
  @spec load_chain(String.t(), String.t(), non_neg_integer()) :: {map(), atom()}
  def load_chain(cache_path, bundled_path, ttl_ms \\ @cache_ttl_ms) do
    cond do
      (cached = fresh_json(cache_path, ttl_ms)) != nil -> {cached, :cache}
      (bundled = read_json(bundled_path)) != nil -> {bundled, :bundled}
      true -> {baked_snapshot(), :baked}
    end
  end

  defp fresh_json(path, ttl_ms) do
    if cache_fresh?(path, ttl_ms), do: read_json(path)
  end

  @doc false
  # True when `path` exists and its mtime is within `ttl_ms`. Exposed so TTL
  # behavior can be tested via file mtime without a real clock.
  @spec cache_fresh?(String.t() | nil, non_neg_integer()) :: boolean()
  def cache_fresh?(path, ttl_ms) do
    with true <- is_binary(path) and File.exists?(path),
         {:ok, %File.Stat{mtime: mtime}} <- File.stat(path, time: :posix) do
      age_ms = (System.system_time(:second) - mtime) * 1000
      age_ms >= 0 and age_ms < ttl_ms
    else
      _ -> false
    end
  end

  defp fetch_and_store do
    url = models_url()

    with_lock(fn ->
      case fetch_catalog(url, fetcher()) do
        {:ok, body} when is_map(body) ->
          write_cache(body)
          store(body, :network)
          Logger.info("[Catalog] Refreshed from #{url}")
          :ok

        {:ok, _} ->
          {:error, :unexpected_body}

        {:error, reason} ->
          Logger.debug("[Catalog] Network refresh failed (#{inspect(reason)}) — keeping snapshot")
          {:error, reason}
      end
    end)
  rescue
    e ->
      Logger.debug("[Catalog] Network refresh raised: #{Exception.message(e)}")
      {:error, :exception}
  end

  @doc false
  # Run the (possibly injected) fetcher and validate its shape. The fetcher is a
  # 1-arity fun `url -> {:ok, map} | {:error, term}`; tests inject a stub so the
  # network is never touched. Defaults to `http_get/1` (exponential-backoff Req).
  @spec fetch_catalog(String.t(), (String.t() -> {:ok, term()} | {:error, term()})) ::
          {:ok, map()} | {:error, term()}
  def fetch_catalog(url, fetcher) do
    case fetcher.(url) do
      {:ok, body} when is_map(body) -> {:ok, body}
      {:ok, _} -> {:error, :unexpected_body}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:bad_fetcher_return, other}}
    end
  rescue
    e -> {:error, {:fetcher_raised, Exception.message(e)}}
  end

  defp fetcher do
    Application.get_env(:optimal_system_agent, :models_fetcher, &__MODULE__.http_get/1)
  end

  @doc false
  # Default network fetcher: Req with transient retry + exponential backoff.
  @spec http_get(String.t()) :: {:ok, term()} | {:error, term()}
  def http_get(url) do
    case Req.get(url,
           receive_timeout: 10_000,
           retry: :transient,
           max_retries: 3,
           retry_delay: fn n -> min(trunc(200 * :math.pow(2, n)), 5_000) end
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Best-effort cross-process guard around the fetch+write so concurrent OSA
  # processes on one box don't all fetch and clobber the cache. Uses an
  # exclusive lock file (advisory); a stale lock (>2 min) is stolen, and if the
  # lock can't be created at all we proceed unlocked rather than skip a refresh.
  defp with_lock(fun) do
    lock = cache_path() <> ".lock"
    File.mkdir_p!(Path.dirname(lock))
    maybe_clear_stale_lock(lock)

    case File.open(lock, [:write, :exclusive]) do
      {:ok, io} ->
        try do
          fun.()
        after
          File.close(io)
          File.rm(lock)
        end

      {:error, :eexist} ->
        Logger.debug("[Catalog] Refresh already in progress (lock held) — skipping")
        {:ok, :locked}

      {:error, _} ->
        fun.()
    end
  end

  defp maybe_clear_stale_lock(lock) do
    case File.stat(lock, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} ->
        if System.system_time(:second) - mtime > 120, do: File.rm(lock)

      _ ->
        :ok
    end
  end

  # Small inline snapshot — the final offline fallback so the catalog ALWAYS
  # resolves the model families OSA uses even if the bundled file is missing.
  # Raw models.dev shape; carries context + capabilities but NO invented pricing.
  defp baked_snapshot do
    %{
      "anthropic" => %{
        "id" => "anthropic",
        "name" => "Anthropic",
        "models" => %{
          "claude-opus-4-6" => %{
            "name" => "Claude Opus 4.6",
            "tool_call" => true,
            "reasoning" => true,
            "attachment" => true,
            "release_date" => "2025-11-01",
            "modalities" => %{"input" => ["text", "image"], "output" => ["text"]},
            "limit" => %{"context" => 200_000, "output" => 64_000}
          },
          "claude-sonnet-4-6" => %{
            "name" => "Claude Sonnet 4.6",
            "tool_call" => true,
            "reasoning" => true,
            "attachment" => true,
            "release_date" => "2025-09-01",
            "modalities" => %{"input" => ["text", "image"], "output" => ["text"]},
            "limit" => %{"context" => 200_000, "output" => 64_000}
          },
          "claude-haiku-4-5" => %{
            "name" => "Claude Haiku 4.5",
            "tool_call" => true,
            "reasoning" => false,
            "attachment" => true,
            "release_date" => "2025-10-01",
            "modalities" => %{"input" => ["text", "image"], "output" => ["text"]},
            "limit" => %{"context" => 200_000, "output" => 32_000}
          }
        }
      },
      "openai" => %{
        "id" => "openai",
        "name" => "OpenAI",
        "models" => %{
          "gpt-4o" => %{
            "name" => "GPT-4o",
            "tool_call" => true,
            "reasoning" => false,
            "attachment" => true,
            "release_date" => "2024-05-13",
            "modalities" => %{"input" => ["text", "image"], "output" => ["text"]},
            "limit" => %{"context" => 128_000, "output" => 16_384}
          },
          "gpt-4o-mini" => %{
            "name" => "GPT-4o mini",
            "tool_call" => true,
            "reasoning" => false,
            "attachment" => true,
            "release_date" => "2024-07-18",
            "modalities" => %{"input" => ["text", "image"], "output" => ["text"]},
            "limit" => %{"context" => 128_000, "output" => 16_384}
          },
          "o3" => %{
            "name" => "o3",
            "tool_call" => true,
            "reasoning" => true,
            "release_date" => "2025-04-16",
            "modalities" => %{"input" => ["text"], "output" => ["text"]},
            "limit" => %{"context" => 200_000, "output" => 100_000}
          }
        }
      },
      "zhipuai" => %{
        "id" => "zhipuai",
        "name" => "Zhipu AI",
        "models" => %{
          "glm-4.6" => %{
            "name" => "GLM-4.6",
            "tool_call" => true,
            "reasoning" => true,
            "release_date" => "2025-09-30",
            "modalities" => %{"input" => ["text"], "output" => ["text"]},
            "limit" => %{"context" => 200_000, "output" => 128_000}
          },
          "glm-5.2" => %{
            "name" => "GLM-5.2",
            "tool_call" => true,
            "reasoning" => true,
            "release_date" => "2026-01-01",
            "modalities" => %{"input" => ["text"], "output" => ["text"]},
            "limit" => %{"context" => 200_000, "output" => 128_000}
          }
        }
      },
      "ollama" => %{
        "id" => "ollama",
        "name" => "Ollama",
        "models" => %{
          "llama3.3" => %{
            "name" => "Llama 3.3",
            "tool_call" => true,
            "reasoning" => false,
            "release_date" => "2024-12-06",
            "modalities" => %{"input" => ["text"], "output" => ["text"]},
            "limit" => %{"context" => 128_000, "output" => 8_192}
          }
        }
      }
    }
  end

  # Atomic cache write: serialize to a temp file, then rename into place.
  defp write_cache(raw) do
    path = cache_path()
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"

    with {:ok, json} <- Jason.encode(raw),
         :ok <- File.write(tmp, json),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      other ->
        _ = File.rm(tmp)
        Logger.debug("[Catalog] Cache write failed: #{inspect(other)}")
        :error
    end
  rescue
    e ->
      Logger.debug("[Catalog] Cache write raised: #{Exception.message(e)}")
      :error
  end

  # Store a raw models.dev-shaped map into ETS as a normalized catalog.
  defp store(raw, source) when is_map(raw) do
    normalized = normalize(raw)
    ensure_table()
    :ets.insert(@table, {@data_key, normalized})

    :ets.insert(
      @table,
      {@meta_key, %{source: source, loaded_at: DateTime.utc_now()}}
    )

    normalized
  end

  @doc false
  # Normalize a raw models.dev api.json map into
  # `%{provider_id => %{model_id => %Model{}}}`. Ignores non-provider keys
  # (e.g. a leading "_comment") and providers without a models object.
  @spec normalize(map()) :: map()
  def normalize(raw) when is_map(raw) do
    Enum.reduce(raw, %{}, fn
      {pid, %{"models" => models}}, acc when is_binary(pid) and is_map(models) ->
        entries =
          Enum.reduce(models, %{}, fn {mid, m}, macc when is_map(m) ->
            Map.put(macc, mid, normalize_model(pid, mid, m))
          end)

        Map.put(acc, pid, entries)

      _, acc ->
        acc
    end)
  end

  def normalize(_), do: %{}

  defp normalize_model(pid, mid, m) do
    limit = Map.get(m, "limit", %{})

    %Model{
      provider_id: pid,
      model_id: mid,
      name: Map.get(m, "name", mid),
      ctx: get_int(limit, "context"),
      max_output: get_int(limit, "output"),
      tool_call: !!Map.get(m, "tool_call", false),
      reasoning: !!Map.get(m, "reasoning", false),
      attachment: !!Map.get(m, "attachment", false),
      structured_output: !!Map.get(m, "structured_output", false),
      release_date: normalize_date(Map.get(m, "release_date")),
      cost: normalize_cost(Map.get(m, "cost")),
      modalities: normalize_modalities(Map.get(m, "modalities"))
    }
  end

  defp normalize_cost(%{} = cost) do
    %{
      input: num(Map.get(cost, "input")),
      output: num(Map.get(cost, "output")),
      cache_read: num(Map.get(cost, "cache_read")),
      cache_write: num(Map.get(cost, "cache_write"))
    }
  end

  defp normalize_cost(_), do: nil

  # models.dev ships "release_date" as "YYYY-MM-DD"; keep a %Date{} or nil.
  defp normalize_date(d) when is_binary(d) do
    case Date.from_iso8601(d) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp normalize_date(_), do: nil

  defp normalize_modalities(%{} = mods) do
    %{
      input: List.wrap(Map.get(mods, "input", [])),
      output: List.wrap(Map.get(mods, "output", []))
    }
  end

  defp normalize_modalities(_), do: %{input: [], output: []}

  defp get_int(map, key) do
    case Map.get(map, key) do
      n when is_integer(n) -> n
      n when is_float(n) -> trunc(n)
      _ -> nil
    end
  end

  defp num(n) when is_number(n), do: n
  defp num(_), do: nil

  # ── ETS access ─────────────────────────────────────────────────────────

  defp data do
    case ets_lookup(@data_key) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp ets_lookup(key) do
    case :ets.whereis(@table) do
      :undefined ->
        :miss

      _ ->
        case :ets.lookup(@table, key) do
          [{^key, value}] -> {:ok, value}
          _ -> :miss
        end
    end
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end
  rescue
    ArgumentError -> :ok
  end

  # ── Config resolution ──────────────────────────────────────────────────

  defp models_url do
    System.get_env("OSA_MODELS_URL") ||
      Application.get_env(:optimal_system_agent, :models_url) || @default_url
  end

  defp bundled_path do
    System.get_env("OSA_MODELS_PATH") ||
      Application.get_env(:optimal_system_agent, :models_path) ||
      Path.join([priv_dir(), "catalog", "models_dev.json"])
  end

  defp cache_path do
    Application.get_env(:optimal_system_agent, :models_cache_path) ||
      Path.join([System.user_home!() || ".", ".osa", "cache", "models.json"])
  end

  defp fetch_disabled? do
    System.get_env("OSA_DISABLE_MODELS_FETCH") not in [nil, ""] or
      Application.get_env(:optimal_system_agent, :disable_models_fetch, false) == true
  end

  defp priv_dir do
    case :code.priv_dir(:optimal_system_agent) do
      {:error, _} -> "priv"
      dir -> to_string(dir)
    end
  end

  defp read_json(path) do
    with true <- is_binary(path) and File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, parsed} <- Jason.decode(content) do
      parsed
    else
      _ -> nil
    end
  end
end
