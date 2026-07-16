defmodule OptimalSystemAgent.Onboarding do
  @moduledoc """
  Onboarding — provider detection, workspace seeding, and first-run setup.

  ## Flow

  1. TUI calls `GET /onboarding/status` → `first_run?/0` + `providers_list/0` + `detect_existing/0`
  2. User picks provider, enters key, picks model
  3. TUI calls `POST /onboarding/health-check` → `health_check/1` verifies connection
  4. TUI calls `POST /onboarding/setup` → `write_setup/1` writes .env + seeds workspace
  5. First conversation: agent detects BOOTSTRAP.md, runs identity ritual

  ## Config Path

  Single source of truth: `~/.osa/.env`
  runtime.exs loads it on boot (lines 31-64). No config.exs. No fighting configs.
  """

  require Logger

  @osa_dir Path.join(System.user_home!(), ".osa")

  @workspace_templates ~w(BOOTSTRAP.md IDENTITY.md USER.md SOUL.md HEARTBEAT.md)

  # ── Public API ───────────────────────────────────────────────────────

  @doc "Zero-config: auto-detect a provider. No-op if already configured."
  def auto_configure do
    unless first_run?() do
      :ok
    else
      # Try Ollama auto-detect as a sensible default
      try do
        OptimalSystemAgent.Providers.Ollama.auto_detect_model()
      rescue
        _ -> :ok
      end

      :ok
    end
  end

  @doc "Interactive TUI setup wizard. Currently a no-op — use HTTP onboarding flow."
  def run_setup_mode, do: :ok

  @doc """
  Returns true if no valid provider is configured.

  Checks ~/.osa/.env for a valid OSA_DEFAULT_PROVIDER line AND at least one
  API key or local Ollama. Falls back to checking if any provider API key
  exists in the environment (user may have exported it in .zshrc).
  """
  def first_run? do
    env_file = Path.join(@osa_dir, ".env")

    # Simple: if ~/.osa/.env exists with a valid provider, onboarding is done.
    # Even if the user has API keys in their shell, they still need to go
    # through the wizard once so workspace files get seeded and they confirm
    # their setup. The wizard shows detected keys so they can just confirm.
    not (File.exists?(env_file) and env_has_provider?(env_file))
  end

  @doc "Return system information for the onboarding UI."
  def detect_system do
    %{
      os: :os.type() |> elem(1) |> to_string(),
      arch: :erlang.system_info(:system_architecture) |> to_string(),
      hostname: hostname(),
      shell: System.get_env("SHELL") || "unknown"
    }
  end

  @doc """
  Detect pre-configured providers from environment variables.

  Returns a list of detected providers with key previews, so the TUI
  can show "Anthropic detected ✓" and let the user skip straight to
  model picker.
  """
  @spec detect_existing() :: %{detected: [map()], ollama_local: map()}
  def detect_existing do
    # Derive the env-var scan list from providers_list/0 so every catalog
    # provider can surface a "✓ ready" indicator. De-dupe by env var
    # (openai + custom share OPENAI_API_KEY — first-declared wins).
    detected =
      providers_list()
      |> Enum.map(fn p -> {p.id, Map.get(p, :env_var)} end)
      |> Enum.filter(fn {_id, env_var} -> is_binary(env_var) and env_var != "" end)
      |> Enum.uniq_by(fn {_id, env_var} -> env_var end)
      |> Enum.map(fn {id, env_var} -> detect_key(id, env_var) end)
      |> Enum.reject(&is_nil/1)

    ollama_local = probe_ollama_local()

    %{detected: detected, ollama_local: ollama_local}
  end

  @doc "Return the full provider catalog for the onboarding UI."
  def providers_list do
    [
      %{
        id: "miosa",
        name: "MIOSA",
        description: "Recommended — Optimal agent, fully managed",
        group: "recommended",
        requires_key: true,
        env_var: "MIOSA_API_KEY",
        default_model: "nemotron-3-miosa",
        base_url: "https://optimal.miosa.ai/v1",
        signup_url: "https://miosa.ai/settings/keys",
        models: :dynamic
      },
      %{
        id: "ollama_cloud",
        name: "Ollama Cloud",
        description: "Fast, no GPU needed",
        group: "bring_your_own",
        requires_key: true,
        # Key is optional: a signed-in local Ollama daemon proxies `:cloud`
        # models via device identity (no key). The picker treats this provider
        # as ready when either an OLLAMA_API_KEY exists OR local Ollama is up.
        key_optional: true,
        env_var: "OLLAMA_API_KEY",
        default_model: "glm-5.2:cloud",
        base_url: "https://ollama.com",
        signup_url: "https://ollama.com/account/keys",
        # Current Ollama Cloud catalog (verified live 2026-07). All run with no
        # local GPU/download — Ollama offloads to its cloud. `:cloud` tags require
        # either an Ollama Cloud key or a signed-in device identity.
        models: [
          %{
            id: "glm-5.2:cloud",
            name: "GLM-5.2",
            ctx: 204_800,
            tools: true,
            recommended: true,
            note: "Z.ai flagship — long-horizon agentic + coding"
          },
          %{
            id: "glm-5.1:cloud",
            name: "GLM-5.1",
            ctx: 204_800,
            tools: true,
            note: "agentic, state-of-the-art coding"
          },
          %{
            id: "kimi-k2.7-code:cloud",
            name: "Kimi K2.7 Code",
            ctx: 262_144,
            tools: true,
            note: "Moonshot coding-focused agentic"
          },
          %{
            id: "kimi-k2.6:cloud",
            name: "Kimi K2.6",
            ctx: 262_144,
            tools: true,
            note: "multimodal agentic, long-horizon coding"
          },
          %{
            id: "minimax-m3:cloud",
            name: "MiniMax M3",
            ctx: 1_048_576,
            tools: true,
            note: "1M ctx, native multimodal + agentic"
          },
          %{
            id: "deepseek-v4-pro:cloud",
            name: "DeepSeek V4 Pro",
            ctx: 163_840,
            tools: true,
            note: "frontier MoE, multiple reasoning modes"
          },
          %{
            id: "deepseek-v4-flash:cloud",
            name: "DeepSeek V4 Flash",
            ctx: 163_840,
            tools: true,
            note: "284B MoE / 13B active — fast"
          },
          %{
            id: "gpt-oss:120b-cloud",
            name: "GPT-OSS 120B",
            ctx: 131_072,
            tools: true,
            note: "OpenAI open-weight, strong reasoning"
          },
          %{
            id: "qwen3.5:cloud",
            name: "Qwen 3.5",
            ctx: 262_144,
            tools: true,
            note: "multimodal, vision + tools"
          },
          %{
            id: "gemini-3-flash-preview:cloud",
            name: "Gemini 3 Flash",
            ctx: 1_048_576,
            tools: true,
            note: "frontier intelligence built for speed"
          },
          %{
            id: "nemotron-3-super:cloud",
            name: "Nemotron 3 Super",
            ctx: 1_048_576,
            tools: true,
            note: "1M ctx, 120B MoE — efficient agentic"
          },
          %{
            id: "gemma4:cloud",
            name: "Gemma 4",
            ctx: 131_072,
            tools: true,
            note: "frontier reasoning + multimodal"
          }
        ]
      },
      %{
        id: "ollama_local",
        name: "Ollama Local",
        description: "Privacy-first — runs on your machine",
        group: "bring_your_own",
        requires_key: false,
        env_var: nil,
        default_model: nil,
        base_url: "http://localhost:11434",
        signup_url: "https://ollama.com/download",
        models: :dynamic
      },
      %{
        id: "openrouter",
        name: "OpenRouter",
        description: "One key → 200+ models",
        group: "bring_your_own",
        requires_key: true,
        env_var: "OPENROUTER_API_KEY",
        default_model: "anthropic/claude-sonnet-4-20250514",
        base_url: "https://openrouter.ai/api/v1",
        signup_url: "https://openrouter.ai/keys",
        models: [
          %{
            id: "anthropic/claude-sonnet-4-6",
            name: "Claude Sonnet 4.6",
            ctx: 1_000_000,
            tools: true,
            recommended: true,
            note: "1M ctx — best for coding"
          },
          %{
            id: "anthropic/claude-opus-4-6",
            name: "Claude Opus 4.6",
            ctx: 1_000_000,
            tools: true,
            note: "1M ctx — strongest reasoning"
          },
          %{
            id: "openai/gpt-5.4-pro",
            name: "GPT-5.4 Pro",
            ctx: 1_050_000,
            tools: true,
            note: "1M ctx — latest frontier"
          },
          %{
            id: "google/gemini-2.5-pro",
            name: "Gemini 2.5 Pro",
            ctx: 1_000_000,
            tools: true,
            note: "1M context"
          },
          %{
            id: "meta-llama/llama-4-maverick",
            name: "Llama 4 Maverick",
            ctx: 1_000_000,
            tools: true,
            note: "400B MoE, 1M ctx"
          },
          %{
            id: "deepseek/deepseek-r1",
            name: "DeepSeek R1",
            ctx: 163_840,
            tools: false,
            note: "reasoning only"
          }
        ]
      },
      %{
        id: "anthropic",
        name: "Anthropic",
        description: "Claude direct — best for coding",
        group: "bring_your_own",
        requires_key: true,
        env_var: "ANTHROPIC_API_KEY",
        default_model: "claude-sonnet-4-20250514",
        base_url: "https://api.anthropic.com",
        signup_url: "https://console.anthropic.com/account/keys",
        models: [
          %{
            id: "claude-sonnet-4-6-20260316",
            name: "Claude Sonnet 4.6",
            ctx: 1_000_000,
            tools: true,
            recommended: true,
            note: "1M ctx — best for coding"
          },
          %{
            id: "claude-opus-4-6-20260316",
            name: "Claude Opus 4.6",
            ctx: 1_000_000,
            tools: true,
            note: "1M ctx — strongest reasoning"
          },
          %{
            id: "claude-haiku-4-5-20251001",
            name: "Claude Haiku 4.5",
            ctx: 200_000,
            tools: true,
            note: "fast + cheap"
          }
        ]
      },
      %{
        id: "openai",
        name: "OpenAI",
        description: "GPT direct",
        group: "bring_your_own",
        requires_key: true,
        env_var: "OPENAI_API_KEY",
        default_model: "gpt-4o",
        base_url: "https://api.openai.com/v1",
        signup_url: "https://platform.openai.com/api-keys",
        models: [
          %{
            id: "gpt-5.4-pro",
            name: "GPT-5.4 Pro",
            ctx: 1_050_000,
            tools: true,
            recommended: true,
            note: "1M ctx — latest frontier"
          },
          %{
            id: "gpt-5.2-pro",
            name: "GPT-5.2 Pro",
            ctx: 400_000,
            tools: true,
            note: "400K ctx — agentic coding"
          },
          %{
            id: "gpt-5.2-chat",
            name: "GPT-5.2 Chat",
            ctx: 128_000,
            tools: true,
            note: "fast + low latency"
          },
          %{id: "o3", name: "o3", ctx: 200_000, tools: true, note: "strongest reasoning"}
        ]
      },
      %{
        id: "custom",
        name: "Custom Endpoint",
        description: "Any OpenAI-compatible URL",
        group: "bring_your_own",
        requires_key: :optional,
        env_var: "OPENAI_API_KEY",
        default_model: nil,
        base_url: nil,
        signup_url: nil,
        models: :manual
      }
    ]
  end

  @doc """
  Fetch available models for a provider.

  For Ollama Local: queries GET /api/tags on the Ollama server.
  For MIOSA: queries GET /v1/models on optimal.miosa.ai.
  For Custom: tries GET /v1/models on the provided base_url.
  For others: returns the hardcoded catalog from providers_list.
  """
  @spec model_list(String.t(), keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def model_list(provider_id, opts \\ []) do
    case provider_id do
      "ollama_local" ->
        url = Keyword.get(opts, :base_url, "http://localhost:11434")
        fetch_ollama_models(url)

      "miosa" ->
        # Fall back to the configured key so an already-connected MIOSA
        # provider can list its models without re-supplying the key.
        api_key = Keyword.get(opts, :api_key) || System.get_env("MIOSA_API_KEY")
        fetch_openai_models("https://optimal.miosa.ai/v1", api_key)

      "custom" ->
        base_url = Keyword.get(opts, :base_url)
        api_key = Keyword.get(opts, :api_key) || System.get_env("OPENAI_API_KEY")

        if base_url do
          fetch_openai_models(base_url, api_key)
        else
          {:ok, []}
        end

      _ ->
        # Return hardcoded catalog
        provider = Enum.find(providers_list(), &(&1.id == provider_id))

        case provider do
          %{models: models} when is_list(models) -> {:ok, models}
          _ -> {:ok, []}
        end
    end
  end

  @doc """
  Verify connection to a provider by sending a minimal test request.

  Returns {:ok, result_map} on success or {:error, error_map} on failure.
  """
  @spec health_check(map()) :: {:ok, map()} | {:error, map()}
  def health_check(params) do
    provider = Map.get(params, "provider", "ollama")
    api_key = Map.get(params, "api_key")
    model = Map.get(params, "model")
    base_url = Map.get(params, "base_url")

    {url, headers, body} = build_health_check_request(provider, api_key, model, base_url)

    start_time = System.monotonic_time(:millisecond)

    case Req.post(url,
           headers: headers,
           json: body,
           receive_timeout: 15_000,
           retry: :transient,
           max_retries: 2
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        latency = System.monotonic_time(:millisecond) - start_time
        {:ok, %{status: "ok", latency_ms: latency, model: model, response_status: status}}

      {:ok, %{status: 401}} ->
        {:error, %{error: "unauthorized", message: "API key is invalid or expired."}}

      {:ok, %{status: 402}} ->
        {:error,
         %{error: "insufficient_credits", message: "Insufficient credits on this account."}}

      {:ok, %{status: 403}} ->
        {:error, %{error: "forbidden", message: "Access denied. Check your API key permissions."}}

      {:ok, %{status: 404}} ->
        {:error, %{error: "model_not_found", message: "Model '#{model}' not found."}}

      {:ok, %{status: 429}} ->
        # Rate limited but key works
        latency = System.monotonic_time(:millisecond) - start_time
        {:ok, %{status: "ok", latency_ms: latency, model: model, warning: "rate_limited"}}

      {:ok, %{status: status, body: resp_body}} ->
        msg = extract_error_message(resp_body) || "Server returned #{status}"
        {:error, %{error: "server_error", message: msg, status: status}}

      {:error, %Req.TransportError{reason: :econnrefused}} ->
        {:error, %{error: "connection_refused", message: "Can't reach #{url}. Check the URL."}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, %{error: "timeout", message: "Connection timed out after 15 seconds."}}

      {:error, reason} ->
        {:error, %{error: "connection_failed", message: "Connection failed: #{inspect(reason)}"}}
    end
  rescue
    e ->
      {:error, %{error: "exception", message: Exception.message(e)}}
  end

  @doc """
  Write setup configuration and seed workspace.

  1. Writes ~/.osa/.env with provider config
  2. Sets env vars in-process (takes effect immediately, no restart)
  3. Seeds workspace templates (BOOTSTRAP.md, IDENTITY.md, USER.md, SOUL.md, HEARTBEAT.md)
  4. Reloads Soul cache
  """
  @spec write_setup(map()) :: :ok | {:error, String.t()}
  def write_setup(%{} = params) do
    File.mkdir_p!(@osa_dir)

    provider = Map.get(params, :provider) || Map.get(params, "provider", "ollama")
    model = Map.get(params, :model) || Map.get(params, "model")
    api_key = Map.get(params, :api_key) || Map.get(params, "api_key")
    base_url = Map.get(params, :base_url) || Map.get(params, "base_url")
    channel_tokens = Map.get(params, :channel_tokens) || Map.get(params, "channel_tokens") || %{}

    user_name = Map.get(params, :user_name) || Map.get(params, "user_name")
    agent_name = Map.get(params, :agent_name) || Map.get(params, "agent_name")

    env_path = Path.join(@osa_dir, ".env")

    # MERGE, don't clobber. Parse the existing .env, overlay the selected
    # provider's canonical vars (preserving every other provider's *_API_KEY),
    # fold in channel tokens + identity, and serialize each var exactly once.
    # This is the fix for keys being lost when switching the active provider.
    merged =
      env_path
      |> parse_env_file()
      |> merge_env(provider_env_pairs(provider, model, api_key, base_url))
      |> merge_env({channel_token_pairs(channel_tokens), []})
      |> merge_env({identity_pairs(user_name, agent_name), []})

    env_content = serialize_env(merged)

    case File.write(env_path, env_content) do
      :ok ->
        # Lock down permissions — the file holds API keys.
        _ = File.chmod(env_path, 0o600)

        # Apply env vars in-process so they take effect immediately
        apply_env_vars(provider, model, api_key, base_url)
        apply_channel_tokens(channel_tokens)

        # Set identity env vars in-process
        if user_name, do: System.put_env("OSA_USER_NAME", user_name)
        if agent_name, do: System.put_env("OSA_AGENT_NAME", agent_name)

        # Auto-enable computer_use on Linux X11
        enable_computer_use_if_linux(env_path)

        # Seed workspace templates (only files that don't exist)
        seed_workspace()

        # Pre-populate identity into workspace files
        prepopulate_user_md(user_name)
        prepopulate_identity_md(agent_name)

        # Reload Soul to pick up new files
        try do
          OptimalSystemAgent.Soul.reload()
        rescue
          _ -> :ok
        end

        Logger.info("[Onboarding] Setup complete: provider=#{provider} model=#{model}")
        :ok

      {:error, reason} ->
        {:error, "Failed to write .env: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  Add or switch a provider's API key, MERGING into ~/.osa/.env.

  Used by the authenticated `POST /api/v1/providers/key` endpoint (the in-UI
  key screen). Unlike `write_setup/1` it does not touch the workspace or
  identity — it only persists the key + (optionally) flips the active provider.

  `params` keys (string or atom): `provider`, `api_key`, `base_url`, `model`,
  `set_active` (default true).

  When `set_active` is true the active provider + model flip and other
  providers' keys are preserved. When false only the key var is written, so a
  user can stash a key without leaving their current provider.
  """
  @spec upsert_provider_key(map()) :: :ok | {:error, String.t()}
  def upsert_provider_key(%{} = params) do
    File.mkdir_p!(@osa_dir)

    provider = Map.get(params, :provider) || Map.get(params, "provider")
    api_key = Map.get(params, :api_key) || Map.get(params, "api_key")
    base_url = Map.get(params, :base_url) || Map.get(params, "base_url")
    model = Map.get(params, :model) || Map.get(params, "model")
    set_active = Map.get(params, :set_active, Map.get(params, "set_active", true))

    env_path = Path.join(@osa_dir, ".env")
    existing = parse_env_file(env_path)

    merged =
      if set_active do
        merge_env(existing, provider_env_pairs(provider, model, api_key, base_url))
      else
        env_var = provider_env_var(provider)
        pairs = [maybe_pair(env_var, api_key)] |> Enum.reject(&is_nil/1)
        merge_env(existing, {pairs, []})
      end

    case File.write(env_path, serialize_env(merged)) do
      :ok ->
        _ = File.chmod(env_path, 0o600)

        if set_active do
          apply_env_vars(provider, model, api_key, base_url)
        else
          apply_provider_key(provider, api_key)
        end

        Logger.info(
          "[Onboarding] Provider key upserted: provider=#{provider} set_active=#{set_active}"
        )

        :ok

      {:error, reason} ->
        {:error, "Failed to write .env: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  Apply a provider's API key to the running node WITHOUT changing the active
  provider — sets both the OS env var and the Application config atom so the
  next request picks it up live (no restart).
  """
  @spec apply_provider_key(String.t(), String.t() | nil) :: :ok
  def apply_provider_key(provider_id, api_key) do
    env_var = provider_env_var(provider_id)
    app_key = provider_app_key(provider_id)

    if is_binary(env_var) and api_key not in [nil, ""] do
      System.put_env(env_var, api_key)
    end

    if not is_nil(app_key) and api_key not in [nil, ""] do
      Application.put_env(:optimal_system_agent, app_key, api_key)
    end

    :ok
  end

  @doc "Look up a provider's API-key env var name from the catalog."
  @spec provider_env_var(String.t()) :: String.t() | nil
  def provider_env_var(provider_id) do
    case Enum.find(providers_list(), &(&1.id == provider_id)) do
      %{env_var: env_var} when is_binary(env_var) -> env_var
      _ -> nil
    end
  end

  # Maps a catalog provider id to its Application config key for the API key.
  defp provider_app_key(provider_id) do
    case provider_id do
      "miosa" -> :miosa_api_key
      "ollama_cloud" -> :ollama_api_key
      "openrouter" -> :openrouter_api_key
      "anthropic" -> :anthropic_api_key
      "openai" -> :openai_api_key
      "custom" -> :openai_api_key
      _ -> nil
    end
  end

  @doc """
  Seed workspace templates from priv/prompts/ to ~/.osa/.

  Only copies files that don't already exist — never overwrites user data.
  """
  def seed_workspace do
    File.mkdir_p!(@osa_dir)
    priv_dir = :code.priv_dir(:optimal_system_agent) |> to_string()
    prompts_dir = Path.join(priv_dir, "prompts")

    Enum.each(@workspace_templates, fn filename ->
      source = Path.join(prompts_dir, filename)
      dest = Path.join(@osa_dir, filename)

      if File.exists?(source) and not File.exists?(dest) do
        File.cp!(source, dest)
        Logger.debug("[Onboarding] Seeded #{filename} → #{dest}")
      end
    end)
  end

  @doc "Run post-setup health checks."
  def doctor_checks do
    checks = []

    # Check .env exists
    env_path = Path.join(@osa_dir, ".env")

    checks =
      if File.exists?(env_path) do
        [{:ok, ".env file exists"} | checks]
      else
        [{:error, ".env file missing", "Run /setup to configure"} | checks]
      end

    # Check workspace files
    missing =
      @workspace_templates
      |> Enum.reject(&File.exists?(Path.join(@osa_dir, &1)))

    checks =
      if missing == [] do
        [{:ok, "All workspace templates seeded"} | checks]
      else
        [{:error, "Missing workspace files", Enum.join(missing, ", ")} | checks]
      end

    Enum.reverse(checks)
  end

  # ── Selector (used by plan_review.ex) ────────────────────────────────

  defmodule Selector do
    @moduledoc """
    Simple arrow-key selector for CLI menus. Falls back to
    numeric input when the terminal does not support raw mode.
    """

    @spec select([{:option, String.t(), term()} | {:input, String.t(), String.t()}]) ::
            {:selected, term()} | {:input, String.t()} | nil
    def select(lines) when is_list(lines) do
      IO.puts("")

      lines
      |> Enum.with_index(1)
      |> Enum.each(fn
        {{:option, label, _value}, idx} ->
          IO.puts("  #{idx}. #{label}")

        {{:input, label, _prompt}, idx} ->
          IO.puts("  #{idx}. #{label}")
      end)

      IO.puts("")
      raw = IO.gets("  Choice [1]: ") |> to_string() |> String.trim()
      choice = if raw == "", do: "1", else: raw

      case Integer.parse(choice) do
        {n, ""} when n >= 1 and n <= length(lines) ->
          case Enum.at(lines, n - 1) do
            {:option, _label, value} ->
              {:selected, value}

            {:input, _label, prompt} ->
              text = IO.gets("  #{prompt} ") |> to_string() |> String.trim()
              {:input, text}
          end

        _ ->
          nil
      end
    end
  end

  # ── Private: .env Merge / Serialize ───────────────────────────────────

  # Parse an existing .env into an ordered [{key, value}] list. Skips blank
  # lines and comments. First occurrence of a key wins (mirrors the runtime.exs
  # loader, which only sets a var when it isn't already present).
  defp parse_env_file(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.reduce([], fn line, acc ->
          trimmed = String.trim(line)

          cond do
            trimmed == "" ->
              acc

            String.starts_with?(trimmed, "#") ->
              acc

            true ->
              case String.split(trimmed, "=", parts: 2) do
                [k, v] ->
                  k = String.trim(k)
                  v = v |> String.trim() |> String.trim("\"") |> String.trim("'")

                  if k != "" and not List.keymember?(acc, k, 0) do
                    acc ++ [{k, v}]
                  else
                    acc
                  end

                _ ->
                  acc
              end
          end
        end)

      _ ->
        []
    end
  end

  # Canonical KV set for a provider selection, plus the list of keys to DELETE
  # (used to clear the opposite active-model override so it can't pin the wrong
  # model — e.g. a stale OSA_MODEL overriding OLLAMA_MODEL). Nil pairs (no key /
  # no model supplied) are dropped by merge_env so existing values survive.
  defp provider_env_pairs(provider, model, api_key, base_url) do
    case provider do
      "miosa" ->
        {[
           {"OSA_DEFAULT_PROVIDER", "miosa"},
           maybe_pair("MIOSA_API_KEY", api_key),
           {"OSA_MODEL", model || "nemotron-3-miosa"}
         ], ["OLLAMA_MODEL"]}

      p when p in ["ollama_cloud", "ollama_local", "ollama"] ->
        default_url =
          if p == "ollama_local", do: "http://localhost:11434", else: "https://ollama.com"

        url = base_url || default_url

        # OLLAMA_URL is the authoritative switch (localhost = key-free device
        # identity; ollama.com = keyed). Always rewritten. OLLAMA_API_KEY only
        # written when a key was actually entered — never nil'd out.
        {[
           {"OSA_DEFAULT_PROVIDER", "ollama"},
           {"OLLAMA_URL", url},
           maybe_pair("OLLAMA_API_KEY", api_key),
           maybe_pair("OLLAMA_MODEL", model)
         ], ["OSA_MODEL"]}

      "openrouter" ->
        {[
           {"OSA_DEFAULT_PROVIDER", "openrouter"},
           maybe_pair("OPENROUTER_API_KEY", api_key),
           maybe_pair("OSA_MODEL", model)
         ], []}

      "anthropic" ->
        {[
           {"OSA_DEFAULT_PROVIDER", "anthropic"},
           maybe_pair("ANTHROPIC_API_KEY", api_key),
           maybe_pair("OSA_MODEL", model)
         ], []}

      "openai" ->
        {[
           {"OSA_DEFAULT_PROVIDER", "openai"},
           maybe_pair("OPENAI_API_KEY", api_key),
           maybe_pair("OPENAI_BASE_URL", base_url),
           maybe_pair("OSA_MODEL", model)
         ], []}

      "custom" ->
        {[
           {"OSA_DEFAULT_PROVIDER", "openai"},
           maybe_pair("OPENAI_API_KEY", api_key),
           maybe_pair("OPENAI_BASE_URL", base_url),
           maybe_pair("OSA_MODEL", model)
         ], []}

      other ->
        {[{"OSA_DEFAULT_PROVIDER", other}, maybe_pair("OSA_MODEL", model)], []}
    end
  end

  defp maybe_pair(_k, nil), do: nil
  defp maybe_pair(_k, ""), do: nil
  defp maybe_pair(k, v), do: {k, v}

  # Overlay incoming pairs onto the existing set: delete the specified keys,
  # then upsert each non-nil incoming pair in place (preserving order). Never
  # drops other providers' keys — that is the whole point of the merge.
  defp merge_env(existing, {incoming, delete_keys}) do
    incoming = Enum.reject(incoming, &is_nil/1)
    base = Enum.reject(existing, fn {k, _v} -> k in delete_keys end)

    Enum.reduce(incoming, base, fn {k, v}, acc ->
      if List.keymember?(acc, k, 0) do
        List.keyreplace(acc, k, 0, {k, v})
      else
        acc ++ [{k, v}]
      end
    end)
  end

  # Emit each var exactly once (no duplicates, no commented-out keys), so the
  # first-occurrence-wins loader always reads the intended value.
  defp serialize_env(pairs) do
    header = [
      "# OSA Agent Configuration",
      "# Generated by setup — #{DateTime.utc_now() |> DateTime.to_iso8601()}",
      "# Keys accumulate; switching provider preserves other providers' keys.",
      ""
    ]

    body = Enum.map(pairs, fn {k, v} -> "#{k}=#{v}" end)

    (header ++ body)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp apply_env_vars(provider, model, api_key, base_url) do
    # Map provider to the runtime.exs provider atom
    provider_atom =
      case provider do
        "miosa" -> :miosa
        "ollama_cloud" -> :ollama
        "ollama_local" -> :ollama
        "custom" -> :openai
        p -> String.to_atom(p)
      end

    Application.put_env(:optimal_system_agent, :default_provider, provider_atom)

    if model do
      Application.put_env(:optimal_system_agent, :default_model, model)
    end

    # Set the appropriate env var so runtime.exs picks it up on next boot
    case provider do
      "miosa" ->
        # Guard every key write: a nil api_key means "switch model only" and
        # must never clobber the already-configured key held in app config.
        if api_key do
          System.put_env("MIOSA_API_KEY", api_key)
          Application.put_env(:optimal_system_agent, :miosa_api_key, api_key)
        end

        System.put_env("OSA_DEFAULT_PROVIDER", "miosa")
        Application.put_env(:optimal_system_agent, :miosa_url, "https://optimal.miosa.ai/v1")

      "ollama_cloud" ->
        # Only set the key when one was entered — the key-free device-identity
        # path must never clobber a previously stored OLLAMA_API_KEY.
        if api_key do
          System.put_env("OLLAMA_API_KEY", api_key)
          Application.put_env(:optimal_system_agent, :ollama_api_key, api_key)
        end

        url = base_url || "https://ollama.com"
        System.put_env("OLLAMA_URL", url)
        Application.put_env(:optimal_system_agent, :ollama_url, url)

        if model do
          System.put_env("OLLAMA_MODEL", model)
          Application.put_env(:optimal_system_agent, :ollama_model, model)
        end

      "ollama_local" ->
        url = base_url || "http://localhost:11434"
        System.put_env("OLLAMA_URL", url)
        Application.put_env(:optimal_system_agent, :ollama_url, url)

        if model do
          System.put_env("OLLAMA_MODEL", model)
          Application.put_env(:optimal_system_agent, :ollama_model, model)
        end

      "openrouter" ->
        if api_key do
          System.put_env("OPENROUTER_API_KEY", api_key)
          Application.put_env(:optimal_system_agent, :openrouter_api_key, api_key)
        end

      "anthropic" ->
        if api_key do
          System.put_env("ANTHROPIC_API_KEY", api_key)
          Application.put_env(:optimal_system_agent, :anthropic_api_key, api_key)
        end

      "openai" ->
        if api_key do
          System.put_env("OPENAI_API_KEY", api_key)
          Application.put_env(:optimal_system_agent, :openai_api_key, api_key)
        end

      "custom" ->
        if api_key do
          System.put_env("OPENAI_API_KEY", api_key)
          Application.put_env(:optimal_system_agent, :openai_api_key, api_key)
        end

        if base_url, do: System.put_env("OPENAI_BASE_URL", base_url)

      _ ->
        :ok
    end
  end

  # ── Private: Channel Token Handling ───────────────────────────────────

  @channel_env_map %{
    "telegram" => "TELEGRAM_BOT_TOKEN",
    "discord" => "DISCORD_BOT_TOKEN",
    "slack" => "SLACK_BOT_TOKEN"
  }

  defp channel_token_pairs(tokens) when map_size(tokens) == 0, do: []

  defp channel_token_pairs(tokens) do
    tokens
    |> Enum.filter(fn {_k, v} -> is_binary(v) and v != "" end)
    |> Enum.map(fn {channel, token} ->
      env_var = Map.get(@channel_env_map, channel, "#{String.upcase(channel)}_TOKEN")
      {env_var, token}
    end)
  end

  defp apply_channel_tokens(tokens) when map_size(tokens) == 0, do: :ok

  defp apply_channel_tokens(tokens) do
    Enum.each(tokens, fn {channel, token} ->
      if is_binary(token) and token != "" do
        env_var = Map.get(@channel_env_map, channel, "#{String.upcase(channel)}_TOKEN")
        System.put_env(env_var, token)

        app_key =
          case channel do
            "telegram" -> :telegram_bot_token
            "discord" -> :discord_bot_token
            "slack" -> :slack_bot_token
            _ -> String.to_atom("#{channel}_token")
          end

        Application.put_env(:optimal_system_agent, app_key, token)
        Logger.info("[Onboarding] Channel #{channel} token configured")
      end
    end)

    # Try to start newly configured channel adapters
    try do
      OptimalSystemAgent.Channels.Manager.start_configured_channels()
    rescue
      _ -> :ok
    end
  end

  # ── Private: Computer Use Auto-Enable ────────────────────────────────

  defp enable_computer_use_if_linux(env_path) do
    case :os.type() do
      {:unix, :linux} ->
        # Check for X11 display
        if System.get_env("DISPLAY") do
          # Append to .env if not already there
          existing = File.read!(env_path)

          unless String.contains?(existing, "OSA_COMPUTER_USE") do
            File.write!(
              env_path,
              existing <> "\n# Computer Use (auto-detected Linux X11)\nOSA_COMPUTER_USE=true\n"
            )

            System.put_env("OSA_COMPUTER_USE", "true")
            Application.put_env(:optimal_system_agent, :computer_use_enabled, true)
            Logger.info("[Onboarding] Auto-enabled computer_use (Linux X11 detected)")
          end
        end

      _ ->
        :ok
    end
  end

  # ── Private: Identity Handling ────────────────────────────────────────

  defp identity_pairs(user_name, agent_name) do
    [
      maybe_pair("OSA_USER_NAME", user_name),
      maybe_pair("OSA_AGENT_NAME", agent_name)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp prepopulate_user_md(nil), do: :ok
  defp prepopulate_user_md(""), do: :ok

  defp prepopulate_user_md(name) do
    path = Path.join(@osa_dir, "USER.md")

    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          updated =
            content
            |> String.replace("- **Name:**\n", "- **Name:** #{name}\n", global: false)
            |> String.replace("- **What to call them:**\n", "- **What to call them:** #{name}\n",
              global: false
            )

          if updated != content do
            File.write!(path, updated)
            Logger.debug("[Onboarding] Pre-populated USER.md with name: #{name}")
          end

        _ ->
          :ok
      end
    end
  end

  defp prepopulate_identity_md(nil), do: :ok
  defp prepopulate_identity_md(""), do: :ok

  defp prepopulate_identity_md(agent_name) do
    path = Path.join(@osa_dir, "IDENTITY.md")

    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          updated =
            String.replace(content, "- **Name:** OSA\n", "- **Name:** #{agent_name}\n",
              global: false
            )

          if updated != content do
            File.write!(path, updated)
            Logger.debug("[Onboarding] Pre-populated IDENTITY.md with agent name: #{agent_name}")
          end

        _ ->
          :ok
      end
    end
  end

  # ── Private: Health Check Request Building ───────────────────────────

  defp build_health_check_request(provider, api_key, model, base_url) do
    case provider do
      "anthropic" ->
        url = "https://api.anthropic.com/v1/messages"

        headers = [
          {"x-api-key", api_key || ""},
          {"anthropic-version", "2023-06-01"},
          {"content-type", "application/json"}
        ]

        body = %{
          model: model || "claude-sonnet-4-20250514",
          max_tokens: 5,
          messages: [%{role: "user", content: "hi"}]
        }

        {url, headers, body}

      "ollama_local" ->
        url = "#{base_url || "http://localhost:11434"}/api/chat"
        headers = [{"content-type", "application/json"}]

        body = %{
          model: model || "llama3.2",
          messages: [%{role: "user", content: "hi"}],
          stream: false,
          options: %{num_predict: 5}
        }

        {url, headers, body}

      "ollama_cloud" ->
        url = "#{base_url || "https://ollama.com"}/api/chat"

        headers = [
          {"content-type", "application/json"},
          {"authorization", "Bearer #{api_key || ""}"}
        ]

        body = %{
          model: model || "nemotron-3-super:cloud",
          messages: [%{role: "user", content: "hi"}],
          stream: false,
          options: %{num_predict: 5}
        }

        {url, headers, body}

      _ ->
        # OpenAI-compatible (miosa, openrouter, openai, custom, etc.)
        resolved_url =
          case provider do
            "miosa" -> "https://optimal.miosa.ai/v1/chat/completions"
            "openrouter" -> "https://openrouter.ai/api/v1/chat/completions"
            "openai" -> "#{base_url || "https://api.openai.com/v1"}/chat/completions"
            "custom" -> "#{base_url}/chat/completions"
            _ -> "#{base_url || "https://api.openai.com/v1"}/chat/completions"
          end

        headers = [
          {"authorization", "Bearer #{api_key || ""}"},
          {"content-type", "application/json"}
        ]

        body = %{
          model: model || "gpt-4o",
          max_tokens: 5,
          messages: [%{role: "user", content: "hi"}]
        }

        {resolved_url, headers, body}
    end
  end

  defp extract_error_message(%{"error" => %{"message" => msg}}) when is_binary(msg), do: msg
  defp extract_error_message(%{"error" => msg}) when is_binary(msg), do: msg
  defp extract_error_message(%{"message" => msg}) when is_binary(msg), do: msg
  defp extract_error_message(_), do: nil

  # ── Private: Model Fetching ──────────────────────────────────────────

  defp fetch_ollama_models(url) do
    case Req.get("#{url}/api/tags", receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"models" => models}}} when is_list(models) ->
        parsed =
          Enum.map(models, fn m ->
            name = m["name"] || m["model"] || "unknown"
            size = m["size"] || 0
            params = parse_param_count(m["details"])

            %{
              id: name,
              name: name,
              ctx: 0,
              tools: true,
              size_bytes: size,
              params: params
            }
          end)

        {:ok, parsed}

      {:ok, %{status: status}} ->
        {:error, "Ollama returned #{status}"}

      {:error, reason} ->
        {:error, "Can't reach Ollama at #{url}: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "Ollama fetch failed: #{Exception.message(e)}"}
  end

  defp fetch_openai_models(base_url, api_key) do
    headers =
      if api_key do
        [{"authorization", "Bearer #{api_key}"}]
      else
        []
      end

    case Req.get("#{base_url}/models", headers: headers, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"data" => models}}} when is_list(models) ->
        parsed =
          Enum.map(models, fn m ->
            %{
              id: m["id"] || "unknown",
              name: m["id"] || "unknown",
              ctx: m["context_window"] || 0,
              tools: true,
              owned_by: m["owned_by"]
            }
          end)

        {:ok, parsed}

      {:ok, %{status: status}} ->
        {:error, "Server returned #{status}"}

      {:error, reason} ->
        {:error, "Can't reach #{base_url}: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "Model fetch failed: #{Exception.message(e)}"}
  end

  defp parse_param_count(%{"parameter_size" => size}) when is_binary(size), do: size
  defp parse_param_count(_), do: nil

  # ── Private: Detection Helpers ───────────────────────────────────────

  defp detect_key(provider_id, env_var) do
    case System.get_env(env_var) do
      nil -> nil
      "" -> nil
      key -> %{provider: provider_id, source: "environment", key_preview: key_preview(key)}
    end
  end

  defp key_preview(key) when byte_size(key) <= 8 do
    String.slice(key, 0, 2) <> "..." <> String.slice(key, -2, 2)
  end

  defp key_preview(key) do
    String.slice(key, 0, 4) <> "..." <> String.slice(key, -4, 4)
  end

  defp probe_ollama_local do
    url =
      Application.get_env(:optimal_system_agent, :ollama_url, "http://localhost:11434")

    # Only probe if URL looks local
    uri = URI.parse(url)
    host = uri.host || "localhost"

    if host in ["localhost", "127.0.0.1", "::1"] do
      case Req.get("#{url}/api/tags", receive_timeout: 3_000) do
        {:ok, %{status: 200, body: %{"models" => models}}} ->
          %{reachable: true, url: url, model_count: length(models)}

        _ ->
          %{reachable: false, url: url, model_count: 0}
      end
    else
      %{reachable: false, url: url, model_count: 0}
    end
  rescue
    _ -> %{reachable: false, url: "http://localhost:11434", model_count: 0}
  end

  defp env_has_provider?(env_path) do
    case File.read(env_path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.any?(fn line ->
          line = String.trim(line)
          not String.starts_with?(line, "#") and String.contains?(line, "OSA_DEFAULT_PROVIDER=")
        end)

      {:error, _} ->
        false
    end
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> "unknown"
    end
  end
end
