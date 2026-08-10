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

  alias OptimalSystemAgent.Auth.Providers.Copilot
  alias OptimalSystemAgent.Auth.Providers.OpenAICodex
  alias OptimalSystemAgent.Auth.SubscriptionStore

  @typedoc "Everything a caller needs to display connection state, with no secrets in it."
  @type status :: %{
          connected?: boolean(),
          provider: String.t(),
          account: String.t() | nil,
          plan: String.t() | nil,
          expires_at: integer() | nil,
          expired?: boolean()
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
    "copilot" => Copilot,
    "openai_codex" => OpenAICodex
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
    do: "Sign-in cancelled. Nothing was saved — re-run setup to try again, or paste #{a_an(name)} API key instead."

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
        "Re-run setup for a fresh code, or paste an API key instead."

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

  def message(:not_connected, name),
    do: "Not signed in to #{name}. Run `osa setup` and choose \"Sign in\", or paste an API key."

  def message(:unsupported_provider, name),
    do: "#{name} does not support account sign-in. Use an API key."

  def message(:lock_timeout, name),
    do:
      "Timed out waiting for another OSA process to finish updating #{name} credentials. " <>
        "Retry in a moment; if it persists, no other OSA process should be running."

  def message({:transport_error, detail}, name),
    do: "Could not reach #{name} to sign in (#{detail}). Check your connection and retry, or paste an API key."

  def message({:http_error, status}, name),
    do: "#{name} returned an unexpected HTTP #{status} during sign-in. Retry, or paste an API key."

  def message({:oauth_error, detail}, name),
    do: "#{name} rejected the sign-in: #{detail}. Retry, or paste an API key."

  def message(other, name),
    do: "#{name} sign-in failed: #{inspect(other)}. You can paste an API key instead."

  defp a_an(<<first::utf8, _::binary>> = _name) when first in ~c"AEIOUaeiou", do: "an"
  defp a_an(_), do: "a"
end
