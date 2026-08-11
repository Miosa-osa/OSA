defmodule OptimalSystemAgent.Auth.Providers.CopilotCli do
  @moduledoc """
  Use a GitHub Copilot subscription through GitHub's own **Copilot CLI**.

  Architecturally this is the same shape as `Auth.Providers.ClaudeCli` — an
  external CLI owns the credential and OSA drives it as a subprocess — but the
  two differ in one way that changes the design, so they are deliberately NOT
  a shared abstraction. See "The auth-check problem" below.

  ## Why the CLI and not ACP

  The brief for this provider called for GitHub's Agent Client Protocol mode
  (`copilot --acp`). That was investigated and rejected on evidence:

    * ACP has **no** tool-definition, tool-registration, tool-allowlist or
      tool-disable message anywhere in its v1 schema. Every tool identifier in
      it is either agent→client *reporting* (`session/update`) or *approval*
      (`session/request_permission`).
    * So an ACP client cannot hand the agent OSA's tools, cannot take the
      agent loop back, and would additionally have to implement
      `fs/read_text_file`, `fs/write_text_file`, `terminal/*` and
      `session/request_permission` callbacks to be useful at all.
    * Tool restriction in Copilot is an **argv-at-spawn** concern
      (`--available-tools`, `--excluded-tools`), which is available to the
      plain CLI transport too — at none of ACP's cost.

  Independently corroborated: the one production ACP client found in the
  reference trees hit this same wall and worked around it by serialising tool
  schemas into the prompt text and scraping the calls back out — i.e. it
  reinvented the plain-CLI approach *through* ACP, for nothing.

  ## The auth-check problem, and why this module never spends a request

  `ClaudeCli` can ask `claude auth status --json`. Copilot has **no
  equivalent** — no `auth status`, no `whoami`, and the token lives in the OS
  credential store. `$COPILOT_HOME/config.json` was suggested as a substitute
  and **empirically is not one**: it is opaque, not JSON, and cannot be
  parsed for a signed-in user.

  That leaves exactly one honest option, because the alternative — making an
  inference call to find out — would spend the operator's metered Copilot
  quota every time a status screen was drawn:

    * **Zero-cost signals only.** An explicit token in the environment, or a
      `gh` CLI session holding a Copilot-compatible token, proves sign-in
      without any network call.
    * **When neither exists, say "unconfirmed" rather than guessing.** The
      credential may be perfectly good and sitting in the keychain; OSA simply
      cannot see it. Reporting a confident "connected" or a confident "signed
      out" would both be fabrications, and this codebase has been burned by
      exactly that. The first real turn resolves it.

  `connect/0` and `live_status/0` therefore never make an inference call, and
  `osa doctor` can be run a thousand times for free.
  """

  @behaviour OptimalSystemAgent.Auth.Subscription

  require Logger

  alias OptimalSystemAgent.Auth.SubscriptionStore

  @provider_id "copilot_cli"
  @display_name "GitHub Copilot (via Copilot CLI)"

  # Copilot's own documented precedence, highest first. Read for PRESENCE
  # only — the value is never stored, logged, or passed on.
  @token_env_vars ~w(COPILOT_GITHUB_TOKEN GH_TOKEN GITHUB_TOKEN)

  # Verified against 1.0.79: `--output-format json` on stdin,
  # `--available-tools`, `--disable-builtin-mcps`, `--no-ask-user`. The floor
  # is lower and advisory — refusing to run on an unrecognised build would
  # break a user whose CLI is merely newer, and a too-old one reports its own
  # "unknown option" verbatim.
  @min_version "1.0.0"
  @verified_version "1.0.79"

  @spec provider_id() :: String.t()
  def provider_id, do: @provider_id

  @spec display_name() :: String.t()
  def display_name, do: @display_name

  @spec min_version() :: String.t()
  def min_version, do: @min_version

  @spec verified_version() :: String.t()
  def verified_version, do: @verified_version

  @spec token_env_vars() :: [String.t()]
  def token_env_vars, do: @token_env_vars

  # ── Binary discovery ────────────────────────────────────────────────────

  @doc """
  Absolute path to the `copilot` binary, or `nil`.

  NOTE for anyone installing it: there are two similarly-named things and
  only one is this. `@github/copilot` provides the `copilot` CLI and is what
  this module drives (ACP registry id `github-copilot-cli`). `@github/
  copilot-language-server` is a **different product** that also speaks ACP
  and is registered as `github-copilot`. Wiring the second one up here
  produces a process that starts, handshakes, and never answers a prompt.
  """
  @spec binary() :: String.t() | nil
  def binary do
    case System.get_env("OSA_COPILOT_CLI_BIN") do
      p when is_binary(p) and p != "" ->
        if File.exists?(p), do: p, else: nil

      _ ->
        Application.get_env(:optimal_system_agent, :copilot_cli_bin) ||
          System.find_executable("copilot")
    end
  end

  @doc """
  Always true, for the same reason `ClaudeCli.available?/0` is: this
  provider's only auth mode is `:oauth`, so reporting it unavailable would
  collapse it to an API-key prompt for a provider that has no key. The
  missing pieces (a binary, a sign-in) are things the user can fix, and
  `login/1` names them.
  """
  @spec available?() :: boolean()
  def available?, do: true

  @doc "True when the Copilot CLI can be found."
  @spec installed?() :: boolean()
  def installed?, do: not is_nil(binary())

  @doc "The CLI's reported version, or `nil`."
  @spec version() :: String.t() | nil
  def version do
    with bin when is_binary(bin) <- binary(),
         {out, 0} <- cmd(bin, ["--version"]) do
      case Regex.run(~r/(\d+\.\d+\.\d+)/, out) do
        [_, v] -> v
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  @doc "True when the installed CLI meets the floor. Unknown version ⇒ allowed."
  @spec version_ok?(String.t() | nil) :: boolean()
  def version_ok?(nil), do: true

  def version_ok?(v) when is_binary(v) do
    Version.compare(v, @min_version) != :lt
  rescue
    _ -> true
  end

  # ── Zero-cost sign-in signals ───────────────────────────────────────────

  @doc """
  Which environment variable, if any, is supplying a Copilot token.

  Presence only — the value is never returned. A credential that is merely
  being *detected* has no business being copied around, and a helper that
  returns one invites a caller to log it.
  """
  @spec token_env_var() :: String.t() | nil
  def token_env_var do
    Enum.find(@token_env_vars, fn var ->
      case System.get_env(var) do
        v when is_binary(v) and v != "" -> true
        _ -> false
      end
    end)
  end

  @doc """
  The `gh` CLI's session, when it holds a Copilot-compatible token.

  `gh auth status` is a local read and costs nothing. The token-type check is
  not incidental: Copilot accepts `gho_*` (OAuth) and fine-grained `github_pat_*`
  tokens but **rejects classic `ghp_*` PATs**, so a `gh` session on a classic
  PAT is not evidence of a usable Copilot credential and must not be reported
  as one.
  """
  @spec gh_session() :: {:ok, map()} | :none
  def gh_session do
    with bin when is_binary(bin) <- System.find_executable("gh"),
         {out, 0} <- cmd(bin, ["auth", "status"]) do
      account = Regex.run(~r/account\s+(\S+)/i, out) |> capture()

      token_type =
        cond do
          String.contains?(out, "gho_") -> "gho"
          String.contains?(out, "github_pat_") -> "github_pat"
          String.contains?(out, "ghp_") -> "ghp"
          true -> nil
        end

      if token_type in ["gho", "github_pat"] do
        {:ok, %{account: account, token_type: token_type}}
      else
        :none
      end
    else
      _ -> :none
    end
  end

  defp capture([_, v]), do: v
  defp capture(_), do: nil

  @doc """
  What OSA can determine about sign-in **without spending anything**.

  Returns one of:

    * `{:ok, %{verified: true, source: "env:VAR" | "gh", account: ...}}`
    * `{:ok, %{verified: false, source: "cli_managed"}}` — the CLI is present
      and may well be signed in via the OS credential store, which OSA cannot
      inspect. This is the honest "don't know", not a failure.
    * `{:error, :cli_not_installed}`
  """
  @spec probe() :: {:ok, map()} | {:error, term()}
  def probe do
    cond do
      is_nil(binary()) ->
        {:error, :cli_not_installed}

      var = token_env_var() ->
        {:ok, %{verified: true, source: "env:" <> var, account: nil}}

      true ->
        case gh_session() do
          {:ok, %{account: account, token_type: type}} ->
            {:ok, %{verified: true, source: "gh", account: account, token_type: type}}

          :none ->
            {:ok, %{verified: false, source: "cli_managed", account: nil}}
        end
    end
  end

  # ── Connect ─────────────────────────────────────────────────────────────

  @impl true
  @spec login(keyword()) :: {:ok, map()} | {:error, term()}
  def login(opts \\ []) do
    io = Keyword.get(opts, :io, &IO.puts/1)

    case binary() do
      nil ->
        io.("")
        io.("  The GitHub Copilot CLI is not installed, or is not on PATH.")
        io.("")
        io.("    npm install -g @github/copilot")
        io.("")
        io.("  (That is the `copilot` CLI. @github/copilot-language-server is a")
        io.("   different product and will not work here.)")
        io.("  If it is installed somewhere unusual, set OSA_COPILOT_CLI_BIN.")
        {:error, :cli_not_installed}

      bin ->
        do_login(bin, io)
    end
  end

  defp do_login(bin, io) do
    ver = version()

    if not version_ok?(ver) do
      io.("")
      io.("  Your Copilot CLI is #{ver}; OSA needs #{@min_version} or newer.")
      io.("  Run  copilot update  and try again.")
      {:error, {:cli_too_old, ver}}
    else
      {:ok, signals} = probe()

      case persist(signals, ver, bin) do
        {:ok, entry} ->
          announce(entry, io)
          {:ok, entry}

        err ->
          err
      end
    end
  end

  defp announce(%{"verified" => true} = entry, io) do
    io.("")
    io.("  ✓ Using your GitHub Copilot plan through the Copilot CLI#{account_suffix(entry)}")
    io.("    Detected via #{entry["auth_source"]}. OSA runs the CLI for inference;")
    io.("    your credential stays with Copilot — OSA never sees or stores it.")
  end

  defp announce(_entry, io) do
    io.("")
    io.("  ✓ Copilot CLI found. OSA will use it for inference.")
    io.("")
    io.("  One caveat, stated up front: OSA could not confirm you are signed in.")
    io.("  Copilot has no offline way to check, and your credential (if any) is in")
    io.("  the system keychain where OSA cannot look. OSA will NOT make a billed")
    io.("  request just to find out.")
    io.("")
    io.("  If your first turn fails on authentication, run:  copilot login")
  end

  defp account_suffix(%{"account_id" => a}) when is_binary(a) and a != "", do: " as #{a}"
  defp account_suffix(_), do: ""

  # The marker. As with ClaudeCli, NOTHING here is a credential — not even the
  # env var's value, only its name. If a future change adds a token to this
  # map, this provider has stopped being a bring-your-own-CLI integration and
  # the moduledoc no longer describes it.
  defp persist(signals, ver, bin) do
    entry = %{
      "kind" => "external_cli",
      "verified" => signals.verified,
      "auth_source" => signals.source,
      "account_id" => signals[:account],
      "cli_version" => ver,
      "cli_path" => bin,
      "connected_at" => System.system_time(:second)
    }

    case SubscriptionStore.put(@provider_id, entry) do
      :ok -> {:ok, entry}
      err -> err
    end
  end

  @doc """
  Re-check the zero-cost signals and refresh the marker in place.

  Never creates a marker: a user who ran `osa logout` must not have it
  resurrected by a status screen noticing that `gh` happens to be logged in.
  Same split as `ClaudeCli`, and the same reason.
  """
  @spec live_status() :: {:ok, map()} | {:error, term()}
  def live_status do
    if is_nil(SubscriptionStore.fetch(@provider_id)) do
      {:error, :not_connected}
    else
      connect()
    end
  end

  @doc "Verify and record, creating the marker if absent. The setup surfaces' step."
  @spec connect() :: {:ok, map()} | {:error, term()}
  def connect do
    case probe() do
      {:ok, signals} -> persist(signals, version(), binary())
      err -> err
    end
  end

  # ── Status ──────────────────────────────────────────────────────────────

  @impl true
  def status do
    case SubscriptionStore.fetch(@provider_id) do
      nil ->
        OptimalSystemAgent.Auth.Subscription.disconnected(@provider_id)

      entry ->
        %{
          connected?: true,
          # Very often `false` here while `connected?` is `true`. See
          # `Auth.Subscription`'s status typedoc: a marker created from
          # "the binary is on PATH" is a record of the user's choice, not
          # evidence of a sign-in, and reporting it as the latter is the
          # fabrication this provider exists to avoid.
          verified?: entry["verified"] == true,
          provider: @provider_id,
          account: entry["account_id"],
          # The Copilot plan tier is not discoverable offline. `nil` is the
          # truthful answer; a plausible-looking constant would not be.
          plan: nil,
          expires_at: nil,
          expired?: false
        }
    end
  end

  @doc "True when sign-in was positively established, not merely assumed."
  @spec verified?() :: boolean()
  def verified? do
    case SubscriptionStore.fetch(@provider_id) do
      %{"verified" => true} -> true
      _ -> false
    end
  end

  @impl true
  def access_token, do: {:error, :externally_managed}

  @impl true
  def logout do
    # Whether anything was actually removed, checked BEFORE the delete. A log
    # line announcing a disconnection that did not happen is the same class of
    # untruth as `/logout` claiming no sign-ins existed while three were live.
    was_connected? = not is_nil(SubscriptionStore.fetch(@provider_id))
    result = SubscriptionStore.delete(@provider_id)

    if was_connected? do
      Logger.info(
        "[Auth] Disconnected #{@display_name} from OSA. Your Copilot CLI sign-in is untouched — " <>
          "run `copilot logout` there if you also want to sign out of it."
      )
    end

    result
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp cmd(bin, args) do
    System.cmd(bin, args, stderr_to_stdout: true, env: probe_env())
  rescue
    e -> {Exception.message(e), 1}
  end

  # Keep the probe on the user's OWN Copilot CLI sign-in.
  #
  # This provider's entire claim is "you are already signed in to the Copilot
  # CLI, so use that". A `GITHUB_TOKEN` or `GH_TOKEN` inherited from OSA's
  # environment — a workspace `.env`, a CI runner, a `gh auth` shell export —
  # makes the CLI answer about THAT token instead, so `verified?/0` reports a
  # sign-in, and every later request is spent, against an account the
  # workspace supplied rather than the one the user connected. On a shared or
  # untrusted workspace that is a credential-confusion hole, not a cosmetic
  # one: the user is told they are connected as themselves.
  #
  # `GH_HOST` is nulled for the same reason one step out — it silently
  # redirects the probe at a GitHub Enterprise instance, so the answer can be
  # about a different *server* as well as a different account.
  #
  # Same discipline as `ClaudeCli.probe_env/0`; `NO_COLOR` is kept so the
  # output stays parseable.
  @doc false
  @spec probe_env() :: [{String.t(), String.t() | nil}]
  def probe_env do
    nulled =
      (@token_env_vars ++ ~w(GITHUB_ENTERPRISE_TOKEN GH_ENTERPRISE_TOKEN GH_HOST))
      |> Enum.uniq()
      |> Enum.map(&{&1, nil})

    [{"NO_COLOR", "1"} | nulled]
  end
end
