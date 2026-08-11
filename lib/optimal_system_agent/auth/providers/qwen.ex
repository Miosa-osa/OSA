defmodule OptimalSystemAgent.Auth.Providers.Qwen do
  @moduledoc """
  Sign in with a Qwen account (the Qwen Code coding plan) instead of pasting a
  DashScope key.

  ## Why this is a second mode rather than a second provider

  Same test `xai` passes, and for the same reason: the wire format is
  unchanged. Both modes speak OpenAI-compatible chat completions, and both
  reach models the picker resolves live. Only the credential differs — a
  bearer token from the account grant instead of a pasted `QWEN_API_KEY` — so
  `qwen` keeps its key path untouched and gains "connect your account" beside
  it.

  The one asymmetry is the host, and it is the provider's own doing: an
  account is issued a `resource_url` at sign-in and its inference endpoint is
  derived from that, while a DashScope key belongs to DashScope's
  compatible-mode endpoint. That is the `ollama_cloud` shape — one row, two
  modes, two endpoints — not a reason to split the row.

  ## Endpoints are read from the provider's own client, not assumed

  Qwen publishes no OIDC discovery document (`chat.qwen.ai/.well-known/
  openid-configuration` serves a marketing page, checked 2026-08-11), so the
  discovery check `xai.ex` performs is not available here. The next-best
  source is the vendor's own client rather than a blog post, and every
  constant below was read from `QwenLM/qwen-code`,
  `packages/core/src/qwen/qwenOAuth2.ts` on 2026-08-11:

    * `QWEN_OAUTH_BASE_URL` = `https://chat.qwen.ai`
    * device code endpoint  = `.../api/v1/oauth2/device/code`
    * token endpoint        = `.../api/v1/oauth2/token`
    * client id             = `f0304373b74a44d2b584a3fb70ca9e56`
    * scope                 = `openid profile email model.completion`
    * grant type            = `urn:ietf:params:oauth:grant-type:device_code`
    * PKCE method           = `S256`

  Re-read that file before changing any constant here.

  ## PKCE is not optional for this provider

  Qwen's device grant is PKCE-bound: the challenge goes with the device
  authorization request and the verifier with the token exchange, and the
  exchange is refused without them. `Auth.DeviceFlow` carries both when a
  `:pkce` key is present on the config, which is why `config/1` generates a
  fresh `Auth.PKCE` pair **per sign-in attempt** — reusing one across attempts
  would defeat the binding it exists to create.

  ## The client id is borrowed, and that is a deliberate, reversible choice

  `@client_id` is the id Alibaba ships in its own Qwen Code CLI. OSA has no
  registered client of its own with Qwen and there is no public self-service
  registration to obtain one. The same properties apply as for `xai`:

    * Alibaba can revoke it at any time, and if they do this flow stops
      working for every OSA user at once. The failure is loud
      (`invalid_client`) and the key path is untouched, so a revocation
      **degrades to "paste a DashScope key"** rather than to a broken
      provider.
    * It is not a secret. Device-code client ids are public by construction —
      they ship in binaries that run on user machines — so nothing leaks here.
    * If OSA is ever granted its own client id, this is a one-line change.

  ## The endpoint is pinned per account, from the provider's own response

  The token response carries `resource_url`, and Qwen's client derives the
  inference base URL from it (`qwenContentGenerator.ts`: take `resource_url`,
  fall back to the DashScope compatible-mode URL, add a scheme if absent,
  ensure it ends in `/v1`). OSA does the same and stores the RESULT in the
  marker at sign-in.

  Storing the resolved URL rather than recomputing it matters twice over: the
  endpoint the user consented to is the endpoint that gets used, and — as with
  `openai_codex` and `xai` — no `QWEN_BASE_URL` from an untrusted workspace
  can redirect an account bearer token to a host of someone else's choosing.

  ## What is stored, and what is NOT touched

  A bearer token, its refresh token and expiry, in `~/.osa/subscriptions.json`
  at 0600 — OSA's own store.

  Note what this deliberately does not do: it does not read, and above all
  does not WRITE, the Qwen CLI's `~/.qwen/oauth_creds.json`. Reusing that file
  is the shortcut the reference implementation takes, and it means two
  programs sharing one single-use rotating refresh token — whichever refreshes
  second finds its token already spent and reports a revoked grant that nobody
  revoked. OSA runs its own grant against the same endpoints instead, so the
  two clients hold independent credentials and neither can invalidate the
  other.
  """

  @behaviour OptimalSystemAgent.Auth.Subscription

  require Logger

  alias OptimalSystemAgent.Auth.DeviceFlow
  alias OptimalSystemAgent.Auth.PKCE
  alias OptimalSystemAgent.Auth.SubscriptionStore

  @provider_id "qwen"

  @issuer "https://chat.qwen.ai"
  @device_code_url "#{@issuer}/api/v1/oauth2/device/code"
  @token_url "#{@issuer}/api/v1/oauth2/token"

  # See the moduledoc: borrowed from Alibaba's own Qwen Code CLI, public by
  # construction, revocable by them, and degrades to the key path.
  @client_id "f0304373b74a44d2b584a3fb70ca9e56"

  # Exactly the scope string qwen-code requests. `model.completion` is what
  # authorises inference; the OIDC trio is what supplies the account identity
  # shown on the status screen.
  #
  # NOTE the absence of `offline_access`. `xai.ex` requests it because xAI's
  # discovery document lists it and withholds a refresh token without it.
  # Qwen's client does not request it and Qwen returns a refresh token anyway,
  # so adding it here would be inventing a scope the provider never
  # advertised — `invalid_scope` is a real risk and buys nothing.
  @scope "openid profile email model.completion"

  # The endpoint a DashScope KEY belongs to, and the documented fallback when
  # a grant returns no `resource_url`. Kept identical to the `qwen` entry in
  # `Providers.OpenAICompatProvider` — same value, one meaning.
  @default_base_url "https://dashscope.aliyuncs.com/compatible-mode/v1"

  # Refresh this far ahead of expiry, so a long turn cannot start on a token
  # that dies mid-stream.
  @refresh_skew_s 300

  @doc "Human-readable name, used in every user-facing message."
  @spec display_name() :: String.t()
  def display_name, do: "Qwen"

  @doc "The endpoint used when a grant returns no `resource_url` of its own."
  @spec default_base_url() :: String.t()
  def default_base_url, do: @default_base_url

  # A FRESH PKCE pair per call. `login/1` calls this once and threads the
  # result through both legs of the grant; `refresh/2` needs no verifier and
  # is given a config without one.
  defp config(pkce \\ nil) do
    base = %{
      device_code_url: @device_code_url,
      token_url: @token_url,
      client_id: @client_id,
      scope: @scope
    }

    if pkce, do: Map.put(base, :pkce, pkce), else: base
  end

  # ── Sign-in ─────────────────────────────────────────────────────────────

  @impl true
  @doc """
  Run the PKCE-bound device-code grant.

  `on_verification` receives `%{user_code:, verification_uri:}` BEFORE polling
  begins, so a non-terminal surface (the TUI's account-login screen) can
  render the code without scraping it out of console text.
  """
  def login(opts \\ []) do
    io = Keyword.get(opts, :io, &IO.puts/1)
    on_verification = Keyword.get(opts, :on_verification)
    on_tick = Keyword.get(opts, :on_tick, fn -> :continue end)

    # One pair, generated here and used for BOTH legs. Generating it inside
    # `config/1` at each call site would send a challenge the verifier does
    # not match, and the exchange would fail in a way that looks like a
    # provider outage.
    pkce = PKCE.generate()
    config = config(pkce)

    with {:ok, session} <- DeviceFlow.start(config) do
      announce(session, io, on_verification)

      case DeviceFlow.poll(config, session, on_tick) do
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
      # Resolved ONCE, at consent time, from the provider's own response.
      "base_url" => resolve_base_url(tokens["resource_url"]),
      "connected_at" => now,
      "issued_by" => DeviceFlow.user_agent()
    }

    case SubscriptionStore.put(@provider_id, entry) do
      :ok -> {:ok, entry}
      err -> err
    end
  end

  @doc """
  Turn a `resource_url` into an inference base URL, the way Qwen's own client
  does: fall back to DashScope when absent, add a scheme when the provider
  returns a bare host (it usually does — `portal.qwen.ai`), and ensure exactly
  one trailing `/v1`.

  Public because it is the one piece of per-account routing here that has
  interesting edge cases, and they are worth pinning directly rather than only
  through a full sign-in.

  A value that is not a plain string is treated as absent rather than
  interpolated: a `resource_url` is attacker-influenced only insofar as the
  provider chooses it, but building a URL out of arbitrary JSON is how a
  request ends up somewhere no one intended.
  """
  @spec resolve_base_url(term()) :: String.t()
  def resolve_base_url(resource_url) do
    case normalize(resource_url) do
      nil ->
        @default_base_url

      url ->
        with_scheme = if String.contains?(url, "://"), do: url, else: "https://" <> url
        trimmed = String.trim_trailing(with_scheme, "/")

        if String.ends_with?(trimmed, "/v1"), do: trimmed, else: trimmed <> "/v1"
    end
  end

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(_), do: nil

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
          # OSA holds the token and can refresh it — direct evidence.
          verified?: true,
          provider: @provider_id,
          account: entry["account_id"],
          plan: entry["plan_type"],
          expires_at: entry["expires_at"],
          expired?: expired?(entry)
        }
    end
  end

  @doc """
  The base URL an account-mode request must be sent to, read from the marker
  written at sign-in. Never an env override — see the moduledoc.

  A **pure read**: it never writes, and in particular never re-creates a
  marker the user has just removed.
  """
  @spec pinned_base_url() :: String.t()
  def pinned_base_url do
    case SubscriptionStore.fetch(@provider_id) do
      %{"base_url" => url} when is_binary(url) and url != "" -> url
      _ -> @default_base_url
    end
  end

  @doc "True when an account marker exists. Pure read, no network, no refresh."
  @spec connected?() :: boolean()
  def connected?, do: SubscriptionStore.connected?(@provider_id)

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
        # No PKCE on a refresh: there is no authorization code to bind, and
        # RFC 7636 defines no verifier for this exchange.
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
             |> Map.put("expires_at", expires_at(tokens["expires_in"], now))
             # A refresh MAY move the account to a different resource. Honour
             # it when it does, keep the pinned value when it does not — never
             # silently fall back to the DashScope default, which would move a
             # working account onto the key endpoint.
             |> Map.put("base_url", refreshed_base_url(tokens, entry))}

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

  defp refreshed_base_url(tokens, entry) do
    case normalize(tokens["resource_url"]) do
      nil -> entry["base_url"] || @default_base_url
      value -> resolve_base_url(value)
    end
  end

  @impl true
  def logout, do: SubscriptionStore.delete(@provider_id)
end
