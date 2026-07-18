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
       boot (and on `refresh/0`) unless disabled, written to the cache file
       atomically (temp + rename), and swapped into ETS.

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
  @cache_ttl_ms 24 * 60 * 60 * 1000

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
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:do_refresh, state) do
    _ = fetch_and_store()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

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
    cond do
      (cached = fresh_cache()) != nil ->
        store(cached, :cache)

      (bundled = read_json(bundled_path())) != nil ->
        store(bundled, :bundled)

      true ->
        # Nothing to load — leave an empty catalog rather than crashing.
        store(%{}, :empty)
    end
  rescue
    e ->
      Logger.warning("[Catalog] Local load failed: #{Exception.message(e)}")
      store(%{}, :empty)
  end

  defp fresh_cache do
    path = cache_path()

    with true <- File.exists?(path),
         {:ok, %File.Stat{mtime: mtime}} <- File.stat(path, time: :posix),
         age_ms = (System.system_time(:second) - mtime) * 1000,
         true <- age_ms >= 0 and age_ms < @cache_ttl_ms,
         parsed when is_map(parsed) <- read_json(path) do
      parsed
    else
      _ -> nil
    end
  end

  defp fetch_and_store do
    url = models_url()

    case safe_get(url) do
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
  rescue
    e ->
      Logger.debug("[Catalog] Network refresh raised: #{Exception.message(e)}")
      {:error, :exception}
  end

  defp safe_get(url) do
    case Req.get(url, receive_timeout: 10_000, retry: false) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
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
