defmodule OptimalSystemAgent.Auth.Providers.ClaudeCli do
  @moduledoc """
  Use a Claude Pro/Max subscription through the **Claude Code CLI** — the one
  path Anthropic sanctions for a third-party harness.

  ## Why this module holds no credential

  Anthropic's position has two halves that only make sense together:

    * The Agent SDK docs say *"Anthropic does not allow third party developers
      to offer claude.ai login … for their products"*. So OSA must not ship
      "Sign in with Claude": no OAuth client id, no browser flow, no token
      minting, no token store.
    * The help-centre article on using the Agent SDK with a Claude plan says
      the plan's Agent SDK credit explicitly covers *"third-party apps that
      authenticate with your Claude subscription through the Agent SDK"*,
      alongside `claude -p`.

  The permitted act is a **user bringing their own already-authenticated
  Claude Code**; the prohibited act is a **vendor offering the login**. This
  module therefore does the smallest possible thing: it finds the `claude`
  binary, asks it whether it is signed in, and records a *non-secret marker*
  so OSA's status surfaces can answer "connected?" the same way they do for
  every other subscription provider.

  Consequently:

    * `access_token/0` deliberately returns `{:error, :externally_managed}`.
      There is no token here for OSA to hold, and that is the point. The
      transport (`Providers.ClaudeCli`) never sees one either — it spawns the
      CLI, which reads its own credential from its own store.
    * `logout/0` forgets OSA's marker only. It cannot and must not log the
      user out of Claude Code; that is `claude auth logout`, and the message
      says so rather than implying OSA cleared something it did not.
    * Nothing written to `subscriptions.json` by this module is a credential,
      so the store's 0600 guarantees are belt-and-braces here rather than
      load-bearing. The account email IS written, so it is still not something
      to leave world-readable.

  ## Driving the vendor CLI's own login, from inside OSA

  Holding no credential does not have to mean sending the user away. The
  prohibited act is OSA *offering* a Claude login; running Anthropic's own
  client, with Anthropic's own login, on a pty OSA happens to be drawing is
  the sanctioned route — it is the same act as typing `claude auth login`
  into a terminal, and the credential still lands in Claude Code's store and
  nowhere else.

  So this module also answers the two questions a caller needs in order to do
  that without guessing:

    * `install_argv/0` — the one command that installs the CLI, for the case
      where the binary is simply absent. "Install Claude Code" with no command
      is a dead end; the command is the whole remedy.
    * `login_argv/0` — *which* login subcommand THIS installation supports,
      read out of its own `--help` rather than assumed. The CLI has shipped
      `claude login`, `claude auth login` and `claude setup-token` at
      different points; picking one by version guesswork is how a user gets
      `unknown command` from a binary that was perfectly capable of signing
      them in.

  ## What is checked, and what a failure means

  `probe/0` shells out to `claude auth status --json` — a **local** read of
  Claude Code's own credential store, no network call, typically well under a
  second. It is the honest source of truth: OSA's marker can go stale the
  moment the user runs `claude auth logout` in another terminal, and a cached
  "connected" that is no longer true is worse than no cache at all. So the
  health check probes and `status/0` (which must stay pure per the
  `Auth.Subscription` contract) reads the marker.
  """

  @behaviour OptimalSystemAgent.Auth.Subscription

  require Logger

  alias OptimalSystemAgent.Auth.SubscriptionStore

  @provider_id "claude_cli"
  @display_name "Claude (via Claude Code)"

  # The flags the transport depends on (`--input-format stream-json`,
  # `--tools`, `--setting-sources`, `--strict-mcp-config`) were verified
  # against 2.1.226. The floor is deliberately lower than that and advisory:
  # refusing to run on an unrecognised version would break a user whose CLI is
  # simply newer, and the failure mode of a too-old CLI is a clear
  # "unknown option" from the binary itself, which is surfaced verbatim.
  @min_version "2.0.0"

  @probe_timeout_ms 15_000

  @spec provider_id() :: String.t()
  def provider_id, do: @provider_id

  @spec display_name() :: String.t()
  def display_name, do: @display_name

  @spec min_version() :: String.t()
  def min_version, do: @min_version

  # ── Binary discovery ────────────────────────────────────────────────────

  @doc """
  Absolute path to the `claude` binary, or `nil`.

  `OSA_CLAUDE_CLI_BIN` overrides discovery, for a CLI installed somewhere
  `PATH` does not reach (a common shape when OSA runs as a service).
  """
  @spec binary() :: String.t() | nil
  def binary do
    case System.get_env("OSA_CLAUDE_CLI_BIN") do
      p when is_binary(p) and p != "" ->
        if File.exists?(p), do: p, else: nil

      _ ->
        Application.get_env(:optimal_system_agent, :claude_cli_bin) ||
          System.find_executable("claude")
    end
  end

  @doc """
  Always true — and that is deliberate, unlike `Copilot`'s.

  `Onboarding.usable_auth_modes_for/1` uses this to drop a sign-in option
  that could not possibly complete. For an OAuth provider with no registered
  client id, hiding it is right: nothing the user can do would make it work.
  Here the opposite holds — the missing piece is a binary the user can
  install in one command, and this is the only provider whose sole auth mode
  is `:oauth`, so reporting "unavailable" would collapse it to a key prompt
  for a provider that has no key.

  So the option is always offered and `login/1` is what reports a missing or
  signed-out CLI, with the exact command to fix it. `installed?/0` is the
  question this function is *not* answering.
  """
  @spec available?() :: boolean()
  def available?, do: true

  @doc "True when the Claude Code CLI can be found. See `available?/0` for why they differ."
  @spec installed?() :: boolean()
  def installed?, do: not is_nil(binary())

  @doc "The CLI's reported version string, or `nil` if it cannot be run."
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

  @doc "True when the installed CLI is at or above `min_version/0`. `nil` version ⇒ unknown ⇒ allowed."
  @spec version_ok?(String.t() | nil) :: boolean()
  def version_ok?(nil), do: true

  def version_ok?(v) when is_binary(v) do
    Version.compare(v, @min_version) != :lt
  rescue
    _ -> true
  end

  # ── Probe (local, no network) ───────────────────────────────────────────

  @doc """
  Ask the CLI whether it is signed in.

  Returns `{:ok, %{email:, plan:, auth_method:, org:}}`, or an error naming
  the specific thing to fix. Every failure here is actionable — there is no
  "something went wrong" branch, because every one of these has a different
  remedy and telling a user to "try again" when the binary is missing wastes
  their time.
  """
  @spec probe() :: {:ok, map()} | {:error, term()}
  def probe do
    case binary() do
      nil ->
        {:error, :cli_not_installed}

      bin ->
        case cmd(bin, ["auth", "status", "--json"]) do
          {out, 0} -> parse_status(out)
          # A non-zero exit here is the CLI telling us it could not answer:
          # not installed correctly, or a flag it does not know. Both are
          # "your CLI is too old / broken", not "you are logged out".
          {out, _} -> {:error, {:cli_error, first_line(out)}}
        end
    end
  end

  defp parse_status(out) do
    with {:ok, json} <- decode_first_object(out) do
      if json["loggedIn"] == true do
        {:ok,
         %{
           email: json["email"],
           plan: json["subscriptionType"],
           auth_method: json["authMethod"],
           api_provider: json["apiProvider"],
           org: json["orgName"]
         }}
      else
        {:error, :cli_not_signed_in}
      end
    end
  end

  # `claude auth status --json` prints a single JSON object, but a stray
  # banner or update notice ahead of it is not worth failing over.
  defp decode_first_object(out) do
    case Jason.decode(String.trim(out)) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      _ ->
        case Regex.run(~r/\{.*\}/s, out) do
          [json] ->
            case Jason.decode(json) do
              {:ok, map} when is_map(map) -> {:ok, map}
              _ -> {:error, :cli_status_unreadable}
            end

          _ ->
            {:error, :cli_status_unreadable}
        end
    end
  end

  # ── Driving the CLI's own login ─────────────────────────────────────────

  # npm because that is the install route Anthropic documents and the one that
  # works on every platform OSA runs on. It is deliberately a bare argv rather
  # than a shell string: whatever runs this is spawning a process, not
  # evaluating a line, and a command that has to survive a shell is a command
  # that can be made to mean something else.
  @install_argv ["npm", "install", "-g", "@anthropic-ai/claude-code"]

  @doc """
  The one command that installs the Claude Code CLI, as an argv.

  Surfaced so a "not installed" screen can *offer to run it* rather than print
  a sentence and stop.
  """
  @spec install_argv() :: [String.t()]
  def install_argv, do: @install_argv

  @doc """
  The argv that starts an interactive sign-in for the installed CLI.

  Detected from the binary's own `--help`, never from its version number.
  Returns `{:error, :cli_not_installed}` when there is nothing to ask, and
  `{:error, {:no_login_subcommand, help}}` when the binary answered but named
  none of the login subcommands we know — which is a real possibility for a
  future CLI, and is reported with the help text so the user can see what it
  *did* offer instead of being told "try again".
  """
  @spec login_argv() :: {:ok, [String.t()]} | {:error, term()}
  def login_argv do
    case binary() do
      nil ->
        {:error, :cli_not_installed}

      bin ->
        top = help_text(bin, [])
        # `claude auth login` is a subcommand of a subcommand, so the top-level
        # help only proves `auth` exists. Ask `auth` itself what it offers
        # before claiming `login` is under it.
        auth = if mentions_subcommand?(top, "auth"), do: help_text(bin, ["auth"]), else: ""
        login_argv_from_help(top, auth)
    end
  end

  @doc """
  The pure half of `login_argv/0`: choose a subcommand from help text.

  Ordering is interactive-first. `setup-token` exists for a box with no
  browser and prints a token the user must paste back; when a real terminal is
  available — and inside OSA one always is, that being the point of the pty —
  the ordinary login is the shorter path and the one whose credential Claude
  Code refreshes by itself.
  """
  @spec login_argv_from_help(String.t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def login_argv_from_help(top_help, auth_help \\ "") do
    cond do
      mentions_subcommand?(auth_help, "login") -> {:ok, ["auth", "login"]}
      mentions_subcommand?(top_help, "login") -> {:ok, ["login"]}
      mentions_subcommand?(top_help, "setup-token") -> {:ok, ["setup-token"]}
      # `auth` exists but we could not read its help (e.g. it wrote to a pager,
      # or exited non-zero). Trusting the one subcommand the top-level help DID
      # name is better than declaring the CLI unusable.
      mentions_subcommand?(top_help, "auth") -> {:ok, ["auth", "login"]}
      true -> {:error, {:no_login_subcommand, String.slice(top_help, 0, 400)}}
    end
  end

  # Matches a word only where a help listing would put a subcommand: at the
  # start of a line (`  login    Sign in…`) or inside a usage/commands
  # enumeration (`<login|logout>`, `login|logout`). A bare substring test
  # matches the word "login" inside a *sentence* about logging in, which is
  # how a CLI with no `login` subcommand gets one invented for it.
  defp mentions_subcommand?(help, word) when is_binary(help) do
    esc = Regex.escape(word)

    Regex.match?(~r/^\s{1,6}#{esc}(?:[\s,|]|$)/m, help) or
      Regex.match?(~r/[<\[|]#{esc}[>\]|]/, help) or
      Regex.match?(~r/^\s*#{esc}\s{2,}\S/m, help)
  end

  defp mentions_subcommand?(_, _), do: false

  # `--help` on a CLI that does not know the subcommand exits non-zero and
  # prints its complaint to stderr; that output is still the most informative
  # thing we have, so it is kept rather than discarded with the exit code.
  defp help_text(bin, args) do
    case cmd(bin, args ++ ["--help"]) do
      {out, _} -> to_string(out)
    end
  end

  @doc """
  Everything a sign-in surface needs to decide what to draw, in one read.

  Deliberately one call: a screen that has to make four separate decisions
  about the same binary (is it there, how old, is it signed in, what do I run)
  will make them at four different instants, and the resulting screen can
  describe a state that never existed.

  ## What the caller is being asked to execute

  A surface that acts on this spawns `login_program` with `login_argv`, so it
  is worth being explicit about where those strings come from:

    * `login_program` is `binary/0` — a path from `PATH` or from the operator's
      own `OSA_CLAUDE_CLI_BIN`. Never from a request.
    * `login_argv` is drawn from a closed set of literals defined in this
      module (`["auth", "login"]`, `["login"]`, `["setup-token"]`). The CLI's
      `--help` output selects *which* literal; no part of it is ever
      interpolated into the argv.
    * `install_argv` is a module constant.

  So no help text, no response body and no user input reaches an exec. That is
  a property to preserve, not an accident: the moment a detected string is
  passed through instead of matched against, this endpoint becomes a way to
  ask OSA to run something.
  """
  @spec cli_state() :: map()
  def cli_state do
    bin = binary()
    ver = if bin, do: version(), else: nil

    {signed_in?, account} =
      case probe() do
        {:ok, acct} -> {true, acct}
        _ -> {false, nil}
      end

    {login_argv, login_error} =
      case login_argv() do
        {:ok, argv} -> {argv, nil}
        {:error, reason} -> {nil, inspect(reason)}
      end

    %{
      installed: not is_nil(bin),
      path: bin,
      version: ver,
      # `nil` when there is no binary to ask, NOT `true`. "Old enough" is a
      # claim about a version we do not have.
      version_ok: if(bin, do: version_ok?(ver), else: nil),
      min_version: @min_version,
      signed_in: signed_in?,
      account: account && account.email,
      org: account && account.org,
      plan: account && account.plan,
      # `login_program` is what gets spawned (an absolute path, so a caller
      # never depends on its own PATH matching OSA's); `login_argv` is the
      # detected subcommand, and the two are only meaningful together.
      login_program: bin,
      login_argv: login_argv,
      login_display: if(login_argv, do: Enum.join(["claude" | login_argv], " "), else: nil),
      login_error: login_error,
      install_argv: @install_argv,
      install_url: "https://claude.com/product/claude-code"
    }
  end

  # ── Connect ─────────────────────────────────────────────────────────────

  @doc """
  "Connect" for this provider is verification, not authentication.

  There is no flow to run: the user signs in to Claude Code with
  `claude auth login` (or `claude setup-token` for a headless box), which is
  Anthropic's own client doing Anthropic's own login. OSA checks the result
  and records that it is usable.

  When the CLI is present but signed out, this prints the exact command to
  run rather than opening a browser — OSA opening an Anthropic login is
  precisely the act that is not permitted.
  """
  @impl true
  @spec login(keyword()) :: {:ok, map()} | {:error, term()}
  def login(opts \\ []) do
    io = Keyword.get(opts, :io, &IO.puts/1)

    case binary() do
      nil ->
        io.("")
        io.("  Claude Code is Anthropic's own command-line client. OSA runs it")
        io.("  for inference, so your Claude Pro/Max plan is billed instead of")
        io.("  per-token API credit — but it is not installed here.")
        io.("")
        io.("    #{Enum.join(@install_argv, " ")}")
        io.("")
        io.("  Or open the provider picker in the OSA TUI (Alt+P → Claude), which")
        io.("  will run that for you and then drive the sign-in in place.")
        io.("  If it IS installed somewhere unusual, set OSA_CLAUDE_CLI_BIN to")
        io.("  its full path.")
        {:error, :cli_not_installed}

      bin ->
        do_login(bin, io)
    end
  end

  defp do_login(bin, io) do
    ver = version()

    if not version_ok?(ver) do
      io.("")
      io.("  Your Claude Code CLI is #{ver}; OSA needs #{@min_version} or newer.")
      io.("  Run  claude update  and try again.")
      {:error, {:cli_too_old, ver}}
    else
      case probe() do
        {:ok, account} ->
          persist(account, ver, bin)
          |> case do
            {:ok, entry} ->
              io.("")
              io.("  ✓ Using your Claude subscription through Claude Code#{plan_suffix(entry)}")
              io.("    OSA runs `claude -p` for inference. Your credential stays in Claude Code;")
              io.("    OSA never sees or stores it.")
              {:ok, entry}

            err ->
              err
          end

        {:error, :cli_not_signed_in} ->
          cmd_line =
            case login_argv() do
              {:ok, argv} -> Enum.join(["claude" | argv], " ")
              _ -> "claude auth login"
            end

          io.("")
          io.("  Claude Code is installed but not signed in.")
          io.("")
          io.("    Open the provider picker in the OSA TUI (Alt+P → Claude) and OSA will")
          io.("    run  #{cmd_line}  for you, in place, and show its prompts here.")
          io.("")
          io.("    Outside the TUI, run it yourself:  #{cmd_line}")
          io.("")
          io.("  Either way it is Anthropic's own client doing Anthropic's own login —")
          io.("  OSA never offers a Claude sign-in of its own, and never sees the")
          io.("  credential that results.")
          {:error, :cli_not_signed_in}

        {:error, reason} ->
          io.("")
          io.("  " <> OptimalSystemAgent.Auth.Subscription.message(reason, @display_name))
          {:error, reason}
      end
    end
  end

  # The marker. Note what is NOT here: no access token, no refresh token, no
  # OAuth anything. If a future change adds one, this provider has stopped
  # being the sanctioned path and the moduledoc above no longer describes it.
  defp persist(account, ver, bin) do
    entry = %{
      "kind" => "external_cli",
      "account_id" => account.email,
      "plan_type" => account.plan,
      "auth_method" => account.auth_method,
      "api_provider" => account.api_provider,
      "org" => account.org,
      "cli_version" => ver,
      "cli_path" => bin,
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
  Pure read of OSA's marker. Never runs the CLI.

  Required by the `Auth.Subscription` contract: `osa doctor`, the model picker
  and `osa auth status` all call this while drawing a screen, and none of them
  should be able to fork a process to do it.
  """
  @impl true
  def status do
    case SubscriptionStore.fetch(@provider_id) do
      nil ->
        OptimalSystemAgent.Auth.Subscription.disconnected(@provider_id)

      entry ->
        %{
          connected?: true,
          # The marker is only ever written after `claude auth status --json`
          # answered `loggedIn: true`, so its existence IS the evidence. It
          # can still go stale (the user may run `claude auth logout`
          # elsewhere), which is what `live_status/0` is for.
          verified?: true,
          provider: @provider_id,
          account: entry["account_id"],
          plan: entry["plan_type"],
          # The marker has carried `org` since it was first written, and only
          # the email was ever displayed — which is how a user with a personal
          # and a work Claude account could read "connected" off a status
          # screen and still not know which one OSA was about to spend. All
          # three are cheap to carry and only one of them is enough to be
          # confidently wrong.
          org: entry["org"],
          # An external credential OSA does not hold has no expiry OSA can
          # know. Reporting `nil` is the truthful answer; inventing one would
          # make the status line confidently wrong.
          expires_at: nil,
          expired?: false
        }
    end
  end

  @doc """
  Live connection state: the marker re-checked against the CLI.

  Used by the health check, where being a few hundred milliseconds slower is
  a good trade for not telling a signed-out user they are signed in.
  """
  @spec live_status() :: {:ok, map()} | {:error, term()}
  def live_status do
    if is_nil(SubscriptionStore.fetch(@provider_id)) do
      # No marker means the user has not connected this provider, or has
      # explicitly disconnected it. A signed-in CLI does NOT re-create it:
      # re-seeding a credential the user just removed is the exact bug that
      # makes "sign out" appear to do nothing, and the store's own design
      # note calls it out. Only `login/1` may create the marker.
      {:error, :not_connected}
    else
      connect()
    end
  end

  @doc """
  Verify the CLI and record the marker, creating it if absent.

  This is what the **setup** surfaces call — `osa setup`'s verify step and the
  TUI wizard's health check both land here, and for this provider "verify" and
  "connect" are the same act: there is no browser round-trip, no code to
  enter, nothing to approve. A user who has selected this provider in the
  wizard has said what they want, so making them confirm a purely local
  file read would be ceremony.

  It is deliberately NOT what `live_status/0` does. Status displays must not
  resurrect a marker the user deleted with `osa logout`.
  """
  @spec connect() :: {:ok, map()} | {:error, term()}
  def connect do
    case probe() do
      {:ok, account} ->
        # Refresh in place, so `status/0` stops reporting a stale plan or
        # account after the user switches profiles in Claude Code.
        _ = persist(account, version(), binary())
        {:ok, account}

      err ->
        err
    end
  end

  @doc """
  There is no token. Saying so explicitly is the contract.

  A caller that needs one is trying to make a direct Anthropic API request on
  a subscription credential, which is exactly the thing OSA removed in
  v1.0.63. This error is how that mistake surfaces loudly instead of half
  working.
  """
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
        "[Auth] Disconnected #{@display_name} from OSA. Your Claude Code sign-in is untouched — " <>
          "run `claude auth logout` if you also want to sign out there."
      )
    end

    result
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp cmd(bin, args) do
    System.cmd(bin, args,
      stderr_to_stdout: true,
      env: probe_env()
    )
  rescue
    e -> {Exception.message(e), 1}
  end

  # Keep the probe on the subscription credential. An `ANTHROPIC_API_KEY`
  # inherited from OSA's own environment would make `claude auth status`
  # answer about the key instead — and would silently bill the user
  # per-token on every subsequent request through a provider they chose
  # *because* it does not.
  @doc false
  @spec probe_env() :: [{String.t(), String.t() | nil}]
  def probe_env do
    [
      {"ANTHROPIC_API_KEY", nil},
      {"ANTHROPIC_AUTH_TOKEN", nil},
      {"ANTHROPIC_BASE_URL", nil}
    ]
  end

  defp first_line(out) do
    out |> to_string() |> String.split("\n", parts: 2) |> List.first() |> String.trim()
  end

  # `System.cmd` has a hard timeout only via the OS; the probe is a local
  # read and has never been observed to hang, but the constant is kept so a
  # future port-based implementation has the number it should use.
  @doc false
  def probe_timeout_ms, do: @probe_timeout_ms
end
