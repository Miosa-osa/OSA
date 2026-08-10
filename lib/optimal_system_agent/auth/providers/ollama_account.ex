defmodule OptimalSystemAgent.Auth.Providers.OllamaAccount do
  @moduledoc """
  Use a signed-in **local Ollama daemon** as Ollama Cloud's second auth mode —
  the account route, next to the pasted `OLLAMA_API_KEY`.

  ## Why this module holds no credential

  `ollama signin` mints nothing OSA could store. It registers the machine's
  existing Ed25519 public key (`~/.ollama/id_ed25519`, created at first daemon
  run, mode 0600) against an ollama.com account; the sign-in state itself lives
  server-side. From then on the *daemon* signs its own cloud requests with that
  key and proxies `:cloud` model tags on the user's behalf.

  So "connecting an Ollama account" in OSA is not a token acquisition. It is:

    1. ask the local daemon who it is signed in as, and
    2. record a **non-secret marker** so the status surfaces can answer
       "connected?" the same way they do for every other subscription provider.

  Consequently `access_token/0` deliberately returns
  `{:error, :externally_managed}` — there is no token here, and that is the
  point. Inference runs through `Providers.Ollama` pointed at the loopback
  daemon with no `Authorization` header at all.

  ## Why the daemon, and not signed requests to ollama.com

  Direct calls to `ollama.com` are possible: sign `"<METHOD>,<path>?ts=<unix>"`
  with the Ed25519 key and send
  `Authorization: <b64 pubkey blob>:<b64 signature>`. That was verified to
  work — and deliberately **not** used. Reimplementing it would mean OSA owning
  a private-key read, a crypto path and an undocumented challenge format that
  can change under it, to arrive at exactly what the daemon already does
  correctly one hop away. The daemon is the sanctioned client for that key;
  OSA proxies through it.

  ## The probe is free, and must stay free

  `POST /api/me` on the loopback daemon is answered **unauthenticated** with
  `{"email", "name", "plan"}`. No network egress, no metered request, no token
  spend — which is what makes it legitimate for a status surface to call. Any
  future change that makes the connection check cost something has broken the
  contract `status/0` is written against.

  A **remote** `OLLAMA_HOST` is declined rather than dialled. Reaching out to
  an arbitrary host to draw a status line is not something a status line should
  do, and OSA has no reason to believe a remote daemon's identity is the user's.
  """

  @behaviour OptimalSystemAgent.Auth.Subscription

  require Logger

  alias OptimalSystemAgent.Auth.SubscriptionStore

  @provider_id "ollama_cloud"
  @display_name "Ollama Cloud"

  # Ollama's own default. Used when nothing else names a loopback daemon —
  # including when `:ollama_url` currently points at https://ollama.com,
  # because that is the KEY mode's endpoint and says nothing about whether a
  # local daemon is running.
  @default_daemon "http://127.0.0.1:11434"

  @loopback_hosts ~w(127.0.0.1 localhost 0.0.0.0 ::1)

  @spec provider_id() :: String.t()
  def provider_id, do: @provider_id

  @spec display_name() :: String.t()
  def display_name, do: @display_name

  @doc """
  Always true — same reasoning as `Auth.Providers.ClaudeCli.available?/0`.

  `Onboarding.usable_auth_modes_for/1` uses this to hide a sign-in that could
  not possibly complete. Here every failure is one command away from fixed
  (`ollama serve`, `ollama signin`), so hiding the option would leave the user
  with a key prompt and no hint that the free route exists. `login/1` is what
  reports what is missing, naming the command.
  """
  @spec available?() :: boolean()
  def available?, do: true

  # ── Daemon discovery ────────────────────────────────────────────────────

  @doc """
  The loopback daemon URL this provider will talk to.

  `OLLAMA_HOST` wins when set (it is Ollama's own variable and the user may
  have moved the daemon's port); otherwise a loopback `:ollama_url` is used;
  otherwise the default. A non-loopback value is returned as-is so callers can
  report *why* they declined instead of silently probing somewhere else.
  """
  @spec daemon_url() :: String.t()
  def daemon_url do
    case System.get_env("OLLAMA_HOST") do
      raw when is_binary(raw) and raw != "" ->
        normalize(raw)

      _ ->
        configured = Application.get_env(:optimal_system_agent, :ollama_url)

        if is_binary(configured) and loopback?(configured) do
          normalize(configured)
        else
          @default_daemon
        end
    end
  end

  defp normalize(raw) do
    raw = String.trim(raw)
    if String.starts_with?(raw, "http"), do: raw, else: "http://" <> raw
  end

  @doc "True when `url` names a plaintext loopback host — the only kind ever dialled here."
  @spec loopback?(String.t() | nil) :: boolean()
  def loopback?(url) when is_binary(url) do
    case URI.parse(normalize(url)) do
      %URI{scheme: "http", host: h} when h in @loopback_hosts -> true
      _ -> false
    end
  end

  def loopback?(_), do: false

  # ── The device key ──────────────────────────────────────────────────────
  #
  # OSA never reads this file — the daemon signs with it. But when the daemon
  # says "not signed in", the state of the key is the difference between "run
  # one command" and "you have a deeper problem", so it is worth naming.

  @doc """
  State of the machine's Ollama device key: `:ok`, `:missing`, or
  `{:insecure, mode}` when it is readable by other users on this box.

  Diagnostic only. Nothing here gates the auth flow: the daemon is the
  authority on whether it can sign, and refusing to connect over a key OSA
  merely disapproves of would break a working setup on a guess.
  """
  @spec key_status() :: :ok | :missing | {:insecure, integer()}
  def key_status do
    path = key_path()

    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} ->
        # Group/other bits set on a private signing key.
        perms = Bitwise.band(mode, 0o777)
        if Bitwise.band(perms, 0o077) != 0, do: {:insecure, perms}, else: :ok

      _ ->
        :missing
    end
  end

  @doc "Where Ollama keeps this machine's signing key. `OLLAMA_MODELS`-style overrides are not a thing here."
  @spec key_path() :: String.t()
  def key_path do
    home = System.get_env("OLLAMA_HOME") || System.user_home() || "~"
    Path.join([home, ".ollama", "id_ed25519"])
  end

  # One extra line, printed only when the key explains something the daemon's
  # answer does not.
  defp key_note do
    case key_status() do
      :missing ->
        ["", "  Note: #{key_path()} does not exist yet. Ollama creates it the first time the", "  daemon runs, and `ollama signin` registers it with your account."]

      {:insecure, mode} ->
        ["", "  Note: #{key_path()} is mode #{Integer.to_string(mode, 8)} — readable by other users", "  on this machine. Run: chmod 600 #{key_path()}"]

      :ok ->
        []
    end
  end

  # ── Probe (loopback, free) ──────────────────────────────────────────────

  @doc """
  Ask the local daemon which account it is signed in as.

  Returns `{:ok, %{account_id:, name:, plan:, daemon_url:}}` or an error whose
  remedy is a single named command. There is no "something went wrong" branch:
  a stopped daemon, a signed-out daemon and a remote `OLLAMA_HOST` need three
  different actions from the user, and collapsing them would waste their time.
  """
  @spec probe() :: {:ok, map()} | {:error, term()}
  def probe do
    url = daemon_url()

    if loopback?(url) do
      # Reuses `Usage`'s loopback client rather than opening a second one:
      # `osa usage` already reads this exact endpoint for the plan display,
      # and two probes of the same daemon would eventually disagree about what
      # "signed in" means.
      case OptimalSystemAgent.Usage.ollama_account(url) do
        {:ok, %{"email" => email} = account} when is_binary(email) and email != "" ->
          {:ok,
           %{
             account_id: email,
             name: account["name"],
             plan: account["plan"],
             daemon_url: url
           }}

        # A 200 with no account on it is the daemon answering about nobody.
        # Treated as signed out, because that is what it means to the user.
        {:ok, _} ->
          {:error, :ollama_not_signed_in}

        {:error, :signed_out} ->
          {:error, :ollama_not_signed_in}

        {:error, :daemon_unreachable} ->
          {:error, :ollama_daemon_unreachable}

        {:error, {:http, status}} ->
          {:error, {:ollama_http, status}}

        {:error, other} ->
          {:error, other}
      end
    else
      {:error, {:ollama_host_remote, url}}
    end
  end

  # ── Connect ─────────────────────────────────────────────────────────────

  @doc """
  "Connect" here is verification, not authentication.

  There is no flow for OSA to run: `ollama signin` is the daemon's own command
  against the machine's own key, and it has either happened or it has not. This
  checks, records, and — when it has not — prints the one command that fixes it.
  """
  @impl true
  @spec login(keyword()) :: {:ok, map()} | {:error, term()}
  def login(opts \\ []) do
    io = Keyword.get(opts, :io, &IO.puts/1)

    case probe() do
      {:ok, account} ->
        case persist(account) do
          {:ok, entry} ->
            io.("")
            io.("  ✓ Using your Ollama account#{plan_suffix(entry)} — signed in as #{account.account_id}")
            io.("    OSA talks to your local Ollama daemon at #{account.daemon_url}, which proxies")
            io.("    :cloud models with this machine's device key. No API key is stored.")
            {:ok, entry}

          err ->
            err
        end

      {:error, :ollama_daemon_unreachable} = err ->
        io.("")
        io.("  No Ollama daemon answered at #{daemon_url()}.")
        io.("")
        io.("    Run   ollama serve       (or start the Ollama app)")
        io.("    then  ollama signin      if you have not signed in on this machine")
        io.("")
        io.("  Then re-run setup. An Ollama Cloud API key works without a local daemon.")
        Enum.each(key_note(), io)
        err

      {:error, :ollama_not_signed_in} = err ->
        io.("")
        io.("  Your local Ollama daemon is running but not signed in to an account.")
        io.("")
        io.("    Run   ollama signin")
        io.("    then re-run OSA setup.")
        io.("")
        io.("  OSA cannot sign you in — `ollama signin` registers THIS machine's key")
        io.("  (~/.ollama/id_ed25519) with your ollama.com account, and only Ollama's")
        io.("  own client can do that.")
        Enum.each(key_note(), io)
        err

      {:error, {:ollama_host_remote, url}} = err ->
        io.("")
        io.("  OLLAMA_HOST points at #{url}, which is not a local daemon.")
        io.("  OSA will not send an account probe to a remote host, so the account")
        io.("  route is unavailable here. Either unset OLLAMA_HOST to use the local")
        io.("  daemon, or paste an Ollama Cloud API key.")
        err

      {:error, reason} = err ->
        io.("")
        io.("  " <> OptimalSystemAgent.Auth.Subscription.message(reason, @display_name))
        err
    end
  end

  # The marker. Note what is NOT here: no token of any kind, and no copy of the
  # Ed25519 key. If a future change adds one, this has stopped being the
  # daemon-proxied route the moduledoc describes.
  defp persist(account) do
    entry = %{
      "kind" => "local_daemon",
      "account_id" => account.account_id,
      "account_name" => account.name,
      "plan_type" => account.plan,
      # Pinned at connect time, so a later settings-cascade `OLLAMA_URL` cannot
      # redirect an account-mode session at an attacker-supplied host.
      "base_url" => account.daemon_url,
      "connected_at" => System.system_time(:second)
    }

    case SubscriptionStore.put(@provider_id, entry) do
      :ok -> {:ok, entry}
      err -> err
    end
  end

  defp plan_suffix(%{"plan_type" => p}) when is_binary(p) and p != "", do: " (#{p} plan)"
  defp plan_suffix(_), do: ""

  # ── Status ──────────────────────────────────────────────────────────────

  @doc """
  Pure read of OSA's marker. Never dials the daemon.

  Required by the `Auth.Subscription` contract — `osa doctor`, `osa auth
  status` and the model picker all call it while drawing a screen.
  """
  @impl true
  def status do
    case SubscriptionStore.fetch(@provider_id) do
      nil ->
        OptimalSystemAgent.Auth.Subscription.disconnected(@provider_id)

      entry ->
        %{
          connected?: true,
          # The marker is only ever written after `/api/me` named an account,
          # so its existence IS the evidence. It can go stale (`ollama
          # signout` in another terminal), which is what `live_status/0` is for.
          verified?: true,
          provider: @provider_id,
          account: entry["account_id"],
          plan: entry["plan_type"],
          # The daemon holds the credential and OSA never sees its lifetime.
          # `nil` is the truthful answer; a made-up expiry would be
          # confidently wrong.
          expires_at: nil,
          expired?: false
        }
    end
  end

  @doc """
  Live connection state: the marker re-checked against the daemon.

  Refuses to create a marker. A signed-in daemon does **not** resurrect a
  connection the user removed with `osa logout` — re-seeding a credential
  somebody just deleted is what makes "sign out" appear to do nothing, and it
  has already been found twice in this subsystem. Only `login/1` and the
  explicit setup-time `connect/0` may write the marker.
  """
  @spec live_status() :: {:ok, map()} | {:error, term()}
  def live_status do
    if is_nil(SubscriptionStore.fetch(@provider_id)) do
      {:error, :not_connected}
    else
      connect()
    end
  end

  @doc """
  Verify the daemon and record the marker, creating it if absent.

  This is what the **setup** surfaces call. For a provider whose sign-in is a
  free loopback read there is nothing else to confirm, so "verify" and
  "connect" are the same act. It is deliberately NOT what `live_status/0` does.
  """
  @spec connect() :: {:ok, map()} | {:error, term()}
  def connect do
    case probe() do
      {:ok, account} ->
        # Refresh in place so `status/0` stops reporting a stale plan or email
        # after the user switches Ollama accounts.
        _ = persist(account)
        {:ok, account}

      err ->
        err
    end
  end

  @doc """
  There is no token. Saying so explicitly is the contract.

  A caller that wants one is trying to make a direct `ollama.com` request on a
  device identity OSA does not hold. That is the API-key mode's job, and this
  error is how the confusion surfaces loudly instead of half working.
  """
  @impl true
  def access_token, do: {:error, :externally_managed}

  @impl true
  def logout do
    result = SubscriptionStore.delete(@provider_id)

    Logger.info(
      "[Auth] Disconnected #{@display_name} from OSA. Your `ollama signin` is untouched — " <>
        "run `ollama signout` if you also want to sign this machine out of ollama.com."
    )

    result
  end
end
