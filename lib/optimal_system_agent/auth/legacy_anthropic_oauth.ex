defmodule OptimalSystemAgent.Auth.LegacyAnthropicOAuth do
  @moduledoc """
  Removal shim for the Anthropic subscription sign-in that OSA used to ship.

  OSA previously implemented an OAuth 2.0 + PKCE flow against
  `console.anthropic.com` using **Claude Code's first-party client id**, and sent
  the subscription request fingerprint (`Authorization: Bearer …` plus
  `anthropic-beta: oauth-2025-04-20`). That flow is gone. It was removed because:

    1. **It made the *user* breach their own agreement.** Anthropic's Consumer
       Terms permit automated access only "via an Anthropic API Key"; using
       Claude Free/Pro/Max OAuth tokens in any other product is explicitly not
       permitted. The account at risk was the user's, not OSA's.
    2. **Anthropic blocks it server-side** (since 2026-01-09: *"This credential
       is only authorized for use with Claude Code and cannot be used for other
       API requests"*).
    3. **It no longer functions at all.** The token endpoint OSA pointed at,
       `https://console.anthropic.com/oauth/token`, 301s to
       `https://platform.claude.com/oauth/token`, which returns **404**.

  Anthropic API-key auth (`x-api-key`) is untouched and is the supported path.

  This module exists only to (a) hold the user-facing explanation and (b) delete
  any credential the old flow left on disk. A stale token for a banned, blocked,
  404ing flow has no value and is a bearer credential sitting in the user's home
  directory, so the upgrade **deletes** it rather than leaving it inert.
  """

  require Logger

  @purged_flag :anthropic_oauth_credentials_purged

  @notice "Anthropic sign-in (Claude Pro/Max) has been removed from OSA. " <>
            "Anthropic does not permit subscription credentials in third-party tools, " <>
            "and the endpoint it used no longer exists. Use an Anthropic API key instead: " <>
            "set ANTHROPIC_API_KEY (from console.anthropic.com/settings/keys) or run `osa setup`."

  @doc "The one-line, user-facing explanation. Shown by every former entry point."
  @spec notice() :: String.t()
  def notice, do: @notice

  defp osa_dir, do: System.get_env("OSA_HOME") || Path.join(System.user_home!(), ".osa")

  @doc "Path of the credential file the removed flow wrote (`~/.osa/oauth.json`)."
  @spec credentials_path() :: String.t()
  def credentials_path, do: Path.join(osa_dir(), "oauth.json")

  @doc "True when a credential from the removed flow is still on disk."
  @spec credentials_present?() :: boolean()
  def credentials_present?, do: File.regular?(credentials_path())

  @doc """
  Delete any credential left behind by the removed flow.

  Returns `:purged` when a file was found and deleted, `:absent` otherwise. On
  `:purged` it records a process-independent flag so this run's error messages
  and `osa doctor` can explain *why* Anthropic stopped working for a user who
  was signed in this way, instead of only saying "no API key".

  Never raises — a home directory that cannot be read must not stop boot.
  """
  @spec purge() :: :purged | :absent
  def purge do
    path = credentials_path()

    if File.regular?(path) do
      _ = File.rm(path)
      Application.put_env(:optimal_system_agent, @purged_flag, true)
      Logger.warning("[Auth] Removed stale ~/.osa/oauth.json — #{@notice}")
      :purged
    else
      :absent
    end
  rescue
    _ -> :absent
  end

  @doc "True when `purge/0` deleted a credential during this run."
  @spec purged?() :: boolean()
  def purged?, do: Application.get_env(:optimal_system_agent, @purged_flag, false) == true

  @doc false
  @spec reset_purged_flag() :: :ok
  def reset_purged_flag do
    Application.delete_env(:optimal_system_agent, @purged_flag)
    :ok
  end
end
