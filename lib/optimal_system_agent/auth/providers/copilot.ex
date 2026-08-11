defmodule OptimalSystemAgent.Auth.Providers.Copilot do
  @moduledoc """
  GitHub Copilot account sign-in, via GitHub's OAuth 2.0 device flow.

  ## Why Copilot is the provider OSA implements sign-in for first

  Of every provider with a subscription, GitHub is the only one that has
  **both** halves of a legitimate story:

    * a **public client registration path** — anyone can register an OAuth
      App or GitHub App and get their own client id, so OSA does not have to
      borrow another product's identity to function; and
    * an **official mechanism for billing inference to the signed-in user's
      own Copilot subscription**.

  That is why this is implemented the supported way and NOT via
  `api.github.com/copilot_internal/v2/token` with a copied editor client id,
  which is the route other third-party tools take. That route works, but it
  depends on an undocumented internal endpoint and on impersonating a
  first-party application — it can be turned off without notice, and the
  account carrying the risk is the user's.

  ## Configuration

  The client id is **not** hardcoded to somebody else's, so it must be
  supplied for this provider's sign-in to be offered at all:

      config :optimal_system_agent, :copilot_client_id, "Iv1.xxxxxxxxxxxx"

  or `OSA_COPILOT_CLIENT_ID` in the environment. With neither set, `login/1`
  returns `{:error, :not_configured}` and the setup surfaces hide the sign-in
  option and go straight to the API-key prompt — which is why the absence of a
  registration degrades to "one fewer menu entry", never to a broken flow.

  ## Token shape

  GitHub issues two different things depending on the registration:

    * **OAuth App** — a non-expiring user token, no refresh token.
    * **GitHub App with expiring user tokens** — an 8-hour access token plus a
      6-month refresh token.

  Both are handled. `expires_at: nil` means "does not expire", and
  `needs_refresh?/1` answers `false` for it forever rather than trying to
  refresh a token that has no refresh token — which would otherwise turn a
  perfectly good credential into a spurious "signed out" on every request.
  """

  @behaviour OptimalSystemAgent.Auth.Subscription

  require Logger

  alias OptimalSystemAgent.Auth.DeviceFlow
  alias OptimalSystemAgent.Auth.RefreshFailures
  alias OptimalSystemAgent.Auth.SubscriptionStore
  alias OptimalSystemAgent.Utils.Browser

  @provider_id "copilot"
  @display_name "GitHub Copilot"

  # `read:user` identifies the account; Copilot entitlement rides on the
  # registered app's own permissions, not on an OAuth scope string.
  @default_scope "read:user"

  @default_device_code_url "https://github.com/login/device/code"
  @default_token_url "https://github.com/login/oauth/access_token"
  @default_user_url "https://api.github.com/user"

  # Refresh this far ahead of expiry. Generous, because the alternative is a
  # token that expires between the check and the request landing.
  @refresh_skew_s 300

  @doc "The onboarding catalog id this module backs."
  @spec provider_id() :: String.t()
  def provider_id, do: @provider_id

  @doc "Human-readable name, used in every user-facing message."
  @spec display_name() :: String.t()
  def display_name, do: @display_name

  # ── Configuration ───────────────────────────────────────────────────────

  @doc """
  OSA's registered GitHub client id, or `nil`.

  `nil` is a supported state, not an error: it means this build has no
  registration, so account sign-in is simply not offered.
  """
  @spec client_id() :: String.t() | nil
  def client_id do
    case System.get_env("OSA_COPILOT_CLIENT_ID") ||
           Application.get_env(:optimal_system_agent, :copilot_client_id) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  @doc "True when account sign-in can actually be attempted."
  @spec available?() :: boolean()
  def available?, do: not is_nil(client_id())

  defp config do
    %{
      device_code_url:
        Application.get_env(:optimal_system_agent, :github_device_code_url, @default_device_code_url),
      token_url: Application.get_env(:optimal_system_agent, :github_token_url, @default_token_url),
      client_id: client_id(),
      scope: Application.get_env(:optimal_system_agent, :copilot_scope, @default_scope)
    }
  end

  defp user_url,
    do: Application.get_env(:optimal_system_agent, :github_user_url, @default_user_url)

  # ── Sign-in ─────────────────────────────────────────────────────────────

  @doc """
  Run the device-flow sign-in.

  Options:

    * `:io` — 1-arity callback receiving each user-facing line. Defaults to
      `IO.puts/1`. Injecting it is what makes the whole flow testable without
      a TTY.
    * `:on_tick` — 0-arity callback run between polls; return `:cancel` to
      abort. Used to drive a spinner and to honour Ctrl-C.
    * `:open_browser` — defaults to true. `Utils.Browser.open/1` is already a
      no-op under `config :optimal_system_agent, :browser_open_enabled, false`
      (set in `config/test.exs`), so the suite cannot launch a real browser.

  The user code is printed **before** the browser is opened, so that a failed
  or missing opener — routine over SSH — leaves the user with everything they
  need to finish by hand rather than a dead end.
  """
  @impl true
  @spec login(keyword()) :: {:ok, map()} | {:error, term()}
  def login(opts \\ []) do
    io = Keyword.get(opts, :io, &IO.puts/1)
    on_tick = Keyword.get(opts, :on_tick, fn -> :continue end)
    cfg = config()

    cond do
      is_nil(cfg.client_id) ->
        {:error, :not_configured}

      # NOTHING IN OSA CAN SPEND THIS TOKEN. See `no_transport?/0`.
      #
      # This flow completed, wrote a real long-lived GitHub bearer token to
      # `~/.osa/subscriptions.json`, and returned "✓ Connected" — and then no
      # transport ever read it, because Copilot inference is not
      # OpenAI-compatible and OSA deliberately does not use the undocumented
      # `copilot_internal/v2/token` route (see the moduledoc). The user got a
      # credential at rest and zero capability.
      #
      # The rule `Auth.Providers.MiniMax` states for itself applies here too:
      # nothing is offered until it is completely wired, because a provider a
      # user can select but never send a request through fails several
      # screens after the mistake. MiniMax is honest about that by staying
      # out of the catalog; this one claimed to work.
      #
      # `status/0` and `logout/0` stay reachable so anyone who already ran
      # this can see and remove what it left behind.
      no_transport?() ->
        io.("")
        io.("  #{@display_name} account sign-in is not available.")
        io.("")
        io.("  OSA has no transport that can send inference through a GitHub")
        io.("  bearer token, so connecting one would store a credential and")
        io.("  give you nothing. Use the `copilot_cli` provider instead — it")
        io.("  runs against your existing `copilot login` session.")

        {:error, :no_transport}

      true ->
        with {:ok, session} <- DeviceFlow.start(cfg),
             :ok <- present(session, io, opts),
             {:ok, token_body} <- DeviceFlow.poll(cfg, session, on_tick),
             {:ok, entry} <- persist(token_body) do
          io.("")
          io.("  ✓ Connected to #{@display_name}#{account_suffix(entry)}")
          {:ok, entry}
        end
    end
  end

  @doc """
  True when no transport in this build can spend a stored Copilot token.

  Derived from the actual wiring rather than hardcoded, so it cannot go stale
  in either direction: the moment `:copilot` is added to
  `Providers.OpenAICompatProvider`'s account-mode table, this answers `false`
  and sign-in turns itself back on with no change here.

  Today it is `true`, because Copilot inference is not OpenAI-compatible (so
  this provider cannot join `xai` and `qwen` in that table as-is) and OSA
  deliberately does not use the undocumented `copilot_internal/v2/token`
  exchange with a borrowed editor client id — see the moduledoc.
  """
  @spec no_transport?() :: boolean()
  def no_transport? do
    :copilot not in OptimalSystemAgent.Providers.OpenAICompatProvider.account_mode_providers()
  end

  defp present(session, io, opts) do
    url = session.verification_uri || "https://github.com/login/device"

    io.("")
    io.("  To connect your #{@display_name} account:")
    io.("")
    io.("    1. Open  #{url}")
    io.("    2. Enter code  #{session.user_code}")
    io.("")
    io.("  You are connecting a GitHub account to OSA, a third-party tool.")
    io.("  Waiting for approval… (Ctrl-C to cancel)")

    if Keyword.get(opts, :open_browser, true), do: Browser.open(url)
    :ok
  end

  defp account_suffix(%{"account" => account}) when is_binary(account) and account != "",
    do: " as #{account}"

  defp account_suffix(_), do: ""

  # ── Persistence ─────────────────────────────────────────────────────────

  defp persist(body) do
    now = System.system_time(:second)
    access_token = body["access_token"]

    expires_at =
      case body["expires_in"] do
        n when is_integer(n) and n > 0 -> now + n
        n when is_binary(n) -> case Integer.parse(n) do
                                 {v, _} when v > 0 -> now + v
                                 _ -> nil
                               end
        _ -> nil
      end

    entry =
      %{
        "kind" => "device_code",
        "access_token" => access_token,
        "refresh_token" => body["refresh_token"],
        "expires_at" => expires_at,
        "scope" => body["scope"],
        # Pin the endpoint AT SIGN-IN TIME. Resolving it later from the
        # settings cascade would let an untrusted workspace point a
        # `*_URL` override at an attacker-controlled host and receive a
        # bearer token for the user's paid account.
        "base_url" => "https://api.githubcopilot.com",
        "connected_at" => now,
        "issued_by" => DeviceFlow.user_agent()
      }
      |> Map.merge(identify(access_token))

    case SubscriptionStore.put(@provider_id, entry) do
      :ok -> {:ok, entry}
      {:error, _} = err -> err
    end
  end

  # Best-effort "who did we just connect as". Purely cosmetic — a failure here
  # must never fail a sign-in that actually succeeded, so every error path
  # returns an empty map and the flow continues without the label.
  defp identify(access_token) do
    req_options = Application.get_env(:optimal_system_agent, :auth_req_options, [])

    options =
      Keyword.merge(
        [
          url: user_url(),
          headers: [
            {"authorization", "Bearer #{access_token}"},
            {"accept", "application/vnd.github+json"},
            {"user-agent", DeviceFlow.user_agent()}
          ],
          receive_timeout: 10_000,
          retry: false
        ],
        req_options
      )

    case Req.get(options) do
      {:ok, %{status: 200, body: %{"login" => login}}} when is_binary(login) ->
        %{"account" => login}

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  catch
    _, _ -> %{}
  end

  # ── Status (pure read — no network, ever) ───────────────────────────────

  @impl true
  @spec status() :: OptimalSystemAgent.Auth.Subscription.status()
  def status do
    case SubscriptionStore.fetch(@provider_id) do
      nil ->
        OptimalSystemAgent.Auth.Subscription.disconnected(@provider_id)

      entry ->
        %{
          connected?: true,
          # A token OSA holds and can refresh is direct evidence.
          verified?: true,
          provider: @provider_id,
          account: entry["account"],
          plan: entry["plan"],
          expires_at: entry["expires_at"],
          expired?: expired?(entry)
        }
    end
  end

  @doc "True when the stored token is past its expiry. A non-expiring token is never expired."
  @spec expired?(map()) :: boolean()
  def expired?(%{"expires_at" => nil}), do: false
  def expired?(%{"expires_at" => at}) when is_integer(at), do: System.system_time(:second) >= at
  def expired?(_), do: false

  @doc """
  True when the token should be refreshed before use.

  Answers `false` when there is no refresh token — a non-expiring OAuth App
  token has nothing to refresh WITH, and attempting it would fail every
  request for a credential that is actually fine.
  """
  @spec needs_refresh?(map()) :: boolean()
  def needs_refresh?(%{"refresh_token" => rt} = entry) when is_binary(rt) and rt != "" do
    case entry["expires_at"] do
      at when is_integer(at) -> System.system_time(:second) >= at - @refresh_skew_s
      _ -> false
    end
  end

  def needs_refresh?(_), do: false

  # ── Token resolution (the only path that may refresh) ───────────────────

  @impl true
  @spec access_token() :: {:ok, String.t()} | {:error, term()}
  def access_token do
    case SubscriptionStore.fetch(@provider_id) do
      nil ->
        {:error, :not_connected}

      entry ->
        cond do
          needs_refresh?(entry) -> refresh_and_get()
          expired?(entry) -> {:error, :refresh_token_invalid}
          true -> {:ok, entry["access_token"]}
        end
    end
  end

  @doc """
  Refresh **because a request came back 401**, not because the clock said so.

  Necessary here for a reason specific to this provider, and the reason is a
  trap: a GitHub OAuth App token can have **no expiry at all**. When
  `expires_at` is `nil`, `expired?/1` is permanently false and
  `needs_refresh?/1` is permanently false — so a token that has been *revoked*
  from the user's GitHub settings page is handed out unchanged on every
  request, forever, with no path out except deleting the store by hand. The
  proactive path cannot fix that, because from its point of view nothing is
  wrong.

  The rejected token is the argument, and that is what makes concurrent calls
  safe: the predicate is "is the stored token still the one that just failed?",
  so a peer that already rotated it is adopted with no network call and the
  single-use refresh token is never double-spent.

  Returns `{:error, :not_refreshable}` when there is nothing to refresh WITH.
  That is the honest answer for a non-expiring token with no refresh token —
  the credential is simply dead, and the caller should say "sign in again"
  rather than retrying a refresh that cannot exist.
  """
  @spec force_refresh(String.t()) :: {:ok, String.t()} | {:error, term()}
  def force_refresh(rejected_token) when is_binary(rejected_token) do
    case SubscriptionStore.fetch(@provider_id) do
      %{"refresh_token" => rt} when is_binary(rt) and rt != "" ->
        refresh_and_get(fn entry -> entry["access_token"] == rejected_token end)

      nil ->
        {:error, :not_connected}

      _ ->
        {:error, :not_refreshable}
    end
  end

  defp refresh_and_get(needs_refresh? \\ &needs_refresh?/1) do
    cfg = config()

    result =
      SubscriptionStore.refresh_within_lock(
        @provider_id,
        fn entry ->
          case DeviceFlow.refresh(cfg, entry["refresh_token"]) do
            {:ok, body} ->
              now = System.system_time(:second)

              expires_at =
                case body["expires_in"] do
                  n when is_integer(n) and n > 0 -> now + n
                  _ -> nil
                end

              {:ok,
               entry
               |> Map.put("access_token", body["access_token"])
               # GitHub rotates the refresh token on every use. Keeping the
               # old one would spend an already-consumed token on the next
               # refresh and invalidate the entire grant.
               |> Map.put("refresh_token", body["refresh_token"] || entry["refresh_token"])
               |> Map.put("expires_at", expires_at)
               |> Map.put("last_refresh", now)}

            {:error, _} = err ->
              err
          end
        end,
        needs_refresh?
      )

    case result do
      {:ok, entry} ->
        # A working token clears the strikes. Two rejections must be
        # CONSECUTIVE — a rejection now and another next Tuesday, with a
        # hundred successful turns between them, is not evidence of anything.
        RefreshFailures.reset(@provider_id)
        {:ok, entry["access_token"]}

      {:error, :refresh_token_invalid} = err ->
        # Deleting a credential is irreversible from the user's side — they
        # have to run the whole sign-in again — so it takes TWO consecutive
        # rejections, not one. Providers return `invalid_grant` for transient
        # reasons, and a single bad minute signing someone out
        # mid-conversation is worse than one extra failed turn. This used to
        # delete on the FIRST rejection here while `OpenAICodex` required two;
        # the rule now lives in one place so it cannot drift again.
        _ =
          RefreshFailures.handle_rejection(@provider_id, @display_name, fn ->
            SubscriptionStore.delete(@provider_id)
          end)

        err

      {:error, _} = err ->
        err
    end
  end

  # ── Sign out ────────────────────────────────────────────────────────────

  @impl true
  @spec logout() :: :ok | {:error, term()}
  def logout do
    # Clear the strike count too. Without this, signing out and back in
    # within one OS process starts the new credential at strike one, and the
    # next transient rejection deletes a sign-in that is seconds old.
    RefreshFailures.reset(@provider_id)
    SubscriptionStore.delete(@provider_id)
  end
end
