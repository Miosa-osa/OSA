defmodule OptimalSystemAgent.Auth.DeviceFlow do
  @moduledoc """
  RFC 8628 OAuth 2.0 Device Authorization Grant.

  The browser hand-off used for "connect my account" sign-in. Provider-agnostic
  — a provider supplies endpoints, a client id and a scope; everything about
  polling, back-off and error classification lives here once.

  ## Why device code and not a localhost callback

  The obvious alternative is the loopback authorization-code flow: spin up a
  local HTTP listener, send the browser to `…?redirect_uri=http://127.0.0.1:PORT`,
  catch the code. OSA does not do that, for three reasons:

    1. **A loopback listener is reachable by every other process on the
       machine.** `state` and PKCE narrow that window but do not close it;
       there is no peer-credential check available for a browser redirect. The
       device grant has **no listener at all**, so the attack surface is not
       mitigated, it is absent.
    2. **It works headless.** OSA is routinely driven over SSH and in
       containers, where there is no browser to redirect *back* to. A device
       code is a string the user can carry to any browser on any machine.
    3. **It is what the providers actually support for CLIs.** GitHub
       documents the device flow as *the* flow for tools that cannot keep a
       client secret, and issues no client secret for it. GitHub does not
       support PKCE for OAuth apps, so a loopback code flow would require
       embedding a client secret in the binary — strictly worse than either
       option above.

  PKCE is therefore not part of *this* grant — there is no authorization code
  redirected through a user agent to protect. (This paragraph previously
  pointed at an `Auth.PKCE` module "retained for the authorization-code
  providers that need it". No such module exists, and none has ever existed:
  the only `code_verifier` in the tree is **server-supplied** by OpenAI's
  deviceauth endpoint, which is PKCE in shape only. The reference is removed
  rather than left as a promise, because the first provider that genuinely
  needs a client-generated S256 challenge — MiniMax — must build it, not
  discover it missing.)

  ## Secret handling

  `device_code` is a bearer credential for the pending grant: anyone holding
  it can complete the sign-in. It is therefore never logged, never printed,
  and never passed as a command-line argument (every request here goes through
  Req with a body, not through a shelled-out `curl`). The `user_code` — the
  short string the user types into the browser — is the only value shown, and
  it is useless without the concurrent polling session.
  """

  require Logger

  alias OptimalSystemAgent.Auth.DeviceFlow.Session

  @default_interval_s 5
  @min_interval_s 1
  # RFC 8628 says back off by "at least 5 seconds" on slow_down.
  @slow_down_bump_s 5

  # An independent ceiling on the whole poll, measured on the MONOTONIC clock.
  #
  # Two separate bugs are closed by this pair. Trusting the server's
  # `expires_in` alone means a buggy or hostile value pins the CLI for its
  # whole duration with no way out; and measuring the deadline on
  # `System.system_time/1` means an NTP step backwards during the wait
  # silently extends it, potentially forever. The provider's expiry is still
  # honoured — whichever limit trips first wins — this is only a floor under
  # how wrong that can go.
  @max_wait_s 900

  # How many CONSECUTIVE transport failures end the poll.
  #
  # The failure this prevents is the worst-feeling one in the whole flow: the
  # user has already opened the browser, typed the code and approved it, and a
  # single dropped packet on the next poll throws all of that away and demands
  # a fresh code. A transport error mid-poll says nothing about the grant,
  # which is sitting approved on the provider's side waiting to be collected.
  # So they are treated as transient and retried at the normal interval, with
  # a bound so a genuinely severed network still terminates rather than
  # spinning to the deadline.
  @max_consecutive_transport_errors 5

  defmodule Session do
    @moduledoc "A pending device-authorization grant."
    @enforce_keys [:device_code, :user_code, :verification_uri, :expires_at, :interval_s]
    defstruct [
      :device_code,
      :user_code,
      :verification_uri,
      :verification_uri_complete,
      :expires_at,
      :interval_s
    ]

    @type t :: %__MODULE__{}

    # `device_code` is a live credential — keep it out of every accidental
    # `inspect/1`, which is how secrets reach logs and crash reports.
    defimpl Inspect do
      import Inspect.Algebra

      def inspect(session, opts) do
        concat([
          "#DeviceFlow.Session<user_code: ",
          to_doc(session.user_code, opts),
          ", device_code: [REDACTED]>"
        ])
      end
    end
  end

  @type config :: %{
          required(:device_code_url) => String.t(),
          required(:token_url) => String.t(),
          required(:client_id) => String.t(),
          optional(:scope) => String.t(),
          optional(:audience) => String.t()
        }

  @doc """
  Begin a device authorization grant.

  Returns `{:ok, %Session{}}` — the caller shows `user_code` and
  `verification_uri` to the user and then calls `poll/3`.
  """
  @spec start(config()) :: {:ok, Session.t()} | {:error, term()}
  def start(%{device_code_url: url, client_id: client_id} = config) do
    params =
      %{"client_id" => client_id}
      |> maybe_put("scope", Map.get(config, :scope))
      |> maybe_put("audience", Map.get(config, :audience))

    case post_form(url, params) do
      {:ok, %{"device_code" => device_code, "user_code" => user_code} = body} ->
        expires_in = as_int(body["expires_in"]) || 900
        interval = max(as_int(body["interval"]) || @default_interval_s, @min_interval_s)

        {:ok,
         %Session{
           device_code: device_code,
           user_code: user_code,
           verification_uri: body["verification_uri"] || body["verification_url"],
           verification_uri_complete: body["verification_uri_complete"],
           expires_at: System.system_time(:second) + expires_in,
           interval_s: interval
         }}

      {:ok, %{"error" => error} = body} ->
        {:error, classify(error, body)}

      {:ok, _} ->
        {:error, :malformed_device_authorization_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Poll the token endpoint until the user approves, denies, or the grant
  expires.

  `on_tick` is invoked before each sleep so a caller can drive a spinner or
  honour a cancel; returning `:cancel` from it aborts the flow with
  `{:error, :cancelled}` (which is how Ctrl-C becomes a clean message rather
  than a stack trace).

  Handles the three states RFC 8628 defines as *not* errors:

    * `authorization_pending` — the user simply has not finished yet
    * `slow_down` — we are polling too fast; the interval is permanently
      increased, per the RFC, not just for one tick
    * a plain HTTP 4xx with one of those bodies — some providers (GitHub among
      them) return them with a non-200 status, so status alone must never be
      treated as failure
  """
  @spec poll(config(), Session.t(), (-> :continue | :cancel)) ::
          {:ok, map()} | {:error, term()}
  def poll(config, %Session{} = session, on_tick \\ fn -> :continue end) do
    deadline = System.monotonic_time(:second) + max_wait_s()
    do_poll(config, session, session.interval_s, on_tick, deadline, 0)
  end

  defp do_poll(config, session, interval_s, on_tick, deadline, transport_errors) do
    cond do
      # Both clocks are consulted, and they answer different questions. The
      # server's `expires_at` is when the GRANT dies; the monotonic deadline is
      # how long OSA is willing to wait regardless of what the server claimed.
      System.system_time(:second) >= session.expires_at ->
        {:error, :device_code_expired}

      System.monotonic_time(:second) >= deadline ->
        {:error, :device_code_timeout}

      on_tick.() == :cancel ->
        {:error, :cancelled}

      true ->
        Process.sleep(interval_s * 1000)

        params = %{
          "client_id" => config.client_id,
          "device_code" => session.device_code,
          "grant_type" => "urn:ietf:params:oauth:grant-type:device_code"
        }

        case post_form(config.token_url, params) do
          {:ok, %{"access_token" => _} = body} ->
            {:ok, body}

          {:ok, %{"error" => "authorization_pending"}} ->
            do_poll(config, session, interval_s, on_tick, deadline, 0)

          {:ok, %{"error" => "slow_down"} = body} ->
            next = max(as_int(body["interval"]) || interval_s + @slow_down_bump_s, interval_s + 1)
            do_poll(config, session, next, on_tick, deadline, 0)

          {:ok, %{"error" => error} = body} ->
            {:error, classify(error, body)}

          {:ok, _} ->
            {:error, :malformed_token_response}

          # A network blip is not a verdict on the grant. Keep polling; the
          # counter resets on the first response of any kind, so this tolerates
          # a flapping connection without tolerating a severed one.
          {:error, {:transport_error, _} = reason} ->
            if transport_errors + 1 >= @max_consecutive_transport_errors do
              {:error, reason}
            else
              do_poll(config, session, interval_s, on_tick, deadline, transport_errors + 1)
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc false
  @spec max_wait_s() :: pos_integer()
  def max_wait_s,
    do: Application.get_env(:optimal_system_agent, :device_flow_max_wait_s, @max_wait_s)

  @doc false
  @spec max_consecutive_transport_errors() :: pos_integer()
  def max_consecutive_transport_errors, do: @max_consecutive_transport_errors

  @doc """
  Exchange a refresh token for a fresh access token.

  Separate from `poll/3` because it runs unattended, mid-turn, and must never
  block on user interaction.
  """
  @spec refresh(config(), String.t()) :: {:ok, map()} | {:error, term()}
  def refresh(config, refresh_token) when is_binary(refresh_token) do
    params = %{
      "client_id" => config.client_id,
      "refresh_token" => refresh_token,
      "grant_type" => "refresh_token"
    }

    case post_form(config.token_url, params) do
      {:ok, %{"access_token" => _} = body} -> {:ok, body}
      {:ok, %{"error" => error} = body} -> {:error, classify(error, body)}
      {:ok, _} -> {:error, :malformed_token_response}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Error classification ────────────────────────────────────────────────

  @doc """
  Map an OAuth error code onto an OSA reason atom.

  The distinctions preserved here are the ones that change what the user
  should DO, which is the only reason to have more than one error:

    * `:access_denied` — they clicked Deny. Re-running may work.
    * `:device_code_expired` — they walked away. Re-running definitely works.
    * `:refresh_token_invalid` — the grant is permanently gone (revoked from
      the provider's UI, rotated, or reused). Re-running the poll will never
      help; only a fresh sign-in will, and the caller must stop retrying it
      every message.
    * `:subscription_required` / `:insufficient_credits` — the credential is
      *fine*. Telling this user to "re-authenticate" sends them round a loop
      that cannot possibly fix a billing state, so these are kept strictly
      distinct from credential errors.
  """
  @spec classify(String.t(), map()) :: atom() | {atom(), String.t()}
  def classify(error, body \\ %{})

  def classify("access_denied", _), do: :access_denied
  def classify("expired_token", _), do: :device_code_expired
  def classify("invalid_grant", _), do: :refresh_token_invalid
  def classify("invalid_client", _), do: :invalid_client
  def classify("unauthorized_client", _), do: :invalid_client
  def classify("invalid_scope", _), do: :invalid_scope
  def classify("subscription_required", _), do: :subscription_required
  def classify("insufficient_quota", _), do: :insufficient_credits

  def classify(other, body) when is_binary(other) do
    case body["error_description"] do
      d when is_binary(d) and d != "" -> {:oauth_error, "#{other}: #{d}"}
      _ -> {:oauth_error, other}
    end
  end

  # ── HTTP ────────────────────────────────────────────────────────────────

  # Form-encoded POST with a JSON response, which is what every device-flow
  # endpoint in the wild speaks.
  #
  # A non-2xx status is NOT treated as a transport failure when the body
  # carries an OAuth `error` — `authorization_pending` arrives as HTTP 400 from
  # several providers, and treating that as a hard failure would break the
  # happy path for everyone using them.
  defp post_form(url, params) do
    req_options =
      Application.get_env(:optimal_system_agent, :auth_req_options, [])

    options =
      Keyword.merge(
        [
          url: url,
          form: params,
          headers: [
            {"accept", "application/json"},
            # Be honest about who is calling. A tool that has to disguise
            # itself to keep working has its answer about whether it should.
            {"user-agent", user_agent()}
          ],
          receive_timeout: 30_000,
          retry: false,
          # Never raise on 4xx — the body is the signal.
          decode_body: true
        ],
        req_options
      )

    case Req.post(options) do
      {:ok, %{body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{body: body}} when is_binary(body) ->
        # A couple of endpoints ignore `Accept` and return form encoding.
        {:ok, decode_form(body)}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, exception} ->
        {:error, {:transport_error, Exception.message(exception)}}
    end
  rescue
    e -> {:error, {:transport_error, Exception.message(e)}}
  end

  defp decode_form(body) do
    body
    |> String.split("&")
    |> Map.new(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [k, v] -> {URI.decode_www_form(k), URI.decode_www_form(v)}
        [k] -> {URI.decode_www_form(k), ""}
      end
    end)
  rescue
    _ -> %{}
  end

  @doc false
  @spec user_agent() :: String.t()
  def user_agent do
    version = Application.spec(:optimal_system_agent, :vsn) |> to_string()
    "osa/#{version}"
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp as_int(v) when is_integer(v), do: v

  defp as_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      _ -> nil
    end
  end

  defp as_int(_), do: nil
end
