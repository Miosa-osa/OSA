defmodule OptimalSystemAgent.CLI.Setup do
  @moduledoc """
  Interactive CLI setup wizard for first-run onboarding.

  Guides the user through:
  1. Provider selection (Anthropic, OpenAI, Ollama, etc.)
  2. API key input (or OAuth for Anthropic)
  3. Model selection
  4. Optional channel setup (WhatsApp, Telegram, etc.)

  Uses @clack-style prompts from CLI.Prompt.
  """

  alias OptimalSystemAgent.CLI.Prompt
  alias OptimalSystemAgent.Onboarding

  @osa_dir Path.join(System.user_home!(), ".osa")

  @providers [
    %{value: :ollama, label: "Ollama (Local)", hint: "Free, runs on your machine"},
    %{value: :anthropic, label: "Anthropic", hint: "Claude models"},
    %{value: :openai, label: "OpenAI", hint: "GPT models"},
    %{value: :groq, label: "Groq", hint: "Fast inference"},
    %{value: :openrouter, label: "OpenRouter", hint: "Multi-model gateway"},
    %{value: :deepseek, label: "DeepSeek", hint: "DeepSeek models"},
  ]

  @channels [
    %{value: :skip, label: "Skip for now", hint: "Set up channels later with /channels"},
    %{value: :telegram, label: "Telegram", hint: "Bot token from @BotFather"},
    %{value: :discord, label: "Discord", hint: "Bot token from Discord Developer Portal"},
    %{value: :slack, label: "Slack", hint: "Bot token + signing secret"},
    %{value: :whatsapp, label: "WhatsApp", hint: "Uses Baileys bridge (Node.js)"},
    %{value: :matrix, label: "Matrix", hint: "Homeserver + access token"},
    %{value: :email, label: "Email", hint: "IMAP/SMTP credentials"},
  ]

  @doc """
  Run the interactive setup wizard.
  Returns :ok on completion, :skip if cancelled.
  """
  def run do
    Prompt.intro("OSA Setup")

    # Step 1: Provider
    provider = Prompt.select("Choose your AI provider", @providers)

    if is_nil(provider) do
      Prompt.outro("Setup cancelled")
      :skip
    else
      # Step 2: Auth
      api_key = get_auth(provider)

      if is_nil(api_key) and provider != :ollama do
        Prompt.outro("Setup cancelled")
        :skip
      else
        # Step 3: Validate connection
        validate_provider(provider, api_key)

        # Step 4: Channel setup (optional)
        channel = Prompt.select("Connect a messaging channel?", @channels)
        if channel && channel != :skip do
          setup_channel(channel)
        end

        # Step 5: Write config
        write_config(provider, api_key)

        Prompt.outro("Setup complete — start chatting!")
        :ok
      end
    end
  end

  @doc "Check if setup is needed and run it if so."
  def maybe_run do
    if Onboarding.first_run?() do
      run()
    else
      :ok
    end
  end

  # ── Provider Auth ────────────────────────────────────────────────

  defp get_auth(:ollama) do
    Prompt.note("Ollama runs locally — no API key needed.", "Local Provider")

    # Check if Ollama is running
    case Req.get("http://localhost:11434/api/tags", receive_timeout: 3_000) do
      {:ok, %{status: 200}} ->
        Prompt.completed("Ollama", "Detected at localhost:11434")

      _ ->
        IO.puts("\e[33m  ⚠ Ollama not detected. Install from https://ollama.com\e[0m")
    end

    nil
  end

  defp get_auth(:anthropic) do
    method = Prompt.select("How do you want to connect?", [
      %{value: :oauth, label: "Sign in with Anthropic", hint: "Opens browser, uses your account"},
      %{value: :api_key, label: "Paste an API key", hint: "From console.anthropic.com/settings/keys"},
    ])

    case method do
      :oauth ->
        run_oauth_flow()

      :api_key ->
        key = Prompt.text("Anthropic API key", placeholder: "sk-ant-api03-...", mask: true)
        if key && String.trim(key) != "", do: String.trim(key), else: nil

      _ ->
        nil
    end
  end

  defp get_auth(provider) do
    placeholder = case provider do
      :openai -> "sk-..."
      :groq -> "gsk_..."
      :openrouter -> "sk-or-..."
      :deepseek -> "sk-..."
      _ -> "..."
    end

    key = Prompt.text("#{provider_name(provider)} API key", placeholder: placeholder, mask: true)
    if key && String.trim(key) != "", do: String.trim(key), else: nil
  end

  # ── OAuth ────────────────────────────────────────────────────────

  defp run_oauth_flow do
    alias OptimalSystemAgent.Auth.OAuth

    port = Application.get_env(:optimal_system_agent, :http_port, 9089)
    redirect_uri = "http://127.0.0.1:#{port}/onboarding/oauth/callback"
    {authorize_url, code_verifier, state} = OAuth.authorize_url(redirect_uri)

    try do
      :ets.new(:oauth_state, [:set, :public, :named_table])
    rescue
      ArgumentError -> :oauth_state
    end
    :ets.insert(:oauth_state, {:pkce, code_verifier, state, redirect_uri})

    IO.puts("\e[2m│  Opening browser...\e[0m")

    case :os.type() do
      {:unix, :darwin} -> System.cmd("open", [authorize_url])
      {:unix, _} -> System.cmd("xdg-open", [authorize_url])
      {:win32, _} -> System.cmd("cmd", ["/c", "start", authorize_url])
    end

    IO.puts("\e[2m│  If browser didn't open:\e[0m")
    IO.puts("\e[36m│  #{authorize_url}\e[0m")
    IO.puts("\e[2m│\e[0m")
    IO.puts("\e[2m│  Waiting for authorization...\e[0m")

    # Poll
    case poll_oauth(45) do
      :ok ->
        Prompt.completed("Anthropic", "Connected via OAuth")
        # OAuth creates an API key — return it
        Application.get_env(:optimal_system_agent, :anthropic_api_key)

      :timeout ->
        IO.puts("\e[33m  ⚠ OAuth timed out. You can try /login later.\e[0m")
        nil
    end
  end

  defp poll_oauth(0), do: :timeout
  defp poll_oauth(remaining) do
    Process.sleep(2_000)
    if OptimalSystemAgent.Auth.OAuth.oauth_configured?() do
      :ok
    else
      poll_oauth(remaining - 1)
    end
  end

  # ── Validation ───────────────────────────────────────────────────

  defp validate_provider(:ollama, _key), do: :ok

  defp validate_provider(provider, key) when is_binary(key) do
    IO.puts("\e[2m│  Verifying connection...\e[0m")

    case test_provider(provider, key) do
      :ok ->
        Prompt.completed("Connection", "Verified ✓")

      {:error, reason} ->
        IO.puts("\e[33m│  ⚠ Connection test failed: #{reason}\e[0m")
        IO.puts("\e[2m│  You can continue — the key will be saved.\e[0m")
    end
  end

  defp validate_provider(_, _), do: :ok

  defp test_provider(:anthropic, key) do
    case Req.post("https://api.anthropic.com/v1/messages",
           json: %{model: "claude-haiku-4-5", max_tokens: 1, messages: [%{role: "user", content: "hi"}]},
           headers: [{"x-api-key", key}, {"anthropic-version", "2023-06-01"}, {"content-type", "application/json"}],
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 401}} -> {:error, "Invalid API key"}
      {:ok, %{status: s}} -> {:error, "HTTP #{s}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp test_provider(:openai, key) do
    case Req.get("https://api.openai.com/v1/models",
           headers: [{"authorization", "Bearer #{key}"}],
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 401}} -> {:error, "Invalid API key"}
      {:ok, %{status: s}} -> {:error, "HTTP #{s}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp test_provider(_, _key), do: :ok

  # ── Channel Setup ───────────────────────────────────────────────

  defp setup_channel(:telegram) do
    token = Prompt.text("Telegram bot token", placeholder: "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11")
    if token && token != "" do
      save_env("TELEGRAM_BOT_TOKEN", token)
      Prompt.completed("Telegram", "Token saved")
    end
  end

  defp setup_channel(:discord) do
    token = Prompt.text("Discord bot token", placeholder: "MTI...", mask: true)
    if token && token != "" do
      save_env("DISCORD_BOT_TOKEN", token)
      Prompt.completed("Discord", "Token saved")
    end
  end

  defp setup_channel(:slack) do
    token = Prompt.text("Slack bot token", placeholder: "xoxb-...")
    secret = Prompt.text("Slack signing secret", mask: true)
    if token && token != "" do
      save_env("SLACK_BOT_TOKEN", token)
      if secret && secret != "", do: save_env("SLACK_SIGNING_SECRET", secret)
      Prompt.completed("Slack", "Configured")
    end
  end

  defp setup_channel(:whatsapp) do
    Prompt.note(
      "WhatsApp requires a Node.js bridge.\n" <>
      "1. cd scripts/whatsapp-bridge && npm install\n" <>
      "2. node bridge.js --pair-only  (scan QR)\n" <>
      "3. node bridge.js  (start bridge)",
      "WhatsApp Setup"
    )
    save_env("WHATSAPP_ENABLED", "true")
    Prompt.completed("WhatsApp", "Config saved — run the bridge separately")
  end

  defp setup_channel(:matrix) do
    homeserver = Prompt.text("Matrix homeserver URL", placeholder: "https://matrix.example.org")
    token = Prompt.text("Access token", mask: true)
    if homeserver && token && homeserver != "" && token != "" do
      save_env("MATRIX_HOMESERVER", homeserver)
      save_env("MATRIX_ACCESS_TOKEN", token)
      Prompt.completed("Matrix", "Connected to #{homeserver}")
    end
  end

  defp setup_channel(:email) do
    address = Prompt.text("Email address", placeholder: "agent@gmail.com")
    password = Prompt.text("Email password (app-specific)", mask: true)
    if address && password && address != "" && password != "" do
      save_env("EMAIL_ADDRESS", address)
      save_env("EMAIL_PASSWORD", password)
      save_env("EMAIL_IMAP_HOST", "imap.gmail.com")
      save_env("EMAIL_SMTP_HOST", "smtp.gmail.com")
      Prompt.completed("Email", address)
    end
  end

  defp setup_channel(_), do: :ok

  # ── Config Writing ──────────────────────────────────────────────

  defp write_config(provider, api_key) do
    File.mkdir_p!(@osa_dir)
    env_path = Path.join(@osa_dir, ".env")

    lines = [
      "OSA_DEFAULT_PROVIDER=#{provider}"
    ]

    lines = if api_key do
      env_key = provider_env_key(provider)
      lines ++ ["#{env_key}=#{api_key}"]
    else
      lines
    end

    # Read existing .env and merge (don't overwrite other keys)
    existing = case File.read(env_path) do
      {:ok, content} -> content
      _ -> ""
    end

    existing_keys = existing
      |> String.split("\n")
      |> Enum.map(fn line -> line |> String.split("=", parts: 2) |> List.first() end)
      |> MapSet.new()

    new_lines = Enum.reject(lines, fn line ->
      key = line |> String.split("=", parts: 2) |> List.first()
      MapSet.member?(existing_keys, key)
    end)

    if new_lines != [] do
      content = if existing == "", do: Enum.join(new_lines, "\n"), else: existing <> "\n" <> Enum.join(new_lines, "\n")
      File.write!(env_path, content <> "\n")
    end

    # Also set in runtime
    Application.put_env(:optimal_system_agent, :default_provider, provider)
    if api_key do
      config_key = provider_config_key(provider)
      Application.put_env(:optimal_system_agent, config_key, api_key)
    end
  end

  defp save_env(key, value) do
    env_path = Path.join(@osa_dir, ".env")
    File.mkdir_p!(@osa_dir)

    existing = case File.read(env_path) do
      {:ok, content} -> content
      _ -> ""
    end

    # Replace or append
    if String.contains?(existing, "#{key}=") do
      updated = Regex.replace(~r/^#{Regex.escape(key)}=.*$/m, existing, "#{key}=#{value}")
      File.write!(env_path, updated)
    else
      File.write!(env_path, existing <> "#{key}=#{value}\n")
    end
  end

  defp provider_name(:anthropic), do: "Anthropic"
  defp provider_name(:openai), do: "OpenAI"
  defp provider_name(:groq), do: "Groq"
  defp provider_name(:openrouter), do: "OpenRouter"
  defp provider_name(:deepseek), do: "DeepSeek"
  defp provider_name(:ollama), do: "Ollama"
  defp provider_name(p), do: to_string(p)

  defp provider_env_key(:anthropic), do: "ANTHROPIC_API_KEY"
  defp provider_env_key(:openai), do: "OPENAI_API_KEY"
  defp provider_env_key(:groq), do: "GROQ_API_KEY"
  defp provider_env_key(:openrouter), do: "OPENROUTER_API_KEY"
  defp provider_env_key(:deepseek), do: "DEEPSEEK_API_KEY"
  defp provider_env_key(p), do: "#{String.upcase(to_string(p))}_API_KEY"

  defp provider_config_key(:anthropic), do: :anthropic_api_key
  defp provider_config_key(:openai), do: :openai_api_key
  defp provider_config_key(:groq), do: :groq_api_key
  defp provider_config_key(:openrouter), do: :openrouter_api_key
  defp provider_config_key(:deepseek), do: :deepseek_api_key
  defp provider_config_key(p), do: :"#{p}_api_key"
end
