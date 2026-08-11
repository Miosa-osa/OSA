defmodule OptimalSystemAgent.Channels.HTTP.API.ProviderRoutes do
  @moduledoc """
  LLM provider management routes.

  Forwarded prefix → effective routes:
    /providers  → GET /
                  POST /:slug/connect
                  DELETE /:slug
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  alias OptimalSystemAgent.System.AtomicFile
  alias OptimalSystemAgent.System.JsonStore

  plug(:match)
  plug(:dispatch)

  # ── GET / — list all providers ─────────────────────────────────────

  get "/" do
    stored_keys = read_config() |> Map.get("api_keys", %{})

    providers =
      try do
        OptimalSystemAgent.Providers.Registry.list_providers()
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end
      |> Enum.reject(&(&1 == :mock))
      |> Enum.map(fn provider ->
        slug = to_string(provider)

        info =
          try do
            case OptimalSystemAgent.Providers.Registry.provider_info(provider) do
              {:ok, data} -> data
              _ -> %{}
            end
          rescue
            _ -> %{}
          catch
            :exit, _ -> %{}
          end

        default_model =
          case info do
            %{default_model: m} when is_binary(m) -> m
            _ -> nil
          end

        available_models =
          case info do
            %{available_models: models} when is_list(models) -> models
            _ -> []
          end

        configured = provider_configured(provider, stored_keys)

        %{
          slug: slug,
          name: provider_display_name(slug),
          type: provider_type(provider),
          configured: configured,
          connected: configured,
          default_model: default_model,
          available_models: available_models,
          # Rich per-model metadata (ctx, pricing, tool_call, reasoning) from
          # the models.dev-style catalog, for the TUI model-picker. Empty when
          # the catalog has no entry for this provider (e.g. local Ollama).
          models: catalog_models(provider)
        }
      end)

    json(conn, 200, %{providers: providers})
  end

  # ── POST /key — add/switch a provider key (merges into ~/.osa/.env) ──
  #
  # The single authenticated save path for the in-UI provider/key picker.
  # Unlike /:slug/connect (which wrote a competing, non-persisted config.json),
  # this merges into ~/.osa/.env — the runtime source of truth — so keys
  # accumulate and survive restarts. `provider` is an onboarding catalog id
  # (e.g. "ollama_cloud", "anthropic"), not a runtime provider atom.

  post "/key" do
    known_ids =
      try do
        OptimalSystemAgent.Onboarding.providers_list() |> Enum.map(& &1.id)
      rescue
        _ -> []
      end

    case conn.body_params do
      %{"provider" => provider} = body when is_binary(provider) ->
        if provider not in known_ids do
          json_error(conn, 400, "invalid_provider", "Unknown provider: #{provider}")
        else
          set_active = Map.get(body, "set_active", true)

          upsert = %{
            provider: provider,
            api_key: Map.get(body, "api_key"),
            base_url: Map.get(body, "base_url"),
            model: Map.get(body, "model"),
            set_active: set_active
          }

          case OptimalSystemAgent.Onboarding.upsert_provider_key(upsert) do
            :ok ->
              Logger.info("[Providers] Key upserted for #{provider} (set_active=#{set_active})")
              json(conn, 200, %{status: "ok", provider: provider, model: Map.get(body, "model")})

            {:error, _reason} ->
              json_error(conn, 500, "save_failed", "Could not persist provider key")
          end
        end

      _ ->
        json_error(conn, 400, "invalid_request", "Missing required field: provider")
    end
  end

  # ── POST /:slug/connect — store API key ────────────────────────────

  post "/:slug/connect" do
    slug = conn.params["slug"]

    known_slugs =
      try do
        OptimalSystemAgent.Providers.Registry.list_providers()
        |> Enum.map(&to_string/1)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    cond do
      slug not in known_slugs ->
        json_error(conn, 404, "unknown_provider", "Provider '#{slug}' is not registered")

      true ->
        case conn.body_params do
          %{"api_key" => api_key} when is_binary(api_key) and api_key != "" ->
            # This file holds every provider's key in plaintext. Degrading an
            # unreadable read to `%{}` meant storing one key DESTROYED all the
            # others — and the endpoint still answered
            # `200 {"status":"connected"}`, so the user had no way to know.
            case store_api_key(slug, api_key) do
              {:error, msg} ->
                json_error(conn, 500, "config_unreadable", msg)

              :ok ->
                System.put_env("#{String.upcase(slug)}_API_KEY", api_key)
                Logger.info("[Providers] API key stored for #{slug}")

                # Optional connection test — never fail the request if it errors
                try do
                  provider = String.to_existing_atom(slug)
                  test_messages = [%{role: "user", content: "hi"}]

                  OptimalSystemAgent.Providers.Registry.chat(test_messages,
                    provider: provider,
                    max_tokens: 5
                  )

                  Logger.info("[Providers] Connection verified for #{slug}")
                rescue
                  _ -> :ok
                catch
                  :exit, _ -> :ok
                end

                json(conn, 200, %{status: "connected", provider: slug})
            end

          _ ->
            json_error(conn, 400, "invalid_request", "Missing required field: api_key")
        end
    end
  end

  # ── DELETE /:slug — remove API key ─────────────────────────────────

  delete "/:slug" do
    slug = conn.params["slug"]

    env_var = "#{String.upcase(slug)}_API_KEY"
    System.delete_env(env_var)

    case update_api_keys(&Map.delete(&1, slug)) do
      {:error, msg} ->
        json_error(conn, 500, "config_unreadable", msg)

      :ok ->
        Logger.info("[Providers] API key removed for #{slug}")
        json(conn, 200, %{status: "disconnected", provider: slug})
    end
  end

  match _ do
    json_error(conn, 404, "not_found", "Provider endpoint not found")
  end

  # ── Private helpers ─────────────────────────────────────────────────

  defp config_path do
    Application.get_env(:optimal_system_agent, :bootstrap_dir, "~/.osa")
    |> Path.expand()
    |> Path.join("config.json")
  end

  defp read_config do
    path = config_path()

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, parsed} <- Jason.decode(content) do
      parsed
    else
      _ -> %{}
    end
  end

  defp store_api_key(slug, api_key), do: update_api_keys(&Map.put(&1, slug, api_key))

  # Read-modify-write of the `api_keys` object, refusing on a degraded read.
  @spec update_api_keys((map() -> map())) :: :ok | {:error, String.t()}
  defp update_api_keys(fun) do
    path = config_path()

    with {:ok, config} <- JsonStore.read_map_for_write(path),
         api_keys = Map.get(config, "api_keys", %{}),
         api_keys = if(is_map(api_keys), do: api_keys, else: %{}),
         updated = Map.put(config, "api_keys", fun.(api_keys)),
         {:ok, json} <- Jason.encode(updated, pretty: true) do
      write_config_json(path, json)
    else
      {:error, :corrupt} ->
        msg = JsonStore.corrupt_message("provider API keys", path)
        Logger.error("[Providers] #{msg}")
        {:error, msg}

      {:error, reason} ->
        msg = "Failed to encode provider config: #{inspect(reason)}"
        Logger.warning("[Providers] #{msg}")
        {:error, msg}
    end
  end

  # `config.json` carries every provider's API key in plaintext, so it must
  # never exist at the process umask (0644 on a default Linux install). The
  # mode is applied to AtomicFile's temp file BEFORE the secret is written and
  # the temp file is then renamed into place, so the key is never observable at
  # a permissive mode — as opposed to `File.write!` followed by `File.chmod!`,
  # which leaves a readable window between the two calls.
  defp write_config_json(path, json) do
    File.mkdir_p!(Path.dirname(path))

    case AtomicFile.write(path, json, mode: 0o600) do
      :ok ->
        :ok

      {:error, reason} ->
        msg = "Failed to write #{path}: #{inspect(reason)}"
        Logger.warning("[Providers] #{msg}")
        {:error, msg}
    end
  rescue
    e ->
      msg = "Config write error: #{Exception.message(e)}"
      Logger.warning("[Providers] #{msg}")
      {:error, msg}
  end

  # Detailed model metadata from the catalog for the TUI model-picker.
  defp catalog_models(provider) do
    OptimalSystemAgent.Providers.Catalog.models(provider)
    |> Enum.map(fn m ->
      %{
        id: m.model_id,
        name: m.name,
        context_window: m.ctx,
        max_output: m.max_output,
        tool_call: m.tool_call,
        reasoning: m.reasoning,
        attachment: m.attachment,
        cost: m.cost,
        modalities: m.modalities
      }
    end)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp provider_type(:ollama), do: "local"
  defp provider_type(:lmstudio), do: "local"
  defp provider_type(_), do: "cloud"

  defp provider_display_name(slug) do
    case slug do
      "openai" -> "OpenAI"
      "anthropic" -> "Anthropic"
      "google" -> "Google"
      "groq" -> "Groq"
      "ollama" -> "Ollama"
      "cohere" -> "Cohere"
      "mistral" -> "Mistral"
      "replicate" -> "Replicate"
      "together" -> "Together AI"
      "fireworks" -> "Fireworks AI"
      "deepseek" -> "DeepSeek"
      "perplexity" -> "Perplexity"
      "openrouter" -> "OpenRouter"
      "qwen" -> "Qwen"
      "moonshot" -> "Moonshot"
      "zhipu" -> "Zhipu"
      "volcengine" -> "Volcengine"
      "baichuan" -> "Baichuan"
      other -> String.capitalize(other)
    end
  end

  # Determines whether a provider is configured, preferring the stored key map
  # over env vars. Ollama is always considered configured (local, no API key needed).
  defp provider_configured(:ollama, _stored_keys), do: true
  defp provider_configured(:lmstudio, _stored_keys), do: true

  defp provider_configured(provider, stored_keys) do
    slug = to_string(provider)

    cond do
      Map.get(stored_keys, slug) not in [nil, ""] ->
        true

      System.get_env("#{String.upcase(slug)}_API_KEY") not in [nil, ""] ->
        true

      true ->
        # Fall back to Registry check, which reads Application env
        try do
          OptimalSystemAgent.Providers.Registry.provider_configured?(provider)
        rescue
          _ -> false
        catch
          :exit, _ -> false
        end
    end
  end
end
