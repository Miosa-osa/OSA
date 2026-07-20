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

  defp osa_dir, do: System.get_env("OSA_HOME") || Path.join(System.user_home!(), ".osa")

  # Item 1 (audit) fix: this used to have NO `ollama_cloud` entry at all, so a
  # user running `/setup` (or hitting the REPL first-run, which shares this
  # module — see `Channels.CLI.start/0` and `cmd_setup/2`) could never pick
  # the recommended provider that the good first-run wizard
  # (`mix osa.setup.wizard`) leads with. Added here, matching the wizard's
  # catalog entry (`Onboarding.providers_list/0`).
  @providers [
    %{value: :ollama, label: "Ollama (Local)", hint: "Free, runs on your machine"},
    %{value: :ollama_cloud, label: "Ollama Cloud", hint: "No GPU needed — recommended"},
    %{value: :anthropic, label: "Anthropic", hint: "Claude models"},
    %{value: :openai, label: "OpenAI", hint: "GPT models"},
    %{value: :groq, label: "Groq", hint: "Fast inference"},
    %{value: :openrouter, label: "OpenRouter", hint: "Multi-model gateway"},
    %{value: :deepseek, label: "DeepSeek", hint: "DeepSeek models"}
  ]

  @doc false
  # Public so the provider catalog (item 1: ollama_cloud parity) is directly
  # unit-testable without driving the interactive `Prompt.select/2` (TTY).
  def providers, do: @providers

  @channels [
    %{value: :skip, label: "Skip for now", hint: "Set up channels later with /channels"},
    %{value: :telegram, label: "Telegram", hint: "Bot token from @BotFather"},
    %{value: :discord, label: "Discord", hint: "Bot token from Discord Developer Portal"},
    %{value: :slack, label: "Slack", hint: "Bot token + signing secret"},
    %{value: :whatsapp, label: "WhatsApp", hint: "Uses Baileys bridge (Node.js)"},
    %{value: :matrix, label: "Matrix", hint: "Homeserver + access token"},
    %{value: :email, label: "Email", hint: "IMAP/SMTP credentials"}
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
      # Step 2: Auth — returns {api_key, base_url}. `base_url` is only ever
      # non-nil for :ollama_cloud (localhost = keyless local daemon route,
      # https://ollama.com = keyed cloud route — item 1 audit fix, M2 parity
      # with the good first-run wizard).
      {api_key, base_url} = get_auth(provider)

      if is_nil(api_key) and provider not in [:ollama, :ollama_cloud] do
        Prompt.outro("Setup cancelled")
        :skip
      else
        # Step 3: Validate connection
        validate_provider(provider, api_key)

        # Step 4: Model selection (item 1 audit fix — this wizard used to
        # have NO model-selection step at all; the config it wrote always
        # fell back to the provider's runtime default with no way to pick a
        # specific model, e.g. the recommended glm-5.2:cloud on Ollama Cloud).
        model = select_model(provider, api_key)

        # Step 5: Channel setup (optional)
        channel = Prompt.select("Connect a messaging channel?", @channels)

        if channel && channel != :skip do
          setup_channel(channel)
        end

        # Step 6: Write config
        write_config(provider, api_key, model: model, base_url: base_url)

        Prompt.note(
          "Make OSA yours — edit files in ~/.osa/:\n" <>
            "  IDENTITY.md / SOUL.md   name, vibe, voice\n" <>
            "  HEARTBEAT.md            recurring proactive tasks\n" <>
            "  skills/ · workflows/    custom skills & playbooks\n" <>
            "Starter templates are in the examples/ folder.",
          "Customize"
        )

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
  #
  # Every clause returns `{api_key_or_nil, base_url_or_nil}`. `base_url` is
  # only meaningful for :ollama_cloud (item 1 audit fix); every other
  # provider always returns `nil` for it.

  defp get_auth(:ollama) do
    Prompt.note("Ollama runs locally — no API key needed.", "Local Provider")

    # Check if Ollama is running
    case Req.get("http://localhost:11434/api/tags", receive_timeout: 3_000) do
      {:ok, %{status: 200}} ->
        Prompt.completed("Ollama", "Detected at localhost:11434")

      _ ->
        IO.puts("\e[33m  ⚠ Ollama not detected. Install from https://ollama.com\e[0m")
    end

    {nil, nil}
  end

  # Item 1 audit fix (M2 parity): the good first-run wizard probes the local
  # Ollama daemon first and offers the keyless "signed-in local Ollama" route
  # before ever demanding an Ollama Cloud API key — mirrored here via the
  # shared `Onboarding.ollama_cloud_route/3` decision table so both entry
  # points make the exact same choice.
  defp get_auth(:ollama_cloud) do
    local = Onboarding.probe_ollama_local()

    if local.reachable do
      choice =
        Prompt.select("Ollama Cloud connection", [
          %{
            value: :local,
            label: "Use signed-in local Ollama (no key)",
            hint: "detected at #{local.url} — proxies :cloud models via device identity"
          },
          %{
            value: :key,
            label: "Enter an Ollama Cloud API key",
            hint: "for a different account or a headless setup"
          }
        ])

      case choice do
        :local ->
          Prompt.completed("Credentials", "using signed-in local Ollama (no key)")
          Onboarding.ollama_cloud_route(true, true, nil)

        _ ->
          key = ask_ollama_cloud_key()
          Onboarding.ollama_cloud_route(true, false, key)
      end
    else
      key = ask_ollama_cloud_key()
      Onboarding.ollama_cloud_route(false, false, key)
    end
  end

  defp get_auth(:anthropic) do
    method =
      Prompt.select("How do you want to connect?", [
        %{
          value: :oauth,
          label: "Sign in with Anthropic",
          hint: "Opens browser, uses your account"
        },
        %{
          value: :api_key,
          label: "Paste an API key",
          hint: "From console.anthropic.com/settings/keys"
        }
      ])

    key =
      case method do
        :oauth ->
          run_oauth_flow()

        :api_key ->
          key = Prompt.text("Anthropic API key", placeholder: "sk-ant-api03-...", mask: true)
          if key && String.trim(key) != "", do: String.trim(key), else: nil

        _ ->
          nil
      end

    {key, nil}
  end

  defp get_auth(provider) do
    placeholder =
      case provider do
        :openai -> "sk-..."
        :groq -> "gsk_..."
        :openrouter -> "sk-or-..."
        :deepseek -> "sk-..."
        _ -> "..."
      end

    key = Prompt.text("#{provider_name(provider)} API key", placeholder: placeholder, mask: true)
    key = if key && String.trim(key) != "", do: String.trim(key), else: nil
    {key, nil}
  end

  defp ask_ollama_cloud_key do
    key = Prompt.text("Ollama Cloud API key", placeholder: "...", mask: true)
    if key && String.trim(key) != "", do: String.trim(key), else: nil
  end

  # ── Model Selection ─────────────────────────────────────────────
  #
  # Item 1 audit fix: this wizard previously had no model-selection step at
  # all. Reuses `Onboarding.model_list/2` (the same catalog the good
  # first-run wizard reads from) so we don't maintain a second copy of every
  # provider's model list. Returns `nil` (no explicit model — the provider's
  # runtime default applies) when there's nothing to pick from, so this never
  # blocks setup on providers we don't have a catalog for (groq, deepseek).
  defp select_model(provider, api_key) do
    onboarding_id = onboarding_provider_id(provider)

    case Onboarding.model_list(onboarding_id, api_key: api_key) do
      {:ok, []} ->
        nil

      {:ok, models} ->
        options =
          Enum.map(models, fn m ->
            %{
              value: Map.get(m, :id),
              label: Map.get(m, :name) || Map.get(m, :id),
              hint: Map.get(m, :note, "")
            }
          end)

        Prompt.select("Default model", options)

      {:error, _} ->
        nil
    end
  rescue
    _ -> nil
  end

  defp onboarding_provider_id(:ollama), do: "ollama_local"
  defp onboarding_provider_id(:ollama_cloud), do: "ollama_cloud"
  defp onboarding_provider_id(provider), do: to_string(provider)

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

  @doc false
  # Public so validation (incl. the ollama_cloud keyless route, item 1) is
  # directly unit-testable without a TTY; still internal API.
  def validate_provider(:ollama, _key), do: :ok

  def validate_provider(provider, key) when is_binary(key) do
    IO.puts("\e[2m│  Verifying connection...\e[0m")

    case test_provider(provider, key) do
      :ok ->
        Prompt.completed("Connection", "Verified ✓")

      # F4 fix: `test_provider/2` used to fall back to a blanket `:ok` for any
      # provider it had no real health-check for (groq/openrouter/deepseek),
      # so this branch reported "Verified ✓" without ever making a network
      # call. A user who fat-fingered a groq/openrouter/deepseek key saw a
      # false-positive "Verified" here and only found out on their first real
      # turn (401). Providers we can't/don't actually probe now return
      # `:unverified` explicitly and get an honest "saved, not verified"
      # message instead.
      :unverified ->
        Prompt.completed("Connection", "Saved (not verified)")
        IO.puts("\e[2m│  Couldn't test this provider automatically — if the key is\e[0m")
        IO.puts("\e[2m│  wrong you'll see an error on your first message.\e[0m")

      {:error, reason} ->
        IO.puts("\e[33m│  ⚠ Connection test failed: #{reason}\e[0m")
        IO.puts("\e[2m│  You can continue — the key will be saved.\e[0m")
    end
  end

  def validate_provider(_, _), do: :ok

  @doc false
  # Public so F4's "actually probe the provider" behavior is directly
  # unit-testable; still internal API (not meant for external callers).
  def test_provider(:anthropic, key) do
    case Req.post("https://api.anthropic.com/v1/messages",
           json: %{
             model: "claude-haiku-4-5",
             max_tokens: 1,
             messages: [%{role: "user", content: "hi"}]
           },
           headers: [
             {"x-api-key", key},
             {"anthropic-version", "2023-06-01"},
             {"content-type", "application/json"}
           ],
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 401}} -> {:error, "Invalid API key"}
      {:ok, %{status: s}} -> {:error, "HTTP #{s}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def test_provider(:openai, key) do
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

  def test_provider(:groq, key) do
    case Req.get("https://api.groq.com/openai/v1/models",
           headers: [{"authorization", "Bearer #{key}"}],
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 401}} -> {:error, "Invalid API key"}
      {:ok, %{status: s}} -> {:error, "HTTP #{s}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def test_provider(:openrouter, key) do
    # OpenRouter's documented key-introspection endpoint — returns key/credit
    # info on a valid key, 401 on a bad one.
    case Req.get("https://openrouter.ai/api/v1/key",
           headers: [{"authorization", "Bearer #{key}"}],
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 401}} -> {:error, "Invalid API key"}
      {:ok, %{status: s}} -> {:error, "HTTP #{s}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def test_provider(:deepseek, key) do
    # DeepSeek's balance endpoint doubles as a cheap, no-token-cost key check.
    case Req.get("https://api.deepseek.com/user/balance",
           headers: [{"authorization", "Bearer #{key}"}],
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 401}} -> {:error, "Invalid API key"}
      {:ok, %{status: s}} -> {:error, "HTTP #{s}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # No real health-check for this provider — say so rather than claiming
  # "Verified ✓" for a key we never actually tested.
  def test_provider(_, _key), do: :unverified

  # ── Channel Setup ───────────────────────────────────────────────

  defp setup_channel(:telegram) do
    token =
      Prompt.text("Telegram bot token", placeholder: "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11")

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

  # F3 fix: re-running `/setup` to switch provider must actually take effect.
  # The previous version only ever APPENDED `OSA_DEFAULT_PROVIDER=...` and
  # skipped it whenever the key already existed in `.env`, so switching from
  # Ollama to Anthropic left `OSA_DEFAULT_PROVIDER=ollama` on disk untouched
  # and the new provider was silently dropped. This now upserts
  # (replace-in-place, like `Onboarding.write_setup`'s `keyreplace` merge):
  # existing keys are updated, new keys are appended, unrelated lines
  # (comments, other providers' keys) are preserved.
  # Item 1 audit fix: `write_config/2` never accepted (or wrote) a model at
  # all — the wizard's step 5 result was always discarded. Now
  # `write_config/3` takes `opts` (`:model`, `:base_url`), defaulting to `[]`
  # so every existing `write_config(provider, api_key)` call (2 arity) keeps
  # working unchanged. `:ollama_cloud` additionally needs `OLLAMA_URL` (the
  # keyless-local vs keyed-cloud switch — M2 parity) instead of a normal
  # `<PROVIDER>_API_KEY` var, and is written to disk as `OSA_DEFAULT_PROVIDER=
  # ollama` (not the literal "ollama_cloud") to match the runtime provider
  # atom every other part of OSA resolves (`Onboarding.apply_env_vars/4` does
  # the same "ollama_cloud" -> :ollama mapping).
  @doc false
  # Public (not `defp`) so the upsert behavior (F3) and model/ollama_cloud
  # writing (item 1) are directly unit-testable without driving the
  # interactive prompt flow; still internal API.
  def write_config(provider, api_key, opts \\ []) do
    model = Keyword.get(opts, :model)
    base_url = Keyword.get(opts, :base_url)

    File.mkdir_p!(osa_dir())
    env_path = Path.join(osa_dir(), ".env")

    {default_provider, extra_pairs} = provider_pairs(provider, api_key, model, base_url)

    pairs = [{"OSA_DEFAULT_PROVIDER", default_provider} | extra_pairs]

    existing =
      case File.read(env_path) do
        {:ok, content} -> content
        _ -> ""
      end

    content = upsert_env(existing, pairs)

    File.write!(env_path, content)
    # Restrict permissions — file contains API keys
    File.chmod!(env_path, 0o600)

    # Also set in runtime
    Application.put_env(:optimal_system_agent, :default_provider, provider)

    if api_key do
      config_key = provider_config_key(provider)
      Application.put_env(:optimal_system_agent, config_key, api_key)
    end

    if model do
      Application.put_env(:optimal_system_agent, :default_model, model)
    end
  end

  # Returns `{osa_default_provider_value, [{env_key, value}]}` for the given
  # provider selection. `nil` model/api_key are simply omitted (never write a
  # blank/placeholder value).
  defp provider_pairs(:ollama_cloud, api_key, model, base_url) do
    url = base_url || "https://ollama.com"

    pairs =
      [{"OLLAMA_URL", url}] ++
        (if api_key, do: [{"OLLAMA_API_KEY", api_key}], else: []) ++
        (if model, do: [{"OLLAMA_MODEL", model}], else: [])

    {"ollama", pairs}
  end

  defp provider_pairs(:ollama, _api_key, model, _base_url) do
    pairs = if model, do: [{"OLLAMA_MODEL", model}], else: []
    {"ollama", pairs}
  end

  defp provider_pairs(provider, api_key, model, _base_url) do
    pairs =
      (if api_key, do: [{provider_env_key(provider), api_key}], else: []) ++
        (if model, do: [{"OSA_MODEL", model}], else: [])

    {to_string(provider), pairs}
  end

  # Upsert `pairs` (a list of `{KEY, value}`) into raw `.env` text: an existing
  # `KEY=...` line is replaced in place; a key not yet present is appended.
  # Every other line (other providers' keys, comments, blanks) is left alone.
  defp upsert_env(existing, pairs) do
    lines =
      existing
      |> String.split("\n", trim: true)

    {updated_lines, remaining_pairs} =
      Enum.map_reduce(lines, pairs, fn line, pending ->
        key = line |> String.split("=", parts: 2) |> List.first()

        case Enum.find(pending, fn {k, _v} -> k == key end) do
          {^key, value} ->
            {"#{key}=#{value}", Enum.reject(pending, fn {k, _v} -> k == key end)}

          nil ->
            {line, pending}
        end
      end)

    appended = Enum.map(remaining_pairs, fn {k, v} -> "#{k}=#{v}" end)

    (updated_lines ++ appended)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp save_env(key, value) do
    env_path = Path.join(osa_dir(), ".env")
    File.mkdir_p!(osa_dir())

    existing =
      case File.read(env_path) do
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
