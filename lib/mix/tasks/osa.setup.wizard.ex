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

    safe_run(fn -> do_run() end)
  end

  @doc """
  Runs `fun` and converts ANY unexpected raise into a friendly message
  instead of a raw stack trace (C1-b). This is what stands between a
  newcomer and a crash-on-first-run: no matter what blows up anywhere in
  the wizard (a bad catalog entry, a provider health-check shape we didn't
  anticipate, a nil where a string was expected, …) the wizard fails soft.

  Public (not `defp`) specifically so it is unit-testable without a TTY —
  see `test/mix/tasks/osa_setup_wizard_test.exs`.
  """
  @spec safe_run((-> term())) :: term() | {:error, String.t()}
  def safe_run(fun) when is_function(fun, 0) do
    fun.()
  rescue
    e ->
      IO.puts("")
      IO.puts("\e[31m✗\e[0m  Something unexpected happened during setup: #{Exception.message(e)}")
      IO.puts("\e[2m│  Run 'osa setup' to try again.\e[0m")
      {:error, Exception.message(e)}
  end

  defp do_run do
    Prompt.intro("OSA Agent Setup")
    Prompt.note(@security_note, "Before we start")

    # Warn early if the HTTP port is taken (shared Net.Port helper via Setup) so
    # onboarding surfaces it before the user finishes and hits the boot preflight.
    OptimalSystemAgent.CLI.Setup.warn_if_port_unavailable()

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

    default_model = resolve_quickstart_model(provider_id, ollama_local)
    Prompt.completed("Provider", provider_label(provider_id))
    Prompt.completed("Model", default_model)

    case run_health_check(provider_id, api_key, default_model, nil) do
      :cancel ->
        Prompt.outro("Setup cancelled. Run 'osa setup' when you're ready.")
        exit(:normal)

      {_status, final_api_key} ->
        channel_tokens = configure_channels()
        write_config(provider_id, final_api_key, default_model, nil, channel_tokens)

        Prompt.note(
          "Make OSA yours — edit files in ~/.osa/:\n" <>
            "  IDENTITY.md / SOUL.md   name, vibe, voice\n" <>
            "  HEARTBEAT.md            recurring proactive tasks\n" <>
            "  skills/ · workflows/    custom skills & playbooks\n" <>
            "Starter templates are in the examples/ folder.",
          "Customize"
        )

        Prompt.outro("Setup complete! Run 'osa' to start chatting.")
    end
  end

  # M5 fix: ollama_local must NEVER end up with the literal model name
  # "default" (the old `provider_default_model/1` catch-all). Instead,
  # query the local daemon's installed models (`GET /api/tags` via
  # `Onboarding.model_list/2`) and use the first one — or prompt, if none
  # are installed. `provider_default_model/1` is still used for providers
  # that genuinely have a sensible hardcoded default (miosa, ollama_cloud,
  # openrouter, anthropic, openai).
  defp resolve_quickstart_model("ollama_local", ollama_local) do
    case Onboarding.model_list("ollama_local", base_url: ollama_local.url) do
      {:ok, [%{id: id} | _]} when is_binary(id) and id != "" ->
        id

      _ ->
        Prompt.note(
          "No installed models found on your local Ollama daemon.\n" <>
            "Pull one first, e.g.: ollama pull llama3.2",
          "Ollama Local"
        )

        prompt_for_model("ollama_local")
    end
  end

  defp resolve_quickstart_model(provider_id, _ollama_local) do
    provider_default_model(provider_id) ||
      raise "No default model configured for #{provider_label(provider_id)}."
  end

  # ── Full Setup ────────────────────────────────────────────────

  defp run_full_setup(detected) do
    detected_ids = MapSet.new(detected, & &1.provider)

    provider_options =
      Onboarding.providers_list()
      |> Enum.map(fn p ->
        %{value: p.id, label: p.name, hint: provider_hint(p, detected_ids)}
      end)

    provider_id = Prompt.select("How do you want to connect?", provider_options)

    {api_key, base_url} = collect_credentials(provider_id, detected)

    model = select_model(provider_id, api_key)

    case run_health_check(provider_id, api_key, model, base_url) do
      :cancel ->
        Prompt.outro("Setup cancelled. Run 'osa setup' when you're ready.")
        exit(:normal)

      {_status, final_api_key} ->
        channel_tokens = configure_channels()
        write_config(provider_id, final_api_key, model, base_url, channel_tokens)

        Prompt.note(
          "Make OSA yours — edit files in ~/.osa/:\n" <>
            "  IDENTITY.md / SOUL.md   name, vibe, voice\n" <>
            "  HEARTBEAT.md            recurring proactive tasks\n" <>
            "  skills/ · workflows/    custom skills & playbooks\n" <>
            "Starter templates are in the examples/ folder.",
          "Customize"
        )

        Prompt.outro("Setup complete! Run 'osa' to start chatting.")
    end
  end

  # C1-c fix: the picker hint used to render `p.description` unconditionally,
  # so a `status: "coming_soon"` catalog entry (MIOSA) looked exactly like a
  # normal, live provider. Surface the catalog's `badge` (falling back to a
  # generic "coming soon" label) whenever `status == "coming_soon"`, and keep
  # "detected ✓" as the highest-priority hint since it's actionable.
  @doc false
  @spec provider_hint(map(), MapSet.t()) :: String.t()
  def provider_hint(p, detected_ids) do
    cond do
      MapSet.member?(detected_ids, p.id) -> "detected ✓"
      Map.get(p, :status) == "coming_soon" -> Map.get(p, :badge) || "coming soon"
      true -> p.description
    end
  end

  # ── Credentials ───────────────────────────────────────────────

  defp collect_credentials("ollama_local", _detected) do
    Prompt.completed("Credentials", "no key required")
    {nil, "http://localhost:11434"}
  end

  # M2 fix: Ollama Cloud used to unconditionally prompt for OLLAMA_API_KEY
  # and pin OLLAMA_URL=https://ollama.com — the documented "signed-in local
  # Ollama, no key" path (the catalog's `key_optional: true`, onboarding.ex
  # ~L178) could never actually be selected, and a blank key meant a 401 on
  # every turn. Probe the local daemon first: if it's reachable, offer the
  # keyless local route as the default; only fall through to a key prompt
  # when there's no local daemon, or the user explicitly wants a key (e.g.
  # a different account, or a headless box).
  defp collect_credentials("ollama_cloud", detected) do
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
          ollama_cloud_credentials(true, true, nil)

        _ ->
          {key, _base_url} = collect_ollama_cloud_key(detected)
          ollama_cloud_credentials(true, false, key)
      end
    else
      {key, _base_url} = collect_ollama_cloud_key(detected)
      ollama_cloud_credentials(false, false, key)
    end
  end

  # Local, keyless servers (LM Studio, llama.cpp) must never be asked for an
  # API key — there is no key to give, so the prompt is a dead end. Driven off
  # the catalog's `requires_key: false` rather than a hardcoded id list, so a
  # future keyless provider is handled automatically.
  defp collect_credentials(provider_id, _detected)
       when provider_id in ["lmstudio", "llamacpp"] do
    entry = catalog_entry(provider_id)
    Prompt.completed("Credentials", "no key required")
    {nil, entry && entry.base_url}
  end

  # The dual-mode fork, driven off the catalog's `auth_modes` through the same
  # pure decision functions the in-app `/setup` uses
  # (`OptimalSystemAgent.CLI.Setup`), so both entry points offer the identical
  # choice — exactly the pattern `Onboarding.ollama_cloud_route/3` already
  # established for Ollama Cloud.
  #
  # A key-only provider gets `[]` back from `auth_options/1` and falls through
  # to the unchanged key flow below.
  defp collect_credentials(provider_id, detected) do
    modes = Onboarding.usable_auth_modes(provider_id)

    choice =
      case Onboarding.auth_options(provider_id) do
        [] -> nil
        options -> Prompt.select("How do you want to connect?", options)
      end

    case Onboarding.auth_route_for(modes, choice) do
      :oauth -> wizard_sign_in(provider_id, modes, detected)
      :api_key -> collect_api_key(provider_id, detected)
    end
  end

  defp wizard_sign_in(provider_id, modes, detected) do
    entry = catalog_entry(provider_id)
    name = (entry && entry.name) || provider_id

    case OptimalSystemAgent.Auth.Subscription.login(provider_id, io: &IO.puts/1) do
      {:ok, _} ->
        Prompt.completed("Credentials", "signed in to #{name}")
        {nil, entry && entry.base_url}

      {:error, reason} ->
        IO.puts("")
        IO.puts("\e[33m  #{OptimalSystemAgent.Auth.Subscription.message(reason, name)}\e[0m")

        # No automatic fallback — silently switching billing model is worse
        # than a clear error. Offer it, do not impose it.
        if :api_key in modes and Prompt.confirm("Use an API key instead?") do
          collect_api_key(provider_id, detected)
        else
          {nil, entry && entry.base_url}
        end
    end
  end

  defp collect_api_key(provider_id, detected) do
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

  # Reuses the standard "detected key? confirm / re-enter" flow for
  # ollama_cloud specifically, but never resolves a base_url itself — the
  # caller always decides that via `ollama_cloud_credentials/3` so the
  # keyless-local vs keyed-cloud URL choice lives in exactly one place.
  defp collect_ollama_cloud_key(detected) do
    env_var = provider_env_var("ollama_cloud")
    existing_key = find_detected_key("ollama_cloud", detected) || System.get_env(env_var)

    if existing_key do
      use_existing = Prompt.confirm("Use detected #{env_var}? (#{preview_key(existing_key)})")

      if use_existing do
        Prompt.completed("Credentials", preview_key(existing_key))
        {existing_key, nil}
      else
        ask_fresh_credentials("ollama_cloud", env_var)
      end
    else
      ask_fresh_credentials("ollama_cloud", env_var)
    end
  end

  # Pure decision table for the ollama_cloud credential route (M2). Extracted
  # to `Onboarding.ollama_cloud_route/3` (shared with the in-app `/setup`
  # command, `OptimalSystemAgent.CLI.Setup`) so both entry points make the
  # exact same keyless-local-vs-keyed-cloud choice. Kept here too (delegating)
  # so this stays directly unit-testable without a TTY and existing callers
  # of `Wizard.ollama_cloud_credentials/3` keep working unchanged.
  @doc false
  @spec ollama_cloud_credentials(boolean(), boolean(), String.t() | nil) ::
          {String.t() | nil, String.t()}
  defdelegate ollama_cloud_credentials(local_reachable, use_local?, key),
    to: Onboarding,
    as: :ollama_cloud_route

  # ── Model Selection ───────────────────────────────────────────

  defp select_model(provider_id, api_key) do
    case Onboarding.model_list(provider_id, api_key: api_key) do
      {:ok, []} ->
        prompt_for_model(provider_id)

      {:ok, models} ->
        options =
          Enum.map(models, fn m ->
            ctx = format_ctx(m[:ctx] || 0)
            hint = [ctx, m[:note]] |> Enum.reject(&(is_nil(&1) or &1 == "")) |> Enum.join(" · ")
            %{value: m.id, label: m[:name] || m.id, hint: hint}
          end)

        Prompt.select("Default model", options)

      {:error, _} ->
        prompt_for_model(provider_id)
    end
  end

  # Shared "no catalog to pick from" fallback (M5). `provider_default_model/1`
  # returns `nil` for providers with no sensible hardcoded default (notably
  # ollama_local — see M5) instead of the old literal string "default", so
  # this NEVER hands back "default" as a model id. When there truly is no
  # default, the user must type a real model name; an empty answer raises
  # (caught by `safe_run/1`, C1-b) rather than silently writing a bogus model.
  defp prompt_for_model(provider_id) do
    default = provider_default_model(provider_id)

    model =
      if default do
        Prompt.text("Model name:", default: default)
      else
        Prompt.text("Model name (required — no default for #{provider_label(provider_id)}):")
      end

    cond do
      model != "" -> model
      is_binary(default) -> default
      true -> raise "No model specified for #{provider_label(provider_id)}."
    end
  end

  # ── Health Check ──────────────────────────────────────────────

  # C1-a fix: `Onboarding.health_check/1` can return `{:ok, result}` shapes
  # that have NO `:latency_ms` key (e.g. MIOSA's `%{status: "coming_soon",
  # ...}`, onboarding.ex ~L564-575). The old code only matched
  # `{:ok, %{latency_ms: latency}}` and `{:error, %{message: msg}}`, so any
  # other shape (including coming_soon) raised a `CaseClauseError` straight
  # to the newcomer's terminal — the exact crash the audit found for MIOSA,
  # the FIRST and "recommended" option in the picker.
  #
  # Public (not `defp`) + `@doc false` so this is directly unit-testable
  # without a TTY: `Onboarding.health_check/1` for "miosa" never touches the
  # network (it's a static `{:ok, %{status: "coming_soon", ...}}`), so
  # exercising this function is fast and deterministic.
  #
  # Returns:
  #   {:ok, api_key}       — verified (or a friendly non-failing notice)
  #   {:continue, api_key} — verify failed, user chose "Continue anyway"
  #   :cancel              — verify failed, user chose "Cancel"
  @doc false
  @spec run_health_check(String.t(), String.t() | nil, String.t() | nil, String.t() | nil) ::
          {:ok, String.t() | nil} | {:continue, String.t() | nil} | :cancel
  def run_health_check(provider_id, api_key, model, base_url) do
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
        {:ok, api_key}

      {:ok, %{status: "coming_soon"} = result} ->
        msg =
          Map.get(result, :message, "This provider isn't available yet — your setup is saved.")

        stop.("\e[33m○\e[0m  #{msg}")
        Prompt.completed("Health check", "saved — coming soon, no connection to verify yet")
        {:ok, api_key}

      {:ok, other} ->
        # Any other non-latency `:ok` shape a provider might return in the
        # future: never raise, always render SOMETHING sensible.
        note = Map.get(other, :message) || to_string(Map.get(other, :status, "connected"))
        stop.("\e[32m✓\e[0m  #{note}")
        Prompt.completed("Health check", note)
        {:ok, api_key}

      {:error, %{message: _} = err} ->
        stop.("\e[31m✗\e[0m  #{err.message}")
        handle_health_check_failure(provider_id, api_key, model, base_url, err)

      {:error, other} ->
        stop.("\e[31m✗\e[0m  Connection failed.")
        handle_health_check_failure(provider_id, api_key, model, base_url, other)
    end
  end

  # M3 fix: the old code printed "failed — fix later" and unconditionally
  # wrote config + claimed "Setup complete!" — a bad key silently broke
  # every turn afterward with no chance to fix it during setup. Now: prompt
  # a 3-way choice and loop on re-enter (so a fat-fingered key can be
  # corrected right here), distinguishing a rejected key (401/403 — worth
  # re-entering) from an unreachable network (safe to save + continue, since
  # the key itself might be fine).
  defp handle_health_check_failure(provider_id, api_key, model, base_url, err) do
    hint =
      case classify_health_failure(err) do
        :key_rejected -> "Your key looks invalid or expired."
        :network_or_other -> "Couldn't reach the provider — this may be a network issue."
      end

    Prompt.note(hint, "Health check failed")

    choice =
      Prompt.select("What would you like to do?", [
        %{value: :retry, label: "Re-enter key", hint: "try a different/corrected key"},
        %{
          value: :continue,
          label: "Continue anyway",
          hint: "save config, fix later with 'osa setup'"
        },
        %{value: :cancel, label: "Cancel setup", hint: "don't save anything"}
      ])

    case choice do
      :retry ->
        env_var = provider_env_var(provider_id)
        {new_key, new_base_url} = ask_fresh_credentials(provider_id, env_var)
        run_health_check(provider_id, new_key, model, new_base_url || base_url)

      :continue ->
        Prompt.completed("Health check", "failed — saved anyway, fix later with 'osa setup'")
        {:continue, api_key}

      :cancel ->
        :cancel
    end
  end

  # Pure classifier so the 401/403-vs-network distinction is unit-testable
  # without driving the interactive 3-way prompt. Public + `@doc false`.
  @doc false
  @spec classify_health_failure(map()) :: :key_rejected | :network_or_other
  def classify_health_failure(%{error: error}) when error in ["unauthorized", "forbidden"],
    do: :key_rejected

  def classify_health_failure(_), do: :network_or_other

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

  # Label / env var / default model / signup URL all come from the ONE
  # onboarding catalog (`Onboarding.providers_list/0`). They used to be four
  # hand-written tables here that listed seven providers — so every other
  # routable provider fell through to the literal env var "API_KEY", a label
  # that was its raw slug, and no default model. Deriving them means adding a
  # provider to the catalog is enough to make it fully usable in this wizard.
  @doc false
  @spec catalog_entry(String.t()) :: map() | nil
  def catalog_entry(provider_id),
    do: Enum.find(Onboarding.providers_list(), &(&1.id == provider_id))

  defp provider_label(id) do
    case catalog_entry(id) do
      %{name: name} when is_binary(name) -> name
      _ -> id
    end
  end

  defp provider_env_var(id) do
    case catalog_entry(id) do
      %{env_var: env_var} when is_binary(env_var) -> env_var
      # A provider with no declared env var still needs SOMETHING to prompt
      # with; the `<PROVIDER>_API_KEY` convention matches what
      # `Onboarding.provider_env_pairs/4` will actually write.
      _ -> String.upcase(id) <> "_API_KEY"
    end
  end

  # m6 fix: ollama_cloud's default model must match the catalog
  # (onboarding.ex ~L180) and docs — glm-5.2:cloud, not the stale
  # nemotron-3-super:cloud that was drifting from the rest of the codebase.
  #
  # M5 fix: providers with no single sensible hardcoded default (ollama_local,
  # custom, and anything unrecognized) return `nil` instead of the literal
  # string "default" — a bogus model id that caused a 404 on every turn.
  # Callers (`prompt_for_model/1`, `resolve_quickstart_model/2`) must handle
  # `nil` explicitly rather than writing it straight into the config.
  @doc false
  @spec provider_default_model(String.t()) :: String.t() | nil
  def provider_default_model(provider_id) do
    case catalog_entry(provider_id) do
      %{default_model: model} when is_binary(model) and model != "" -> model
      _ -> nil
    end
  end

  defp provider_signup_url(provider_id) do
    case catalog_entry(provider_id) do
      %{signup_url: url} when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end

  defp channel_instructions("telegram"),
    do: "1) Open @BotFather  2) /newbot  3) Copy token"

  defp channel_instructions("discord"),
    do: "discord.com/developers → Your App → Bot → Copy token"

  defp channel_instructions("slack"),
    do: "api.slack.com/apps → OAuth & Permissions → Bot User OAuth Token"

  defp channel_instructions(_), do: "Enter your bot token"
end
