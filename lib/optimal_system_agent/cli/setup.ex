defmodule OptimalSystemAgent.CLI.Setup do
  @moduledoc """
  Interactive CLI setup wizard for first-run onboarding.

  Guides the user through:
  1. Provider selection (Anthropic, OpenAI, Ollama, etc.)
  2. API key input (every cloud provider is API-key only)
  3. Model selection
  4. Optional channel setup (WhatsApp, Telegram, etc.)

  Uses @clack-style prompts from CLI.Prompt.
  """

  alias OptimalSystemAgent.CLI.Prompt
  alias OptimalSystemAgent.Auth.LoginSession
  alias OptimalSystemAgent.Auth.Subscription
  alias OptimalSystemAgent.Onboarding

  defp osa_dir, do: System.get_env("OSA_HOME") || Path.join(System.user_home!(), ".osa")

  # Item 1 (audit) fix: this used to have NO `ollama_cloud` entry at all, so a
  # user running `/setup` (or hitting the REPL first-run, which shares this
  # module — see `Channels.CLI.start/0` and `cmd_setup/2`) could never pick
  # the recommended provider that the good first-run wizard
  # (`mix osa.setup.wizard`) leads with. Added here, matching the wizard's
  # catalog entry (`Onboarding.providers_list/0`).
  # DERIVED from `Onboarding.providers_list/0` — the same catalog the first-run
  # wizard reads. The hand-written version listed seven providers, so a user in
  # `/setup` could not reach Google, xAI, Mistral, Cohere, Cerebras, Fireworks,
  # Together, Perplexity, Replicate, MIOSA, the Chinese providers or the local
  # OpenAI-compatible servers even though the Registry routes every one of them.
  #
  # `:ollama_local` is presented as `:ollama` because that is the atom this
  # module's `get_auth/1` and `write_config/3` clauses already speak.
  @doc false
  # Public so the provider catalog is directly unit-testable without driving
  # the interactive `Prompt.select/2` (TTY).
  def providers do
    Onboarding.providers_list()
    |> Enum.map(fn p ->
      %{value: setup_provider_atom(p.id), label: p.name, hint: p.description}
    end)
    |> Enum.uniq_by(& &1.value)
  rescue
    # A catalog problem must never leave `/setup` with an empty picker.
    _ ->
      [
        %{value: :ollama_cloud, label: "Ollama Cloud", hint: "No GPU needed — recommended"},
        %{value: :anthropic, label: "Anthropic", hint: "Claude models"},
        %{value: :openai, label: "OpenAI", hint: "GPT models"}
      ]
  end

  # Picker id -> the atom this module's clauses dispatch on. Only ids the
  # onboarding catalog declares reach here, so there is no unbounded
  # `String.to_atom` on user input.
  defp setup_provider_atom("ollama_local"), do: :ollama
  defp setup_provider_atom("ollama_cloud"), do: :ollama_cloud
  defp setup_provider_atom("custom"), do: :custom

  defp setup_provider_atom(id) do
    case Onboarding.known_provider_atom(id) do
      {:ok, atom} -> atom
      :error -> :custom
    end
  end

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

    # Warn early if the HTTP port is already taken, so a fresh user is told
    # DURING onboarding rather than "completing setup" then crashing on first
    # launch (the boot preflight would halt). Non-fatal — setup can proceed.
    warn_if_port_unavailable()

    # Step 1: Provider
    # `providers()`, not `@providers`: the latter is an undefined module
    # attribute that silently evaluates to nil, so this picker was being
    # handed nil instead of the provider catalog.
    provider = Prompt.select("Choose your AI provider", providers())

    if is_nil(provider) do
      Prompt.outro("Setup cancelled")
      :skip
    else
      # Step 2: Auth — returns {api_key, base_url}. `base_url` is only ever
      # non-nil for :ollama_cloud (localhost = keyless local daemon route,
      # https://ollama.com = keyed cloud route — item 1 audit fix, M2 parity
      # with the good first-run wizard).
      auth = get_auth(provider)

      # Providers that legitimately need no key: local Ollama, a signed-in
      # local Ollama Cloud route, the local OpenAI-compatible servers, a
      # Custom Endpoint whose server may not require auth at all, and a
      # subscription provider whose credential lives in the credential store
      # rather than in a key.
      {api_key, base_url} = if auth == :cancelled, do: {nil, nil}, else: auth

      if auth == :cancelled or
           (is_nil(api_key) and
              provider not in [
                :ollama,
                :ollama_cloud,
                :lmstudio,
                :llamacpp,
                :custom,
                :openai_codex,
                # Credential lives in the vendor's own CLI, not in OSA at all.
                :claude_cli,
                :copilot_cli
              ]) do
        Prompt.outro("Setup cancelled")
        :skip
      else
        # Step 3: Validate connection — AT ENTRY, with a re-enter loop, so a
        # typo'd key is caught while the user is still looking at the prompt
        # instead of on their first real turn (parity with the first-run
        # wizard's `handle_health_check_failure/5`). Returns the key the user
        # settled on, which may differ from the one first typed.
        api_key = validate_with_retry(provider, api_key)

        # Step 4: Model selection (item 1 audit fix — this wizard used to
        # have NO model-selection step at all; the config it wrote always
        # fell back to the provider's runtime default with no way to pick a
        # specific model, e.g. the recommended glm-5.2:cloud on Ollama Cloud).
        model = select_model(provider, api_key, base_url)

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

  @doc """
  Warn (non-fatally) during onboarding if the configured HTTP port is already
  in use, using the SAME `Net.Port` helper the boot preflight and doctor use.
  Public so the setup wizard can share this one formatting/decision path.
  """
  def warn_if_port_unavailable do
    port = OptimalSystemAgent.Net.Port.configured_http_port()

    unless OptimalSystemAgent.Net.Port.available?(port) do
      message =
        case OptimalSystemAgent.Net.Port.holder_kind(port) do
          :osa ->
            "OSA already appears to be running on port #{port}.\n" <>
              "You can connect to it, or set OSA_HTTP_PORT to run a second instance."

          _ ->
            "Port #{port} is in use by another process.\n" <>
              "Free it (ss -ltnp | grep #{port}) or set OSA_HTTP_PORT=<other>\n" <>
              "before launching OSA — otherwise it won't start."
        end

      Prompt.note(message, "Heads up: port #{port} is busy")
    end

    :ok
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
  # Now driven off the catalog's `auth_modes` like every other dual-mode
  # provider, so the account route is a real, verified sign-in rather than a
  # bespoke "is a daemon listening?" branch. Two things changed:
  #
  #   * the account option is offered even when no daemon is answering, and
  #     `Auth.Providers.OllamaAccount.login/1` names the command that fixes it
  #     (`ollama serve` / `ollama signin`). The old branch hid the option, so a
  #     user with the daemon stopped was silently told the only way in was a key.
  #   * choosing it now VERIFIES the daemon is signed in and records a marker,
  #     instead of assuming that a reachable daemon is an authenticated one.
  #
  # The key half is untouched: same prompt, same `ollama_cloud_route/3`
  # decision, same `https://ollama.com` endpoint.
  defp get_auth(:ollama_cloud) do
    id = "ollama_cloud"
    modes = Onboarding.usable_auth_modes(id)

    choice =
      case Onboarding.auth_options(id) do
        [] -> nil
        options -> Prompt.select("How do you want to connect?", options)
      end

    case Onboarding.auth_route_for(modes, choice) do
      :oauth ->
        sign_in(id, modes, :ollama_cloud)

      :api_key ->
        key = ask_ollama_cloud_key()
        Onboarding.ollama_cloud_route(false, false, key)
    end
  end

  # NOTE: there is deliberately no `get_auth(:anthropic)` clause. Anthropic used
  # to fork here into "Sign in with Anthropic" (OAuth) vs "Paste an API key";
  # the sign-in branch was removed (see
  # `OptimalSystemAgent.Auth.LegacyAnthropicOAuth`) so Anthropic now falls
  # through to the generic API-key clause below like every other cloud provider.

  # Custom Endpoint is the one entry that is USELESS without a base URL — it is
  # defined by the URL. Asking for the key and silently dropping the URL is how
  # a self-hosted/proxy key ended up being sent to api.openai.com.
  defp get_auth(:custom) do
    base_url = Prompt.text("Base URL (e.g. https://api.together.ai/v1)")
    key = Prompt.text("API key (leave blank if the server needs none)", mask: true)

    {
      if(key && String.trim(key) != "", do: String.trim(key), else: nil),
      if(base_url && String.trim(base_url) != "", do: String.trim(base_url), else: nil)
    }
  end

  # Local OpenAI-compatible servers need no key at all — prompting for one is a
  # dead end the user cannot satisfy.
  defp get_auth(provider) when provider in [:lmstudio, :llamacpp] do
    Prompt.note("#{provider_name(provider)} runs locally — no API key needed.", "Local Provider")
    {nil, nil}
  end

  # The dual-mode fork, driven entirely off the catalog's `auth_modes` via
  # `Onboarding.auth_options/1` + `auth_route_for/2` — the SAME pure decision
  # functions `mix osa.setup.wizard` calls, so the two entry points cannot
  # drift apart on what they offer or what a choice means.
  #
  # A key-only provider gets `[]` back and falls straight through to the key
  # prompt below: no extra question, no extra keystroke, byte-identical to
  # the behaviour before `auth_modes` existed.
  defp get_auth(provider) do
    id = onboarding_provider_id(provider)
    modes = Onboarding.usable_auth_modes(id)

    choice =
      case Onboarding.auth_options(id) do
        [] -> nil
        options -> Prompt.select("How do you want to connect?", options)
      end

    case Onboarding.auth_route_for(modes, choice) do
      :oauth -> sign_in(id, modes, provider)
      :api_key -> ask_api_key(provider)
    end
  end

  # Run a provider's account sign-in. On failure the user is told exactly what
  # happened and, when the provider also accepts a key, offered that route
  # instead — the whole point of the fork is that either path reaches the same
  # configured state, so a user blocked here is never stuck.
  #
  # There is deliberately no AUTOMATIC fallback to the key path: silently
  # switching someone's billing model is worse than a clear error.
  defp sign_in(id, modes, provider) do
    name = provider_display_name(id)

    # `on_tick` is what makes the wait cancellable and visibly alive. Without
    # it a device-code poll blocks this process in silence for up to fifteen
    # minutes, Esc does nothing, and Ctrl-C takes down the VM rather than the
    # sign-in. `with_cancellation/2` scopes the SIGINT trap to this call.
    result =
      LoginSession.with_cancellation(id, fn ->
        Subscription.login(id, io: &IO.puts/1, on_tick: LoginSession.on_tick(id))
      end)

    case result do
      {:ok, entry} ->
        Prompt.completed("Credentials", "signed in to #{name}")
        {nil, connected_base_url(entry, id)}

      {:error, reason} ->
        IO.puts("")
        IO.puts("\e[33m  #{Subscription.message(reason, name)}\e[0m")

        if :api_key in modes and Prompt.confirm("Use an API key instead?") do
          ask_key_for(provider)
        else
          :cancelled
        end
    end
  end

  # The endpoint the sign-in itself pinned, if it pinned one. `ollama_cloud`
  # does: its account mode talks to the LOCAL daemon, which is a different
  # endpoint from the catalog `base_url` the keyed mode uses, and which one is
  # correct is decided by the mode — not by the entry. Providers that pin
  # nothing fall back to the catalog exactly as before.
  defp connected_base_url(entry, id) when is_map(entry) do
    case Map.get(entry, "base_url") do
      url when is_binary(url) and url != "" -> url
      _ -> subscription_base_url(id)
    end
  end

  defp connected_base_url(_entry, id), do: subscription_base_url(id)

  # Ollama Cloud's key prompt is its own (it names the product and resolves the
  # keyed endpoint), so the "use a key instead" escape hatch after a failed
  # sign-in must land on the same prompt the key mode uses — not a generic one
  # that would leave the base URL unset.
  defp ask_key_for(:ollama_cloud) do
    Onboarding.ollama_cloud_route(false, false, ask_ollama_cloud_key())
  end

  defp ask_key_for(provider), do: ask_api_key(provider)

  defp provider_display_name(id) do
    case Enum.find(Onboarding.providers_list(), &(&1.id == id)) do
      %{name: name} -> name
      _ -> id
    end
  end

  # The endpoint pinned into the credential at sign-in time, never one
  # resolved later from the settings cascade.
  defp subscription_base_url(id) do
    case Enum.find(Onboarding.providers_list(), &(&1.id == id)) do
      # A dual-mode provider whose two modes have different endpoints declares
      # the sign-in one under `:subscription`; `:base_url` on the entry is the
      # key mode's and would be the wrong answer here.
      %{subscription: %{base_url: url}} when is_binary(url) and url != "" -> url
      %{base_url: url} when is_binary(url) -> url
      _ -> nil
    end
  end

  defp ask_api_key(provider) do
    placeholder =
      case provider do
        :openai -> "sk-..."
        :groq -> "gsk_..."
        :openrouter -> "sk-or-..."
        :deepseek -> "sk-..."
        :anthropic -> "sk-ant-api03-..."
        :google -> "AIza..."
        :xai -> "xai-..."
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
  # `base_url` is passed through because for `ollama_cloud` it is what says
  # WHICH mode was taken: a loopback URL means the account route, and the
  # daemon then answers authoritatively which cloud models that account can
  # reach. Every other provider ignores it exactly as before.
  defp select_model(provider, api_key, base_url) do
    onboarding_id = onboarding_provider_id(provider)

    case Onboarding.model_list(onboarding_id, api_key: api_key, base_url: base_url) do
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
  defp onboarding_provider_id(:custom), do: "custom"
  defp onboarding_provider_id(provider), do: to_string(provider)

  # ── Validation ───────────────────────────────────────────────────

  # Validate the key AT ENTRY and, when the provider explicitly REJECTED it
  # (401/403 — as opposed to an unreachable network, which says nothing about
  # the key), offer to re-enter rather than saving a key we already know is
  # dead. Bounded retries so a user who keeps pasting the same bad key still
  # reaches a working "save anyway" exit instead of an infinite prompt loop.
  defp validate_with_retry(provider, key, attempts_left \\ 2)

  defp validate_with_retry(provider, key, 0) do
    validate_provider(provider, key)
    key
  end

  defp validate_with_retry(provider, key, attempts_left) when is_binary(key) do
    IO.puts("\e[2m│  Verifying connection...\e[0m")

    case test_provider(provider, key) do
      :ok ->
        Prompt.completed("Connection", "Verified ✓")
        key

      :unverified ->
        Prompt.completed("Connection", "Saved (not verified)")
        IO.puts("\e[2m│  Couldn't test this provider automatically — if the key is\e[0m")
        IO.puts("\e[2m│  wrong you'll see an error on your first message.\e[0m")
        key

      {:key_rejected, reason} ->
        IO.puts("\e[31m│  ✗ #{reason}\e[0m")

        choice =
          Prompt.select("What would you like to do?", [
            %{value: :retry, label: "Re-enter key", hint: "try a different/corrected key"},
            %{
              value: :continue,
              label: "Continue anyway",
              hint: "save config, fix later with /setup"
            }
          ])

        if choice == :retry do
          # `get_auth/1` can answer `:cancelled` for a dual-mode provider whose
          # sign-in failed and whose key offer was declined. Keep the key we
          # already have rather than crashing the wizard on a match.
          new_key =
            case get_auth(provider) do
              {k, _base_url} -> k
              _ -> nil
            end

          validate_with_retry(provider, new_key || key, attempts_left - 1)
        else
          Prompt.completed("Connection", "not verified — saved anyway")
          key
        end

      {:error, reason} ->
        IO.puts("\e[33m│  ⚠ Connection test failed: #{reason}\e[0m")
        IO.puts("\e[2m│  You can continue — the key will be saved.\e[0m")
        key
    end
  end

  defp validate_with_retry(_provider, key, _attempts_left), do: key

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

      {:key_rejected, reason} ->
        IO.puts("\e[31m│  ✗ #{reason}\e[0m")
        IO.puts("\e[2m│  Re-run /setup with a corrected key.\e[0m")

      {:error, reason} ->
        IO.puts("\e[33m│  ⚠ Connection test failed: #{reason}\e[0m")
        IO.puts("\e[2m│  You can continue — the key will be saved.\e[0m")
    end
  end

  def validate_provider(_, _), do: :ok

  # A key the provider EXPLICITLY rejected (401/403) is a different fact from
  # "we couldn't reach the provider", and only the first is worth asking the
  # user to re-type. Same three-way split `Onboarding.health_check/1` makes,
  # and the same wording, so the message is identical whichever surface the
  # user came through.
  @rejected_message "API key is invalid or expired."

  @doc false
  @spec classify_status(integer()) :: :ok | {:key_rejected, String.t()} | {:error, String.t()}
  def classify_status(status) when status in 200..299, do: :ok
  def classify_status(401), do: {:key_rejected, @rejected_message}
  def classify_status(403), do: {:key_rejected, "Access denied. Check your API key permissions."}

  def classify_status(402),
    do: {:key_rejected, "Insufficient credits on this account."}

  def classify_status(status), do: {:error, "HTTP #{status}"}

  defp classify_response({:ok, %{status: status}}), do: classify_status(status)
  defp classify_response({:error, reason}), do: {:error, inspect(reason)}

  @doc false
  # Public so F4's "actually probe the provider" behavior is directly
  # unit-testable; still internal API (not meant for external callers).
  # `opts` is a Req option passthrough (e.g. `plug:` for `Req.Test`) so the
  # 401-vs-network split is testable without real network access.
  def test_provider(provider, key, opts \\ [])

  def test_provider(:anthropic, key, opts) do
    Req.post(
      [
        url: "https://api.anthropic.com/v1/messages",
        json: %{
          model: OptimalSystemAgent.Providers.AnthropicModels.default_model(),
          max_tokens: 1,
          messages: [%{role: "user", content: "hi"}]
        },
        headers: [
          {"x-api-key", key},
          {"anthropic-version", "2023-06-01"},
          {"content-type", "application/json"}
        ],
        receive_timeout: 10_000
      ] ++ opts
    )
    |> classify_response()
  end

  def test_provider(:openai, key, opts) do
    # `GET /v1/models` is authoritative for what this key can reach — the same
    # call `Onboarding.model_list/2` uses to narrow the picker.
    probe_get("https://api.openai.com/v1/models", [{"authorization", "Bearer #{key}"}], opts)
  end

  def test_provider(:groq, key, opts) do
    probe_get("https://api.groq.com/openai/v1/models", [{"authorization", "Bearer #{key}"}], opts)
  end

  def test_provider(:openrouter, key, opts) do
    # OpenRouter's documented key-introspection endpoint — returns key/credit
    # info on a valid key, 401 on a bad one.
    probe_get("https://openrouter.ai/api/v1/key", [{"authorization", "Bearer #{key}"}], opts)
  end

  def test_provider(:deepseek, key, opts) do
    # DeepSeek's balance endpoint doubles as a cheap, no-token-cost key check.
    probe_get("https://api.deepseek.com/user/balance", [{"authorization", "Bearer #{key}"}], opts)
  end

  # Everything else now goes through `Onboarding.health_check/1`, which since
  # the multi-provider pass has a REAL, correctly-targeted endpoint for every
  # routable provider (Google's `:generateContent`, Cohere's `/v2/chat`,
  # Replicate's `/account`, and each OpenAI-compatible provider's OWN base URL
  # — never a fallback to api.openai.com). `:unverified` is now reserved for
  # providers we genuinely cannot probe, instead of being the answer for
  # two-thirds of the catalog.
  def test_provider(provider, key, opts) do
    params =
      %{
        "provider" => onboarding_provider_id(provider),
        "api_key" => key,
        # This is the verify step of a setup run the user is sitting in front
        # of, so the externally-managed providers may create their connection
        # marker here. See `Onboarding.during_setup?/1` for why every caller
        # has to say so explicitly.
        "during_setup" => true
      }
      |> then(fn p ->
        case Keyword.get(opts, :plug) do
          nil -> p
          plug -> Map.put(p, "req_plug", plug)
        end
      end)

    case Onboarding.health_check(params) do
      {:ok, _} -> :ok
      {:error, %{verified: :key_rejected, message: msg}} -> {:key_rejected, msg}
      {:error, %{error: "no_endpoint"}} -> :unverified
      {:error, %{message: msg}} -> {:error, msg}
      {:error, _} -> :unverified
    end
  rescue
    _ -> :unverified
  catch
    _, _ -> :unverified
  end

  defp probe_get(url, headers, opts) do
    Req.get([url: url, headers: headers, receive_timeout: 10_000] ++ opts)
    |> classify_response()
  end

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

    apply_live(provider, api_key, model, pairs)
  end

  # Make the just-written config take effect in THIS node — no restart hunt.
  #
  # Three things were missing here and each one on its own is enough to make a
  # freshly entered key look ignored:
  #
  #   1. `Application.put_env(:default_provider, provider)` stored the PICKER's
  #      id. `:ollama_cloud` is not a runtime provider atom (the .env correctly
  #      gets `OSA_DEFAULT_PROVIDER=ollama`), so `Runtime.Identity.provider/0`
  #      — the single source the status bar and `/health` both read — reported
  #      a provider that resolves nowhere.
  #   2. The OS env var was never set, only the Application key. Every live
  #      re-read path (`Onboarding.live_env/1`, `Registry.live_cloud_key_present?/1`,
  #      `Onboarding.detect_existing/0`) checks `System.get_env` first.
  #   3. `CredentialPool` was never reloaded, and its `get_key/1` OUTRANKS
  #      Application env in `Providers.Anthropic.resolve_auth/0` — so a key
  #      corrected here lost to the one snapshotted at boot.
  defp apply_live(provider, api_key, model, pairs) do
    Application.put_env(:optimal_system_agent, :default_provider, runtime_provider_atom(provider))

    # Mirror every persisted pair into the live OS environment.
    Enum.each(pairs, fn {k, v} -> if is_binary(v) and v != "", do: System.put_env(k, v) end)

    # A base URL only takes effect through the `:<provider>_url` application
    # key — `OpenAICompatProvider` never reads OPENAI_BASE_URL directly. Writing
    # only the env var is how a Custom Endpoint kept dialling api.openai.com
    # until the next restart.
    case List.keyfind(pairs, "OPENAI_BASE_URL", 0) do
      {_, url} when is_binary(url) and url != "" ->
        Application.put_env(:optimal_system_agent, :openai_url, url)

      _ ->
        :ok
    end

    if api_key do
      Application.put_env(:optimal_system_agent, provider_config_key(provider), api_key)
      _ = OptimalSystemAgent.Providers.CredentialPool.reload()
    end

    if model do
      Application.put_env(:optimal_system_agent, :default_model, model)

      if provider in [:ollama, :ollama_cloud] do
        Application.put_env(:optimal_system_agent, :ollama_model, model)
      end
    end

    :ok
  end

  # The picker's provider id vs. the atom the rest of OSA resolves. Mirrors
  # `Onboarding.apply_env_vars/4`'s mapping so the two setup entry points can't
  # disagree about what "Ollama Cloud" means.
  @doc false
  @spec runtime_provider_atom(atom()) :: atom()
  def runtime_provider_atom(:ollama_cloud), do: :ollama
  def runtime_provider_atom(:custom), do: :openai
  def runtime_provider_atom(provider), do: provider

  # Returns `{osa_default_provider_value, [{env_key, value}]}` for the given
  # provider selection. `nil` model/api_key are simply omitted (never write a
  # blank/placeholder value).
  defp provider_pairs(:ollama_cloud, api_key, model, base_url) do
    url = base_url || "https://ollama.com"

    pairs =
      [{"OLLAMA_URL", url}] ++
        if(api_key, do: [{"OLLAMA_API_KEY", api_key}], else: []) ++
        if model, do: [{"OLLAMA_MODEL", model}], else: []

    {"ollama", pairs}
  end

  defp provider_pairs(:ollama, _api_key, model, _base_url) do
    pairs = if model, do: [{"OLLAMA_MODEL", model}], else: []
    {"ollama", pairs}
  end

  # Custom Endpoint = the OpenAI-compatible client pointed somewhere else. The
  # base URL is the whole point, so it is persisted (OPENAI_BASE_URL, which
  # `config/runtime.exs` reads back into `:openai_url`) rather than dropped.
  defp provider_pairs(:custom, api_key, model, base_url) do
    pairs =
      if(api_key, do: [{"OPENAI_API_KEY", api_key}], else: []) ++
        if(base_url, do: [{"OPENAI_BASE_URL", base_url}], else: []) ++
        if model, do: [{"OSA_MODEL", model}], else: []

    {"openai", pairs}
  end

  defp provider_pairs(provider, api_key, model, _base_url) do
    pairs =
      if(api_key, do: [{provider_env_key(provider), api_key}], else: []) ++
        if model, do: [{"OSA_MODEL", model}], else: []

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

  # `:ollama_cloud` is a picker id, not a runtime provider — its key lives under
  # `:ollama_api_key` like every other Ollama route (the generic
  # `:"#{p}_api_key"` fallback would have stashed it at `:ollama_cloud_api_key`,
  # where nothing reads it).
  defp provider_config_key(:ollama_cloud), do: :ollama_api_key
  defp provider_config_key(:custom), do: :openai_api_key
  defp provider_config_key(:anthropic), do: :anthropic_api_key
  defp provider_config_key(:openai), do: :openai_api_key
  defp provider_config_key(:groq), do: :groq_api_key
  defp provider_config_key(:openrouter), do: :openrouter_api_key
  defp provider_config_key(:deepseek), do: :deepseek_api_key
  defp provider_config_key(p), do: :"#{p}_api_key"
end
