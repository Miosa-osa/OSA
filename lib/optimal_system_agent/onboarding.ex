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

  alias OptimalSystemAgent.System.AtomicFile

  defp osa_dir, do: System.get_env("OSA_HOME") || Path.join(System.user_home!(), ".osa")

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
    env_file = Path.join(osa_dir(), ".env")

    # Simple: if ~/.osa/.env exists with a valid provider, onboarding is done.
    # Even if the user has API keys in their shell, they still need to go
    # through the wizard once so workspace files get seeded and they confirm
    # their setup. The wizard shows detected keys so they can just confirm.
    not (File.exists?(env_file) and env_has_provider?(env_file))
  end

  @doc """
  Live-read a single env var: checks the process's live `System.get_env`
  first (covers exported shell vars and anything set via `System.put_env`
  since boot), then falls back to re-parsing `./.env` and `~/.osa/.env`
  straight off disk.

  Exists so provider/key resolution never has to trust a boot-time
  `Application.get_env` snapshot alone — that goes stale the instant a
  *different* OS process (the standalone CLI setup wizard `bin/osa` shells
  out to, `osa setup`, a hand edit) writes `~/.osa/.env` while this node
  keeps running. Mirrors the precedence `config/runtime.exs` uses at boot
  (explicit env wins over `.env`, project `.env` wins over `~/.osa/.env`),
  just re-evaluated on every call instead of once.

  The `.env`-file fallback is disabled in `:test` (`config :optimal_system_agent,
  :live_env_file_fallback, false` in `config/test.exs`) — same reason
  `config/runtime.exs` skips loading `.env` files under `config_env() ==
  :test`: the suite must never read the OPERATOR's real `~/.osa/.env` and
  become flaky depending on whose machine runs it. `System.get_env` is still
  checked (tests exercise that path explicitly via `System.put_env`).
  """
  @spec live_env(String.t()) :: String.t() | nil
  def live_env(key) when is_binary(key) do
    case System.get_env(key) do
      v when is_binary(v) and v != "" ->
        v

      _ ->
        if env_file_fallback_enabled?() do
          [Path.expand(".env"), Path.join(osa_dir(), ".env")]
          |> Enum.find_value(fn path ->
            if File.exists?(path) do
              case List.keyfind(parse_env_file(path), key, 0) do
                {^key, v} when is_binary(v) and v != "" -> v
                _ -> nil
              end
            end
          end)
        end
    end
  rescue
    _ -> nil
  end

  defp env_file_fallback_enabled? do
    Application.get_env(:optimal_system_agent, :live_env_file_fallback, true)
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

    %{detected: detected ++ detect_subscriptions(detected), ollama_local: ollama_local}
  end

  # A connected account is "already configured" every bit as much as a key in
  # the environment is, so the picker must badge it the same way — otherwise a
  # user who signed in last week comes back, sees no ✓ against the provider,
  # and concludes nothing is wired up.
  #
  # Env keys are detected FIRST and win the dedupe: if a user has both, the key
  # they explicitly set is the one shown, matching the resolution order (an
  # explicitly-set credential is never shadowed by an auto-discovered one).
  #
  # Pure read — `Subscription.status/1` never touches the network, so drawing
  # the provider picker can never hang on, or be failed by, a token refresh.
  defp detect_subscriptions(already_detected) do
    keyed = MapSet.new(already_detected, & &1.provider)

    OptimalSystemAgent.Auth.Subscription.status_all()
    |> Enum.filter(&(&1.connected? and not MapSet.member?(keyed, &1.provider)))
    |> Enum.map(fn status ->
      %{
        provider: status.provider,
        source: "subscription",
        mode: :oauth,
        key_preview: subscription_preview(status)
      }
    end)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp subscription_preview(%{expired?: true}), do: "sign-in expired"
  defp subscription_preview(%{account: a}) when is_binary(a) and a != "", do: "connected as #{a}"
  defp subscription_preview(_), do: "connected"

  @doc "Return the full provider catalog for the onboarding UI."
  def providers_list do
    [
      %{
        id: "miosa",
        name: "MIOSA",
        description: "Custom + trained models, run your own harness",
        group: "recommended",
        requires_key: true,
        env_var: "MIOSA_API_KEY",
        default_model: "nemotron-3-miosa",
        base_url: "https://optimal.miosa.ai/v1",
        signup_url: "https://miosa.ai/settings/keys",
        # MIOSA Cloud is gated during early access. Surfaced at the top of the
        # picker so users can discover it, but marked coming_soon so the UI can
        # render a badge and health_check returns a friendly notice (not a hard
        # failure) instead of pretending the endpoint is live.
        availability: :limited,
        status: "coming_soon",
        badge: "Limited access — request at miosa.ai",
        models: :dynamic
      },
      %{
        id: "ollama_cloud",
        name: "Ollama Cloud",
        description: "No GPU needed — recommended",
        group: "recommended",
        recommended: true,
        requires_key: true,
        # Key is optional: a signed-in local Ollama daemon proxies `:cloud`
        # models via device identity (no key). The picker treats this provider
        # as ready when either an OLLAMA_API_KEY exists OR local Ollama is up.
        key_optional: true,
        env_var: "OLLAMA_API_KEY",
        default_model: "glm-5.2:cloud",
        base_url: "https://ollama.com",
        signup_url: "https://ollama.com/account/keys",
        # The only entry with BOTH modes, and the only one where `:oauth` is a
        # second way into an existing provider rather than a provider of its
        # own (pattern A, as opposed to the `openai`/`openai_codex` split):
        # both modes reach the same Ollama Cloud models, so nothing but the
        # credential differs. The API-key half below is untouched — same
        # `env_var`, same `base_url`, same catalog — so a user who pastes a key
        # takes exactly the path they took before this field existed.
        #
        # `subscription.base_url` is the account mode's endpoint: the LOCAL
        # daemon, which proxies `:cloud` tags with this machine's device key.
        # It is separate from the entry's `base_url` (ollama.com, the keyed
        # endpoint) precisely because the two modes do not share one.
        auth_modes: [:api_key, :oauth],
        subscription: %{
          kind: :local_daemon,
          label: "Use my signed-in Ollama account",
          hint: "Your local Ollama daemon proxies cloud models — no key, uses your Ollama plan",
          key_label: "Paste an Ollama Cloud API key",
          key_hint: "Pay-per-token billing against ollama.com",
          base_url: "http://127.0.0.1:11434"
        },
        # Current Ollama Cloud catalog. All run with no local GPU/download —
        # Ollama offloads to its cloud. `:cloud` tags require either an Ollama
        # Cloud key or a signed-in device identity.
        #
        # SINGLE SOURCE OF TRUTH: `Providers.OllamaCloud` (context windows,
        # capabilities, pricing, notes). Add new cloud models THERE — this list
        # is derived, and so are the Registry context-window table, the pricing
        # table and the Ollama tool/thinking gating.
        models: OptimalSystemAgent.Providers.OllamaCloud.picker_models()
      },
      %{
        id: "ollama_local",
        name: "Ollama Local",
        description: "Private — needs a local GPU",
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
        group: "recommended",
        requires_key: true,
        env_var: "OPENROUTER_API_KEY",
        default_model:
          "anthropic/" <> OptimalSystemAgent.Providers.AnthropicModels.default_model(),
        base_url: "https://openrouter.ai/api/v1",
        signup_url: "https://openrouter.ai/keys",
        # Any vendor/model id may be entered free-text; model_list/2 also fetches
        # the live OpenRouter catalog. These are curated defaults/fallbacks.
        allow_free_text: true,
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
        default_model: OptimalSystemAgent.Providers.AnthropicModels.default_model(),
        base_url: "https://api.anthropic.com",
        signup_url: "https://console.anthropic.com/account/keys",
        models: OptimalSystemAgent.Providers.AnthropicModels.picker_models()
      },
      %{
        id: "openai",
        name: "OpenAI",
        description: "GPT direct",
        group: "bring_your_own",
        requires_key: true,
        env_var: "OPENAI_API_KEY",
        default_model: OptimalSystemAgent.Providers.OpenAIModels.default_model(),
        base_url: "https://api.openai.com/v1",
        signup_url: "https://platform.openai.com/api-keys",
        models: OptimalSystemAgent.Providers.OpenAIModels.picker_models()
      },
      # ChatGPT plan sign-in. A SEPARATE entry from `openai` rather than a
      # second auth mode on it, because the two differ in more than the
      # credential — different base URL, different wire protocol (Responses vs
      # chat/completions) and a Codex-only model list. Same reasoning as the
      # existing `ollama_cloud` / `ollama_local` split.
      #
      # `auth_modes: [:oauth]` — there is deliberately NO key path here. An
      # OpenAI API key belongs on the `openai` entry, where it bills
      # per-token against the endpoint that accepts it.
      %{
        id: "openai_codex",
        name: "ChatGPT (Codex)",
        description: "Use your ChatGPT Plus/Pro plan — no per-token billing",
        group: "recommended",
        requires_key: false,
        env_var: nil,
        default_model: OptimalSystemAgent.Providers.OpenAICodex.default_model(),
        base_url: "https://chatgpt.com/backend-api/codex",
        signup_url: "https://chatgpt.com/",
        auth_modes: [:oauth],
        subscription: %{
          kind: :device_code,
          label: "Sign in with ChatGPT",
          hint: "Uses your ChatGPT plan — no per-token billing"
        },
        models: :dynamic
      },
      # Claude Pro/Max plan through Anthropic's own CLI. A separate entry from
      # `anthropic` because nothing about it is the same call: the transport
      # is a subprocess, not HTTPS, and the model names are Claude Code's
      # aliases rather than API model ids. `anthropic` is untouched and
      # remains the pay-per-token, API-key route sitting next to this one.
      #
      # `auth_modes: [:oauth]` describes the *shape of the question* the setup
      # surfaces ask ("connect an account" vs "paste a key"), not the
      # mechanism: there is no OAuth client here and OSA never holds a
      # credential. `usable_auth_modes_for/1` drops the option entirely on a
      # machine with no `claude` binary, so the picker never offers a path
      # that cannot complete.
      %{
        id: "claude_cli",
        name: "Claude subscription (via Claude Code)",
        description: "Use your Claude Pro/Max plan — runs Anthropic's CLI locally",
        group: "recommended",
        requires_key: false,
        env_var: nil,
        default_model: OptimalSystemAgent.Providers.ClaudeCli.default_model(),
        base_url: nil,
        signup_url: "https://claude.com/product/claude-code",
        auth_modes: [:oauth],
        subscription: %{
          kind: :external_cli,
          label: "Use my Claude Code sign-in",
          hint: "Requires the Claude Code CLI; OSA runs it and never sees your credential"
        },
        # Aliases, not dated model ids — the CLI decides which concrete model
        # an alias resolves to, and OSA reports that back after the first
        # call rather than claiming to know it up front. `ctx: 0` is not a
        # placeholder for a number nobody filled in: it is how the picker is
        # told there is no context window to display, which is the truthful
        # answer for a model whose identity is chosen downstream.
        # `fable` was absent until `claude --help` was read back — it names
        # "'fable', 'opus', or 'sonnet'" as its own examples, so a subscriber
        # could run it and OSA never offered it.
        models: [
          %{
            id: "fable",
            name: "Fable",
            ctx: 0,
            tools: true,
            recommended?: false,
            note: "Newest — resolves to the current claude-fable-*"
          },
          %{
            id: "sonnet",
            name: "Sonnet",
            ctx: 0,
            tools: true,
            recommended?: true,
            note: "Balanced — Claude Code's default"
          },
          %{
            id: "opus",
            name: "Opus",
            ctx: 0,
            tools: true,
            recommended?: false,
            note: "Most capable"
          },
          %{
            id: "haiku",
            name: "Haiku",
            ctx: 0,
            tools: true,
            recommended?: false,
            note: "Fastest, cheapest against your plan"
          }
        ]
      },
      # GitHub Copilot plan, driven through GitHub's own CLI. Separate entry
      # for the same reason as `claude_cli`: the transport is a subprocess,
      # not an HTTP API, and the model catalogue is per-account.
      #
      # `models: :dynamic` and a default of "auto" are load-bearing, not
      # laziness — Copilot's router picks the model, its catalogue differs per
      # account, and the `--model` flag validates against a DIFFERENT list
      # than the router uses (see `Providers.CopilotCli`).
      %{
        id: "copilot_cli",
        name: "GitHub Copilot (via Copilot CLI)",
        description: "Use your Copilot plan — runs GitHub's CLI locally",
        group: "recommended",
        requires_key: false,
        env_var: nil,
        default_model: OptimalSystemAgent.Providers.CopilotCli.default_model(),
        base_url: nil,
        signup_url: "https://github.com/features/copilot",
        auth_modes: [:oauth],
        subscription: %{
          kind: :external_cli,
          label: "Use my Copilot CLI sign-in",
          hint: "Requires GitHub's Copilot CLI; OSA runs it and never sees your credential"
        },
        models: :dynamic
      },
      # Amazon Bedrock. ONE entry with BOTH modes (pattern A), not a split
      # pair, and the test for which pattern applies is whether anything
      # besides the credential differs: here nothing does. Same host, same
      # model ids, same Converse request, same catalogue — a bearer key and a
      # SigV4-signed AWS identity are two ways to prove who you are to the
      # identical endpoint. Contrast `openai`/`openai_codex`, which are split
      # precisely because the base URL, the wire protocol and the model list
      # all change with the credential.
      #
      # `requires_key: true` with `key_optional: true` is the SAME pairing
      # `ollama_cloud` uses, and it is what makes the account mode reachable
      # from the TUI. The TUI's onboarding dialog decides whether to render a
      # credential field from `requires_key` alone; `requires_key: false`
      # would skip that screen entirely and take the bearer-key mode away from
      # TUI users. With the field present, `auth_modes` containing `:oauth`
      # makes it render "leave blank to use your signed-in account instead",
      # which is how the account mode is chosen there. Both CLI surfaces are
      # unaffected — they fork on `auth_modes` before any key is requested.
      %{
        id: "bedrock",
        name: "Amazon Bedrock",
        description: "Claude, Nova and Llama billed to your own AWS account",
        group: "bring_your_own",
        requires_key: true,
        key_optional: true,
        # AWS's own variable name, not a `BEDROCK_API_KEY` of OSA's invention
        # — a user who exported it for the AWS CLI should not have to export
        # it again under a second name.
        env_var: "AWS_BEARER_TOKEN_BEDROCK",
        default_model: OptimalSystemAgent.Providers.Bedrock.default_model(),
        # Region-dependent, so there is no single correct value to put here.
        # The real endpoint is pinned into the connection marker at connect
        # time from the resolved region; this is only what the picker shows.
        base_url: nil,
        signup_url: "https://console.aws.amazon.com/bedrock/home#/modelaccess",
        auth_modes: [:api_key, :oauth],
        subscription: %{
          kind: :aws_credential_chain,
          label: "Use my AWS credentials",
          hint: "Signs with the same credentials as the AWS CLI — OSA never stores them",
          key_label: "Paste an Amazon Bedrock API key",
          key_hint: "A bearer token from the Bedrock console; needs AWS_REGION set"
        },
        # From the account's own ListFoundationModels, so the picker can only
        # offer models this account has actually been granted. A hardcoded
        # list would advertise models that 403 on first use, several screens
        # away from the mistake.
        models: :dynamic
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
    |> Kernel.++(additional_providers())
    |> Enum.map(&normalize_auth_modes/1)
    |> Enum.with_index()
    |> Enum.map(fn {entry, idx} -> normalize_grouping(entry, idx) end)
  end

  # ── tab/order: how a setup surface GROUPS the catalog ─────────────────────
  #
  # `auth_modes` says what a provider *can* do; `tab` says which of the two
  # questions a user is answering when they look at it — "connect an account"
  # or "paste a key". A flat list of 31 providers is why account-capable
  # entries were indistinguishable from key-only ones on screen, and why a
  # provider that offers ONLY sign-in (`openai_codex`) could read as "needs
  # key".
  #
  # It is a FIELD, not a derivation, because the two do come apart: a provider
  # can be keyless (an ambient machine credential, e.g. `bedrock`'s AWS chain)
  # and still belong under "keys" because the user is not being asked to
  # connect anything. Deriving it from `auth_modes` would make that
  # unrepresentable. The default below is the derivation, so no existing entry
  # has to say anything; an entry that disagrees just sets `tab:` itself.
  #
  # `order` defaults to catalog position, which is already curated (the
  # recommended entries lead), so a UI can sort by it without reproducing a
  # second, drifting priority list of its own.
  defp normalize_grouping(entry, idx) when is_map(entry) do
    default_tab =
      if :oauth in Map.get(entry, :auth_modes, [:api_key]), do: "accounts", else: "keys"

    entry
    |> Map.put_new(:tab, default_tab)
    |> Map.put_new(:order, idx)
  end

  # ── auth_modes: the SINGLE capability source of truth ─────────────────────
  #
  # Every setup surface (`osa setup`, `mix osa.setup.wizard`, the TUI's
  # GET /onboarding/status, `/model`) reads the fork from THIS field and
  # nowhere else.
  #
  # The alternative — a separate "which providers support sign-in" list per
  # surface — is the exact failure mode observed in the tool this was modelled
  # on, which grew three such lists that disagreed with each other: a provider
  # was `api_key` in its registry, landed in the GUI's *keys* tab, and yet had
  # the most elaborate subscription-vs-key menu in its CLI. Declaring the
  # capability ON the provider entry makes disagreement unrepresentable.
  #
  # Defaulting here (rather than writing `auth_modes: [:api_key]` 27 times) is
  # what guarantees the refactor is behaviour-preserving: a provider that says
  # nothing keeps exactly the key-only flow it had before this field existed,
  # and a NEW provider added to @additional_providers cannot accidentally
  # acquire a sign-in prompt it has no implementation for.
  defp normalize_auth_modes(entry) when is_map(entry) do
    Map.put_new(entry, :auth_modes, [:api_key])
  end

  @doc """
  The authentication modes a provider offers, in render order.

  `[:api_key]` for every provider that only takes a pasted credential (the
  default), `[:api_key, :oauth]` for a provider that can also connect the
  user's own account/subscription.

  Unknown ids answer `[:api_key]` rather than raising: an id that is not in
  the catalog cannot have a sign-in implementation, so key-only is both the
  safe answer and the correct one.
  """
  @spec auth_modes(String.t() | atom()) :: [:api_key | :oauth]
  def auth_modes(provider_id) do
    id = to_string(provider_id)

    case Enum.find(providers_list(), &(&1.id == id)) do
      nil -> [:api_key]
      entry -> Map.get(entry, :auth_modes, [:api_key])
    end
  rescue
    _ -> [:api_key]
  end

  # The concrete model Claude Code last resolved an alias to, or nil before any
  # call. Isolated so a transport that never recorded one degrades to "not
  # known yet" rather than failing the whole model list.
  defp claude_cli_resolved do
    OptimalSystemAgent.Providers.ClaudeCli.last_resolved_model()
  rescue
    _ -> nil
  end

  # Append the resolved id to the note of the alias it belongs to.
  #
  # Matching is a substring test on the concrete id (`opus` → `claude-opus-…`),
  # which is how Anthropic names them. The resolved id is only ever ADDED to a
  # note, never substituted into `id`: `id` is what gets handed back to the
  # CLI, and the alias is what the CLI accepts.
  defp annotate_resolved(models, resolved) when is_binary(resolved) do
    Enum.map(models, fn m ->
      id = to_string(Map.get(m, :id) || Map.get(m, "id") || "")

      if id != "" and String.contains?(resolved, id) do
        note = Map.get(m, :note) || Map.get(m, "note") || ""
        Map.put(m, :note, String.trim("#{note} · now #{resolved}"))
      else
        m
      end
    end)
  end

  defp annotate_resolved(models, _), do: models

  @doc """
  The shape of a provider's account sign-in, from the catalog, or `nil`.

  `:device_code` and `:auth_code` are interactive — the user has to visit a
  URL and approve something. `:external_cli`, `:local_daemon` and
  `:aws_credential_chain` are not: they complete from a local read.

  Declared on the catalog entry rather than inferred from the implementation
  module, so it stays one field on one row that every surface reads — the same
  rule `auth_modes` follows, and for the same reason.
  """
  @spec subscription_kind(String.t() | atom()) :: atom() | nil
  def subscription_kind(provider_id) do
    id = to_string(provider_id)

    case Enum.find(providers_list(), &(&1.id == id)) do
      %{subscription: %{kind: kind}} -> kind
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  True when signing in requires the user to leave OSA and come back.

  The distinction is what lets a request/response surface decline a flow it
  cannot finish. Starting a device grant inside an HTTP request and then
  writing the response abandons the poll: the user is shown a code that
  nothing is waiting on, which looks exactly like a broken sign-in. Declining
  it, and naming the command that does work, is the honest answer.
  """
  @spec interactive_sign_in?(String.t() | atom()) :: boolean()
  def interactive_sign_in?(provider_id) do
    subscription_kind(provider_id) in [:device_code, :auth_code, :pkce_user_code]
  end

  @doc """
  True when a provider offers more than one way in, i.e. its setup step must
  render the fork instead of going straight to a key prompt.
  """
  @spec dual_mode?(String.t() | atom()) :: boolean()
  def dual_mode?(provider_id), do: length(auth_modes(provider_id)) > 1

  # ── The rest of the routable catalog ─────────────────────────────────────
  #
  # `Providers.Registry` routes ~26 providers, but onboarding offered seven.
  # Everything else — Google, xAI, Groq, DeepSeek, Mistral, Cohere, Cerebras,
  # Fireworks, Together, Perplexity, Replicate, the Chinese providers and the
  # local OpenAI-compatible servers — was reachable only by hand-editing
  # `~/.osa/.env`, which is exactly the "config file editing" the setup flow
  # exists to remove.
  #
  # ONLY the presentation fields (label, blurb, grouping, signup URL, the
  # env-var name) live here. `default_model`, `base_url` and the model list are
  # DERIVED from the provider modules at call time, so this table can never
  # drift from the catalogs — a model id or endpoint is corrected in one place
  # and this picker follows. Adding a provider here without routing in the
  # Registry would be worse than omitting it, so the list is filtered against
  # `Registry.list_providers/0` before it is returned.
  @additional_providers [
    {"google", "Google Gemini", "Gemini direct — long context", "bring_your_own",
     "GOOGLE_API_KEY", "https://aistudio.google.com/apikey"},
    {"xai", "xAI", "Grok models", "bring_your_own", "XAI_API_KEY", "https://console.x.ai"},
    {"groq", "Groq", "Fastest inference", "bring_your_own", "GROQ_API_KEY",
     "https://console.groq.com/keys"},
    {"deepseek", "DeepSeek", "Strong reasoning, low cost", "bring_your_own", "DEEPSEEK_API_KEY",
     "https://platform.deepseek.com/api_keys"},
    {"mistral", "Mistral", "European models", "bring_your_own", "MISTRAL_API_KEY",
     "https://console.mistral.ai/api-keys"},
    {"cohere", "Cohere", "Command models", "bring_your_own", "COHERE_API_KEY",
     "https://dashboard.cohere.com/api-keys"},
    {"cerebras", "Cerebras", "Ultra-fast inference", "more", "CEREBRAS_API_KEY",
     "https://cloud.cerebras.ai"},
    {"fireworks", "Fireworks", "Open models, serverless", "more", "FIREWORKS_API_KEY",
     "https://fireworks.ai/account/api-keys"},
    {"together", "Together AI", "Open models", "more", "TOGETHER_API_KEY",
     "https://api.together.xyz/settings/api-keys"},
    {"perplexity", "Perplexity", "Search-grounded answers", "more", "PERPLEXITY_API_KEY",
     "https://www.perplexity.ai/settings/api"},
    {"replicate", "Replicate", "Hosted open models", "more", "REPLICATE_API_KEY",
     "https://replicate.com/account/api-tokens"},
    {"sambanova", "SambaNova", "Fast open models", "more", "SAMBANOVA_API_KEY",
     "https://cloud.sambanova.ai/apis"},
    {"hyperbolic", "Hyperbolic", "Open models", "more", "HYPERBOLIC_API_KEY",
     "https://app.hyperbolic.xyz/settings"},
    {"qwen", "Qwen (Alibaba)", "Qwen models", "more", "QWEN_API_KEY",
     "https://dashscope.console.aliyun.com"},
    {"moonshot", "Moonshot (Kimi)", "Kimi models", "more", "MOONSHOT_API_KEY",
     "https://platform.moonshot.cn/console/api-keys"},
    {"zhipu", "Zhipu (GLM)", "GLM models", "more", "ZHIPU_API_KEY",
     "https://open.bigmodel.cn/usercenter/apikeys"},
    {"volcengine", "Volcengine (Doubao)", "Doubao models", "more", "VOLCENGINE_API_KEY",
     "https://console.volcengine.com/ark"},
    {"baichuan", "Baichuan", "Baichuan models", "more", "BAICHUAN_API_KEY",
     "https://platform.baichuan-ai.com"}
  ]

  # Local OpenAI-compatible servers: no key, no signup, discovered by URL.
  @local_providers [
    {"lmstudio", "LM Studio", "Local server — no key needed", "http://localhost:1234/v1"},
    {"llamacpp", "llama.cpp", "Local server — no key needed", "http://localhost:8080/v1"}
  ]

  # ── Per-provider capability overlay for the compact tuple rows ──────────
  #
  # `@additional_providers` is a tuple list precisely because those rows differ
  # only in six presentation strings; the fields that vary are the six in the
  # tuple and nothing else. When ONE of them gains a capability the other
  # seventeen do not have — an account sign-in — there are two ways to express
  # it, and only one of them is reversible:
  #
  #   * expand that row into a literal map alongside the tuples. That splits
  #     the list into two shapes, and the next provider to gain a capability
  #     splits it again.
  #   * declare the extra fields separately, keyed by provider id, and merge
  #     them onto the expanded row. The tuple list stays one shape.
  #
  # This is the second. It is a MERGE over the expanded row, so an overlay can
  # only ADD or OVERRIDE named fields: a provider id absent from this map
  # expands byte-identically to how it did before this function existed, which
  # is what keeps the key-only providers untouched. Two more providers are
  # expected to need it, which is why it is a map rather than a special case.
  #
  # A function rather than a module attribute so the values can be read from
  # the auth modules at call time (the same "derive, never duplicate" rule
  # `derived_base_url/1` follows) without making this module compile-time
  # dependent on every auth provider.
  defp additional_provider_overlays do
    %{
      # xAI: a SECOND MODE on the existing row, not a second provider. Same
      # host (`api.x.ai/v1`), same OpenAI-compatible wire format, same models
      # — only the credential differs, so splitting it into an `xai`/`xai_oauth`
      # pair would present a distinction that does not exist below the
      # credential. Compare `openai`/`openai_codex`, which ARE split because
      # the base URL, the protocol and the model list all change with the
      # credential. Pattern A, the same one `ollama_cloud` and `bedrock` use.
      "xai" => %{
        # `requires_key: true` (from the tuple, unchanged) paired with
        # `key_optional: true` is what makes the account mode reachable from
        # the TUI: its onboarding dialog decides whether to render a
        # credential field from `requires_key` alone, so `requires_key: false`
        # would take the KEY mode away from TUI users, and omitting
        # `key_optional` would make the key mandatory and hide the account
        # mode. Identical reasoning to `bedrock`'s.
        key_optional: true,
        auth_modes: [:api_key, :oauth],
        subscription: %{
          kind: :device_code,
          label: "Sign in with my xAI account",
          hint: "Uses your SuperGrok or Premium+ plan — nothing to paste",
          key_label: "Paste an xAI API key",
          key_hint: "Pay-per-token billing against console.x.ai",
          # Unlike `ollama_cloud`, whose two modes genuinely reach different
          # hosts, this is the SAME endpoint the key path uses. It is stated
          # anyway, and read from the auth module rather than retyped, because
          # it is the value the transport pins at sign-in — see
          # `Auth.Providers.XAI.pinned_base_url/0`.
          base_url: OptimalSystemAgent.Auth.Providers.XAI.base_url()
        }
      },
      # Qwen: the same second-mode shape, with one difference that is the
      # provider's own doing rather than a modelling choice. An account is
      # issued a `resource_url` at sign-in and its inference endpoint is
      # derived from that; a DashScope key belongs to DashScope's
      # compatible-mode endpoint. So the two modes reach different hosts —
      # exactly the `ollama_cloud` situation, where `subscription.base_url`
      # exists precisely because the modes do not share one.
      #
      # The value below is only what the picker SHOWS before sign-in. The
      # endpoint actually used is resolved per account from the provider's own
      # token response and pinned into the marker; see
      # `Auth.Providers.Qwen.resolve_base_url/1`.
      "qwen" => %{
        key_optional: true,
        auth_modes: [:api_key, :oauth],
        subscription: %{
          kind: :device_code,
          label: "Sign in with my Qwen account",
          hint: "Uses your Qwen Code coding plan — nothing to paste",
          key_label: "Paste a DashScope API key",
          key_hint: "Pay-per-token billing against DashScope",
          base_url: OptimalSystemAgent.Auth.Providers.Qwen.default_base_url()
        }
      }
    }
  end

  defp additional_providers do
    routable = routable_provider_ids()
    overlays = additional_provider_overlays()

    keyed =
      for {id, name, description, group, env_var, signup_url} <- @additional_providers,
          MapSet.member?(routable, id) do
        %{
          id: id,
          name: name,
          description: description,
          group: group,
          requires_key: true,
          env_var: env_var,
          default_model: derived_default_model(id),
          base_url: derived_base_url(id),
          signup_url: signup_url,
          models: :dynamic
        }
        |> Map.merge(Map.get(overlays, id, %{}))
      end

    local =
      for {id, name, description, base_url} <- @local_providers,
          MapSet.member?(routable, id) do
        %{
          id: id,
          name: name,
          description: description,
          group: "bring_your_own",
          requires_key: false,
          env_var: nil,
          default_model: derived_default_model(id),
          base_url: base_url,
          signup_url: nil,
          models: :dynamic
        }
      end

    keyed ++ local
  end

  defp routable_provider_ids do
    MapSet.new(OptimalSystemAgent.Providers.Registry.list_providers(), &Atom.to_string/1)
  rescue
    _ -> MapSet.new()
  catch
    _, _ -> MapSet.new()
  end

  # Ask the Registry (which asks the provider module / catalog) rather than
  # keeping a second copy of any model id.
  defp derived_default_model(provider_id) do
    with {:ok, atom} <- known_provider_atom(provider_id),
         {:ok, info} <- OptimalSystemAgent.Providers.Registry.provider_info(atom) do
      to_string(info.default_model)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp derived_base_url(provider_id) do
    case known_provider_atom(provider_id) do
      {:ok, atom} -> provider_base_url(atom)
      _ -> nil
    end
  end

  @doc """
  The endpoint OSA will actually dial for a provider — the same value the
  provider module resolves, never a second hand-maintained copy.

  Returns nil when the provider has no fixed endpoint (a Custom Endpoint the
  user supplies, or a provider we don't route).
  """
  @spec provider_base_url(atom()) :: String.t() | nil
  def provider_base_url(:anthropic),
    do: Application.get_env(:optimal_system_agent, :anthropic_url, "https://api.anthropic.com")

  def provider_base_url(:google),
    do:
      Application.get_env(
        :optimal_system_agent,
        :google_url,
        "https://generativelanguage.googleapis.com/v1beta"
      )

  def provider_base_url(:cohere),
    do: Application.get_env(:optimal_system_agent, :cohere_url, "https://api.cohere.com/v2")

  def provider_base_url(:replicate),
    do: Application.get_env(:optimal_system_agent, :replicate_url, "https://api.replicate.com/v1")

  def provider_base_url(:ollama),
    do: Application.get_env(:optimal_system_agent, :ollama_url, "http://localhost:11434")

  def provider_base_url(provider) when is_atom(provider) do
    OptimalSystemAgent.Providers.OpenAICompatProvider.base_url(provider)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # Resolve a picker id to a Registry provider atom WITHOUT `String.to_atom` on
  # caller-supplied data (an unbounded atom table is a memory-exhaustion vector
  # on a public endpoint) — only atoms the Registry already declares can match.
  @doc false
  @spec known_provider_atom(String.t()) :: {:ok, atom()} | :error
  def known_provider_atom(provider_id) when is_binary(provider_id) do
    case Enum.find(
           OptimalSystemAgent.Providers.Registry.list_providers(),
           &(Atom.to_string(&1) == provider_id)
         ) do
      nil -> :error
      atom -> {:ok, atom}
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  def known_provider_atom(_), do: :error

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

      # The rows are aliases, and an alias alone does not answer "which model
      # am I actually running" — the question the picker exists to answer.
      # Claude Code resolves the alias downstream and reports the concrete id
      # back on the first call; annotate the row it belongs to once that is
      # known, rather than leaving the user to infer it or read the CLI
      # header. Before any call the notes are unchanged, because inventing a
      # dated id here is the exact confident lie the alias design avoids.
      "claude_cli" ->
        {:ok, annotate_resolved(static_models("claude_cli"), claude_cli_resolved())}

      "custom" ->
        base_url = Keyword.get(opts, :base_url)
        api_key = Keyword.get(opts, :api_key) || System.get_env("OPENAI_API_KEY")

        if base_url do
          fetch_openai_models(base_url, api_key)
        else
          {:ok, []}
        end

      "ollama_cloud" ->
        # ACCOUNT MODE ONLY — signalled by a loopback `base_url` with no key,
        # which is exactly what the account route produces and what the keyed
        # route never does. With a key, this falls through to the shipped
        # catalog unchanged.
        #
        # The daemon is authoritative about what THIS account can reach:
        # `/api/tags` lists every hosted tag with a `remote_host`, and the
        # shipped catalog can legitimately contain a model a given plan cannot
        # use. So the catalog supplies names, notes and pricing and the daemon
        # decides membership — the same "narrow, never invent" rule the
        # openai/anthropic branch below follows.
        api_key = Keyword.get(opts, :api_key)
        base_url = Keyword.get(opts, :base_url)

        if (is_nil(api_key) or api_key == "") and
             OptimalSystemAgent.Auth.Providers.OllamaAccount.loopback?(base_url) do
          ollama_account_models(base_url, static_models("ollama_cloud"))
        else
          {:ok, static_models("ollama_cloud")}
        end

      "openrouter" ->
        # Live catalog (ctx + pricing + tool support). Falls back to the
        # curated list if the network call fails so the picker still works.
        case fetch_openrouter_models() do
          {:ok, models} when models != [] -> {:ok, models}
          _ -> {:ok, hardcoded_models(provider_id)}
        end

      p when p in ["openai", "anthropic"] ->
        # Ollama Local probes the daemon for the models that account/box can
        # actually serve; do the equivalent for the two direct BYO-key
        # providers so onboarding offers a list the user's key can really use.
        # OpenAI exposes `GET /v1/models`, Anthropic `GET /v1/models` — both
        # authoritative for a given key. STRICTLY narrowing: the catalog stays
        # the source of names/context/pricing and the probe only filters it, so
        # a probe failure, an unauthenticated call, or an id shape we don't
        # recognise degrades to the full catalog rather than an empty picker.
        catalog = static_models(p)

        probe_opts =
          case Keyword.get(opts, :req_plug) do
            nil -> []
            plug -> [plug: plug, retry: false]
          end

        case probe_accessible_ids(
               p,
               Keyword.get(opts, :api_key),
               Keyword.get(opts, :base_url),
               probe_opts
             ) do
          {:ok, ids} -> {:ok, narrow_to_accessible(catalog, ids)}
          :skip -> {:ok, catalog}
        end

      _ ->
        {:ok, static_models(provider_id)}
    end
  end

  # Static providers (anthropic, openai, …): prefer the refreshable Catalog
  # (models.dev-style, with `Catalog.apply_sot_overlay/1` forcing the
  # Anthropic/OpenAI sections to come from the SoT modules), fall back to the
  # curated hardcoded list.
  defp static_models(provider_id) do
    case catalog_model_maps(provider_id) do
      [] ->
        case hardcoded_models(provider_id) do
          [] -> registry_model_maps(provider_id)
          models -> models
        end

      models ->
        models
    end
  end

  # Last resort for a provider whose catalog entry is `:dynamic` and that
  # models.dev doesn't cover: ask the Registry, which asks the provider module
  # itself. Keeps every model id in ONE place (the provider catalogs) instead
  # of a second copy in the onboarding table — a picker entry with no models is
  # a provider the user can select but never finish configuring.
  defp registry_model_maps(provider_id) do
    with {:ok, atom} <- known_provider_atom(provider_id),
         {:ok, %{available_models: ids}} when is_list(ids) <-
           OptimalSystemAgent.Providers.Registry.provider_info(atom) do
      Enum.map(ids, fn id ->
        id = to_string(id)

        %{
          id: id,
          name: id,
          ctx: OptimalSystemAgent.Providers.Catalog.context_window(id) || 0,
          tools: true
        }
      end)
    else
      _ -> []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # Keep only catalog entries the key can actually reach.
  #
  # Matching is exact, plus ONE deliberate tolerance: Anthropic's `/v1/models`
  # answers with dated snapshots (`claude-opus-5-20260115`) where OSA's catalog
  # carries the moving alias (`claude-opus-5`). That tolerance is scoped to a
  # literal `-YYYYMMDD` suffix rather than a general prefix test, because a
  # general one silently over-matches: `gpt-4o` returned by the API would also
  # admit `gpt-4o-mini`, a DIFFERENT model the key may not have.
  #
  # If nothing matches — an unfamiliar id scheme, a proxy that lists nothing we
  # know — the catalog is returned untouched. Offering too many models is
  # recoverable; offering none is a dead end.
  @dated_snapshot_suffix ~r/^-\d{8}$/

  @spec narrow_to_accessible([map()], [String.t()]) :: [map()]
  defp narrow_to_accessible(catalog, ids) do
    available = MapSet.new(ids)

    filtered =
      Enum.filter(catalog, fn %{id: id} ->
        MapSet.member?(available, id) or Enum.any?(ids, &dated_snapshot_of?(&1, id))
      end)

    if filtered == [], do: catalog, else: filtered
  end

  defp dated_snapshot_of?(returned_id, catalog_id) do
    String.starts_with?(returned_id, catalog_id) and
      Regex.match?(
        @dated_snapshot_suffix,
        binary_part(
          returned_id,
          byte_size(catalog_id),
          byte_size(returned_id) - byte_size(catalog_id)
        )
      )
  end

  # `{:ok, ids}` when we got an authoritative list, `:skip` when we could not
  # (no key, transport error, non-200) — never an error, because failing to
  # probe must not fail model selection.
  @spec probe_accessible_ids(String.t(), String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, [String.t()]} | :skip
  defp probe_accessible_ids(_provider, key, _base_url, _req_opts) when key in [nil, ""], do: :skip

  defp probe_accessible_ids("openai", key, base_url, req_opts) do
    fetch_model_ids(
      "#{base_url || "https://api.openai.com/v1"}/models",
      [{"authorization", "Bearer #{key}"}],
      req_opts
    )
  end

  defp probe_accessible_ids("anthropic", key, base_url, req_opts) do
    fetch_model_ids(
      "#{base_url || "https://api.anthropic.com"}/v1/models?limit=1000",
      [{"x-api-key", key}, {"anthropic-version", "2023-06-01"}],
      req_opts
    )
  end

  defp probe_accessible_ids(_provider, _key, _base_url, _req_opts), do: :skip

  # Both providers answer `GET .../models` with `{"data": [{"id": ...}, ...]}`.
  defp fetch_model_ids(url, headers, req_opts) do
    case Req.get([url: url, headers: headers, receive_timeout: 10_000, retry: false] ++ req_opts) do
      {:ok, %{status: 200, body: %{"data" => entries}}} when is_list(entries) ->
        ids =
          entries
          |> Enum.map(fn e -> is_map(e) && e["id"] end)
          |> Enum.filter(&(is_binary(&1) and &1 != ""))

        if ids == [], do: :skip, else: {:ok, ids}

      _ ->
        :skip
    end
  rescue
    _ -> :skip
  catch
    _, _ -> :skip
  end

  # Curated per-provider models from the onboarding catalog (fallback source).
  defp hardcoded_models(provider_id) do
    case Enum.find(providers_list(), &(&1.id == provider_id)) do
      %{models: models} when is_list(models) -> models
      _ -> []
    end
  end

  # Onboarding-shaped model maps sourced from Providers.Catalog. Maps an
  # onboarding provider id to its catalog provider id (they coincide for the
  # static providers). Returns [] when the Catalog has no entry.
  defp catalog_model_maps(provider_id) do
    OptimalSystemAgent.Providers.Catalog.models(provider_id)
    |> Enum.map(fn m ->
      %{
        id: m.model_id,
        name: m.name || m.model_id,
        ctx: m.ctx || 0,
        tools: m.tool_call,
        reasoning: m.reasoning,
        cost: m.cost
      }
    end)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # Live OpenRouter model catalog. Parses context length, pricing, and tool
  # support (from supported_parameters) into onboarding-shaped maps.
  defp fetch_openrouter_models do
    case Req.get("https://openrouter.ai/api/v1/models", receive_timeout: 10_000, retry: false) do
      {:ok, %{status: 200, body: %{"data" => models}}} when is_list(models) ->
        parsed =
          Enum.map(models, fn m ->
            supported = m["supported_parameters"] || []
            pricing = m["pricing"] || %{}

            %{
              id: m["id"] || "unknown",
              name: m["name"] || m["id"] || "unknown",
              ctx: m["context_length"] || 0,
              tools: "tools" in supported or "tool_choice" in supported,
              cost: %{
                input: parse_price(pricing["prompt"]),
                output: parse_price(pricing["completion"])
              }
            }
          end)

        {:ok, parsed}

      {:ok, %{status: status}} ->
        {:error, "OpenRouter returned #{status}"}

      {:error, reason} ->
        {:error, "Can't reach OpenRouter: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "OpenRouter fetch failed: #{Exception.message(e)}"}
  end

  # OpenRouter prices are per-token USD strings (e.g. "0.000003"). Convert to a
  # per-million-token float to match the catalog's cost convention; nil if absent.
  defp parse_price(nil), do: nil
  defp parse_price(""), do: nil

  defp parse_price(str) when is_binary(str) do
    case Float.parse(str) do
      {v, _} -> Float.round(v * 1_000_000, 4)
      :error -> nil
    end
  end

  defp parse_price(n) when is_number(n), do: Float.round(n * 1_000_000, 4)
  defp parse_price(_), do: nil

  @doc """
  Verify connection to a provider by sending a minimal test request.

  Returns {:ok, result_map} on success or {:error, error_map} on failure.

  ## Three-way classification (hotfix: onboarding TUI dead-end on ollama_cloud)

  Every `{:error, map}` result now carries a `verified:` tag so callers never
  have to guess whether a failure means "this key is bad" or "we simply
  couldn't reach the provider right now":

    * `:key_rejected` — the provider EXPLICITLY rejected the credential
      (HTTP 401, 403, or the 402 `insufficient_credits` case). Worth asking
      the user to re-enter the key, but MUST still allow "save anyway".
    * `:unverified` — everything else that isn't a clean 2xx: transport
      errors (connection refused, timeout, DNS), a non-auth 4xx (e.g. 404
      model-not-found), or a 5xx. A transport/HTTP error must NEVER be
      reported as "key invalid" — the key might be perfectly fine and the
      network/provider is just flaky. Callers treat this as non-blocking.

  `ollama_cloud` gets a dedicated route: the RUNTIME path for a signed-in
  local Ollama daemon is keyless device-identity (`Providers.Ollama`,
  `http://localhost:11434`), not a Bearer token against `https://ollama.com`.
  So health_check now probes the local daemon FIRST and, if it's reachable,
  verifies against it (matching what actually runs) regardless of whether a
  key was typed — a mismatched Bearer-vs-device-identity path must never
  fail an otherwise-working local setup. Only when no local daemon is
  reachable does a supplied key get verified against `ollama.com`, and even
  then a transport error there is `:unverified`, never `:key_rejected`.
  """
  @spec health_check(map()) :: {:ok, map()} | {:error, map()}
  def health_check(%{"provider" => "miosa"} = _params) do
    # MIOSA Cloud is gated during early access. Return a friendly, non-failing
    # notice so the TUI can show "coming soon" rather than a red connection
    # error — the endpoint is real but access is limited.
    {:ok,
     %{
       status: "coming_soon",
       availability: "limited",
       message: "MIOSA Cloud is in limited early access. Request access at miosa.ai.",
       signup_url: "https://miosa.ai/settings/keys"
     }}
  end

  # A subscription provider has no key to verify, so "is this configured?" is
  # a question about the stored sign-in, not about an endpoint accepting a
  # credential. Answered from the credential store as a PURE READ: probing the
  # live endpoint here would make `osa doctor` and the setup wizard capable of
  # triggering a token refresh — and of reporting a refresh failure as a
  # health failure — as a side effect of asking a question.
  def health_check(%{"provider" => "openai_codex"} = _params) do
    case OptimalSystemAgent.Auth.Subscription.status("openai_codex") do
      %{connected?: true, expired?: false} = status ->
        {:ok,
         %{
           status: "connected",
           verified: true,
           auth_mode: "subscription",
           plan: status.plan,
           message:
             "Signed in to ChatGPT#{if status.plan, do: " (#{status.plan} plan)", else: ""}."
         }}

      %{connected?: true} ->
        {:error,
         %{
           verified: :unverified,
           error: "sign_in_expired",
           message: "Your ChatGPT sign-in has expired. Run /login to sign in again."
         }}

      _ ->
        {:error,
         %{
           verified: :unverified,
           error: "not_connected",
           message: "Not signed in to ChatGPT. Run /login and choose \"Sign in with ChatGPT\"."
         }}
    end
  end

  # `claude_cli` is the one provider whose credential lives outside OSA, so
  # the honest check is not "what did we store?" but "what does the CLI say
  # right now?". A user who ran `claude auth logout` in another terminal has
  # a stored marker that is already wrong, and a green tick over a signed-out
  # CLI is worse than a slower check. The probe is a LOCAL read of Claude
  # Code's own store — no network call, and nothing here can refresh a token,
  # so the read-only-resolve contract still holds.
  def health_check(%{"provider" => "claude_cli"} = params) do
    alias OptimalSystemAgent.Auth.Providers.ClaudeCli

    # `connect/0` CREATES the marker; `live_status/0` refuses to. Which one
    # runs is decided by `during_setup?/1` and never by the provider module,
    # because the same function is reached from two kinds of caller with
    # opposite requirements:
    #
    #   * a **setup** surface (`osa setup`, the wizard, first-run onboarding)
    #     is the user saying "connect this" — creating the marker is the
    #     entire point, and for a provider whose sign-in is a local file read
    #     there is nothing else to confirm.
    #   * a **status** surface (the post-onboarding candidate-provider probe
    #     over `POST /onboarding/health-check`) is only asking. If that path
    #     created a marker, signing out would appear to do nothing the moment
    #     any screen refreshed — which is exactly the bug `live_status/0` was
    #     written to prevent and which reappeared here by calling through it.
    result = if during_setup?(params), do: ClaudeCli.connect(), else: ClaudeCli.live_status()

    case result do
      {:ok, account} ->
        {:ok,
         %{
           status: "connected",
           verified: true,
           auth_mode: "subscription",
           plan: account.plan,
           account: account.email,
           message:
             "Using your Claude subscription through Claude Code" <>
               if(account.plan, do: " (#{account.plan} plan)", else: "") <> "."
         }}

      {:error, reason} ->
        {:error,
         %{
           verified: :unverified,
           error: health_error_code(reason),
           message: claude_cli_health_message(reason)
         }}
    end
  end

  # Copilot's health check is the same "setup verify == connect" step as
  # claude_cli's, with one difference that drives the whole design: there is
  # no offline way to confirm a Copilot sign-in, and confirming it online
  # would spend the operator's metered quota on drawing a screen. So a
  # positive answer here means "OSA found a usable credential signal", and an
  # unconfirmed one says exactly that rather than guessing either way.
  def health_check(%{"provider" => "copilot_cli"} = params) do
    alias OptimalSystemAgent.Auth.Providers.CopilotCli

    # Same setup-vs-status split as `claude_cli` above, and it matters more
    # here: `CopilotCli.probe/0` answers "unverified but present" for nothing
    # more than the `copilot` binary being on PATH, so a status surface
    # calling `connect/0` would manufacture a "connected" entry out of an
    # `ls` — with no sign-in evidence whatsoever — for a user who had just
    # signed out.
    result = if during_setup?(params), do: CopilotCli.connect(), else: CopilotCli.live_status()

    case result do
      {:ok, %{"verified" => true} = entry} ->
        {:ok,
         %{
           status: "connected",
           verified: true,
           auth_mode: "subscription",
           account: entry["account_id"],
           message:
             "Using your GitHub Copilot plan through the Copilot CLI (via #{entry["auth_source"]})."
         }}

      {:ok, _entry} ->
        # NOT an error: the CLI is installed and may well be signed in. OSA
        # reports what it actually knows, and `verified: :unverified` is the
        # existing vocabulary for exactly that.
        {:ok,
         %{
           status: "connected",
           verified: :unverified,
           auth_mode: "subscription",
           message:
             "Copilot CLI found. OSA cannot confirm your sign-in offline and will not make a " <>
               "billed request to check — if the first turn fails on auth, run `copilot login`."
         }}

      {:error, reason} ->
        {:error,
         %{
           verified: :unverified,
           error: health_error_code(reason),
           message: OptimalSystemAgent.Auth.Subscription.message(reason, "the Copilot CLI")
         }}
    end
  end

  # Bedrock's check is free, which is what lets it be a REAL check rather than
  # a stored-marker read. `ListFoundationModels` lives on the control plane —
  # it is not inference, is not metered per token, and returns the account's
  # actual model catalogue — so one request proves the signature is valid,
  # proves the region exists, and proves the identity has Bedrock permissions.
  # An `/invoke` probe would have charged the operator for drawing a screen,
  # which is the line this codebase does not cross.
  #
  # Same setup-vs-status split as the other account providers: only a setup
  # surface may create the connection marker.
  def health_check(%{"provider" => "bedrock"} = params) do
    alias OptimalSystemAgent.Auth.Providers.Bedrock

    api_key = Map.get(params, "api_key")

    if is_binary(api_key) and String.trim(api_key) != "" do
      bedrock_key_health(String.trim(api_key))
    else
      result = if during_setup?(params), do: Bedrock.connect(), else: Bedrock.live_status()

      case result do
        {:ok, entry} ->
          {:ok,
           %{
             status: "connected",
             verified: true,
             auth_mode: "subscription",
             account: entry["access_key_hint"] && "…#{entry["access_key_hint"]}",
             plan: entry["region"],
             message:
               "Using your AWS account in #{entry["region"]} via #{entry["source"]} — " <>
                 "#{entry["model_count"]} foundation models available."
           }}

        {:error, reason} ->
          {:error,
           %{
             verified: :unverified,
             error: health_error_code(reason),
             message: Bedrock.message(reason)
           }}
      end
    end
  end

  def health_check(%{"provider" => "ollama_cloud"} = params) do
    api_key = Map.get(params, "api_key")
    model = Map.get(params, "model")
    req_opts = req_opts(params)

    cond do
      # ACCOUNT MODE. Only reached when the user actually chose it — either
      # this call says so, or a connection marker already exists from a
      # previous run. Without one of those the two branches below are
      # byte-for-byte the behaviour they had before account mode existed, which
      # is what keeps the API-key path unchanged.
      #
      # A key still wins if one was supplied: an explicitly-typed credential is
      # never shadowed by an auto-discovered one.
      (is_nil(api_key) or api_key == "") and ollama_account_mode?(params) ->
        ollama_account_health(params)

      is_binary(api_key) and api_key != "" ->
        # The user explicitly picked **Ollama Cloud** and supplied a key: verify
        # against ollama.com with the Bearer key. This is the whole point of the
        # cloud selection — honour it. The previous "local-first" ordering
        # hijacked an explicit cloud choice to a local daemon on localhost:11434
        # whenever one happened to be running, and since a `:cloud` model
        # (e.g. glm-5.2:cloud) is NOT served by a bare local daemon, verification
        # died with "error sending request for url (http://localhost:11434…)".
        # Cloud selection ⇒ cloud URL, always.
        run_health_request("ollama_cloud", api_key, model, "https://ollama.com", req_opts)

      true ->
        # No key: the only thing verifiable is a keyless local device-identity
        # daemon (Ollama's signed-in local app, which can proxy cloud models).
        # Use it if present; otherwise report unverified (non-blocking).
        local = probe_ollama_local(req_opts)

        if local.reachable do
          run_health_request("ollama_local", nil, model, local.url, req_opts)
        else
          {:error,
           %{
             verified: :unverified,
             error: "no_local_daemon",
             message:
               "No local Ollama daemon detected and no API key supplied. " <>
                 "Sign in to Ollama locally or add a key — you can still continue."
           }}
        end
    end
  end

  def health_check(params) do
    provider = Map.get(params, "provider", "ollama")
    api_key = Map.get(params, "api_key")
    model = Map.get(params, "model")
    base_url = Map.get(params, "base_url")

    run_health_request(provider, api_key, model, base_url, req_opts(params))
  end

  # The bearer-key half. Verified against the same free control-plane call, so
  # a pasted key that is valid-looking but wrong is caught here rather than at
  # the user's first turn. The key is NOT persisted by this function — the
  # setup surfaces write it to `~/.osa/.env` under AWS's own variable name,
  # exactly as they do for every other keyed provider.
  defp bedrock_key_health(api_key) do
    alias OptimalSystemAgent.Auth.Providers.Bedrock

    case OptimalSystemAgent.Auth.AwsCredentials.region() do
      {:error, reason} ->
        {:error,
         %{
           verified: :unverified,
           error: "no_region",
           message:
             "An Amazon Bedrock API key needs a region alongside it — Bedrock has no global " <>
               "endpoint. " <> OptimalSystemAgent.Auth.AwsCredentials.explain(reason)
         }}

      {:ok, region} ->
        url = Bedrock.control_url(region) <> "/foundation-models"

        case Req.get(
               url: url,
               headers: [{"authorization", "Bearer #{api_key}"}, {"accept", "application/json"}],
               receive_timeout: 15_000,
               retry: false
             ) do
          {:ok, %{status: 200}} ->
            {:ok,
             %{
               status: "connected",
               verified: true,
               auth_mode: "api_key",
               plan: region,
               message: "Amazon Bedrock API key accepted in #{region}."
             }}

          {:ok, %{status: status, body: body}} when status in [400, 401, 403] ->
            {:error,
             %{
               verified: :unverified,
               error: "key_rejected",
               message: "Amazon Bedrock rejected that API key: #{Bedrock.aws_message(body)}"
             }}

          {:ok, %{status: status, body: body}} ->
            {:error,
             %{
               verified: :unverified,
               error: "http_error",
               message: "Amazon Bedrock returned HTTP #{status}: #{Bedrock.aws_message(body)}"
             }}

          # A transport failure is NOT evidence the key is bad, and saying so
          # would send the user to rotate a perfectly good credential.
          {:error, e} ->
            {:error,
             %{
               verified: :unverified,
               error: "unreachable",
               message:
                 "Could not reach Amazon Bedrock in #{region} (#{Exception.message(e)}). " <>
                   "The key was not checked — this is a network or region problem."
             }}
        end
    end
  end

  # The TUI's onboarding dialog has one credential field and no auth-mode
  # menu, so "Ollama Cloud with the key left blank" is how a user asks for the
  # account route there. Without this it wrote `OLLAMA_URL=https://ollama.com`
  # with no key — a config that 401s on the first turn — because the keyed
  # endpoint is the entry's declared `base_url`.
  #
  # Deliberately narrow: only when the provider is ollama_cloud, only when NO
  # key was supplied, only when the caller named no URL of its own, and only
  # when a local daemon actually answers with an account. Anything else keeps
  # the previous value, so the keyed path is untouched.
  defp resolve_ollama_account_url("ollama_cloud", api_key, nil)
       when is_nil(api_key) or api_key == "" do
    alias OptimalSystemAgent.Auth.Providers.OllamaAccount

    case OllamaAccount.connect() do
      {:ok, %{daemon_url: url}} -> url
      _ -> nil
    end
  end

  defp resolve_ollama_account_url(_provider, _api_key, base_url), do: base_url

  # True when the *account* half of `ollama_cloud` is what is being asked
  # about. Deliberately NOT inferred from "a local daemon happens to be
  # running": a box with a signed-in daemon and a pasted key is an API-key
  # user, and answering about their daemon would be answering a question they
  # did not ask.
  defp ollama_account_mode?(params) do
    Map.get(params, "auth_mode") in ["oauth", :oauth] or
      Map.get(params, :auth_mode) in ["oauth", :oauth] or
      OptimalSystemAgent.Auth.SubscriptionStore.connected?("ollama_cloud")
  rescue
    _ -> false
  end

  # The connect/live_status split, for the same reason it exists on
  # `claude_cli` — and it is load-bearing here too: this function is reachable
  # over HTTP from `POST /onboarding/health-check`, so a status surface that
  # called `connect/0` would re-create the marker a user had just removed with
  # `osa logout`, and signing out would appear to do nothing.
  #
  # Both branches cost nothing: the probe is an unauthenticated loopback read
  # of `/api/me`. No token is spent, no request leaves the machine.
  defp ollama_account_health(params) do
    alias OptimalSystemAgent.Auth.Providers.OllamaAccount

    result =
      if during_setup?(params), do: OllamaAccount.connect(), else: OllamaAccount.live_status()

    case result do
      {:ok, account} ->
        {:ok,
         %{
           status: "connected",
           verified: true,
           auth_mode: "subscription",
           plan: account.plan,
           account: account.account_id,
           message:
             "Using your Ollama account" <>
               if(account.plan, do: " (#{account.plan} plan)", else: "") <>
               " through the local daemon at #{account.daemon_url}."
         }}

      {:error, reason} ->
        # Reported honestly rather than falling through to the keyed check: a
        # user in account mode has no key to verify, and "couldn't reach
        # ollama.com" would name the wrong problem.
        {:error,
         %{
           verified: :unverified,
           error: health_error_code(reason),
           message: OptimalSystemAgent.Auth.Subscription.message(reason, "Ollama Cloud")
         }}
    end
  end

  # The generic subscription copy ends every message with "or paste an API
  # key", which is wrong here: this provider has no key path, and the key
  # route is the separate `anthropic` entry. Naming that explicitly is the
  # difference between a dead end and a redirect.
  @doc """
  True when this health check is the *verify* step of a setup flow, rather
  than a status surface asking a question.

  Only the externally-managed providers (`claude_cli`, `copilot_cli`) consult
  it, and only to decide whether creating a connection marker is permitted.
  The distinction cannot be inferred from the provider, the parameters or the
  transport — it is a property of **who called**, so every caller states it.

  Two deliberate properties:

    * The default is `false`. A caller that has not thought about it gets the
      safe answer: report state, never create it.
    * `channels/http.ex` sets this itself and **discards whatever the request
      body said**. A remote caller must not be able to talk a status route
      into re-creating a credential marker by adding a JSON field; the
      unauthenticated first-run onboarding path is setup by construction and
      the authenticated post-onboarding probe is not, so the transport
      already knows the answer without asking the client.
  """
  @spec during_setup?(map()) :: boolean()
  def during_setup?(params) when is_map(params) do
    Map.get(params, "during_setup") == true or Map.get(params, :during_setup) == true
  end

  def during_setup?(_), do: false

  defp claude_cli_health_message(:not_connected),
    do:
      "Not connected. Run /login, choose \"Claude subscription (via Claude Code)\" — " <>
        "or pick \"Anthropic\" to use an API key instead."

  defp claude_cli_health_message(reason),
    do: OptimalSystemAgent.Auth.Subscription.message(reason, "Claude Code")

  defp health_error_code(:cli_not_installed), do: "cli_not_installed"
  defp health_error_code(:cli_not_signed_in), do: "not_connected"
  defp health_error_code(:not_connected), do: "not_connected"
  defp health_error_code({:cli_too_old, _}), do: "cli_too_old"
  # Distinct codes so a client can tell "start the daemon" from "sign in" from
  # "you pointed me at a remote host" without parsing the message text.
  defp health_error_code(:ollama_daemon_unreachable), do: "no_local_daemon"
  defp health_error_code(:ollama_not_signed_in), do: "not_signed_in"
  defp health_error_code({:ollama_host_remote, _}), do: "remote_ollama_host"
  defp health_error_code(_), do: "not_connected"

  # Shared verification request + three-way classification, used both by the
  # generic provider path and by ollama_cloud's local-first / keyed-fallback
  # routing above.
  @spec run_health_request(
          String.t(),
          String.t() | nil,
          String.t() | nil,
          String.t() | nil,
          keyword()
        ) :: {:ok, map()} | {:error, map()}
  defp run_health_request(provider, api_key, model, base_url, req_opts) do
    case build_health_check_request(provider, api_key, model, base_url) do
      {nil, _headers, _body} ->
        # No endpoint we can honestly probe for this provider. Refusing is the
        # only safe answer — the alternative was POSTing the user's key to
        # api.openai.com to find out.
        {:error,
         %{
           verified: :unverified,
           error: "no_endpoint",
           message:
             "No API endpoint is configured for provider '#{provider}'. " <>
               "Set a base URL to verify this key."
         }}

      {url, headers, body} ->
        do_health_request(url, headers, body, model, req_opts)
    end
  end

  # A `nil` body means the provider's key check is a GET (Replicate's
  # `/account`), not a chat completion. Everything downstream — the three-way
  # classification, the latency stamp — is identical.
  defp do_health_request(url, headers, nil, model, req_opts) do
    start_time = System.monotonic_time(:millisecond)

    get_opts =
      [headers: headers, receive_timeout: 15_000, retry: :transient, max_retries: 2] ++ req_opts

    classify_health_response(Req.get([url: url] ++ get_opts), url, model, start_time)
  rescue
    e ->
      {:error, %{verified: :unverified, error: "exception", message: Exception.message(e)}}
  end

  defp do_health_request(url, headers, body, model, req_opts) do
    start_time = System.monotonic_time(:millisecond)

    # req_opts LAST: Req folds options into a map via `Map.new/1`, where the
    # LAST occurrence of a duplicate key wins — so putting req_opts after the
    # production defaults lets an injected test override (e.g. `retry:
    # false`) actually take effect instead of being shadowed.
    post_opts =
      [
        headers: headers,
        json: body,
        receive_timeout: 15_000,
        retry: :transient,
        max_retries: 2
      ] ++ req_opts

    classify_health_response(Req.post([url: url] ++ post_opts), url, model, start_time)
  rescue
    e ->
      {:error, %{verified: :unverified, error: "exception", message: Exception.message(e)}}
  end

  # Shared three-way classification for BOTH the POST (chat probe) and GET
  # (Replicate's account probe) shapes, so a provider can never end up with a
  # subtly different notion of "your key was rejected".
  defp classify_health_response(result, url, model, start_time) do
    case result do
      {:ok, %{status: status}} when status in 200..299 ->
        latency = System.monotonic_time(:millisecond) - start_time

        {:ok,
         %{
           verified: :ok,
           status: "ok",
           latency_ms: latency,
           model: model,
           response_status: status
         }}

      {:ok, %{status: 401}} ->
        {:error,
         %{
           verified: :key_rejected,
           error: "unauthorized",
           message: "API key is invalid or expired."
         }}

      {:ok, %{status: 402}} ->
        {:error,
         %{
           verified: :key_rejected,
           error: "insufficient_credits",
           message: "Insufficient credits on this account."
         }}

      {:ok, %{status: 403}} ->
        {:error,
         %{
           verified: :key_rejected,
           error: "forbidden",
           message: "Access denied. Check your API key permissions."
         }}

      {:ok, %{status: 404}} ->
        # Not an auth failure — the model/endpoint just isn't there. The key
        # (if any) may be perfectly valid, so this is unverified, not rejected.
        {:error,
         %{
           verified: :unverified,
           error: "model_not_found",
           message: "Model '#{model}' not found."
         }}

      {:ok, %{status: 429}} ->
        # Rate limited but key works
        latency = System.monotonic_time(:millisecond) - start_time

        {:ok,
         %{
           verified: :ok,
           status: "ok",
           latency_ms: latency,
           model: model,
           warning: "rate_limited"
         }}

      {:ok, %{status: status, body: resp_body}} ->
        msg = extract_error_message(resp_body) || "Server returned #{status}"
        {:error, %{verified: :unverified, error: "server_error", message: msg, status: status}}

      {:error, %Req.TransportError{reason: :econnrefused}} ->
        {:error,
         %{
           verified: :unverified,
           error: "connection_refused",
           message: "Can't reach #{url}. Check the URL."
         }}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error,
         %{
           verified: :unverified,
           error: "timeout",
           message: "Connection timed out after 15 seconds."
         }}

      {:error, reason} ->
        {:error,
         %{
           verified: :unverified,
           error: "connection_failed",
           message: "Connection failed: #{inspect(reason)}"
         }}
    end
  rescue
    e ->
      {:error, %{verified: :unverified, error: "exception", message: Exception.message(e)}}
  end

  # Lets tests inject a `Req.Test` plug without threading a new param through
  # every public call site: `params["req_plug"]` (string key, matches every
  # other onboarding param) is stripped from the request build and turned
  # into Req opts merged into the call. Absent in production (real HTTP
  # calls from the TUI/wizard never set it). When a plug IS present we also
  # disable the transient-error retry/backoff — deterministic offline tests
  # must not sit through multi-second retry sleeps for the transport-error
  # cases they're specifically testing.
  @spec req_opts(map()) :: keyword()
  defp req_opts(params) do
    case Map.get(params, "req_plug") || Map.get(params, :req_plug) do
      nil -> []
      plug -> [plug: plug, retry: false]
    end
  end

  @doc """
  Write setup configuration and seed workspace.

  1. Writes ~/.osa/.env with provider config
  2. Sets env vars in-process — takes effect immediately, no restart, **but
     only for the OS process this function runs in**. Called from the
     in-daemon HTTP flow (`POST /onboarding/setup`, `/setup` in the TUI) that
     process IS the serving daemon, so this is true and the very next request
     picks up the new key. Called from a separate short-lived OS process
     (the standalone `mix osa.setup.wizard` that `bin/osa` shells out to on
     first run) these `System.put_env`/`Application.put_env` calls only
     mutate that subprocess and are discarded when it exits a moment later —
     the serving daemon never sees them. `bin/osa` restarts the daemon right
     after that wizard exits so `config/runtime.exs` reloads the freshly
     written `.env`; provider/key resolution in `Providers.Registry` and
     `Providers.OpenAICompatProvider` also re-reads `~/.osa/.env` live via
     `live_env/1` as a second line of defense, so a key already works even
     if some other caller skips the restart.
  3. Seeds workspace templates (BOOTSTRAP.md, IDENTITY.md, USER.md, SOUL.md, HEARTBEAT.md)
  4. Reloads Soul cache
  """
  @spec write_setup(map()) :: :ok | {:error, String.t()}
  def write_setup(%{} = params) do
    File.mkdir_p!(osa_dir())

    provider = Map.get(params, :provider) || Map.get(params, "provider", "ollama")
    model = Map.get(params, :model) || Map.get(params, "model")
    api_key = Map.get(params, :api_key) || Map.get(params, "api_key")
    base_url = Map.get(params, :base_url) || Map.get(params, "base_url")
    base_url = resolve_ollama_account_url(provider, api_key, base_url)
    channel_tokens = Map.get(params, :channel_tokens) || Map.get(params, "channel_tokens") || %{}

    user_name = Map.get(params, :user_name) || Map.get(params, "user_name")
    agent_name = Map.get(params, :agent_name) || Map.get(params, "agent_name")

    env_path = Path.join(osa_dir(), ".env")

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
      |> merge_env({onboarding_meta_pairs(), []})

    env_content = serialize_env(merged)

    # 0600 applied to the temp file BEFORE the keys are written to it, then
    # renamed into place. `File.write` followed by `File.chmod` is a real
    # TOCTOU hole, not a theoretical one: between the two calls the file exists
    # at the process umask (0644 on a default Linux install) with every API key
    # already in it, readable by any local process.
    case AtomicFile.write(env_path, env_content, mode: 0o600) do
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
    File.mkdir_p!(osa_dir())

    provider = Map.get(params, :provider) || Map.get(params, "provider")
    api_key = Map.get(params, :api_key) || Map.get(params, "api_key")
    base_url = Map.get(params, :base_url) || Map.get(params, "base_url")
    model = Map.get(params, :model) || Map.get(params, "model")
    set_active = Map.get(params, :set_active, Map.get(params, "set_active", true))

    env_path = Path.join(osa_dir(), ".env")
    existing = parse_env_file(env_path)

    merged =
      if set_active do
        merge_env(existing, provider_env_pairs(provider, model, api_key, base_url))
      else
        env_var = provider_env_var(provider)
        pairs = [maybe_pair(env_var, api_key)] |> Enum.reject(&is_nil/1)
        merge_env(existing, {pairs, []})
      end

    # 0600 from birth — see the note on the other .env write in this module.
    case AtomicFile.write(env_path, serialize_env(merged), mode: 0o600) do
      :ok ->
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

    # The CredentialPool snapshots keys at boot and its get_key/1 takes
    # PRIORITY over Application env in the providers — so without this reload
    # the pool keeps serving the key captured at startup and the key the user
    # just entered never takes effect. They would watch their corrected key be
    # rejected over and over.
    _ = OptimalSystemAgent.Providers.CredentialPool.reload()

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
      # Every other routable provider follows the `:<provider>_api_key`
      # convention `config/runtime.exs` declares. Returning nil here meant
      # `apply_provider_key/2` was a no-op for two-thirds of the catalog.
      other -> if match?({:ok, _}, known_provider_atom(other)), do: :"#{other}_api_key", else: nil
    end
  end

  @doc """
  Seed workspace templates from priv/prompts/ to ~/.osa/.

  Only copies files that don't already exist — never overwrites user data.
  """
  def seed_workspace do
    File.mkdir_p!(osa_dir())
    priv_dir = :code.priv_dir(:optimal_system_agent) |> to_string()
    prompts_dir = Path.join(priv_dir, "prompts")

    Enum.each(@workspace_templates, fn filename ->
      source = Path.join(prompts_dir, filename)
      dest = Path.join(osa_dir(), filename)

      if File.exists?(source) and not File.exists?(dest) do
        File.cp!(source, dest)
        Logger.debug("[Onboarding] Seeded #{filename} → #{dest}")
      end
    end)

    # Seed the documented, user-editable config.toml (never clobbers an
    # existing one). This is the standard config surface — see ConfigFile.
    try do
      OptimalSystemAgent.ConfigFile.write_default_template()
    rescue
      e -> Logger.debug("[Onboarding] config.toml seed skipped: #{inspect(e)}")
    end
  end

  @doc "Run post-setup health checks."
  def doctor_checks do
    checks = []

    # Check .env exists
    env_path = Path.join(osa_dir(), ".env")

    checks =
      if File.exists?(env_path) do
        [{:ok, ".env file exists"} | checks]
      else
        [{:error, ".env file missing", "Run /setup to configure"} | checks]
      end

    # Check workspace files
    missing =
      @workspace_templates
      |> Enum.reject(&File.exists?(Path.join(osa_dir(), &1)))

    checks =
      if missing == [] do
        [{:ok, "All workspace templates seeded"} | checks]
      else
        [{:error, "Missing workspace files", Enum.join(missing, ", ")} | checks]
      end

    # Update-check UX: surface a pending release in doctor output.
    checks =
      case update_check() do
        %{update_available: true, latest: latest} ->
          [{:error, "Update available: v#{latest}", "Run `osa update` to upgrade"} | checks]

        %{current: current} ->
          [{:ok, "OSA up to date (v#{current})"} | checks]
      end

    Enum.reverse(checks)
  end

  @doc """
  Update-check UX (CC parity: AutoUpdater status line). Wraps
  `ReleaseNotes.version_status/0` and never raises — a git/tag/network
  failure reports the running version with no update flagged.
  """
  @spec update_check() :: %{
          current: String.t(),
          latest: String.t(),
          update_available: boolean(),
          hint: String.t() | nil
        }
  def update_check do
    status = OptimalSystemAgent.ReleaseNotes.version_status()
    hint = if status.update_available, do: "Run `osa update` to upgrade", else: nil
    Map.put(status, :hint, hint)
  rescue
    _ ->
      current = safe_current_version()
      %{current: current, latest: current, update_available: false, hint: nil}
  end

  @doc """
  The OSA version that last completed the onboarding wizard, or nil.

  Recorded as OSA_ONBOARDING_VERSION by `write_setup/1` (CC parity:
  lastOnboardingVersion) so future releases can re-run new wizard steps
  after an upgrade instead of gating on the .env file alone.
  """
  @spec completed_onboarding_version() :: String.t() | nil
  def completed_onboarding_version do
    osa_dir()
    |> Path.join(".env")
    |> parse_env_file()
    |> List.keyfind("OSA_ONBOARDING_VERSION", 0)
    |> case do
      {_, v} when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  defp safe_current_version do
    OptimalSystemAgent.ReleaseNotes.current_version()
  rescue
    _ -> "unknown"
  end

  defp onboarding_meta_pairs do
    [
      maybe_pair("OSA_ONBOARDING_VERSION", safe_current_version()),
      maybe_pair("OSA_ONBOARDED_AT", DateTime.utc_now() |> DateTime.to_iso8601())
    ]
    |> Enum.reject(&is_nil/1)
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
  # One shared implementation with the boot loader (`Application.load_dotenv/0`)
  # and `CLI.Setup`. Four hand-rolled copies of this loop existed, all with the
  # same U+FEFF hole; a fix in one of them would have left the surfaces
  # disagreeing about what a key is called, which on this path means one
  # reporting "no key configured" while another writes the key back out.
  defp parse_env_file(path), do: OptimalSystemAgent.Config.Dotenv.parse_file(path)

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
        # Every other routable provider (google, xai, groq, deepseek, mistral,
        # cohere, cerebras, fireworks, …). The old catch-all wrote the provider
        # and the model but silently DROPPED the API key, so picking any of
        # them produced a `.env` that selected a provider with no credential —
        # "not configured" on the first turn, with the key the user had just
        # typed nowhere on disk.
        # No base-URL var is persisted here on purpose: `config/runtime.exs`
        # only reads OPENAI_BASE_URL / ANTHROPIC_BASE_URL back, so writing a
        # `GOOGLE_BASE_URL` would be a setting that silently does nothing after
        # a restart. A non-standard endpoint is what the Custom Endpoint entry
        # is for.
        {[
           {"OSA_DEFAULT_PROVIDER", other},
           maybe_pair(provider_env_var(other) || generic_env_var(other), api_key),
           maybe_pair("OSA_MODEL", model)
         ], ["OLLAMA_MODEL"]}
    end
  end

  # `<PROVIDER>_API_KEY` — the convention `config/runtime.exs` already reads
  # for every provider it declares.
  defp generic_env_var(provider_id),
    do: provider_id |> to_string() |> String.upcase() |> Kernel.<>("_API_KEY")

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

  # Picker id -> the provider id the rest of OSA resolves. `ollama_cloud` and
  # `ollama_local` are two credential routes to the SAME `:ollama` provider
  # (distinguished by OLLAMA_URL); `custom` is the OpenAI-compatible client
  # pointed at a user-supplied base URL.
  @doc false
  @spec runtime_provider_id(String.t()) :: String.t()
  def runtime_provider_id("ollama_cloud"), do: "ollama"
  def runtime_provider_id("ollama_local"), do: "ollama"
  def runtime_provider_id("custom"), do: "openai"
  def runtime_provider_id(provider), do: provider

  defp apply_env_vars(provider, model, api_key, base_url) do
    # Resolve to a provider atom the Registry ALREADY declares. The old
    # `String.to_atom(p)` minted an atom from whatever string arrived, which
    # both grows the atom table without bound and could install a
    # `:default_provider` that routes nowhere.
    provider_atom =
      case known_provider_atom(runtime_provider_id(provider)) do
        {:ok, atom} -> atom
        :error -> :ollama
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

        # `provider_env_pairs/4` persists OPENAI_BASE_URL for "openai" too (an
        # Azure/proxy front-end still selected as the OpenAI provider). Applying
        # it in-process as well means the very next request honours it instead
        # of silently dialling api.openai.com until the daemon restarts —
        # `OpenAICompatProvider` reads `:openai_url`, not the env var.
        if base_url do
          System.put_env("OPENAI_BASE_URL", base_url)
          Application.put_env(:optimal_system_agent, :openai_url, base_url)
        end

      "custom" ->
        if api_key do
          System.put_env("OPENAI_API_KEY", api_key)
          Application.put_env(:optimal_system_agent, :openai_api_key, api_key)
        end

        if base_url do
          System.put_env("OPENAI_BASE_URL", base_url)
          Application.put_env(:optimal_system_agent, :openai_url, base_url)
        end

      other ->
        # Generic path for every other routable provider. Previously a no-op,
        # so a Google/xAI/Groq/… key entered in the wizard was written to disk
        # but never applied to the running node — the user had to restart to
        # get the thing they had just configured.
        if api_key do
          System.put_env(generic_env_var(other), api_key)
          Application.put_env(:optimal_system_agent, :"#{other}_api_key", api_key)
        end

        if base_url do
          Application.put_env(:optimal_system_agent, :"#{other}_url", base_url)
        end
    end

    # The provider itself is applied for EVERY branch (the per-provider cases
    # above only handle keys/URLs). `Registry.default_provider/0` re-reads
    # OSA_DEFAULT_PROVIDER live, so setting it here is what makes the switch
    # land on the next turn without a restart.
    case known_provider_atom(runtime_provider_id(provider)) do
      {:ok, _atom} -> System.put_env("OSA_DEFAULT_PROVIDER", runtime_provider_id(provider))
      :error -> :ok
    end

    # The CredentialPool snapshots every *_API_KEY at boot and its `get_key/1`
    # takes PRIORITY over Application env in `Providers.Anthropic.resolve_auth/0`.
    # `apply_provider_key/2` already reloaded it; `apply_env_vars/4` — the path
    # every onboarding/setup write actually goes through (`write_setup/1`,
    # `upsert_provider_key/1` with `set_active: true`) — did not. So a user who
    # booted with a wrong/expired ANTHROPIC_API_KEY and corrected it in the
    # wizard watched the OLD key be rejected turn after turn, no matter how
    # many times they re-entered the right one. One reload closes it for every
    # write path.
    _ = OptimalSystemAgent.Providers.CredentialPool.reload()

    :ok
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
            AtomicFile.write!(
              env_path,
              existing <> "\n# Computer Use (auto-detected Linux X11)\nOSA_COMPUTER_USE=true\n",
              mode: 0o600
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
    path = Path.join(osa_dir(), "USER.md")

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
            AtomicFile.write!(path, updated)
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
    path = Path.join(osa_dir(), "IDENTITY.md")

    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          updated =
            String.replace(content, "- **Name:** OSA\n", "- **Name:** #{agent_name}\n",
              global: false
            )

          if updated != content do
            AtomicFile.write!(path, updated)
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
          model: model || OptimalSystemAgent.Providers.AnthropicModels.default_model(),
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
          model: model || "glm-5.2:cloud",
          messages: [%{role: "user", content: "hi"}],
          stream: false,
          options: %{num_predict: 5}
        }

        {url, headers, body}

      # ── Native (non-OpenAI-shaped) protocols ──────────────────────────
      #
      # Google, Cohere and Replicate do NOT speak `/chat/completions`. Probing
      # them with an OpenAI-shaped request is how "your key was rejected" gets
      # reported for a perfectly good key — and routing them to a DEFAULT
      # OpenAI URL is how a Google key ends up POSTed to a third party. Each
      # gets its own real endpoint, in its own wire format.
      "google" ->
        model_id = model || OptimalSystemAgent.Providers.Google.default_model()
        base = base_url || provider_base_url(:google)

        # Key travels in `x-goog-api-key`, not `?key=` — a query-string
        # credential leaks into proxy logs and crash reports.
        headers = [
          {"x-goog-api-key", api_key || ""},
          {"content-type", "application/json"}
        ]

        body = %{
          contents: [%{role: "user", parts: [%{text: "hi"}]}],
          generationConfig: %{maxOutputTokens: 5}
        }

        {"#{base}/models/#{model_id}:generateContent", headers, body}

      "cohere" ->
        headers = [
          {"authorization", "Bearer #{api_key || ""}"},
          {"content-type", "application/json"}
        ]

        body = %{
          model: model || OptimalSystemAgent.Providers.Cohere.default_model(),
          max_tokens: 5,
          messages: [%{role: "user", content: "hi"}]
        }

        {"#{base_url || provider_base_url(:cohere)}/chat", headers, body}

      "replicate" ->
        # Replicate authenticates with `Token <key>` and has no cheap chat
        # probe — its account endpoint is the documented key check. `nil` body
        # marks this as a GET (see `do_health_request/5`).
        headers = [{"authorization", "Token #{api_key || ""}"}]
        {"#{base_url || provider_base_url(:replicate)}/account", headers, nil}

      _ ->
        # OpenAI-compatible (miosa, openrouter, openai, custom, groq, xai,
        # deepseek, mistral, cerebras, fireworks, together, perplexity, the
        # Chinese providers, and the local lmstudio/llamacpp servers).
        #
        # The URL is resolved from the provider's OWN routing table
        # (`OpenAICompatProvider.base_url/1`, via `provider_base_url/1`) rather
        # than defaulting to api.openai.com — that default is what previously
        # sent a Groq/xAI/DeepSeek key to OpenAI. A provider we cannot resolve
        # an endpoint for still yields `nil`, and `run_health_request/5` says
        # so honestly instead of guessing.
        resolved_url =
          case provider do
            "custom" ->
              if base_url, do: "#{base_url}/chat/completions", else: nil

            "openai" ->
              "#{base_url || provider_base_url(:openai)}/chat/completions"

            other ->
              cond do
                is_binary(base_url) and base_url != "" ->
                  "#{base_url}/chat/completions"

                true ->
                  case known_provider_atom(runtime_provider_id(other)) do
                    {:ok, atom} ->
                      case provider_base_url(atom) do
                        url when is_binary(url) and url != "" -> "#{url}/chat/completions"
                        _ -> nil
                      end

                    :error ->
                      nil
                  end
              end
          end

        headers = [
          {"authorization", "Bearer #{api_key || ""}"},
          {"content-type", "application/json"}
        ]

        # Default to the PROVIDER'S own model, not OpenAI's. Probing Groq or
        # xAI with `gpt-5.6-terra` returns a model-not-found 404 that the user
        # reads as "my key failed" — the endpoint was right and the model was
        # borrowed from the wrong catalog.
        resolved_model =
          model || derived_default_model(runtime_provider_id(provider)) ||
            OptimalSystemAgent.Providers.OpenAIModels.default_model()

        # Reasoning models (the o-series AND the GPT-5.x family) reject
        # `max_tokens` with a 400 and require `max_completion_tokens`. The
        # runtime path already gets this right; the health check did not, so
        # probing a reasoning model with a perfectly valid key returned
        # "server_error" and the user was told their key failed.
        token_field =
          if OptimalSystemAgent.Providers.OpenAIModels.reasoning?(resolved_model),
            do: :max_completion_tokens,
            else: :max_tokens

        body =
          %{
            model: resolved_model,
            messages: [%{role: "user", content: "hi"}]
          }
          |> Map.put(token_field, 5)

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

  # The cloud tags a signed-in daemon reports it can proxy, enriched from the
  # shipped catalog where the two agree.
  #
  # Three outcomes, and the middle one is the point:
  #
  #   * daemon lists hosted tags -> those, and only those
  #   * daemon reachable but lists none -> `{:ok, []}`. Showing the full
  #     catalog here would be inventing a list: the account demonstrably
  #     cannot reach any of it, and an empty picker is the honest answer.
  #   * daemon unreachable / unreadable -> the shipped catalog, i.e. exactly
  #     what every caller got before this existed. Not knowing is not the same
  #     as knowing the answer is empty.
  defp ollama_account_models(base_url, catalog) do
    # `retry: false`: a daemon that is not there is not going to be there in
    # four seconds, and this runs while a user waits at a picker.
    case Req.get("#{base_url}/api/tags", receive_timeout: 5_000, retry: false) do
      {:ok, %{status: 200, body: %{"models" => models}}} when is_list(models) ->
        by_id = Map.new(catalog, &{&1.id, &1})

        {:ok,
         models
         |> Enum.filter(&hosted_ollama_model?/1)
         |> Enum.map(fn m ->
           id = m["name"] || m["model"]

           Map.get(by_id, id) ||
             %{
               id: id,
               name: id,
               ctx: get_in(m, ["details", "context_length"]) || 0,
               tools: "tools" in (m["capabilities"] || []),
               recommended: false,
               note: "reported by your Ollama daemon"
             }
         end)
         |> Enum.reject(&is_nil(&1.id))}

      _ ->
        {:ok, catalog}
    end
  rescue
    _ -> {:ok, catalog}
  end

  # A hosted tag is one the daemon says it proxies (`remote_host`), with the
  # naming convention as a fallback for daemons that do not report it.
  defp hosted_ollama_model?(m) do
    remote = m["remote_host"]

    (is_binary(remote) and remote != "") or
      OptimalSystemAgent.Providers.OllamaCloud.cloud_tag?(m["name"] || m["model"] || "")
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

  @doc """
  Probe the local Ollama daemon (`http://localhost:11434` by default) for
  reachability. Public so the setup wizard can offer the keyless
  "signed-in local Ollama" path for `ollama_cloud` (M2 fix) without
  duplicating the localhost-only guard here.

  Never raises — any failure (daemon down, DNS, timeout, malformed body)
  degrades to `reachable: false` so callers (onboarding status, health-check)
  can always render/return SOMETHING instead of crashing.
  """
  @spec probe_ollama_local() :: %{
          reachable: boolean(),
          url: String.t(),
          model_count: non_neg_integer()
        }
  def probe_ollama_local(req_opts \\ []) do
    url =
      Application.get_env(:optimal_system_agent, :ollama_url, "http://localhost:11434")

    # Only probe if URL looks local
    uri = URI.parse(url)
    host = uri.host || "localhost"

    if host in ["localhost", "127.0.0.1", "::1"] do
      case Req.get([url: "#{url}/api/tags", receive_timeout: 3_000] ++ req_opts) do
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

  @doc """
  Decide the `ollama_cloud` connection route: keyless "signed-in local
  Ollama" (proxies `:cloud` models via device identity — no key needed) vs.
  keyed `https://ollama.com` (a different account, or a headless box with no
  local daemon).

  Pure decision table, shared between the standalone `mix osa.setup.wizard`
  (`bin/osa`'s first-run wizard) and the in-app `/setup` command
  (`OptimalSystemAgent.CLI.Setup`) so both entry points offer the exact same
  choice instead of the in-app wizard silently pinning `OLLAMA_URL=
  https://ollama.com` and demanding a key even when a local daemon is already
  signed in.

    * signed in locally, chose the keyless route -> localhost, NO key
      (must never fall through to https://ollama.com)
    * key entered (with or without a local daemon) -> ollama.com, WITH key
  """
  @spec ollama_cloud_route(boolean(), boolean(), String.t() | nil) ::
          {String.t() | nil, String.t()}
  def ollama_cloud_route(local_reachable, use_local?, key)
  def ollama_cloud_route(true, true, _key), do: {nil, "http://localhost:11434"}
  def ollama_cloud_route(_local_reachable, _use_local?, key), do: {key, "https://ollama.com"}

  @doc """
  The options a provider's auth step should offer, in render order.

  `auth_modes` is a **capability set** in a canonical order (`:api_key` first,
  so the key-only default `[:api_key]` is a stable prefix and equality
  comparisons against it are meaningful). Presentation order is decided *here*
  instead, because it is a UX question, not a data question: sign-in is shown
  first for a user who already pays for the plan.

  Returns `[]` for a key-only provider — meaning **do not prompt at all**,
  fall straight through to the existing key flow. That empty list is what
  keeps the 27 key-only providers byte-identical to their pre-`auth_modes`
  behaviour: no extra question, no extra keystroke.

  Returns a `Prompt.select/2`-shaped option list for a dual-mode provider.
  Sign-in is listed first because it is the cheaper answer for someone who
  already pays for the plan, and the hints name the BILLING MODEL
  ("subscription" vs "pay-per-token") rather than the protocol, because that
  is the distinction the user is actually choosing between.

  Pure — no I/O, no TTY. Shared by the in-app `/setup`
  (`OptimalSystemAgent.CLI.Setup`) and the standalone `mix osa.setup.wizard`
  so both entry points render the identical fork, exactly as
  `ollama_cloud_route/3` already does for Ollama Cloud.
  """
  @spec auth_options(String.t() | atom()) :: [map()]
  def auth_options(provider_id) do
    id = to_string(provider_id)
    entry = Enum.find(providers_list(), &(&1.id == id)) || %{id: id}

    auth_options_for(entry)
  end

  @doc """
  `auth_options/1` for a provider entry that is already in hand.

  The catalog lookup and the decision are split because they are different
  concerns and fail differently: the lookup can miss, the decision cannot.
  Keeping the decision total and pure means it can be exercised directly —
  including for a provider shape that is not (yet) in the catalog — without
  either mocking the catalog or, worse, adding a half-wired entry to the real
  one just to have something to test against.
  """
  @spec auth_options_for(map()) :: [map()]
  def auth_options_for(entry) when is_map(entry) do
    modes = usable_auth_modes_for(entry)

    if length(modes) < 2 do
      []
    else
      sub = Map.get(entry, :subscription) || %{}
      name = Map.get(entry, :name) || Map.get(entry, :id) || "this provider"

      # Sign-in first — see the note above on why order is decided here.
      modes
      |> Enum.sort_by(fn
        :oauth -> 0
        _ -> 1
      end)
      |> Enum.map(fn
        :oauth ->
          %{
            value: :oauth,
            label: Map.get(sub, :label) || "Sign in with #{name}",
            hint: Map.get(sub, :hint) || "Opens your browser — uses your existing plan"
          }

        :api_key ->
          %{
            value: :api_key,
            label: Map.get(sub, :key_label) || "Paste an API key",
            hint: Map.get(sub, :key_hint) || "Pay-per-token billing"
          }
      end)
    end
  end

  @doc """
  Resolve a provider + the user's (possibly absent) choice into the auth mode
  to execute.

  * a key-only provider always resolves to `:api_key`, whatever was passed —
    a stray `:oauth` choice can never route a provider into a sign-in flow
    that does not exist for it
  * `nil` (nothing chosen: non-interactive run, `--yes`, a TUI client that
    has not been taught the fork) resolves to `:api_key`, the mode that works
    everywhere and never blocks on a browser
  * an explicit, supported choice is honoured

  Pure decision table — the single place the fork's MEANING lives, so the two
  CLI surfaces cannot drift apart on it.
  """
  @spec auth_route(String.t() | atom(), :api_key | :oauth | nil) :: :api_key | :oauth
  def auth_route(provider_id, choice) do
    auth_route_for(usable_auth_modes(provider_id), choice)
  end

  @doc """
  The catalog as a *setup surface* needs it: every entry decorated with the
  grouping, the modes this machine can actually run, the labelled options for
  the fork, and the provider's current connection state.

  One function, because the alternative is what shipped: the TUI hardcoded its
  own idea of which providers offer sign-in (`ollama_cloud` and `miosa`, in a
  `match` on provider id), which disagreed with `auth_modes` the moment
  `openai_codex`, `claude_cli`, `copilot_cli` and `bedrock` were added. Every
  one of them rendered as "needs key". A surface that reads this function
  cannot hold that opinion.

  Pure read. `Auth.Subscription.status/1` never dials out and never refreshes,
  so drawing a picker can neither spend a rotating refresh token nor bill a
  metered request.
  """
  @spec provider_ui_entries() :: [map()]
  def provider_ui_entries do
    Enum.map(providers_list(), &decorate_for_ui/1)
  end

  @doc "`provider_ui_entries/0` for a single entry already in hand."
  @spec decorate_for_ui(map()) :: map()
  def decorate_for_ui(entry) when is_map(entry) do
    id = Map.get(entry, :id)
    usable = usable_auth_modes_for(entry)

    entry
    |> Map.put(:usable_auth_modes, usable)
    |> Map.put(:auth_options, auth_options_for(entry))
    |> Map.put(:auth, auth_state(id, usable))
  end

  # The three things a row has to be able to say, and the reason they are
  # separate: "OSA holds a record" (`connected`), "OSA has evidence behind it"
  # (`verified`) and "this machine could sign in if asked" (`can_sign_in`).
  # Collapsing the first two is how a status row presents a guess as a fact —
  # see the `Auth.Subscription` moduledoc on Copilot.
  defp auth_state(nil, _usable), do: %{state: "unknown"}

  defp auth_state(id, usable) do
    sub =
      if :oauth in usable do
        safe_status(id)
      else
        nil
      end

    state =
      cond do
        sub && sub.connected? && sub.expired? -> "expired"
        sub && sub.connected? && sub.verified? -> "connected"
        sub && sub.connected? -> "connected_unverified"
        :oauth in usable -> "needs_sign_in"
        true -> "needs_key"
      end

    %{
      state: state,
      can_sign_in: :oauth in usable,
      can_paste_key: :api_key in usable,
      account: sub && sub.account,
      plan: sub && sub.plan,
      expires_at: sub && sub.expires_at
    }
  end

  defp safe_status(id) do
    OptimalSystemAgent.Auth.Subscription.status(id)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  @doc """
  `auth_route/2` for a mode list already in hand.

  The default when nothing is chosen is `:api_key` **when that mode is
  available**, because it works everywhere and never blocks on a browser. A
  provider that offers ONLY sign-in (`openai_codex` — an OpenAI API key
  belongs on the `openai` entry, billed per-token against the endpoint that
  accepts it) has no key path to fall back to, so it resolves to its single
  available mode instead. Falling back to `:api_key` there would prompt for a
  credential the provider cannot use.
  """
  @spec auth_route_for([:api_key | :oauth], :api_key | :oauth | nil) :: :api_key | :oauth
  def auth_route_for(modes, choice) when is_list(modes) do
    cond do
      choice != nil and choice in modes -> choice
      :api_key in modes -> :api_key
      true -> List.first(modes) || :api_key
    end
  end

  @doc """
  The declared auth modes, minus any the running build cannot actually
  perform.

  `auth_modes/1` answers what the provider *offers*; this answers what the
  user can *do right now*. They differ when a sign-in implementation exists
  but has no registered OAuth client id configured — in that case `:oauth` is
  dropped here, the fork is not rendered, and the provider behaves exactly
  like a key-only one. Degrading to "one fewer menu entry" is the only
  acceptable outcome; offering a path that cannot possibly complete is not.

  `:api_key` is never removed, so this can never return an empty list and no
  provider can become unconfigurable.
  """
  @spec usable_auth_modes(String.t() | atom()) :: [:api_key | :oauth]
  def usable_auth_modes(provider_id) do
    id = to_string(provider_id)
    entry = Enum.find(providers_list(), &(&1.id == id)) || %{id: id}

    usable_auth_modes_for(entry)
  end

  @doc "`usable_auth_modes/1` for a provider entry already in hand."
  @spec usable_auth_modes_for(map()) :: [:api_key | :oauth]
  def usable_auth_modes_for(entry) when is_map(entry) do
    id = Map.get(entry, :id)

    entry
    |> Map.get(:auth_modes, [:api_key])
    |> Enum.filter(fn
      :oauth -> OptimalSystemAgent.Auth.Subscription.available?(id)
      _ -> true
    end)
  end

  # Asked through the same parser the rest of the credential path uses, so
  # "is onboarding done?" and "what does that file contain?" can never
  # disagree — a BOM used to make this answer yes while `parse_env_file/1`
  # produced a key nothing could look up.
  defp env_has_provider?(env_path) do
    env_path
    |> OptimalSystemAgent.Config.Dotenv.parse_file()
    |> List.keymember?("OSA_DEFAULT_PROVIDER", 0)
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> "unknown"
    end
  end
end
