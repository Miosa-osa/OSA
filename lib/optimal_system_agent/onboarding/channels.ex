defmodule OptimalSystemAgent.Onboarding.Channels do
  @moduledoc """
  Channel setup wizard — guides users through connecting Telegram, WhatsApp, Discord, and Slack.

  Can be run:
  - During initial onboarding (Step 4)
  - Standalone via `/setup` command
  """

  alias OptimalSystemAgent.Onboarding.Selector

  @osa_dir Path.expand("~/.osa")

  @cyan IO.ANSI.cyan()
  @bold IO.ANSI.bright()
  @dim IO.ANSI.faint()
  @green IO.ANSI.green()
  @red IO.ANSI.red()
  @yellow IO.ANSI.yellow()
  @reset IO.ANSI.reset()

  @doc "Run channel setup wizard. Returns list of configured channels."
  @spec run() :: [atom()]
  def run do
    IO.puts("\n  #{@bold}Channel Setup#{@reset}")
    IO.puts("  #{@dim}Connect messaging platforms to your agent.#{@reset}\n")

    channels = select_channels()

    if channels == [] or channels == [:skip] do
      IO.puts("  #{@dim}Skipping channel setup.#{@reset}")
      []
    else
      configured =
        Enum.flat_map(channels, fn channel ->
          case setup_channel(channel) do
            {:ok, channel} -> [channel]
            {:error, _reason} -> []
          end
        end)

      if configured != [] do
        IO.puts(
          "\n  #{@green}✓#{@reset} Configured #{length(configured)} channel(s): #{Enum.join(configured, ", ")}"
        )
      end

      configured
    end
  end

  # ── Channel Selection ──────────────────────────────────────────

  defp select_channels do
    lines = [
      {:header, "#{@dim}Which channels do you want to connect?#{@reset}"},
      {:option, "Telegram", :telegram},
      {:option, "WhatsApp", :whatsapp},
      {:option, "Discord", :discord},
      {:option, "Slack", :slack},
      :separator,
      {:option, "#{@dim}Skip for now#{@reset}", :skip}
    ]

    collect_channels(lines, [])
  end

  defp collect_channels(lines, selected) do
    display_lines =
      if selected != [] do
        lines ++
          [:separator, {:option, "#{@green}Done (#{length(selected)} selected)#{@reset}", :done}]
      else
        lines
      end

    case Selector.select(display_lines) do
      {:selected, :skip} ->
        [:skip]

      {:selected, :done} ->
        Enum.reverse(selected)

      {:selected, channel} when channel in [:telegram, :whatsapp, :discord, :slack] ->
        if channel in selected do
          IO.puts("  #{@dim}#{channel} already selected#{@reset}")
          collect_channels(lines, selected)
        else
          IO.puts("  #{@green}+#{@reset} #{channel}")
          collect_channels(lines, [channel | selected])
        end

      _ ->
        if selected != [], do: Enum.reverse(selected), else: []
    end
  end

  # ── Channel Setup Dispatchers ──────────────────────────────────

  defp setup_channel(:telegram), do: setup_telegram()
  defp setup_channel(:whatsapp), do: setup_whatsapp()
  defp setup_channel(:discord), do: setup_discord()
  defp setup_channel(:slack), do: setup_slack()

  # ── Telegram ───────────────────────────────────────────────────

  defp setup_telegram do
    IO.puts("\n  #{@bold}#{@cyan}Telegram Setup#{@reset}\n")
    IO.puts("  1. Open Telegram and message @BotFather")
    IO.puts("  2. Send /newbot and follow the prompts")
    IO.puts("  3. Copy the bot token\n")

    token = prompt("Bot token")

    if token == "" do
      IO.puts("  #{@red}✗#{@reset} No token provided")
      {:error, :no_token}
    else
      IO.puts("  #{@dim}Validating token...#{@reset}")

      case validate_telegram_token(token) do
        {:ok, bot_name} ->
          IO.puts("  #{@green}✓#{@reset} Bot verified: @#{bot_name}")

          webhook_url = prompt("Webhook URL (your server's public URL, or skip)", "skip")

          if webhook_url != "skip" and webhook_url != "" do
            case set_telegram_webhook(token, webhook_url) do
              :ok -> IO.puts("  #{@green}✓#{@reset} Webhook set")
              {:error, reason} -> IO.puts("  #{@yellow}⚠#{@reset} Webhook failed: #{reason}")
            end
          end

          save_channel_config(:telegram, %{
            "token" => token,
            "bot_name" => bot_name,
            "webhook_url" => webhook_url
          })

          System.put_env("TELEGRAM_BOT_TOKEN", token)
          Application.put_env(:optimal_system_agent, :telegram_token, token)

          {:ok, :telegram}

        {:error, reason} ->
          IO.puts("  #{@red}✗#{@reset} Validation failed: #{reason}")
          {:error, :validation_failed}
      end
    end
  end

  # ── WhatsApp ───────────────────────────────────────────────────

  defp setup_whatsapp do
    IO.puts("\n  #{@bold}#{@cyan}WhatsApp Setup#{@reset}\n")

    if baileys_available?() do
      setup_whatsapp_web()
    else
      setup_whatsapp_api()
    end
  end

  defp baileys_available? do
    sidecar_path =
      Path.join([:code.priv_dir(:optimal_system_agent) |> to_string(), "sidecar", "baileys"])

    node_modules = Path.join(sidecar_path, "node_modules")
    File.exists?(sidecar_path) and File.dir?(node_modules)
  end

  defp setup_whatsapp_web do
    IO.puts("  #{@green}Baileys sidecar detected#{@reset} — using WhatsApp Web (QR code)")
    IO.puts("  #{@dim}QR code linking will be available after setup.#{@reset}")

    save_channel_config(:whatsapp, %{"mode" => "web"})
    Application.put_env(:optimal_system_agent, :whatsapp_mode, "web")
    Application.put_env(:optimal_system_agent, :whatsapp_web_enabled, true)
    {:ok, :whatsapp}
  end

  defp setup_whatsapp_api do
    IO.puts("  Using Meta Cloud API (requires Meta Business account)")
    IO.puts("  1. Go to developers.facebook.com/apps")
    IO.puts("  2. Create or select your app")
    IO.puts("  3. Add WhatsApp product\n")

    token = prompt("WhatsApp API token")
    phone_id = prompt("Phone Number ID")
    verify_token = prompt("Webhook verify token", "osa_whatsapp_verify")

    if token == "" or phone_id == "" do
      IO.puts("  #{@red}✗#{@reset} Token and Phone Number ID are required")
      {:error, :missing_fields}
    else
      save_channel_config(:whatsapp, %{
        "mode" => "api",
        "token" => token,
        "phone_number_id" => phone_id,
        "verify_token" => verify_token
      })

      System.put_env("WHATSAPP_TOKEN", token)
      System.put_env("WHATSAPP_PHONE_NUMBER_ID", phone_id)
      System.put_env("WHATSAPP_VERIFY_TOKEN", verify_token)
      Application.put_env(:optimal_system_agent, :whatsapp_token, token)
      Application.put_env(:optimal_system_agent, :whatsapp_phone_number_id, phone_id)
      Application.put_env(:optimal_system_agent, :whatsapp_verify_token, verify_token)
      Application.put_env(:optimal_system_agent, :whatsapp_mode, "api")

      IO.puts("  #{@green}✓#{@reset} WhatsApp configured (Meta API)")
      {:ok, :whatsapp}
    end
  end

  # ── Discord ────────────────────────────────────────────────────

  defp setup_discord do
    IO.puts("\n  #{@bold}#{@cyan}Discord Setup#{@reset}\n")
    IO.puts("  1. Go to discord.com/developers/applications")
    IO.puts("  2. Create a new application → Bot section")
    IO.puts("  3. Copy the bot token\n")

    token = prompt("Bot token")

    if token == "" do
      IO.puts("  #{@red}✗#{@reset} No token provided")
      {:error, :no_token}
    else
      IO.puts("  #{@dim}Validating token...#{@reset}")

      case validate_discord_token(token) do
        {:ok, bot_name} ->
          IO.puts("  #{@green}✓#{@reset} Bot verified: #{bot_name}")

          save_channel_config(:discord, %{
            "token" => token,
            "bot_name" => bot_name
          })

          System.put_env("DISCORD_BOT_TOKEN", token)
          Application.put_env(:optimal_system_agent, :discord_token, token)

          {:ok, :discord}

        {:error, reason} ->
          IO.puts("  #{@red}✗#{@reset} Validation failed: #{reason}")
          {:error, :validation_failed}
      end
    end
  end

  # ── Slack ──────────────────────────────────────────────────────

  defp setup_slack do
    IO.puts("\n  #{@bold}#{@cyan}Slack Setup#{@reset}\n")
    IO.puts("  1. Go to api.slack.com/apps")
    IO.puts("  2. Create a new app → OAuth & Permissions")
    IO.puts("  3. Install to workspace and copy the Bot token\n")

    token = prompt("Bot User OAuth Token (xoxb-...)")

    if token == "" do
      IO.puts("  #{@red}✗#{@reset} No token provided")
      {:error, :no_token}
    else
      IO.puts("  #{@dim}Validating token...#{@reset}")

      case validate_slack_token(token) do
        {:ok, bot_name} ->
          IO.puts("  #{@green}✓#{@reset} Bot verified: #{bot_name}")

          signing_secret = prompt("Signing Secret (for event verification)", "")

          config = %{"token" => token, "bot_name" => bot_name}

          config =
            if signing_secret != "" do
              Map.put(config, "signing_secret", signing_secret)
            else
              config
            end

          save_channel_config(:slack, config)

          System.put_env("SLACK_BOT_TOKEN", token)
          Application.put_env(:optimal_system_agent, :slack_token, token)

          if signing_secret != "" do
            System.put_env("SLACK_SIGNING_SECRET", signing_secret)
            Application.put_env(:optimal_system_agent, :slack_signing_secret, signing_secret)
          end

          {:ok, :slack}

        {:error, reason} ->
          IO.puts("  #{@red}✗#{@reset} Validation failed: #{reason}")
          {:error, :validation_failed}
      end
    end
  end

  # ── HTTP Validation Helpers ────────────────────────────────────

  defp validate_telegram_token(token) do
    try do
      case Req.get("https://api.telegram.org/bot#{token}/getMe") do
        {:ok, %{status: 200, body: %{"ok" => true, "result" => %{"username" => name}}}} ->
          {:ok, name}

        {:ok, %{body: body}} ->
          {:error, body["description"] || "unknown error"}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp set_telegram_webhook(token, url) do
    try do
      case Req.post("https://api.telegram.org/bot#{token}/setWebhook",
             json: %{"url" => url}
           ) do
        {:ok, %{status: 200, body: %{"ok" => true}}} -> :ok
        {:ok, %{body: body}} -> {:error, body["description"] || "unknown error"}
        {:error, reason} -> {:error, inspect(reason)}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp validate_discord_token(token) do
    try do
      case Req.get("https://discord.com/api/v10/users/@me",
             headers: [{"authorization", "Bot #{token}"}]
           ) do
        {:ok, %{status: 200, body: %{"username" => name}}} ->
          {:ok, name}

        {:ok, %{status: status, body: body}} ->
          {:error, body["message"] || "HTTP #{status}"}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp validate_slack_token(token) do
    try do
      case Req.get("https://slack.com/api/auth.test",
             headers: [{"authorization", "Bearer #{token}"}]
           ) do
        {:ok, %{status: 200, body: %{"ok" => true, "bot_id" => _, "user" => name}}} ->
          {:ok, name}

        {:ok, %{status: 200, body: %{"ok" => false, "error" => error}}} ->
          {:error, error}

        {:ok, %{status: status}} ->
          {:error, "HTTP #{status}"}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  # ── Config Persistence ─────────────────────────────────────────

  defp save_channel_config(channel, config) do
    config_path = Path.join(@osa_dir, "config.json")

    existing =
      case File.read(config_path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, map} -> map
            _ -> %{}
          end

        _ ->
          %{}
      end

    channels = Map.get(existing, "channels", %{})
    updated = Map.put(channels, to_string(channel), config)
    final = Map.put(existing, "channels", updated)

    File.mkdir_p!(@osa_dir)
    File.write!(config_path, Jason.encode!(final, pretty: true))
  end

  # ── I/O Helpers ────────────────────────────────────────────────

  defp prompt(text, default \\ "") do
    suffix = if default != "" and default != nil, do: " [#{default}]", else: ""

    case IO.gets("  #{text}#{suffix}: ") do
      :eof ->
        default || ""

      input ->
        trimmed = String.trim(input)
        if trimmed == "" and default != nil, do: default, else: trimmed
    end
  end
end
