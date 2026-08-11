defmodule OptimalSystemAgent.Auth.Providers.MiniMax do
  @moduledoc """
  Sign in with a MiniMax account instead of pasting a `MINIMAX_API_KEY`.

  ## STATUS: DORMANT — deliberately registered NOWHERE

  This module compiles, is tested, and is referenced by no `@implementations`
  map, no catalog row and no transport. That is on purpose, and the reason is
  the rule the rest of this subsystem is built on: **nothing enters the
  catalog until it is completely wired**. A provider a user can select but
  never send a request through is worse than one that is absent, because the
  failure arrives several screens after the mistake.

  What is missing is not the credential — that is all here — it is the
  transport. See "The wire format is Anthropic Messages" below. When a
  MiniMax transport exists, wiring this up is three lines: an
  `@implementations` entry in `Auth.Subscription`, an
  `@additional_provider_overlays` entry in `Onboarding`, and a Registry route.
  Do not add any one of them before the other two.

  ## The wire format is Anthropic Messages, NOT OpenAI chat

  This is the single most expensive thing to get wrong here, because getting
  it wrong is silent: a request shaped for `/v1/chat/completions` sent to an
  Anthropic Messages endpoint does not fail cleanly, it fails as garbled or
  empty content that looks like a model problem.

  MiniMax's own documentation
  (`platform.minimax.io/docs/api-reference/text-anthropic-api`, read
  2026-08-11) says to point an Anthropic client at
  `ANTHROPIC_BASE_URL=https://api.minimax.io/anthropic`, i.e. requests go to
  `https://api.minimax.io/anthropic/v1/messages` with Anthropic's own headers
  (`x-api-key`, `anthropic-version`), not to an OpenAI-compatible path.

  That is why this provider cannot simply join `xai` and `qwen` in
  `Providers.OpenAICompatProvider`'s account-mode table: those two are
  OpenAI-compatible and this one is not.

  ## Endpoints could NOT be verified the way xAI's were

  `xai.ex` sets the standard: its constants were read from a live OIDC
  discovery document, and that document was re-checked (2026-08-11) and still
  confirms them. **MiniMax publishes no such document** —
  `api.minimax.io/.well-known/openid-configuration` is a 404, checked
  2026-08-11 — and its OAuth flow is not RFC 8628 either. The grant type is
  `urn:ietf:params:oauth:grant-type:user_code`, which is not a registered IANA
  grant type, and the endpoints below are not documented publicly anywhere
  found.

  So they come from a single source: the `hermes-agent` reference
  implementation (`hermes_cli/auth.py`, `_minimax_request_user_code` /
  `_minimax_poll_token` / `_refresh_minimax_oauth_state`). That is a weaker
  provenance than `xai` or `qwen` have, and it is recorded here rather than
  glossed over — it is a second, independent reason this provider stays
  dormant until someone can exercise it against a live MiniMax account.

  The INFERENCE endpoint is the exception: that one is confirmed by MiniMax's
  own live documentation, cited above.

  ## The client id is borrowed, and that is a deliberate, reversible choice

  `@client_id` is the id MiniMax ships in its own first-party client. OSA has
  no registered client of its own with MiniMax and there is no public
  self-service registration to obtain one. Same properties as `xai` and
  `qwen`:

    * MiniMax can revoke it at any time, and if they do this flow stops
      working for every OSA user at once. The failure is loud and the API-key
      path is untouched, so **a revocation degrades to "paste a MiniMax API
      key"** rather than to a broken provider.
    * It is not a secret — user-code client ids are public by construction,
      shipped in binaries that run on user machines.
    * If OSA is ever granted its own client id, this is a one-line change.

  ## PKCE is mandatory here

  The grant is PKCE-bound: a fresh S256 challenge goes with the authorization
  request and the matching verifier with every token poll. `Auth.PKCE`
  supplies both (>=32 CSPRNG bytes — in fact 96), and a fresh pair is
  generated per sign-in attempt.

  ## Regions are two different accounts, not a setting

  `api.minimax.io` (global) and `api.minimaxi.com` (mainland China) are
  separate deployments with separate accounts. The region chosen at sign-in
  determines BOTH the portal that issues the token and the inference host it
  is valid against, so it is pinned into the marker as a pair and never
  recombined afterwards — a global token sent to the CN host is simply an
  invalid credential.

  ## Secret handling

  Tokens live in `~/.osa/subscriptions.json` at 0600. No token is ever logged,
  printed, put in an error message, or passed as a command-line argument;
  every request here goes through Req with a form body.
  """

  require Logger

  alias OptimalSystemAgent.Auth.PKCE
  alias OptimalSystemAgent.Auth.SubscriptionStore

  @provider_id "minimax"

  # See the moduledoc: borrowed from MiniMax's own client, public by
  # construction, revocable by them, and degrades to the key path.
  @client_id "78257093-7e40-4613-99e0-527b14b39113"

  # `model.completion` is what authorises inference; `group_id` is what
  # identifies the billing group the plan belongs to. Taken verbatim from the
  # reference implementation — NOT invented, and not extended, because an
  # unadvertised scope is an `invalid_scope` waiting to happen.
  @scope "group_id profile model.completion"

  # Not an IANA-registered grant type. MiniMax's own.
  @grant_type "urn:ietf:params:oauth:grant-type:user_code"

  @regions %{
    "global" => %{
      portal: "https://api.minimax.io",
      # Confirmed against MiniMax's live documentation — see the moduledoc.
      inference: "https://api.minimax.io/anthropic"
    },
    "cn" => %{
      portal: "https://api.minimaxi.com",
      inference: "https://api.minimaxi.com/anthropic"
    }
  }

  @default_region "global"

  # MiniMax's refresh window is short and its own client uses 60s. A larger
  # skew than the provider's own client uses risks refreshing a token the
  # server still considers fresh on every single call.
  @refresh_skew_s 60

  # Polling floor, so a hostile or buggy `interval` cannot spin this loop.
  @min_interval_s 2
  @default_interval_s 2

  # An independent ceiling on the whole poll, on the MONOTONIC clock, for the
  # same two reasons `DeviceFlow` has one: a hostile `expired_in` must not be
  # able to pin the flow for its whole duration, and an NTP step backwards
  # must not silently extend the wait.
  @max_wait_s 900

  @doc "Human-readable name, used in every user-facing message."
  @spec display_name() :: String.t()
  def display_name, do: "MiniMax"

  @doc "The regions this provider can sign in to."
  @spec regions() :: [String.t()]
  def regions, do: Map.keys(@regions) |> Enum.sort()

  @doc """
  The portal (token-issuing) and inference hosts for a region.

  Returns `nil` for an unknown region rather than defaulting to the global
  one: silently signing a Chinese account into the global portal would produce
  a credential that fails at first use, several steps from the typo.
  """
  @spec region_hosts(String.t()) :: %{portal: String.t(), inference: String.t()} | nil
  def region_hosts(region), do: Map.get(@regions, region)

  @doc "The default region when a caller does not pick one."
  @spec default_region() :: String.t()
  def default_region, do: @default_region

  # ── Sign-in ─────────────────────────────────────────────────────────────

  @doc """
  Run the PKCE-bound user-code grant.

  `on_verification` receives `%{user_code:, verification_uri:}` BEFORE polling
  begins, so a non-terminal surface can render the code without scraping it
  out of console text.
  """
  @spec login(keyword()) :: {:ok, map()} | {:error, term()}
  def login(opts \\ []) do
    io = Keyword.get(opts, :io, &IO.puts/1)
    on_verification = Keyword.get(opts, :on_verification)
    on_tick = Keyword.get(opts, :on_tick, fn -> :continue end)
    region = Keyword.get(opts, :region, @default_region)

    case region_hosts(region) do
      nil ->
        {:error, {:unknown_region, region}}

      hosts ->
        pkce = PKCE.generate()

        with {:ok, code} <- request_user_code(hosts.portal, pkce),
             :ok <- announce(code, io, on_verification),
             {:ok, tokens} <- poll(hosts.portal, code, pkce, on_tick) do
          persist(tokens, region, hosts)
        end
    end
  end

  # Leg 1: ask the portal for a user code. The `state` we send must come back
  # unchanged; a mismatch means the response is not the one for our request,
  # so the flow is abandoned rather than continued against an unknown grant.
  defp request_user_code(portal, %PKCE{} = pkce) do
    state = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    params = %{
      "response_type" => "code",
      "client_id" => @client_id,
      "scope" => @scope,
      "code_challenge" => pkce.challenge,
      "code_challenge_method" => pkce.method,
      "state" => state
    }

    case post_form("#{portal}/oauth/code", params) do
      {:ok, %{"user_code" => user_code, "verification_uri" => uri} = body} ->
        cond do
          body["state"] != state ->
            {:error, :state_mismatch}

          not is_binary(user_code) or user_code == "" ->
            {:error, :device_code_incomplete}

          true ->
            {:ok,
             %{
               user_code: user_code,
               verification_uri: uri,
               # Both an absolute unix-ms instant and a TTL in seconds are
               # seen in the wild here; `deadline_from/1` resolves which.
               deadline: deadline_from(body["expired_in"]),
               interval_s: interval_from(body["interval"])
             }}
        end

      {:ok, body} ->
        {:error, minimax_error(body, :device_code_incomplete)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp announce(code, io, on_verification) do
    if is_function(on_verification, 1) do
      on_verification.(%{user_code: code.user_code, verification_uri: code.verification_uri})
    end

    io.("  Open #{code.verification_uri} and enter the code: #{code.user_code}")
    :ok
  end

  # Leg 2: poll the token endpoint. Unlike RFC 8628 this reports progress in a
  # `status` FIELD on a 200 response rather than through an OAuth `error`
  # code, so "pending" must not be read as failure.
  defp poll(portal, code, %PKCE{} = pkce, on_tick) do
    ceiling = System.monotonic_time(:second) + @max_wait_s
    do_poll(portal, code, pkce, on_tick, ceiling)
  end

  defp do_poll(portal, code, pkce, on_tick, ceiling) do
    cond do
      System.system_time(:second) >= code.deadline ->
        {:error, :device_code_expired}

      System.monotonic_time(:second) >= ceiling ->
        {:error, :device_code_timeout}

      on_tick.() == :cancel ->
        {:error, :cancelled}

      true ->
        Process.sleep(code.interval_s * 1000)

        params = %{
          "grant_type" => @grant_type,
          "client_id" => @client_id,
          "user_code" => code.user_code,
          # The verifier is a secret and travels in the form BODY.
          "code_verifier" => pkce.verifier
        }

        case post_form("#{portal}/oauth/token", params) do
          {:ok, %{"status" => "success"} = body} ->
            if is_binary(body["access_token"]) and body["access_token"] != "" do
              {:ok, body}
            else
              {:error, :device_code_incomplete}
            end

          {:ok, %{"status" => "error"} = body} ->
            {:error, minimax_error(body, :access_denied)}

          # "pending" — or anything else on a 200 — means keep waiting.
          {:ok, %{"status" => _}} ->
            do_poll(portal, code, pkce, on_tick, ceiling)

          {:ok, body} ->
            {:error, minimax_error(body, :malformed_token_response)}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp persist(tokens, region, hosts) do
    now = System.system_time(:second)

    entry = %{
      "kind" => "pkce_user_code",
      "access_token" => tokens["access_token"],
      "refresh_token" => tokens["refresh_token"],
      "expires_at" => expires_at(tokens["expired_in"], now),
      "region" => region,
      # Both hosts pinned as a PAIR at consent time: the portal that can
      # refresh this token and the inference host it is valid against. Neither
      # is ever recombined with the other region's, and neither is ever read
      # from an env override.
      "portal_base_url" => hosts.portal,
      "base_url" => hosts.inference,
      "connected_at" => now,
      "issued_by" => user_agent()
    }

    case SubscriptionStore.put(@provider_id, entry) do
      :ok -> {:ok, entry}
      err -> err
    end
  end

  # ── Status ──────────────────────────────────────────────────────────────

  @doc "Pure read of stored connection state. Never performs network I/O."
  @spec status() :: map()
  def status do
    case SubscriptionStore.fetch(@provider_id) do
      nil ->
        OptimalSystemAgent.Auth.Subscription.disconnected(@provider_id)

      entry ->
        %{
          connected?: true,
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
  The inference base URL pinned at sign-in. Never an env override.

  A **pure read**: it never writes, and never re-creates a marker the user has
  just removed.
  """
  @spec pinned_base_url() :: String.t() | nil
  def pinned_base_url do
    case SubscriptionStore.fetch(@provider_id) do
      %{"base_url" => url} when is_binary(url) and url != "" -> url
      _ -> nil
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

  @doc "A usable access token, refreshing first if it is close to expiry."
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

  # Refresh inside the store's lock so two OSA processes cannot both spend the
  # same single-use refresh token.
  defp refresh_and_get do
    SubscriptionStore.refresh_within_lock(
      @provider_id,
      fn entry -> do_refresh(entry) end,
      &needs_refresh?/1
    )
    |> case do
      {:ok, entry} -> {:ok, entry["access_token"]}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_refresh(entry) do
    portal = entry["portal_base_url"] || @regions[@default_region].portal

    params = %{
      "grant_type" => "refresh_token",
      "client_id" => @client_id,
      "refresh_token" => entry["refresh_token"]
    }

    # No PKCE on a refresh: there is no authorization code to bind.
    case post_form("#{portal}/oauth/token", params) do
      {:ok, %{"status" => "success", "access_token" => token} = body}
      when is_binary(token) and token != "" ->
        now = System.system_time(:second)

        {:ok,
         entry
         |> Map.put("access_token", token)
         # A rotated refresh token replaces the old one; a provider that does
         # not rotate returns none, and the existing one must be KEPT rather
         # than nulled.
         |> Map.put("refresh_token", body["refresh_token"] || entry["refresh_token"])
         |> Map.put("expires_at", expires_at(body["expired_in"], now))}

      {:ok, body} ->
        {:error, minimax_error(body, :refresh_token_invalid)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Forget the stored credential."
  @spec logout() :: :ok | {:error, term()}
  def logout, do: SubscriptionStore.delete(@provider_id)

  # ── Expiry: milliseconds or seconds ─────────────────────────────────────

  @doc """
  Resolve MiniMax's `expired_in` to an absolute unix-second expiry.

  The field is overloaded: it is sometimes a TTL in seconds and sometimes an
  absolute unix-MILLISECOND instant. They are told apart by magnitude — an
  absolute ms timestamp today is ~1.8e12, while any plausible TTL in seconds
  is at most ~1e7 — so a value larger than half the current ms clock can only
  be an absolute timestamp.

  Getting this backwards is not a small error: reading an absolute ms
  timestamp as a TTL would place expiry ~57,000 years out and the credential
  would never be refreshed until the server started refusing it.
  """
  @spec expires_at(term(), integer()) :: integer() | nil
  def expires_at(value, now) do
    case as_int(value) do
      nil ->
        nil

      raw when raw <= 0 ->
        nil

      raw ->
        if absolute_ms?(raw, now), do: div(raw, 1000), else: now + raw
    end
  end

  defp absolute_ms?(raw, now_s), do: raw > div(now_s * 1000, 2)

  defp deadline_from(value) do
    now = System.system_time(:second)
    expires_at(value, now) || now + @max_wait_s
  end

  # MiniMax reports the poll interval in MILLISECONDS. Treating it as seconds
  # would poll ~500x too slowly and time every sign-in out.
  defp interval_from(value) do
    case as_int(value) do
      ms when is_integer(ms) and ms > 0 -> max(div(ms, 1000), @min_interval_s)
      _ -> @default_interval_s
    end
  end

  # ── Errors ──────────────────────────────────────────────────────────────

  # MiniMax nests its human-readable failure under `base_resp.status_msg`.
  # Only the MESSAGE is surfaced; no part of the request (and therefore no
  # verifier and no token) is ever echoed into an error.
  defp minimax_error(body, fallback) when is_map(body) do
    case get_in(body, ["base_resp", "status_msg"]) do
      msg when is_binary(msg) and msg != "" -> {:oauth_error, msg}
      _ -> if is_binary(body["error"]), do: {:oauth_error, body["error"]}, else: fallback
    end
  end

  defp minimax_error(_, fallback), do: fallback

  # ── HTTP ────────────────────────────────────────────────────────────────

  defp post_form(url, params) do
    req_options = Application.get_env(:optimal_system_agent, :auth_req_options, [])

    options =
      Keyword.merge(
        [
          url: url,
          form: params,
          headers: [
            {"accept", "application/json"},
            {"user-agent", user_agent()}
          ],
          receive_timeout: 30_000,
          retry: false,
          decode_body: true
        ],
        req_options
      )

    case Req.post(options) do
      {:ok, %{body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, exception} -> {:error, {:transport_error, Exception.message(exception)}}
    end
  rescue
    e -> {:error, {:transport_error, Exception.message(e)}}
  end

  defp user_agent do
    version = Application.spec(:optimal_system_agent, :vsn) |> to_string()
    "osa/#{version}"
  end

  defp as_int(v) when is_integer(v), do: v

  defp as_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      _ -> nil
    end
  end

  defp as_int(_), do: nil
end
