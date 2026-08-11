defmodule OptimalSystemAgent.Auth.Subscription do
  @moduledoc """
  The "connect my account" half of dual-mode provider auth.

  A provider that declares `auth_modes: [:api_key, :oauth]` in
  `Onboarding.providers_list/0` must have a module here implementing this
  behaviour. That is the whole contract: the catalog declares the capability,
  this behaviour supplies it, and the two setup surfaces call `login/2`
  without knowing anything about the provider.

  Dispatch is an explicit map rather than `String.to_atom/1` on a caller-
  supplied provider id — an unbounded atom table is a memory-exhaustion
  vector, and the same guard is already applied in `Onboarding`.

  ## Resolution contract

  `status/1` is a **pure read**. It never refreshes, never dials out. `osa
  doctor`, `osa auth status` and the model picker all call it, and none of
  them should be able to trigger a token refresh — let alone a refresh
  *failure* — as a side effect of drawing a screen.

  `access_token/1` MAY refresh, and is the only function that may.
  """

  alias OptimalSystemAgent.Auth.Providers.Bedrock
  alias OptimalSystemAgent.Auth.Providers.ClaudeCli
  alias OptimalSystemAgent.Auth.Providers.Copilot
  alias OptimalSystemAgent.Auth.Providers.CopilotCli
  alias OptimalSystemAgent.Auth.Providers.OllamaAccount
  alias OptimalSystemAgent.Auth.Providers.OpenAICodex
  alias OptimalSystemAgent.Auth.Providers.Qwen
  alias OptimalSystemAgent.Auth.Providers.XAI
  alias OptimalSystemAgent.Auth.SubscriptionStore

  @typedoc """
  Everything a caller needs to display connection state, with no secrets in it.

  `connected?` and `verified?` are **not** the same question, and collapsing
  them is how a status screen ends up lying:

    * `connected?` — the user asked OSA to use this provider and a marker
      exists. It is a statement about OSA's own records.
    * `verified?` — OSA has positive evidence the underlying sign-in is real.
      For `openai_codex` that is a token OSA holds; for `claude_cli` it is
      `claude auth status` having answered "signed in". For `copilot_cli` it is
      often **false while `connected?` is true**, because Copilot offers no way
      to confirm a sign-in offline and OSA will not spend a metered request to
      find out. That combination is the honest answer, not a bug, and a
      surface that renders only `connected?` presents a guess as a fact.
  """
  @type status :: %{
          required(:connected?) => boolean(),
          required(:verified?) => boolean(),
          required(:provider) => String.t(),
          required(:account) => String.t() | nil,
          required(:plan) => String.t() | nil,
          required(:expires_at) => integer() | nil,
          required(:expired?) => boolean(),
          # Optional because only some providers' markers record an
          # organisation — and the ones that do must be able to say so.
          # `account` alone does not identify an account: a user with a
          # personal plan and a work plan reads the same email on both, which
          # is exactly the ambiguity a status screen exists to remove. A
          # provider with no notion of an org omits the key rather than
          # sending `nil`, so "no org" and "personal" stay distinguishable.
          optional(:org) => String.t() | nil
        }

  @doc "Run the interactive sign-in. `io` is an output callback so the flow is testable headlessly."
  @callback login(opts :: keyword()) :: {:ok, map()} | {:error, term()}

  @doc "Pure read of stored connection state. Must not perform network I/O."
  @callback status() :: status()

  @doc "A usable access token, refreshing first if it is close to expiry."
  @callback access_token() :: {:ok, String.t()} | {:error, term()}

  @doc "Forget the stored credential."
  @callback logout() :: :ok | {:error, term()}

  # Provider id (as it appears in the onboarding catalog) → implementation.
  @implementations %{
    # Not an OAuth client either, and not a bring-your-own-CLI: `bedrock`
    # connects the AWS credential chain the machine already has and signs
    # every request with SigV4. Like the CLI-backed entries it holds no
    # token — the AWS secret stays where AWS put it and is re-read live.
    "bedrock" => Bedrock,
    # Not an OAuth client: `claude_cli` verifies an existing Claude Code
    # sign-in and holds no credential. It implements this behaviour anyway so
    # every surface asks the same question of every subscription provider.
    "claude_cli" => ClaudeCli,
    "copilot" => Copilot,
    # Same bring-your-own-CLI shape as claude_cli: no client id, no token held.
    "copilot_cli" => CopilotCli,
    # The one entry that is a SECOND mode on an existing key provider rather
    # than a provider of its own: `ollama_cloud` keeps its API key path
    # untouched and gains "use my signed-in local daemon" beside it. No token
    # is held here either — the daemon owns the device key.
    "ollama_cloud" => OllamaAccount,
    "openai_codex" => OpenAICodex,
    # Third of the same shape. `qwen` differs from `xai` in one respect only:
    # its two modes reach different hosts, because an account is issued a
    # `resource_url` at sign-in while a DashScope key belongs to DashScope.
    # That is the `ollama_cloud` situation, not a reason to split the row.
    "qwen" => Qwen,
    # The second entry of that shape (see `ollama_cloud` above), and the first
    # one where OSA genuinely HOLDS the account credential: `xai` keeps its
    # `XAI_API_KEY` path byte-identical and gains "sign in with your xAI
    # account" beside it. Same host, same wire format, same models — only the
    # credential differs, which is why it is one row with two modes rather
    # than an `openai`/`openai_codex`-style split.
    "xai" => XAI
  }

  @doc "The provider ids that support account sign-in."
  @spec supported() :: [String.t()]
  def supported, do: Map.keys(@implementations) |> Enum.sort()

  @doc "The implementation module for a provider id, or `nil`."
  @spec impl(String.t() | atom()) :: module() | nil
  def impl(provider_id), do: Map.get(@implementations, to_string(provider_id))

  @doc "True when this provider can be connected via account sign-in."
  @spec supported?(String.t() | atom()) :: boolean()
  def supported?(provider_id), do: not is_nil(impl(provider_id))

  @doc """
  True when sign-in can actually be ATTEMPTED in this build — not merely that
  code for it exists.

  The distinction is real: an OAuth flow needs a registered client id, and a
  build without one can implement the provider perfectly and still be unable
  to sign anyone in. Offering the menu entry anyway would send the user down a
  path that cannot succeed, so the setup surfaces consult this (not
  `supported?/1`) before rendering the fork, and a provider whose sign-in is
  unavailable silently degrades to the API-key prompt it would have shown
  before this feature existed.

  A module opts into the check by exporting `available?/0`; one that does not
  is assumed always available.
  """
  @spec available?(String.t() | atom()) :: boolean()
  def available?(provider_id) do
    case impl(provider_id) do
      nil ->
        false

      module ->
        Code.ensure_loaded?(module) and
          (not function_exported?(module, :available?, 0) or module.available?())
    end
  rescue
    _ -> false
  end

  @doc """
  Run a provider's sign-in flow.

  Returns `{:error, :unsupported_provider}` rather than raising for a provider
  with no implementation, so a catalog entry that declares `:oauth` before its
  module exists degrades to a clear message instead of a crash.
  """
  @spec login(String.t() | atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def login(provider_id, opts \\ []) do
    case impl(provider_id) do
      nil -> {:error, :unsupported_provider}
      module -> module.login(opts)
    end
  end

  @doc "Pure read of a provider's connection state. Never touches the network."
  @spec status(String.t() | atom()) :: status()
  def status(provider_id) do
    case impl(provider_id) do
      nil -> disconnected(provider_id)
      module -> module.status()
    end
  end

  @doc "Connection state for every sign-in-capable provider. Pure read."
  @spec status_all() :: [status()]
  def status_all, do: Enum.map(supported(), &status/1)

  @doc "A usable access token for a connected provider, refreshing if needed."
  @spec access_token(String.t() | atom()) :: {:ok, String.t()} | {:error, term()}
  def access_token(provider_id) do
    case impl(provider_id) do
      nil -> {:error, :unsupported_provider}
      module -> module.access_token()
    end
  end

  @doc "Sign out of a provider. Idempotent."
  @spec logout(String.t() | atom()) :: :ok | {:error, term()}
  def logout(provider_id) do
    case impl(provider_id) do
      nil -> SubscriptionStore.delete(provider_id)
      module -> module.logout()
    end
  end

  @doc false
  @spec disconnected(String.t() | atom()) :: status()
  def disconnected(provider_id) do
    %{
      connected?: false,
      verified?: false,
      provider: to_string(provider_id),
      account: nil,
      plan: nil,
      expires_at: nil,
      expired?: false
    }
  end

  # ── User-facing messages ────────────────────────────────────────────────

  @doc """
  Turn a failure reason into one honest, actionable line.

  Two rules are enforced here deliberately:

  **Never append "re-authenticate" to a quota or entitlement error.** A user
  whose subscription is out of credits has a perfectly valid credential;
  telling them to sign in again sends them round a loop that cannot fix it,
  and hides the real cause. Those cases get their own messages and never
  mention re-auth.

  **Always name the fallback.** Every one of these ends with the API-key route
  still being available, because a user blocked on sign-in should not be stuck
  — the whole point of the two-mode fork is that either mode reaches the same
  configured state.
  """
  @spec message(term(), String.t()) :: String.t()
  def message(reason, provider_name \\ "this provider")

  def message(:cancelled, name),
    do:
      "Sign-in cancelled. Nothing was saved — re-run setup to try again, or paste #{a_an(name)} API key instead."

  def message(:access_denied, name),
    do:
      "Sign-in was denied in the browser. If that was not deliberate, re-run setup and approve the request — " <>
        "or paste #{a_an(name)} API key instead."

  def message(:device_code_expired, name),
    do:
      "The sign-in code expired before it was approved. Re-run setup to get a fresh code, " <>
        "or paste #{a_an(name)} API key instead."

  def message(:refresh_token_invalid, name),
    do:
      "Your #{name} sign-in is no longer valid — it was revoked, or it expired after a long gap. " <>
        "Re-run setup to sign in again, or paste an API key instead."

  def message(:invalid_client, name),
    do:
      "#{name} rejected OSA's application credentials. This is a problem with OSA's registration, not your account — " <>
        "please report it. You can use an API key in the meantime."

  # Deliberately NO "re-authenticate" guidance: the credential is fine.
  def message(:subscription_required, name),
    do:
      "No active #{name} subscription was found for that account. Activate a plan and retry — " <>
        "your sign-in itself worked, so there is nothing to fix about it."

  def message(:insufficient_credits, name),
    do:
      "That #{name} subscription is out of included usage. Top up or wait for the quota to reset — " <>
        "your sign-in is still valid."

  # Throttling at the LOGIN endpoint. Not a credential problem, so it must not
  # collect re-auth advice either — the user's credential may not even exist
  # yet.
  def message(:login_rate_limited, name),
    do:
      "#{name} is temporarily rate-limiting sign-in requests. This is on their side, not a problem " <>
        "with your account — wait a minute and try again, or paste an API key instead."

  def message(:device_code_timeout, name),
    do:
      "Timed out after 15 minutes waiting for #{name} sign-in to be approved. " <>
        "Run /login for a fresh code, or /provider to paste an API key instead."

  # The provider refused to issue a device code at all. Overwhelmingly this is
  # a security setting on the user's own account rather than anything wrong
  # with OSA or the request: ChatGPT ships "device code authorization" off for
  # some accounts and organisations, and the endpoint declines before any code
  # exists. The provider's verification page says to re-run *its own CLI*
  # afterwards, which is not the right instruction here, so the setting is
  # named and the tool is not.
  def message({:device_auth_refused, status, reason}, name) do
    base =
      "#{name} would not start a sign-in (HTTP #{status}). This is usually an account setting " <>
        "rather than a fault: device code authorization has to be enabled for your account or " <>
        "organization before any tool can request a code. Turn it on in your #{name} security " <>
        "settings, then run /login again."

    case reason do
      r when is_binary(r) -> base <> "\n\n#{name} said: #{r}"
      _ -> base
    end
  end

  def message(:device_code_incomplete, name),
    do:
      "#{name} returned an incomplete sign-in response. Retry, and if it persists please report it — " <>
        "you can use an API key in the meantime."

  # The honest-originator trade-off, surfaced rather than hidden. See
  # Auth.Providers.OpenAICodex's moduledoc.
  def message(:originator_rejected, name),
    do:
      "#{name} refused the request because OSA identifies itself honestly rather than claiming to be " <>
        "OpenAI's own Codex CLI. This is most common from a VPS or datacentre IP. Your sign-in is valid — " <>
        "set OSA_CODEX_ORIGINATOR to override, or use an API key."

  def message(:not_configured, name),
    do:
      "Account sign-in for #{name} is not available in this build: OSA has no registered OAuth client id for it. " <>
        "Paste an API key instead."

  # A credential with no expiry and no refresh token that the server has
  # started refusing. There is genuinely nothing to renew, so this is the one
  # 401-shaped case where "sign in again" is the correct and only advice.
  def message(:not_refreshable, name),
    do:
      "Your #{name} credential can no longer be renewed — it has no refresh token, and the one " <>
        "OSA holds is being refused. Run /login to sign in again, or /provider to paste an API key."

  # Everything a user needs is reachable from inside the running session: this
  # message is read from the TUI far more often than from a shell, and telling
  # someone to quit and run a different program to fix the thing they are
  # already looking at is the worst available answer. `/login` opens the
  # provider surface in place; the CLI remains available but is not the advice.
  def message(:not_connected, name),
    do: "Not signed in to #{name}. Run /login to sign in, or /provider to paste an API key."

  def message(:unsupported_provider, name),
    do: "#{name} does not support account sign-in. Use an API key."

  # Not a credential problem and not a user error: another OSA process held the
  # store's lock long enough to be judged dead, took it over, and this process
  # correctly abandoned its own write rather than clobbering the newer
  # credential. Retrying re-reads whatever the winner wrote, which is normally
  # a perfectly good token — so this must not send anyone to a re-auth.
  def message(:lock_lost, name),
    do:
      "Another OSA process finished updating #{name} credentials first, so this update was " <>
        "discarded rather than overwriting it. Retry — your sign-in is intact."

  def message(:lock_timeout, name),
    do:
      "Timed out waiting for another OSA process to finish updating #{name} credentials. " <>
        "Retry in a moment; if it persists, no other OSA process should be running."

  def message({:transport_error, detail}, name),
    do:
      "Could not reach #{name} to sign in (#{detail}). Check your connection and retry, or paste an API key."

  def message({:http_error, status}, name),
    do:
      "#{name} returned an unexpected HTTP #{status} during sign-in. Retry, or paste an API key."

  def message({:oauth_error, detail}, name),
    do: "#{name} rejected the sign-in: #{detail}. Retry, or paste an API key."

  # ── Externally-managed credentials (Claude Code) ────────────────────────
  #
  # These are not sign-in failures in the usual sense: the credential lives in
  # another vendor's client, so the remedy is a command in THAT client, not a
  # retry in OSA. Saying "re-run setup" here would send the user in a circle.
  def message(:cli_not_installed, name),
    do:
      "#{name} needs the Claude Code CLI, which is not installed or not on PATH. " <>
        "Install it from https://claude.com/product/claude-code (or set OSA_CLAUDE_CLI_BIN to its full path), " <>
        "then re-run setup. The Anthropic provider with an API key works without it."

  def message(:cli_not_signed_in, name),
    do:
      "Claude Code is installed but not signed in, so #{name} cannot be used yet. " <>
        "Run `claude auth login` (or `claude setup-token` on a headless machine), then re-run setup. " <>
        "OSA cannot perform that sign-in for you — Anthropic permits you to point your own Claude Code " <>
        "at a third-party tool, but not a third-party tool to offer Claude login."

  def message({:cli_too_old, version}, name),
    do:
      "Your Claude Code CLI (#{version || "unknown version"}) is older than #{name} requires. " <>
        "Run `claude update` and try again."

  def message(:cli_status_unreadable, _name),
    do:
      "Could not read `claude auth status`. Run it yourself to see what it says; if it works there, " <>
        "please report this."

  def message({:cli_error, detail}, _name),
    do: "Claude Code could not report its authentication status: #{detail}"

  def message(:externally_managed, name),
    do:
      "#{name} has no token for OSA to use — the credential is held by the client that owns it " <>
        "(the Claude Code CLI, or your local Ollama daemon), not by OSA. If you are seeing this, " <>
        "something asked for a token it should not need."

  # ── Externally-managed credentials (the local Ollama daemon) ────────────
  #
  # Same shape as the Claude Code cases above: the credential is the machine's
  # own Ed25519 key, held by Ollama's daemon, so every remedy is a command in
  # THAT client. "Re-run setup" alone would send the user in a circle.
  def message(:ollama_daemon_unreachable, name),
    do:
      "No local Ollama daemon answered, so #{name} cannot use your account. " <>
        "Start it with `ollama serve` (or launch the Ollama app), then re-run setup. " <>
        "An Ollama Cloud API key works without a local daemon."

  def message(:ollama_not_signed_in, name),
    do:
      "Your local Ollama daemon is running but not signed in, so #{name} has no account to use. " <>
        "Run `ollama signin`, then re-run setup. OSA cannot do it for you — signing in registers " <>
        "this machine's key with your ollama.com account, and only Ollama's own client can."

  def message({:ollama_host_remote, url}, name),
    do:
      "OLLAMA_HOST points at #{url}, which is not a local daemon, so #{name}'s account mode is " <>
        "unavailable. OSA will not send an account probe to a remote host. Unset OLLAMA_HOST to " <>
        "use the local daemon, or paste an Ollama Cloud API key."

  def message({:ollama_http, status}, name),
    do:
      "The local Ollama daemon answered HTTP #{status} when #{name} asked which account it is " <>
        "signed in as. Check `ollama serve` is healthy, or paste an Ollama Cloud API key."

  def message(other, name),
    do: "#{name} sign-in failed: #{inspect(other)}. You can paste an API key instead."

  defp a_an(<<first::utf8, _::binary>> = _name) when first in ~c"AEIOUaeiou", do: "an"
  defp a_an(_), do: "a"
end
