defmodule OptimalSystemAgent.LocalModels do
  @moduledoc """
  Local model management for `/models`: what is installed and loaded, what the
  curated catalog offers, whether each one fits THIS machine and how fast it
  should decode, and the lifecycle verbs — install (pull + benchmark), remove,
  load, unload, alias, set as default.

  Composes `LocalModels.Hardware` (what the box has), `LocalModels.Fit` (does
  it fit / est. tok/s), `LocalModels.OllamaAdmin` (the daemon),
  `LocalModels.HuggingFace` (exact GGUF sizes) and `LocalModels.Catalog`.
  """

  require Logger

  alias OptimalSystemAgent.LocalModels.{Catalog, Fit, Hardware, HuggingFace, OllamaAdmin}
  alias OptimalSystemAgent.System.{AtomicFile, JsonStore}

  @floor_ctx 32_768
  @ctx_buckets [32_768, 49_152, 65_536, 98_304, 131_072, 196_608, 262_144]

  # `auto_num_ctx/1` runs inside `Registry.effective_context_window/2`, which
  # `Loop.handle_call({:swap_provider, ...})` invokes on the model-switch path,
  # under the 5_000 ms `GenServer.call` default. The `/api/show` here is the
  # SECOND daemon round-trip on that path (the context-window probe is the
  # first), so it must fail FAST against an unreachable or half-open daemon
  # rather than fall back to Finch's 5 s connect default: 3 s probe + 5 s here
  # overran the call and the swap landed while the caller reported failure. A
  # local daemon connects in well under this; only a black hole waits it out.
  @auto_ctx_probe_opts [connect_options: [timeout: 500], receive_timeout: 800, retry: false]

  @type row :: %{
          tag: String.t(),
          name: String.t(),
          installed: boolean(),
          loaded: boolean(),
          remote: boolean(),
          size_bytes: non_neg_integer(),
          params: String.t() | nil,
          quant: String.t() | nil,
          capabilities: [String.t()],
          fit: Fit.t() | nil,
          measured_tps: float() | nil,
          entry: Catalog.entry() | nil
        }

  # ── overview ────────────────────────────────────────────────────────────

  @doc """
  Everything the picker needs in one call: hardware, installed local models
  (with what is resident), and the catalog — each with a fit verdict.
  Never raises; a daemon that is down yields `installed: []` and an error.
  """
  @spec overview() :: %{
          hardware: Hardware.t(),
          ctx: pos_integer(),
          installed: [row()],
          catalog: [row()],
          error: String.t() | nil
        }
  def overview do
    hw = Hardware.detect()
    ctx = context_for_fit()
    bench = read_bench()

    {installed, error} =
      case OllamaAdmin.installed() do
        {:ok, list} -> {list, nil}
        {:error, e} -> {[], e}
      end

    loaded =
      case OllamaAdmin.loaded() do
        {:ok, list} -> MapSet.new(list, & &1.name)
        _ -> MapSet.new()
      end

    # An alias (`ollama cp hf.co/… superqwen-abliterated`) shares the digest
    # of the tag it was copied from, so it inherits that tag's catalog entry,
    # capabilities and quant.
    by_digest =
      installed
      |> Enum.reject(& &1.remote)
      |> Enum.reduce(%{}, fn m, acc ->
        case Catalog.entry_for_tag(m.name) do
          nil -> acc
          entry -> Map.put_new(acc, m.digest, {entry, m.quant})
        end
      end)

    installed_rows =
      installed
      |> Enum.reject(& &1.remote)
      |> Enum.map(fn m ->
        {entry, quant} =
          case {Catalog.entry_for_tag(m.name), Map.get(by_digest, m.digest)} do
            {nil, {entry, q}} -> {entry, m.quant || q}
            {entry, _} -> {entry, m.quant || (entry && entry.quant)}
          end

        spec = %{
          weights_bytes: m.size_bytes,
          params_b: entry && entry.params_b,
          active_params_b: entry && entry.active_params_b,
          quant: quant,
          family: (entry && entry.family) || m.family
        }

        %{
          tag: m.name,
          name: (entry && entry.name) || m.name,
          installed: true,
          loaded: MapSet.member?(loaded, m.name),
          remote: false,
          size_bytes: m.size_bytes,
          params: m.params,
          quant: quant,
          capabilities: (entry && entry.capabilities) || [],
          fit: Fit.assess(spec, hw, ctx),
          measured_tps: measured_for(m, bench, installed),
          entry: entry
        }
      end)

    installed_tags = MapSet.new(installed, & &1.name)

    catalog_rows =
      Catalog.all()
      |> Enum.reject(fn e ->
        Enum.any?(e.quants, &MapSet.member?(installed_tags, Catalog.tag(e, &1)))
      end)
      |> Enum.map(fn e ->
        spec = %{
          params_b: e.params_b,
          active_params_b: e.active_params_b,
          quant: e.quant,
          family: e.family
        }

        %{
          tag: Catalog.tag(e),
          name: e.name,
          installed: false,
          loaded: false,
          remote: false,
          size_bytes: elem(Fit.weights_bytes(spec), 0),
          params: "#{e.params_b}B",
          quant: e.quant,
          capabilities: e.capabilities,
          fit: Fit.assess(spec, hw, ctx),
          measured_tps: nil,
          entry: e
        }
      end)

    %{hardware: hw, ctx: ctx, installed: installed_rows, catalog: catalog_rows, error: error}
  end

  @doc "One-line summary of a row for pickers: fit · speed · capabilities."
  @spec note(row()) :: String.t()
  def note(row) do
    fit =
      case row.fit && row.fit.verdict do
        :fits -> "✓ fits in VRAM"
        :partial -> "⚠ partial offload"
        :cpu -> "⚠ CPU only"
        :no -> "✗ won't fit"
        _ -> nil
      end

    speed =
      cond do
        row.measured_tps -> "#{row.measured_tps} tok/s measured"
        row.fit && row.fit.est_tps -> "~#{round(row.fit.est_tps)} tok/s est."
        true -> nil
      end

    caps = if row.capabilities == [], do: nil, else: Enum.join(row.capabilities, ", ")
    size = if row.size_bytes > 0, do: "#{Float.round(row.size_bytes / 1.0e9, 1)} GB"

    [fit, speed, size, caps] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")
  end

  @doc "JSON-safe shape of a row / inspect result / fit for the HTTP API."
  @spec to_json(term()) :: term()
  def to_json(%{} = map) do
    map
    |> Map.drop([:entry, :model_info])
    |> Map.new(fn
      {:fit, fit} -> {:fit, to_json(fit)}
      {:quants, qs} when is_list(qs) -> {:quants, Enum.map(qs, &to_json/1)}
      {:hardware, hw} -> {:hardware, hw}
      {k, v} when is_atom(v) and not is_boolean(v) and not is_nil(v) -> {k, Atom.to_string(v)}
      {k, v} -> {k, v}
    end)
    |> then(fn m ->
      case Map.get(map, :entry) do
        %{id: id, blurb: blurb, tags: tags, repo: repo, quants: quants} ->
          Map.merge(m, %{
            catalog_id: id,
            blurb: blurb,
            tags: tags,
            repo: repo,
            catalog_quants: quants
          })

        _ ->
          m
      end
    end)
  end

  def to_json(list) when is_list(list), do: Enum.map(list, &to_json/1)
  def to_json(other), do: other

  # ── inspect one ─────────────────────────────────────────────────────────

  @doc """
  Full detail for one model — installed tag, catalog id, or `hf.co/…` tag.
  For a catalog/HF model that is not installed, sizes come from the Hub
  (exact) and the fit is per available quant.
  """
  @spec inspect_model(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def inspect_model(ref, opts \\ []) do
    hw = Hardware.detect()
    ctx = context_for_fit()

    case resolve(ref) do
      {:installed, tag} -> inspect_installed(tag, hw, ctx)
      {:catalog, entry, quant} -> inspect_catalog(entry, quant, hw, ctx, opts)
      {:hf, repo, quant} -> inspect_hf(repo, quant, hw, ctx, opts)
      :unknown -> {:error, "unknown model: #{ref} — try /models to see what's available"}
    end
  end

  defp inspect_installed(tag, hw, ctx) do
    with {:ok, d} <- OllamaAdmin.show(tag) do
      entry = Catalog.entry_for_tag(tag)
      size = installed_size(tag)

      spec = %{
        weights_bytes: size,
        params_b: params_b_of(d, entry),
        active_params_b: entry && entry.active_params_b,
        quant: d.quant,
        family: (entry && entry.family) || d.family,
        kv_bytes_per_token: d.kv_bytes_per_token
      }

      {:ok,
       %{
         tag: tag,
         name: (entry && entry.name) || tag,
         installed: true,
         capabilities: d.capabilities,
         family: d.family,
         params: d.params,
         quant: d.quant,
         context_length: d.context_length,
         size_bytes: size,
         fit: Fit.assess(spec, hw, ctx),
         measured: read_bench()[tag],
         quants: [],
         entry: entry
       }}
    end
  end

  defp inspect_catalog(entry, quant, hw, ctx, opts) do
    quants = fit_per_quant(entry.repo, entry, hw, ctx, opts)

    # Recommend for THIS machine — the largest quant that fully fits — when
    # the Hub told us the real sizes; the catalog's quant is the offline guess.
    chosen =
      cond do
        is_binary(quant) -> quant
        Enum.any?(quants, & &1.exact) -> pick_quant(quants)
        true -> entry.quant
      end

    {:ok,
     %{
       tag: Catalog.tag(entry, chosen),
       name: entry.name,
       installed: false,
       capabilities: entry.capabilities,
       family: entry.family,
       params: "#{entry.params_b}B",
       quant: chosen,
       context_length: entry.context,
       size_bytes: Enum.find_value(quants, 0, &(&1.quant == String.upcase(chosen) && &1.bytes)),
       fit: Enum.find_value(quants, &(&1.quant == String.upcase(chosen) && &1.fit)),
       measured: nil,
       quants: quants,
       entry: entry
     }}
  end

  defp inspect_hf(repo, quant, hw, ctx, opts) do
    with {:ok, hf} <- HuggingFace.repo(repo, opts) do
      if hf.quants == [] do
        {:error, "#{repo} has no GGUF files"}
      else
        quants = fit_per_quant(repo, nil, hw, ctx, opts)
        chosen = quant || pick_quant(quants)

        {:ok,
         %{
           tag: "hf.co/#{repo}:#{chosen}",
           name: repo,
           installed: false,
           capabilities: if(hf.mmproj_bytes > 0, do: ["vision"], else: []),
           family: nil,
           params: nil,
           quant: chosen,
           context_length: nil,
           size_bytes:
             Enum.find_value(quants, 0, &(&1.quant == String.upcase(chosen) && &1.bytes)),
           fit: Enum.find_value(quants, &(&1.quant == String.upcase(chosen) && &1.fit)),
           measured: nil,
           quants: quants,
           entry: nil
         }}
      end
    end
  end

  # Every quant the repo ships, sized exactly from the Hub when reachable,
  # else estimated from params — each with its own fit.
  defp fit_per_quant(repo, entry, hw, ctx, opts) do
    params = entry && entry.params_b
    active = entry && entry.active_params_b
    family = entry && entry.family

    case HuggingFace.repo(repo, opts) do
      {:ok, hf} when hf.quants != [] ->
        Enum.map(hf.quants, fn q ->
          spec = %{
            weights_bytes: q.bytes + hf.mmproj_bytes,
            params_b: params,
            active_params_b: active,
            quant: q.quant,
            family: family
          }

          %{quant: q.quant, bytes: q.bytes, exact: true, fit: Fit.assess(spec, hw, ctx)}
        end)

      _ when is_map(entry) ->
        Enum.map(entry.quants, fn q ->
          spec = %{params_b: params, active_params_b: active, quant: q, family: family}
          {bytes, _} = Fit.weights_bytes(spec)
          %{quant: String.upcase(q), bytes: bytes, exact: false, fit: Fit.assess(spec, hw, ctx)}
        end)

      _ ->
        []
    end
  end

  # Largest quant that fully fits; else the smallest available.
  defp pick_quant(quants) do
    fitting = Enum.filter(quants, &(&1.fit.verdict == :fits))

    case fitting do
      [] -> quants |> Enum.min_by(& &1.bytes, fn -> %{quant: "Q4_K_M"} end) |> Map.get(:quant)
      list -> list |> Enum.max_by(& &1.bytes) |> Map.get(:quant)
    end
  end

  # ── lifecycle ───────────────────────────────────────────────────────────

  @doc """
  Pull `ref` (catalog id, `hf.co/…` tag, or plain Ollama tag) at `quant`,
  streaming progress, then benchmark it and remember the measured speed.
  Returns the installed tag and the benchmark.
  """
  @spec install(String.t(), keyword()) ::
          {:ok, %{tag: String.t(), bench: map() | nil}} | {:error, String.t()}
  def install(ref, opts \\ []) do
    on_progress = Keyword.get(opts, :on_progress, fn _ -> :ok end)
    quant = Keyword.get(opts, :quant)

    tag =
      case resolve(ref) do
        {:installed, tag} -> tag
        {:catalog, entry, q} -> Catalog.tag(entry, quant || q)
        {:hf, repo, q} -> "hf.co/#{repo}:#{quant || q || "Q4_K_M"}"
        :unknown -> ref
      end

    with :ok <- OllamaAdmin.pull(tag, on_progress) do
      bench =
        if Keyword.get(opts, :bench, true) do
          case bench(tag) do
            {:ok, b} -> b
            _ -> nil
          end
        end

      {:ok, %{tag: tag, bench: bench}}
    end
  end

  @doc "Measure decode speed and remember it for the picker."
  @spec bench(String.t()) :: {:ok, map()} | {:error, String.t()}
  def bench(tag) do
    with {:ok, b} <- OllamaAdmin.bench(tag) do
      write_bench(
        Map.put(read_bench(), tag, %{
          "decode_tps" => b.decode_tps,
          "prompt_tps" => b.prompt_tps,
          "load_ms" => b.load_ms,
          "measured_at" =>
            DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        })
      )

      {:ok, b}
    end
  end

  @spec remove(String.t()) :: :ok | {:error, String.t()}
  def remove(tag) do
    with :ok <- OllamaAdmin.delete(tag) do
      write_bench(Map.delete(read_bench(), tag))
      :ok
    end
  end

  defdelegate load(tag), to: OllamaAdmin
  defdelegate unload(tag), to: OllamaAdmin
  defdelegate alias_tag(from, to), to: OllamaAdmin, as: :copy

  @doc "Make `tag` the default for new sessions (config.json + OLLAMA_MODEL)."
  @spec set_default(String.t()) :: :ok | {:error, String.t()}
  def set_default(tag) when is_binary(tag) do
    path = Path.join(osa_home(), "config.json")

    with {:ok, existing} <- read_config(path),
         updated = Map.merge(existing, %{"provider" => "ollama", "model" => tag}),
         {:ok, json} <- Jason.encode(updated, pretty: true),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- AtomicFile.write(path, json <> "\n", mode: 0o600) do
      try do
        OptimalSystemAgent.CLI.Setup.save_env("OLLAMA_MODEL", tag)
      rescue
        _ -> :ok
      end

      Application.put_env(:optimal_system_agent, :ollama_model, tag)
      :ok
    else
      {:error, :corrupt} -> {:error, JsonStore.corrupt_message("model selection", path)}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # ── resolution ──────────────────────────────────────────────────────────

  @doc false
  def resolve(ref) when is_binary(ref) do
    ref = String.trim(ref)
    installed = installed_tags()

    cond do
      ref == "" ->
        :unknown

      MapSet.member?(installed, ref) ->
        {:installed, ref}

      MapSet.member?(installed, ref <> ":latest") ->
        {:installed, ref <> ":latest"}

      String.ends_with?(ref, ":latest") and
          MapSet.member?(installed, String.trim_trailing(ref, ":latest")) ->
        {:installed, ref}

      entry = Catalog.find(ref) ->
        {_, quant} = Catalog.split_tag(ref)
        quant = if Catalog.hf_tag?(ref) or String.contains?(ref, "/"), do: quant, else: nil

        # A catalog id whose model is already pulled (at any quant) IS that
        # installed tag — `/models info <id>` after `/models install <id>`
        # must describe what is on disk, and `/models use <id>` must work.
        case Enum.find(entry.quants, &MapSet.member?(installed, Catalog.tag(entry, &1))) do
          nil -> {:catalog, entry, quant}
          q -> {:installed, Catalog.tag(entry, q)}
        end

      Catalog.hf_tag?(ref) or (String.contains?(ref, "/") and not String.contains?(ref, " ")) ->
        {repo, quant} = Catalog.split_tag(ref)
        {:hf, repo, quant}

      true ->
        :unknown
    end
  end

  # A benchmark is keyed by tag, but an alias shares its source's digest and
  # therefore its speed.
  defp measured_for(m, bench, installed) do
    get_in(bench, [m.name, "decode_tps"]) ||
      Enum.find_value(installed, fn other ->
        other.digest == m.digest and other.name != m.name and
          get_in(bench, [other.name, "decode_tps"])
      end)
  end

  defp installed_tags do
    case OllamaAdmin.installed() do
      {:ok, list} -> MapSet.new(list, & &1.name)
      _ -> MapSet.new()
    end
  end

  # `superqwen-abliterated` and `superqwen-abliterated:latest` are the same
  # tag to Ollama; config.json usually carries the short form.
  defp installed_size(tag) do
    case OllamaAdmin.installed() do
      {:ok, list} ->
        Enum.find_value(list, 0, fn m ->
          (m.name == tag or m.name == tag <> ":latest" or m.name <> ":latest" == tag) and
            m.size_bytes
        end)

      _ ->
        0
    end
  end

  defp params_b_of(%{params_count: n}, _entry) when is_integer(n) and n > 0, do: n / 1.0e9
  defp params_b_of(_, %{params_b: p}), do: p
  defp params_b_of(_, _), do: nil

  # ── persistence ─────────────────────────────────────────────────────────

  @doc false
  def context_for_fit do
    case Application.get_env(:optimal_system_agent, :ollama_num_ctx) do
      n when is_integer(n) -> n
      _ -> @floor_ctx
    end
  end

  # ── context window ceiling ─────────────────────────────────────────────

  @doc """
  The `num_ctx` ceiling for a local model. `OLLAMA_NUM_CTX=<n>` pins it;
  `auto` (the default) returns the largest bucket whose KV cache fits in
  VRAM beside the weights on THIS machine, floored at 32k. Cached per model.
  """
  @spec num_ctx_ceiling(String.t() | nil) :: pos_integer()
  def num_ctx_ceiling(model) do
    case Application.get_env(:optimal_system_agent, :ollama_num_ctx) do
      n when is_integer(n) and n > 0 -> n
      _ -> auto_num_ctx(model)
    end
  end

  @doc false
  def auto_num_ctx(model) when is_binary(model) do
    key = {__MODULE__, :auto_ctx, model}

    case :persistent_term.get(key, nil) do
      nil ->
        ctx = compute_auto_num_ctx(model)
        :persistent_term.put(key, ctx)
        ctx

      ctx ->
        ctx
    end
  end

  def auto_num_ctx(_), do: @floor_ctx

  @doc false
  def forget_auto_num_ctx(model), do: :persistent_term.erase({__MODULE__, :auto_ctx, model})

  defp compute_auto_num_ctx(model) do
    with {:ok, d} <- OllamaAdmin.show(model, @auto_ctx_probe_opts),
         size when size > 0 <- installed_size(model) do
      spec = %{
        weights_bytes: size,
        quant: d.quant,
        family: d.family,
        kv_bytes_per_token: d.kv_bytes_per_token
      }

      auto_ctx_for(spec, Hardware.detect(), d.context_length)
    else
      _ -> @floor_ctx
    end
  rescue
    _ -> @floor_ctx
  catch
    :exit, _ -> @floor_ctx
  end

  @doc "Pure: largest bucket that fully fits, floored at 32k, capped at the trained window."
  @spec auto_ctx_for(Fit.spec(), Hardware.t(), pos_integer() | nil) :: pos_integer()
  def auto_ctx_for(spec, hw, trained) do
    cap = if is_integer(trained) and trained > 0, do: trained, else: List.last(@ctx_buckets)

    @ctx_buckets
    |> Enum.filter(&(&1 <= cap))
    |> Enum.filter(&(Fit.assess(spec, hw, &1).verdict == :fits))
    |> Enum.max(fn -> @floor_ctx end)
    |> max(@floor_ctx)
  end

  defp bench_path do
    Application.get_env(:optimal_system_agent, :local_bench_path) ||
      Path.join([osa_home(), "cache", "local_bench.json"])
  end

  @doc false
  def read_bench do
    with {:ok, raw} <- File.read(bench_path()),
         {:ok, map} when is_map(map) <- Jason.decode(raw) do
      map
    else
      _ -> %{}
    end
  end

  defp write_bench(map) do
    File.mkdir_p!(Path.dirname(bench_path()))
    File.write(bench_path(), Jason.encode!(map, pretty: true))
  rescue
    _ -> :ok
  end

  defp read_config(path) do
    if File.exists?(path), do: JsonStore.read_map_for_write(path), else: {:ok, %{}}
  end

  defp osa_home do
    (Application.get_env(:optimal_system_agent, :bootstrap_dir) ||
       System.get_env("OSA_HOME") || Path.join(System.user_home!(), ".osa"))
    |> Path.expand()
  end
end
