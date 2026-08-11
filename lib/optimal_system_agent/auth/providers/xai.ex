defmodule OptimalSystemAgent.Auth.Providers.XAI do
  @moduledoc """
  Sign in with an xAI account (SuperGrok / Premium+) instead of pasting a key.

  ## Why this is a second mode rather than a second provider

  Unlike `openai_codex`, which needed its own catalog row because it speaks a
  different protocol to a different host with a different model list, xAI's
  account path is the **same endpoint** (`api.x.ai/v1`), the **same
  OpenAI-compatible wire format** and the **same models** as the API-key path.
  Only the credential differs — a bearer token from the account grant instead
  of a pasted key. Splitting that into two rows would present the user with a
  distinction that does not exist below the credential.

  So `xai` keeps its key path untouched and gains "connect your account"
  beside it, the same shape `ollama_cloud` uses.

  ## Endpoints are discovered, not assumed

  The device and token URLs below were read from xAI's own OIDC discovery
  document (`https://auth.x.ai/.well-known/openid-configuration`) rather than
  copied from a blog post, and it confirms
  `urn:ietf:params:oauth:grant-type:device_code` among `grant_types_supported`
  and every scope requested here among `scopes_supported`. Re-check discovery
  before changing any constant in this file.

  `offline_access` is requested because without it the grant returns no refresh
  token, and a subscription that silently stops working an hour after sign-in
  is worse than one that never connected.

  ## The client id is borrowed, and that is a deliberate, reversible choice

  `@client_id` is the id xAI ships in its own Grok CLI. OSA has no registered
  client of its own with xAI, and there is no public self-service registration
  to obtain one. The alternatives were: no account sign-in for Grok at all, or
  this. It is recorded here rather than buried because it has real properties:

    * xAI can revoke it at any time, and if they do this flow stops working
      for every OSA user at once. The failure is loud (`invalid_client`) and
      the key path is unaffected, so a revocation degrades to "paste a key"
      rather than to a broken provider.
    * It is not a secret. Device-code client ids are public by construction —
      they are shipped in binaries that run on user machines — so there is
      nothing here that leaks.
    * If OSA is ever granted its own client id, this is a one-line change.

  ## What is stored

  A bearer token, its refresh token and expiry, in `~/.osa/subscriptions.json`
  at 0600. Unlike `claude_cli` and `bedrock`, this provider genuinely holds a
  credential, so the store's permission guarantees are load-bearing here.
  """

  @behaviour OptimalSystemAgent.Auth.Subscription

  require Logger

  alias OptimalSystemAgent.Auth.DeviceFlow
  alias OptimalSystemAgent.Auth.SubscriptionStore

  @provider_id "xai"

  @issuer "https://auth.x.ai"
  @device_code_url "#{@issuer}/oauth2/device/code"
  @token_url "#{@issuer}/oauth2/token"

  # See the moduledoc: borrowed from xAI's own Grok CLI, public by
  # construction, revocable by them, and degrades to the key path.
  @client_id "b1a00492-073a-47ea-816f-4c329264a828"

  # `offline_access` buys the refresh token; `api:access` is what actually
  # authorises inference against api.x.ai. Both are in `scopes_supported`.
  @scope "openid profile email offline_access grok-cli:access api:access"

  # The inference host, pinned at sign-in so an `XAI_BASE_URL` override from an
  # untrusted workspace cannot redirect a subscription bearer token elsewhere.
  # Same reasoning as `openai_codex`.
  @base_url "https://api.x.ai/v1"

  # Refresh this far ahead of expiry, so a long turn cannot start on a token
  # that dies mid-stream.
  @refresh_skew_s 300

  @doc "Human-readable name, used in every user-facing message."
  @spec display_name() :: String.t()
  def display_name, do: "xAI (Grok)"

  @doc "The pinned inference base URL for the account path."
  @spec base_url() :: String.t()
  def base_url, do: @base_url

  @doc """
  The base URL an account-mode request must be sent to, read from the marker
  written at sign-in.

  This is deliberately NOT `Application.get_env(:xai_url)`. The key path
  honours that override, and should: a pasted key is the user's own
  credential, and pointing it at a proxy or a gateway is a legitimate thing to
  want. A subscription bearer token is different — it is minted by xAI for
  xAI, and an `XAI_BASE_URL` picked up from an untrusted workspace `.env`
  would silently redirect it to a host of the attacker's choosing, which is
  credential exfiltration dressed as configuration. Same reasoning as
  `openai_codex`.

  Reading it from the marker rather than from `@base_url` means the value that
  was in force when the user consented is the value that is used, so changing
  the constant later cannot retarget a token already issued.

  A **pure read**. It never writes, and in particular it never re-creates a
  marker the user has just removed — the whole point of `fetch/1` returning
  `nil` rather than a default entry.
  """
  @spec pinned_base_url() :: String.t()
  def pinned_base_url do
    case SubscriptionStore.fetch(@provider_id) do
      %{"base_url" => url} when is_binary(url) and url != "" -> url
      _ -> @base_url
    end
  end

  @doc """
  True when an account marker exists. Pure read, no network, no refresh.

  Exists so the transport can ask "is there an account to fall back to?"
  without calling `access_token/0`, which MAY refresh — the resolution
  contract in `Auth.Subscription` turns on exactly that distinction.
  """
  @spec connected?() :: boolean()
  def connected?, do: SubscriptionStore.connected?(@provider_id)

  defp config do
    %{
      device_code_url: @device_code_url,
      token_url: @token_url,
      client_id: @client_id,
      scope: @scope
    }
  end

  # ── Sign-in ─────────────────────────────────────────────────────────────

  @impl true
  @doc """
  Run the device-code grant.

  `on_verification` receives `%{user_code:, verification_uri:}` BEFORE polling
  begins, so a non-terminal surface (the TUI's account-login screen) can render
  the code without scraping it out of console text — the defect that made
  `openai_codex` sign-in work from `osa setup` and nowhere else.
  """
  def login(opts \\ []) do
    io = Keyword.get(opts, :io, &IO.puts/1)
    on_verification = Keyword.get(opts, :on_verification)
    on_tick = Keyword.get(opts, :on_tick, fn -> :continue end)

    with {:ok, session} <- DeviceFlow.start(config()) do
      announce(session, io, on_verification)

      case DeviceFlow.poll(config(), session, on_tick) do
        {:ok, tokens} -> persist(tokens)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp announce(session, io, on_verification) do
    if is_function(on_verification, 1) do
      on_verification.(%{
        user_code: session.user_code,
        verification_uri: session.verification_uri_complete || session.verification_uri
      })
    end

    io.("  Open #{session.verification_uri} and enter the code: #{session.user_code}")
    :ok
  end

  defp persist(tokens) do
    now = System.system_time(:second)

    entry = %{
      "kind" => "device_code",
      "access_token" => tokens["access_token"],
      "refresh_token" => tokens["refresh_token"],
      "expires_at" => expires_at(tokens["expires_in"], now),
      "account_id" => account_from(tokens),
      "base_url" => @base_url,
      "connected_at" => now,
      "issued_by" => DeviceFlow.user_agent()
    }

    case SubscriptionStore.put(@provider_id, entry) do
      :ok -> {:ok, entry}
      err -> err
    end
  end

  # The id token carries the account identity when present. Absent one, nil —
  # a status screen showing "signed in" with no name is honest; a fabricated
  # one is not.
  defp account_from(%{"id_token" => jwt}) when is_binary(jwt) do
    with [_, payload, _] <- String.split(jwt, "."),
         {:ok, json} <- Base.url_decode64(pad(payload), padding: false),
         {:ok, claims} <- Jason.decode(json) do
      claims["email"] || claims["sub"]
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp account_from(_), do: nil

  defp pad(s) do
    case rem(byte_size(s), 4) do
      0 -> s
      n -> s <> String.duplicate("=", 4 - n)
    end
  end

  defp expires_at(n, now) when is_integer(n) and n > 0, do: now + n

  defp expires_at(n, now) when is_binary(n) do
    case Integer.parse(n) do
      {v, _} when v > 0 -> now + v
      _ -> nil
    end
  end

  defp expires_at(_, _), do: nil

  # ── Status ──────────────────────────────────────────────────────────────

  @impl true
  def status do
    case SubscriptionStore.fetch(@provider_id) do
      nil ->
        OptimalSystemAgent.Auth.Subscription.disconnected(@provider_id)

      entry ->
        %{
          connected?: true,
          # OSA holds the token and can refresh it — direct evidence, the same
          # standard `openai_codex` sets.
          verified?: true,
          provider: @provider_id,
          account: entry["account_id"],
          plan: entry["plan_type"],
          expires_at: entry["expires_at"],
          expired?: expired?(entry)
        }
    end
  end

  @spec expired?(map()) :: boolean()
  def expired?(%{"expires_at" => at}) when is_integer(at), do: System.system_time(:second) >= at
  def expired?(_), do: false

  @spec needs_refresh?(map()) :: boolean()
  def needs_refresh?(%{"refresh_token" => rt} = entry) when is_binary(rt) and rt != "" do
    case entry["expires_at"] do
      at when is_integer(at) -> System.system_time(:second) >= at - @refresh_skew_s
      _ -> false
    end
  end

  def needs_refresh?(_), do: false

  # ── Token resolution ────────────────────────────────────────────────────

  @impl true
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

  # Refresh inside the store's lock so two OSA processes cannot both spend the
  # same single-use refresh token — the peer that loses the race adopts the
  # winner's rotated token instead of invalidating it.
  defp refresh_and_get do
    SubscriptionStore.refresh_within_lock(
      @provider_id,
      fn entry ->
        case DeviceFlow.refresh(config(), entry["refresh_token"]) do
          {:ok, tokens} ->
            now = System.system_time(:second)

            {:ok,
             entry
             |> Map.put("access_token", tokens["access_token"])
             # A rotated refresh token replaces the old one; a provider that
             # does not rotate returns none, and the existing one must be kept
             # rather than nulled.
             |> Map.put("refresh_token", tokens["refresh_token"] || entry["refresh_token"])
             |> Map.put("expires_at", expires_at(tokens["expires_in"], now))}

          {:error, reason} ->
            {:error, reason}
        end
      end,
      &needs_refresh?/1
    )
    |> case do
      {:ok, entry} -> {:ok, entry["access_token"]}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def logout, do: SubscriptionStore.delete(@provider_id)
end
