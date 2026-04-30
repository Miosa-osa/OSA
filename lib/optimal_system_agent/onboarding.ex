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
    detected =
      [
        detect_key("miosa", "MIOSA_API_KEY"),
        detect_key("anthropic", "ANTHROPIC_API_KEY"),
        detect_key("openai", "OPENAI_API_KEY"),
        detect_key("openrouter", "OPENROUTER_API_KEY"),
        detect_key("ollama_cloud", "OLLAMA_API_KEY"),
        detect_key("groq", "GROQ_API_KEY"),
        detect_key("deepseek", "DEEPSEEK_API_KEY")
      ]
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
        env_var: "OLLAMA_API_KEY",
        default_model: "nemotron-3-super:cloud",
        base_url: "https://ollama.com",
        signup_url: "https://ollama.com/account/keys",
        models: [
          %{
            id: "nemotron-3-super:cloud",
            name: "Nemotron 3 Super",
            ctx: 1_048_576,
            tools: true,
            recommended: true,
            note: "1M ctx, 120B MoE — best agentic"
          },
          %{
            id: "kimi-k2.5:cloud",
            name: "Kimi K2.5",
            ctx: 262_144,
            tools: true,
            note: "multimodal + vision + thinking"
          },
          %{
            id: "qwen3.5:cloud",
            name: "Qwen 3.5",
            ctx: 262_144,
            tools: true,
            note: "multimodal, vision + tools"
          },
          %{
            id: "llama4:cloud",
            name: "Llama 4 Scout",
            ctx: 10_485_760,
            tools: true,
            note: "10M ctx, 109B MoE"
          },
          %{
            id: "glm-5:cloud",
            name: "GLM-5",
            ctx: 262_144,
            tools: true,
            note: "744B MoE — reasoning + agentic"
          },
          %{
            id: "deepseek-r1:cloud",
            name: "DeepSeek R1",
            ctx: 163_840,
            tools: false,
            note: "reasoning only, no tools"
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
        api_key = Keyword.get(opts, :api_key)
        fetch_openai_models("https://optimal.miosa.ai/v1", api_key)

      "custom" ->
        base_url = Keyword.get(opts, :base_url)
        api_key = Keyword.get(opts, :api_key)

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

    # Build .env content
    env_content = build_env_content(provider, model, api_key, base_url)

    # Append channel tokens
    env_content = append_channel_tokens(env_content, channel_tokens)

    # Append identity
    env_content = append_identity(env_content, user_name, agent_name)
    env_path = Path.join(@osa_dir, ".env")

    # Preserve old config as comments if .env already exists
    env_content =
      if File.exists?(env_path) do
        old = File.read!(env_path)
        commented = old |> String.split("\n") |> Enum.map(&"# #{&1}") |> Enum.join("\n")

        """
        # Previous config (#{DateTime.utc_now() |> DateTime.to_iso8601()}):
        #{commented}

        #{env_content}
        """
      else
        env_content
      end

    case File.write(env_path, env_content) do
      :ok ->
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

  # ── Private: .env Generation ──────────────────────────────────────────

  defp build_env_content(provider, model, api_key, base_url) do
    lines = [
      "# OSA Agent Configuration",
      "# Generated by setup wizard — #{DateTime.utc_now() |> DateTime.to_iso8601()}",
      "# Edit freely. Changes take effect on next restart.",
      ""
    ]

    lines =
      case provider do
        "miosa" ->
          lines ++
            [
              "# MIOSA Platform (Optimal)",
              "OSA_DEFAULT_PROVIDER=miosa",
              if(api_key, do: "MIOSA_API_KEY=#{api_key}", else: nil),
              if(model, do: "OSA_MODEL=#{model}", else: "OSA_MODEL=nemotron-3-miosa")
            ]

        "ollama_cloud" ->
          lines ++
            [
              "# Ollama Cloud",
              "OSA_DEFAULT_PROVIDER=ollama",
              "OLLAMA_URL=#{base_url || "https://ollama.com"}",
              if(api_key, do: "OLLAMA_API_KEY=#{api_key}", else: nil),
              if(model, do: "OLLAMA_MODEL=#{model}", else: "OLLAMA_MODEL=nemotron-3-super:cloud")
            ]

        "ollama_local" ->
          lines ++
            [
              "# Ollama Local",
              "OSA_DEFAULT_PROVIDER=ollama",
              "OLLAMA_URL=#{base_url || "http://localhost:11434"}",
              if(model, do: "OLLAMA_MODEL=#{model}", else: nil)
            ]

        "openrouter" ->
          lines ++
            [
              "# OpenRouter",
              "OSA_DEFAULT_PROVIDER=openrouter",
              if(api_key, do: "OPENROUTER_API_KEY=#{api_key}", else: nil),
              if(model, do: "OSA_MODEL=#{model}", else: nil)
            ]

        "anthropic" ->
          lines ++
            [
              "# Anthropic",
              "OSA_DEFAULT_PROVIDER=anthropic",
              if(api_key, do: "ANTHROPIC_API_KEY=#{api_key}", else: nil),
              if(model, do: "OSA_MODEL=#{model}", else: nil)
            ]

        "openai" ->
          lines ++
            [
              "# OpenAI",
              "OSA_DEFAULT_PROVIDER=openai",
              if(api_key, do: "OPENAI_API_KEY=#{api_key}", else: nil),
              if(base_url, do: "OPENAI_BASE_URL=#{base_url}", else: nil),
              if(model, do: "OSA_MODEL=#{model}", else: nil)
            ]

        "custom" ->
          lines ++
            [
              "# Custom Endpoint (OpenAI-compatible)",
              "OSA_DEFAULT_PROVIDER=openai",
              if(api_key, do: "OPENAI_API_KEY=#{api_key}", else: nil),
              if(base_url, do: "OPENAI_BASE_URL=#{base_url}", else: nil),
              if(model, do: "OSA_MODEL=#{model}", else: nil)
            ]

        _ ->
          lines ++ ["OSA_DEFAULT_PROVIDER=#{provider}"]
      end

    lines
    |> Enum.reject(&is_nil/1)
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
        if api_key, do: System.put_env("MIOSA_API_KEY", api_key)
        System.put_env("OSA_DEFAULT_PROVIDER", "miosa")
        Application.put_env(:optimal_system_agent, :miosa_api_key, api_key)
        Application.put_env(:optimal_system_agent, :miosa_url, "https://optimal.miosa.ai/v1")

      "ollama_cloud" ->
        if api_key, do: System.put_env("OLLAMA_API_KEY", api_key)
        url = base_url || "https://ollama.com"
        System.put_env("OLLAMA_URL", url)
        Application.put_env(:optimal_system_agent, :ollama_url, url)
        Application.put_env(:optimal_system_agent, :ollama_api_key, api_key)

      "ollama_local" ->
        url = base_url || "http://localhost:11434"
        System.put_env("OLLAMA_URL", url)
        Application.put_env(:optimal_system_agent, :ollama_url, url)

      "openrouter" ->
        if api_key, do: System.put_env("OPENROUTER_API_KEY", api_key)
        Application.put_env(:optimal_system_agent, :openrouter_api_key, api_key)

      "anthropic" ->
        if api_key, do: System.put_env("ANTHROPIC_API_KEY", api_key)
        Application.put_env(:optimal_system_agent, :anthropic_api_key, api_key)

      "openai" ->
        if api_key, do: System.put_env("OPENAI_API_KEY", api_key)
        Application.put_env(:optimal_system_agent, :openai_api_key, api_key)

      "custom" ->
        if api_key, do: System.put_env("OPENAI_API_KEY", api_key)
        if base_url, do: System.put_env("OPENAI_BASE_URL", base_url)
        Application.put_env(:optimal_system_agent, :openai_api_key, api_key)

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

  defp append_channel_tokens(env_content, tokens) when map_size(tokens) == 0, do: env_content

  defp append_channel_tokens(env_content, tokens) do
    lines =
      tokens
      |> Enum.filter(fn {_k, v} -> is_binary(v) and v != "" end)
      |> Enum.map(fn {channel, token} ->
        env_var = Map.get(@channel_env_map, channel, "#{String.upcase(channel)}_TOKEN")
        "#{env_var}=#{token}"
      end)

    case lines do
      [] ->
        env_content

      lines ->
        env_content <> "\n# Channels\n" <> Enum.join(lines, "\n") <> "\n"
    end
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

  defp append_identity(env_content, nil, nil), do: env_content

  defp append_identity(env_content, user_name, agent_name) do
    lines =
      [
        if(user_name && user_name != "", do: "OSA_USER_NAME=#{user_name}", else: nil),
        if(agent_name && agent_name != "", do: "OSA_AGENT_NAME=#{agent_name}", else: nil)
      ]
      |> Enum.reject(&is_nil/1)

    case lines do
      [] -> env_content
      lines -> env_content <> "\n# Identity\n" <> Enum.join(lines, "\n") <> "\n"
    end
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
