defmodule OptimalSystemAgent.CLI.Auth do
  @moduledoc """
  `osa auth` — the surface for account sign-ins, and the only supported way
  back out of one.

  ## Why this module exists at all

  For one release OSA could sign a user *in* to a provider subscription and had
  no way to sign them out. `Auth.Subscription.logout/1` was implemented,
  tested, and had zero callers anywhere in `lib/`; `/logout` in the REPL
  printed "No account sign-in sessions exist — OSA uses API keys only", which
  had become false; and two moduledocs cited `osa auth status` as a caller of
  their read-only paths while no such command existed. The only actual exit was
  `rm ~/.osa/subscriptions.json`.

  That is worse than not shipping sign-in. A credential a user cannot revoke
  through the product is a credential they have to reason about themselves, and
  "delete this JSON file" is not an answer anyone should have to find.

  ## The read-only contract, restated because this is the module that tests it

  Every command here except `login` and `logout` is a **pure read**. `status/0`
  walks `Auth.Subscription.status_all/0`, which never dials out and never
  refreshes — so running `osa auth status` in a loop cannot spend a rotating
  refresh token, cannot trip a rate limit, and cannot spend a metered request
  against the user's plan. The corollary is that a token which expired while
  OSA was not looking is reported as expired rather than quietly renewed; that
  is the honest trade and the reason `expires_at` is displayed at all.

  ## Subcommands

      osa auth                      same as `osa auth status`
      osa auth status               one row per sign-in-capable provider
      osa auth login <provider>     run that provider's sign-in flow
      osa auth logout <provider>    forget OSA's copy of that credential
      osa auth logout --all         forget every one of them

  `osa logout [provider]` is an alias for `osa auth logout`, because that is
  the verb people reach for first.
  """

  alias OptimalSystemAgent.Auth.Subscription
  alias OptimalSystemAgent.Auth.SubscriptionStore

  @reset "\e[0m"
  @dim "\e[2m"
  @bold "\e[1m"
  @green "\e[32m"
  @yellow "\e[33m"
  @cyan "\e[36m"

  @doc """
  Entry point for the `osa auth` subcommand.

  Returns `:ok` for success and `{:error, reason}` for a failure the caller
  should turn into a non-zero exit code — `bin/osa` propagates it, so a
  scripted `osa auth logout` that silently did nothing cannot look like a
  success.
  """
  @spec run([String.t()]) :: :ok | {:error, term()}
  def run(argv \\ [])

  def run([]), do: run(["status"])
  def run(["status" | _]), do: status()
  def run(["list" | _]), do: status()

  def run(["login"]), do: usage("`osa auth login` needs a provider.")
  def run(["login", provider | _]), do: login(provider)

  def run(["logout", "--all" | _]), do: logout_all()
  def run(["logout"]), do: logout_interactive()
  def run(["logout", provider | _]), do: logout(provider)

  def run(["help" | _]), do: help()
  def run(["--help" | _]), do: help()
  def run(["-h" | _]), do: help()

  def run([other | _]), do: usage("Unknown `osa auth` subcommand: #{other}")

  # ── status ──────────────────────────────────────────────────────────────

  @doc """
  Print one row per sign-in-capable provider. Pure read — no network, no
  refresh, no metered request.
  """
  @spec status() :: :ok
  def status do
    IO.puts("")
    IO.puts("  #{@bold}Account sign-ins#{@reset}")
    IO.puts("")

    rows = Subscription.status_all()

    if Enum.all?(rows, &(not &1.connected?)) do
      IO.puts("  #{@dim}No provider is connected by account sign-in.#{@reset}")
      IO.puts("")

      IO.puts(
        "  #{@dim}Providers that support it:#{@reset} #{Enum.join(Subscription.supported(), ", ")}"
      )

      IO.puts(
        "  #{@dim}Connect one with#{@reset}  #{@cyan}osa auth login <provider>#{@reset}  #{@dim}or#{@reset}  #{@cyan}osa setup#{@reset}"
      )
    else
      Enum.each(rows, &print_row/1)
      IO.puts("")
      IO.puts("  #{@dim}Sign out with#{@reset}  #{@cyan}osa auth logout <provider>#{@reset}")
      print_store_note()
    end

    IO.puts("")
    :ok
  end

  defp print_row(%{connected?: false} = row) do
    IO.puts("  #{pad(row.provider)}  #{@dim}not connected#{@reset}")
  end

  defp print_row(row) do
    IO.puts("  #{pad(row.provider)}  #{state_label(row)}#{detail_suffix(row)}")
  end

  # The three states are deliberately distinct. "connected, unconfirmed" is
  # not a softer way of saying connected: it is OSA reporting that it holds a
  # record of the user's choice and no evidence behind it, which is exactly
  # the situation Copilot leaves it in and exactly the thing that must not be
  # rendered as a green tick.
  defp state_label(%{expired?: true}), do: "#{@yellow}expired#{@reset}"
  defp state_label(%{verified?: true}), do: "#{@green}connected#{@reset}"

  defp state_label(_),
    do: "#{@green}connected#{@reset} #{@dim}(sign-in unconfirmed)#{@reset}"

  defp detail_suffix(row) do
    parts =
      [row.account, row.plan, expiry_label(row)]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))

    if parts == [], do: "", else: "  #{@dim}#{Enum.join(parts, " · ")}#{@reset}"
  end

  # Only shown when OSA actually holds a token with an expiry. A provider
  # whose credential lives in someone else's CLI has no expiry OSA can know,
  # and inventing one would make the row confidently wrong.
  defp expiry_label(%{expires_at: at}) when is_integer(at) do
    case at - System.system_time(:second) do
      s when s <= 0 -> "expired"
      s when s < 3600 -> "expires in #{div(s, 60)}m"
      s when s < 86_400 -> "expires in #{div(s, 3600)}h"
      s -> "expires in #{div(s, 86_400)}d"
    end
  end

  defp expiry_label(_), do: nil

  defp print_store_note do
    path = SubscriptionStore.path()

    if File.regular?(path) do
      IO.puts("  #{@dim}Stored in #{path} (0600).#{@reset}")
    end
  end

  defp pad(name), do: String.pad_trailing(to_string(name), 16)

  # ── login ───────────────────────────────────────────────────────────────

  @doc "Run a provider's sign-in flow from the terminal."
  @spec login(String.t()) :: :ok | {:error, term()}
  def login(provider) do
    cond do
      not Subscription.supported?(provider) ->
        IO.puts("")
        IO.puts("  #{@yellow}#{provider} does not support account sign-in.#{@reset}")

        IO.puts(
          "  #{@dim}Providers that do:#{@reset} #{Enum.join(Subscription.supported(), ", ")}"
        )

        IO.puts("")
        {:error, :unsupported_provider}

      not Subscription.available?(provider) ->
        # Distinct from "unsupported": the code exists, the build cannot use
        # it. Saying "unsupported" here would send the user looking for a
        # typo in a provider name that is perfectly correct.
        IO.puts("")
        IO.puts("  #{@yellow}#{Subscription.message(:not_configured, provider)}#{@reset}")
        IO.puts("")
        {:error, :not_configured}

      true ->
        do_login(provider)
    end
  end

  defp do_login(provider) do
    # `on_tick` is what makes Ctrl-C and the TUI's Esc reach a device-code
    # poll that would otherwise block for up to fifteen minutes in silence.
    # See `Auth.LoginSession`.
    alias OptimalSystemAgent.Auth.LoginSession

    result =
      LoginSession.with_cancellation(provider, fn ->
        Subscription.login(provider,
          io: &IO.puts/1,
          on_tick: LoginSession.on_tick(provider)
        )
      end)

    case result do
      {:ok, _entry} ->
        IO.puts("")
        :ok

      {:error, reason} ->
        IO.puts("")
        IO.puts("  #{@yellow}#{Subscription.message(reason, provider)}#{@reset}")
        IO.puts("")
        {:error, reason}
    end
  end

  # ── logout ──────────────────────────────────────────────────────────────

  @doc """
  Forget OSA's copy of a provider credential.

  Idempotent, and deliberately loud about what it did *not* do. For the
  bring-your-own-CLI providers OSA never held the credential in the first
  place, so "signed out" would be a lie — the vendor's own CLI is still signed
  in, and the message says so with the command that changes that.
  """
  @spec logout(String.t()) :: :ok | {:error, term()}
  def logout(provider) do
    was_connected? = SubscriptionStore.connected?(provider)

    case Subscription.logout(provider) do
      :ok ->
        IO.puts("")

        if was_connected? do
          IO.puts("  #{@green}✓#{@reset} Signed out of #{provider} in OSA.")
        else
          IO.puts("  #{@dim}#{provider} was not connected. Nothing to do.#{@reset}")
        end

        print_external_note(provider)
        IO.puts("")
        :ok

      {:error, reason} = err ->
        IO.puts("")
        IO.puts("  #{@yellow}Could not sign out of #{provider}: #{inspect(reason)}#{@reset}")
        IO.puts("")
        err
    end
  end

  @doc "Forget every stored account credential."
  @spec logout_all() :: :ok
  def logout_all do
    connected = SubscriptionStore.list() |> Map.keys()

    if connected == [] do
      IO.puts("")
      IO.puts("  #{@dim}No account sign-ins to clear.#{@reset}")
      IO.puts("")
    else
      Enum.each(connected, fn provider ->
        _ = Subscription.logout(provider)
        IO.puts("  #{@green}✓#{@reset} Signed out of #{provider} in OSA.")
        print_external_note(provider)
      end)

      IO.puts("")
    end

    :ok
  end

  defp logout_interactive do
    case SubscriptionStore.list() |> Map.keys() do
      [] ->
        IO.puts("")
        IO.puts("  #{@dim}No account sign-ins to clear.#{@reset}")
        IO.puts("")
        :ok

      [only] ->
        logout(only)

      several ->
        IO.puts("")
        IO.puts("  #{@bold}Connected:#{@reset} #{Enum.join(several, ", ")}")
        IO.puts("")
        IO.puts("  #{@dim}Name one, or use#{@reset} #{@cyan}osa auth logout --all#{@reset}")
        IO.puts("")
        {:error, :ambiguous}
    end
  end

  # The honesty rule from `Auth.Subscription.message/2`, applied to removal:
  # never imply OSA cleared something it did not touch.
  defp print_external_note("claude_cli") do
    IO.puts(
      "  #{@dim}Your Claude Code sign-in is untouched — run `claude auth logout` to clear that too.#{@reset}"
    )
  end

  defp print_external_note("copilot_cli") do
    IO.puts(
      "  #{@dim}Your Copilot CLI sign-in is untouched — run `copilot logout` to clear that too.#{@reset}"
    )
  end

  defp print_external_note(provider) do
    # For a provider whose token OSA genuinely held, the grant may still be
    # listed on the vendor's authorised-applications page. Say so rather than
    # letting the user believe a local delete revoked it.
    if Subscription.supported?(provider) do
      IO.puts(
        "  #{@dim}The local credential is gone. The authorisation may still be listed in your " <>
          "#{provider} account's connected-apps settings.#{@reset}"
      )
    end
  end

  # ── help ────────────────────────────────────────────────────────────────

  defp usage(message) do
    IO.puts("")
    IO.puts("  #{@yellow}#{message}#{@reset}")
    help()
    {:error, :usage}
  end

  defp help do
    IO.puts("")
    IO.puts("  #{@bold}osa auth#{@reset} #{@dim}— account sign-ins#{@reset}")
    IO.puts("")

    IO.puts(
      "    #{@cyan}osa auth status#{@reset}              #{@dim}show every connected account#{@reset}"
    )

    IO.puts("    #{@cyan}osa auth login <provider>#{@reset}    #{@dim}sign in#{@reset}")
    IO.puts("    #{@cyan}osa auth logout <provider>#{@reset}   #{@dim}sign out of OSA#{@reset}")

    IO.puts(
      "    #{@cyan}osa auth logout --all#{@reset}        #{@dim}sign out of everything#{@reset}"
    )

    IO.puts("")
    IO.puts("  #{@dim}Supports:#{@reset} #{Enum.join(Subscription.supported(), ", ")}")
    IO.puts("")
    :ok
  end
end
