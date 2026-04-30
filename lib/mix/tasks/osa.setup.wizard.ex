defmodule Mix.Tasks.Osa.Setup.Wizard do
  @moduledoc """
  Interactive CLI setup wizard using OptimalSystemAgent.CLI.Prompt.

  Runs in the terminal (not the TUI). Uses @clack/prompts-style inline
  terminal UI with arrow-key navigation.

  Usage: mix osa.setup.wizard
  Called automatically by bin/osa on first run.
  """
  use Mix.Task

  alias OptimalSystemAgent.CLI.Prompt
  alias OptimalSystemAgent.Onboarding

  @shortdoc "Interactive setup wizard (CLI)"

  @security_note """
  OSA runs entirely on YOUR machine. Your API keys are
  written only to ~/.osa/.env — never sent anywhere else.
  You can audit the code at any time.
  """

  @impl true
  def run(_args) do
    Application.ensure_all_started(:req)

    Prompt.intro("OSA Agent Setup")
    Prompt.note(@security_note, "Before we start")

    unless Prompt.confirm("Ready to set up?") do
      IO.puts("\e[2m│  Cancelled. Run 'mix osa.setup.wizard' when ready.\e[0m")
      exit(:normal)
    end

    mode =
      Prompt.select("Setup mode", [
        %{value: :quickstart, label: "QuickStart", hint: "Auto-detect and use sensible defaults"},
        %{value: :full, label: "Full Setup", hint: "Choose provider, model, and channels"}
      ])

    # Auto-detect existing providers
    %{detected: detected, ollama_local: ollama_local} = Onboarding.detect_existing()

    detected_summary =
      cond do
        detected != [] ->
          names = Enum.map_join(detected, ", ", & &1.provider)
          "#{names} (from environment)"

        ollama_local.reachable ->
          "Ollama Local (running at #{ollama_local.url})"

        true ->
          "none"
      end

    Prompt.completed("Detected providers", detected_summary)

    # QuickStart: use first detected provider and skip provider/model steps
    if mode == :quickstart and (detected != [] or ollama_local.reachable) do
      run_quickstart(detected, ollama_local)
    else
      run_full_setup(detected)
    end
  end

  # ── QuickStart ────────────────────────────────────────────────

  defp run_quickstart(detected, ollama_local) do
    {provider_id, api_key} =
      cond do
        detected != [] ->
          first = List.first(detected)
          env_var = provider_env_var(first.provider)
          {first.provider, System.get_env(env_var)}

        ollama_local.reachable ->
          {"ollama_local", nil}
      end

    default_model = provider_default_model(provider_id)
    Prompt.completed("Provider", provider_label(provider_id))
    Prompt.completed("Model", default_model)

    run_health_check(provider_id, api_key, default_model, nil)

    channel_tokens = configure_channels()
    write_config(provider_id, api_key, default_model, nil, channel_tokens)

    Prompt.outro("Setup complete! Run 'osa' to start chatting.")
  end

  # ── Full Setup ────────────────────────────────────────────────

  defp run_full_setup(detected) do
    detected_ids = MapSet.new(detected, & &1.provider)

    provider_options =
      Onboarding.providers_list()
      |> Enum.map(fn p ->
        badge = if MapSet.member?(detected_ids, p.id), do: "detected ✓", else: p.description
        %{value: p.id, label: p.name, hint: badge}
      end)

    provider_id = Prompt.select("How do you want to connect?", provider_options)

    {api_key, base_url} = collect_credentials(provider_id, detected)

    model = select_model(provider_id, api_key)

    run_health_check(provider_id, api_key, model, base_url)

    channel_tokens = configure_channels()
    write_config(provider_id, api_key, model, base_url, channel_tokens)

    Prompt.outro("Setup complete! Run 'osa' to start chatting.")
  end

  # ── Credentials ───────────────────────────────────────────────

  defp collect_credentials("ollama_local", _detected) do
    Prompt.completed("Credentials", "no key required")
    {nil, "http://localhost:11434"}
  end

  defp collect_credentials(provider_id, detected) do
    env_var = provider_env_var(provider_id)
    existing_key = find_detected_key(provider_id, detected) || System.get_env(env_var)

    if existing_key do
      use_existing = Prompt.confirm("Use detected #{env_var}? (#{preview_key(existing_key)})")

      if use_existing do
        Prompt.completed("Credentials", preview_key(existing_key))
        base_url = if provider_id == "custom", do: ask_base_url(), else: nil
        {existing_key, base_url}
      else
        ask_fresh_credentials(provider_id, env_var)
      end
    else
      ask_fresh_credentials(provider_id, env_var)
    end
  end

  defp ask_fresh_credentials(provider_id, env_var) do
    signup_url = provider_signup_url(provider_id)

    if signup_url do
      Prompt.note("Get your key at: #{signup_url}", provider_label(provider_id))
    end

    api_key = Prompt.text("#{env_var}:", mask: true)
    base_url = if provider_id == "custom", do: ask_base_url(), else: nil
    {clean_key(api_key), base_url}
  end

  defp ask_base_url do
    Prompt.text("Base URL (e.g. https://api.together.ai/v1):")
  end

  # ── Model Selection ───────────────────────────────────────────

  defp select_model(provider_id, api_key) do
    case Onboarding.model_list(provider_id, api_key: api_key) do
      {:ok, []} ->
        model = Prompt.text("Model name:", default: provider_default_model(provider_id))
        if model == "", do: provider_default_model(provider_id), else: model

      {:ok, models} ->
        options =
          Enum.map(models, fn m ->
            ctx = format_ctx(m[:ctx] || 0)
            hint = [ctx, m[:note]] |> Enum.reject(&(is_nil(&1) or &1 == "")) |> Enum.join(" · ")
            %{value: m.id, label: m[:name] || m.id, hint: hint}
          end)

        Prompt.select("Default model", options)

      {:error, _} ->
        model = Prompt.text("Model name:", default: provider_default_model(provider_id))
        if model == "", do: provider_default_model(provider_id), else: model
    end
  end

  # ── Health Check ──────────────────────────────────────────────

  defp run_health_check(provider_id, api_key, model, base_url) do
    stop = Prompt.spinner("Testing connection...")

    params = %{
      "provider" => provider_id,
      "api_key" => api_key,
      "model" => model,
      "base_url" => base_url
    }

    case Onboarding.health_check(params) do
      {:ok, %{latency_ms: latency}} ->
        stop.("\e[32m✓\e[0m  Connection verified (#{latency}ms)")
        Prompt.completed("Health check", "verified #{latency}ms")

      {:error, %{message: msg}} ->
        stop.("\e[31m✗\e[0m  #{msg}")
        Prompt.completed("Health check", "failed — fix later with 'osa setup'")
    end
  end

  # ── Channels ──────────────────────────────────────────────────

  defp configure_channels do
    selected =
      Prompt.multiselect("Connect channels? (optional)", [
        %{value: "telegram", label: "Telegram", hint: "get token from @BotFather"},
        %{value: "discord", label: "Discord", hint: "discord.com/developers → Bot → token"},
        %{value: "slack", label: "Slack", hint: "api.slack.com/apps → OAuth → Bot token"}
      ])

    if selected == [] do
      %{}
    else
      Enum.reduce(selected, %{}, fn channel, tokens ->
        instructions = channel_instructions(channel)
        Prompt.note(instructions, String.capitalize(channel))
        token = Prompt.text("#{String.upcase(channel)}_BOT_TOKEN:", mask: true)

        if token == "" do
          tokens
        else
          Map.put(tokens, channel, token)
        end
      end)
    end
  end

  # ── Write Config ──────────────────────────────────────────────

  defp write_config(provider_id, api_key, model, base_url, channel_tokens) do
    stop = Prompt.spinner("Writing configuration...")

    params = %{
      "provider" => provider_id,
      "api_key" => api_key,
      "model" => model,
      "base_url" => base_url,
      "channel_tokens" => channel_tokens
    }

    case Onboarding.write_setup(params) do
      :ok ->
        stop.("\e[32m✓\e[0m  Configuration saved")
        Prompt.completed("Config", "~/.osa/.env written + workspace seeded")

      {:error, reason} ->
        stop.("\e[31m✗\e[0m  Failed: #{reason}")
    end
  end

  # ── Helpers ───────────────────────────────────────────────────

  defp find_detected_key(provider_id, detected) do
    case Enum.find(detected, &(&1.provider == provider_id)) do
      nil -> nil
      _ -> System.get_env(provider_env_var(provider_id))
    end
  end

  defp clean_key(raw) do
    trimmed = String.trim(raw)

    value =
      case String.split(trimmed, "=", parts: 2) do
        [lhs, rhs] ->
          lhs_clean = lhs |> String.trim() |> String.replace("export ", "")
          if Regex.match?(~r/^[A-Z_]+$/, lhs_clean), do: String.trim(rhs), else: trimmed

        _ ->
          trimmed
      end

    value =
      cond do
        String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
          String.slice(value, 1..-2//1)

        String.starts_with?(value, "'") and String.ends_with?(value, "'") ->
          String.slice(value, 1..-2//1)

        true ->
          value
      end

    String.trim_trailing(value, ";") |> String.trim()
  end

  defp preview_key(nil), do: "not set"
  defp preview_key(key) when byte_size(key) <= 8, do: "••••"

  defp preview_key(key) do
    String.slice(key, 0, 4) <> "..." <> String.slice(key, -4, 4)
  end

  defp format_ctx(ctx) when ctx >= 1_000_000, do: "#{div(ctx, 1_000_000)}M ctx"
  defp format_ctx(ctx) when ctx > 0, do: "#{div(ctx, 1024)}K ctx"
  defp format_ctx(_), do: ""

  defp provider_label("miosa"), do: "MIOSA"
  defp provider_label("ollama_cloud"), do: "Ollama Cloud"
  defp provider_label("ollama_local"), do: "Ollama Local"
  defp provider_label("openrouter"), do: "OpenRouter"
  defp provider_label("anthropic"), do: "Anthropic"
  defp provider_label("openai"), do: "OpenAI"
  defp provider_label("custom"), do: "Custom Endpoint"
  defp provider_label(id), do: id

  defp provider_env_var("miosa"), do: "MIOSA_API_KEY"
  defp provider_env_var("ollama_cloud"), do: "OLLAMA_API_KEY"
  defp provider_env_var("openrouter"), do: "OPENROUTER_API_KEY"
  defp provider_env_var("anthropic"), do: "ANTHROPIC_API_KEY"
  defp provider_env_var("openai"), do: "OPENAI_API_KEY"
  defp provider_env_var("custom"), do: "OPENAI_API_KEY"
  defp provider_env_var(_), do: "API_KEY"

  defp provider_default_model("miosa"), do: "nemotron-3-miosa"
  defp provider_default_model("ollama_cloud"), do: "nemotron-3-super:cloud"
  defp provider_default_model("openrouter"), do: "anthropic/claude-sonnet-4-6"
  defp provider_default_model("anthropic"), do: "claude-sonnet-4-6-20260316"
  defp provider_default_model("openai"), do: "gpt-5.4-pro"
  defp provider_default_model(_), do: "default"

  defp provider_signup_url("miosa"), do: "https://miosa.ai/settings/keys"
  defp provider_signup_url("ollama_cloud"), do: "https://ollama.com/account/keys"
  defp provider_signup_url("openrouter"), do: "https://openrouter.ai/keys"
  defp provider_signup_url("anthropic"), do: "https://console.anthropic.com/account/keys"
  defp provider_signup_url("openai"), do: "https://platform.openai.com/api-keys"
  defp provider_signup_url(_), do: nil

  defp channel_instructions("telegram"),
    do: "1) Open @BotFather  2) /newbot  3) Copy token"

  defp channel_instructions("discord"),
    do: "discord.com/developers → Your App → Bot → Copy token"

  defp channel_instructions("slack"),
    do: "api.slack.com/apps → OAuth & Permissions → Bot User OAuth Token"

  defp channel_instructions(_), do: "Enter your bot token"
end
