defmodule OptimalSystemAgent.Channels.HTTP.API.DataRoutes do
  @moduledoc """
  Data management routes forwarded from multiple prefixes.

  Forwarded prefixes → effective routes:
    /memory     → GET /recall, GET /search, POST /
    /models     → GET /, POST /switch, GET /current, POST /current
    /analytics  → GET /
    /scheduler  → GET /jobs, POST /reload
    /webhooks   → POST /:trigger_id
    /machines   → GET /
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  alias OptimalSystemAgent.SDK.Memory
  alias OptimalSystemAgent.Providers.ModelCatalog
  alias OptimalSystemAgent.Agent.Scheduler
  alias OptimalSystemAgent.Machines

  plug(:match)
  plug(:dispatch)

  # ── GET / ─────────────────────────────────────────────────────────
  # Handles GET /models, GET /analytics, GET /machines after prefix strip.

  get "/" do
    case List.last(conn.script_name) do
      "analytics" -> handle_analytics(conn)
      "machines" -> handle_machines(conn)
      _ -> handle_list_models(conn)
    end
  end

  # ── GET /recall — memory recall ────────────────────────────────────

  get "/recall" do
    raw = Memory.recall()

    # Memory.recall/0 may return a list of entry maps or a binary string.
    # Normalise to a binary (for downstream consumers) or nil when empty.
    content =
      cond do
        is_binary(raw) ->
          raw

        is_list(raw) and raw == [] ->
          nil

        is_list(raw) ->
          raw
          |> Enum.map(fn
            %{content: c} -> c
            %{"content" => c} -> c
            other -> inspect(other)
          end)
          |> Enum.join("\n\n")

        true ->
          nil
      end

    body = Jason.encode!(%{content: content})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── GET /search — memory search ────────────────────────────────────
  # Query params: q (required), category (optional), limit (optional, default 10),
  #               sort (optional: relevance|recency|importance), mode (optional: relevant|keyword)

  get "/search" do
    query = conn.query_params["q"]

    if is_nil(query) or query == "" do
      json_error(conn, 400, "invalid_request", "Missing required query param: q")
    else
      mode = conn.query_params["mode"] || "keyword"
      limit = parse_int(conn.query_params["limit"]) || 10
      category = conn.query_params["category"]
      sort = parse_sort_atom(conn.query_params["sort"])

      results =
        if mode == "relevant" do
          max_tokens = limit * 200
          Memory.recall_relevant(query, max_tokens)
        else
          opts =
            [limit: limit, sort: sort]
            |> maybe_put(:category, category)

          Memory.search(query, opts)
        end

      body = Jason.encode!(%{results: results, count: length(results), query: query})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    end
  end

  # ── GET /jobs — scheduler jobs ─────────────────────────────────────

  get "/jobs" do
    jobs =
      try do
        Scheduler.list_jobs()
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    body =
      Jason.encode!(%{
        jobs: jobs,
        count: length(jobs)
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── POST / ────────────────────────────────────────────────────────
  # Handles POST /memory after prefix strip.

  post "/" do
    with %{"content" => content} <- conn.body_params do
      category = conn.body_params["category"] || "general"
      Memory.remember(content, category)

      body = Jason.encode!(%{status: "saved", category: category})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(201, body)
    else
      _ -> json_error(conn, 400, "invalid_request", "Missing required field: content")
    end
  end

  # ── POST /switch — model switch ────────────────────────────────────

  post "/switch" do
    valid_providers = OptimalSystemAgent.Providers.Registry.list_providers()
    valid_names = Enum.map(valid_providers, &Atom.to_string/1)

    with %{"provider" => prov_str, "model" => model_name} <- conn.body_params,
         true <- prov_str in valid_names,
         provider <- String.to_existing_atom(prov_str) do
      Application.put_env(:optimal_system_agent, :default_provider, provider)
      Application.put_env(:optimal_system_agent, :default_model, model_name)

      if provider == :ollama do
        Application.put_env(:optimal_system_agent, :ollama_model, model_name)
      end

      # Persist selection to ~/.osa/config.json so it survives restarts.
      persist_model_selection(prov_str, model_name)

      Logger.info("[Models] Switched to #{prov_str}/#{model_name}")

      context_window = OptimalSystemAgent.Providers.Registry.context_window(model_name)

      body =
        Jason.encode!(%{
          provider: prov_str,
          model: model_name,
          status: "ok",
          context_window: context_window
        })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    else
      false ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "unknown provider"}))

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "missing or invalid provider/model"}))
    end
  end

  # ── GET /current — active model ────────────────────────────────────
  # Effective path: GET /models/current

  get "/current" do
    provider =
      Application.get_env(:optimal_system_agent, :default_provider, :ollama)
      |> to_string()

    model =
      Application.get_env(:optimal_system_agent, :default_model) ||
        Application.get_env(:optimal_system_agent, :ollama_model, "llama3.2:latest")

    model_name = to_string(model)

    context_window =
      try do
        OptimalSystemAgent.Providers.Registry.context_window(model_name)
      rescue
        _ -> nil
      end

    body =
      Jason.encode!(%{
        provider: provider,
        model: model_name,
        context_window: context_window
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── POST /current — switch active model ────────────────────────────
  # Effective path: POST /models/current
  # Body: {"provider": "...", "model": "..."}

  post "/current" do
    valid_providers = OptimalSystemAgent.Providers.Registry.list_providers()
    valid_names = Enum.map(valid_providers, &Atom.to_string/1)

    with %{"provider" => prov_str, "model" => model_name} <- conn.body_params,
         true <- is_binary(prov_str) and prov_str != "",
         true <- is_binary(model_name) and model_name != "",
         true <- prov_str in valid_names,
         provider <- String.to_existing_atom(prov_str) do
      Application.put_env(:optimal_system_agent, :default_provider, provider)
      Application.put_env(:optimal_system_agent, :default_model, model_name)

      if provider == :ollama do
        Application.put_env(:optimal_system_agent, :ollama_model, model_name)
      end

      persist_model_selection(prov_str, model_name)

      Logger.info("[Models] Switched (current) to #{prov_str}/#{model_name}")

      context_window =
        try do
          OptimalSystemAgent.Providers.Registry.context_window(model_name)
        rescue
          _ -> nil
        end

      body =
        Jason.encode!(%{
          status: "switched",
          provider: prov_str,
          model: model_name,
          context_window: context_window
        })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    else
      false ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(%{error: "unknown_provider", details: "Provider not registered"})
        )

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(%{
            error: "invalid_request",
            details: "Missing or invalid provider/model fields"
          })
        )
    end
  end

  # ── POST /reload — scheduler reload ───────────────────────────────

  post "/reload" do
    Scheduler.reload_crons()

    body = Jason.encode!(%{status: "reloading", message: "Scheduler reload queued"})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(202, body)
  end

  # ── POST /:trigger_id — webhook trigger ────────────────────────────

  post "/:trigger_id" do
    trigger_id = conn.params["trigger_id"]
    payload = conn.body_params || %{}

    Logger.info("Webhook received for trigger '#{trigger_id}'")

    Scheduler.fire_trigger(trigger_id, payload)

    body =
      Jason.encode!(%{
        status: "accepted",
        trigger_id: trigger_id,
        message: "Trigger queued for execution"
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(202, body)
  end

  match _ do
    json_error(conn, 404, "not_found", "Data endpoint not found")
  end

  # ── Private handlers ────────────────────────────────────────────────

  defp handle_list_models(conn) do
    provider = Application.get_env(:optimal_system_agent, :default_provider, :ollama)

    current_model =
      Application.get_env(:optimal_system_agent, :default_model) ||
        Application.get_env(:optimal_system_agent, :ollama_model, "llama3.2:latest")

    configured_providers = configured_provider_map()
    provider_string = to_string(provider)

    local_ollama_models = list_local_ollama_models(provider_string, current_model)

    catalog_models =
      ModelCatalog.entries()
      |> Enum.map(fn entry ->
        model_entry(entry.provider, entry.name, current_model, provider_string,
          size: entry.size,
          context_window: entry.context_window,
          configured: Map.get(configured_providers, entry.provider, false),
          capabilities: entry.capabilities,
          source: entry.source
        )
      end)

    provider_models =
      list_provider_models(provider_string, current_model, configured_providers)

    all_models =
      (local_ollama_models ++ catalog_models ++ provider_models)
      |> uniq_models()
      |> Enum.sort_by(fn m ->
        {not m.configured, -m.context_window, m.provider, m.name}
      end)

    body =
      Jason.encode!(%{
        models: all_models,
        current: to_string(current_model),
        provider: to_string(provider)
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  defp list_local_ollama_models(provider_string, current_model) do
    case OptimalSystemAgent.Providers.Ollama.list_models() do
      {:ok, models} ->
        Enum.map(models, fn m ->
          model_entry("ollama", m.name, current_model, provider_string,
            size: m.size,
            configured: true,
            capabilities: infer_capabilities(m.name),
            source: "ollama-local"
          )
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp list_provider_models(provider_string, current_model, configured_providers) do
    OptimalSystemAgent.Providers.Registry.list_providers()
    |> Enum.reject(&(&1 in [:mock, :ollama]))
    |> Enum.flat_map(fn provider ->
      case OptimalSystemAgent.Providers.Registry.provider_info(provider) do
        {:ok, info} ->
          Enum.map(info.available_models, fn model_name ->
            model_entry(to_string(provider), model_name, current_model, provider_string,
              configured: Map.get(configured_providers, to_string(provider), false),
              capabilities: infer_capabilities(model_name),
              source: "provider"
            )
          end)

        _ ->
          []
      end
    end)
  rescue
    _ -> []
  end

  defp configured_provider_map do
    OptimalSystemAgent.Providers.Registry.list_providers()
    |> Enum.reject(&(&1 == :mock))
    |> Map.new(fn provider ->
      {to_string(provider), OptimalSystemAgent.Providers.Registry.provider_configured?(provider)}
    end)
  rescue
    _ -> %{"ollama" => true}
  end

  defp model_entry(provider, name, current_model, current_provider, opts) do
    context_window =
      Keyword.get_lazy(opts, :context_window, fn ->
        try do
          OptimalSystemAgent.Providers.Registry.context_window(name)
        rescue
          _ -> 128_000
        end
      end)

    %{
      name: name,
      provider: provider,
      size: Keyword.get(opts, :size, 0),
      active: provider == current_provider and name == current_model,
      context_window: context_window,
      configured: Keyword.get(opts, :configured, false),
      capabilities: Keyword.get(opts, :capabilities, infer_capabilities(name)),
      source: Keyword.get(opts, :source, "provider")
    }
  end

  defp uniq_models(models) do
    models
    |> Enum.reduce(%{}, fn model, acc ->
      key = {model.provider, model.name}

      Map.update(acc, key, model, fn existing ->
        cond do
          model.source == "ollama-local" -> model
          existing.source == "ollama-local" -> existing
          model.configured and not existing.configured -> model
          true -> existing
        end
      end)
    end)
    |> Map.values()
  end

  defp infer_capabilities(model_name) do
    name = String.downcase(model_name)

    [
      if(String.contains?(name, "cloud"), do: "cloud"),
      if(String.contains?(name, "coder") or String.contains?(name, "codex"), do: "coding"),
      if(
        String.contains?(name, "reason") or String.contains?(name, "think") or
          String.contains?(name, "r1") or String.starts_with?(name, "o"),
        do: "reasoning"
      ),
      if(
        String.contains?(name, "vision") or String.contains?(name, "vl") or
          String.contains?(name, "kimi-k2.6"),
        do: "vision"
      ),
      if(
        String.contains?(name, "tool") or String.contains?(name, "qwen") or
          String.contains?(name, "nemotron"),
        do: "tools"
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp handle_analytics(conn) do
    budget =
      try do
        case OptimalSystemAgent.Budget.get_status() do
          {:ok, data} -> data
          data when is_map(data) -> data
          _ -> %{}
        end
      rescue
        _ -> %{}
      end

    learning =
      try do
        unwrap_ok(OptimalSystemAgent.Memory.Learning.metrics())
      rescue
        _ -> %{}
      end

    hooks =
      try do
        unwrap_ok(OptimalSystemAgent.Agent.Hooks.metrics())
      rescue
        _ -> %{}
      end

    compactor =
      try do
        unwrap_ok(OptimalSystemAgent.Agent.Compactor.stats())
      rescue
        _ -> %{}
      end

    live_sessions =
      Registry.select(OptimalSystemAgent.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])

    body =
      Jason.encode!(%{
        sessions: %{active: length(live_sessions)},
        budget: budget,
        learning: learning,
        hooks: hooks,
        compactor: compactor
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  defp handle_machines(conn) do
    active = Machines.active()

    body =
      Jason.encode!(%{
        machines: active,
        count: length(active)
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  defp parse_sort_atom("recency"), do: :recency
  defp parse_sort_atom("importance"), do: :importance
  defp parse_sort_atom(_), do: :relevance

  # Persist provider/model selection to ~/.osa/config.json so it survives restarts.
  # Reads existing config (if any), merges the two keys, and writes back atomically.
  defp persist_model_selection(provider, model) do
    config_path =
      Application.get_env(:optimal_system_agent, :bootstrap_dir, "~/.osa")
      |> Path.expand()
      |> Path.join("config.json")

    existing =
      with true <- File.exists?(config_path),
           {:ok, content} <- File.read(config_path),
           {:ok, parsed} <- Jason.decode(content) do
        parsed
      else
        _ -> %{}
      end

    updated = Map.merge(existing, %{"provider" => provider, "model" => model})

    case Jason.encode(updated, pretty: true) do
      {:ok, json} ->
        File.mkdir_p!(Path.dirname(config_path))
        File.write!(config_path, json)

      {:error, reason} ->
        Logger.warning("[Models] Failed to persist model selection: #{inspect(reason)}")
    end
  rescue
    e -> Logger.warning("[Models] Config persist error: #{Exception.message(e)}")
  end
end
