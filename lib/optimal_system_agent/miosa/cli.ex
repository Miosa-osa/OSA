defmodule OptimalSystemAgent.MIOSA.CLI do
  @moduledoc """
  Thin wrapper around the **MIOSA CLI** (`miosa`, published as the npm package
  `@miosa/cli`).

  OSA does **not** bundle or auto-install the CLI. This module only *detects*
  the CLI, reports its version, and *surfaces* the official install / login
  commands for the user to run themselves. We never shell out to a network
  installer (that would also trip OSA's dangerous-command guard).

  ## Two distinct credentials

  MIOSA involves two separate keys that must never be conflated:

    * `MIOSA_API_KEY` — **inference** (LLM completions at `optimal.miosa.ai`),
      configured during onboarding. *Not* used here.
    * `MIOSA_PLATFORM_API_KEY` — **platform account** (`api.miosa.ai`, sandboxes,
      OpenComputers, and the `miosa` CLI itself). This is the credential this
      module and `OptimalSystemAgent.MIOSA.Platform` care about.

  See `OptimalSystemAgent.MIOSA.Platform` for reading/persisting platform auth
  and `OptimalSystemAgent.MIOSA.MCP` for registering the CLI as an MCP server.
  """

  alias OptimalSystemAgent.MIOSA.Platform

  @binary "miosa"
  @npm_install "npm install -g @miosa/cli"
  @curl_install "curl https://miosa.ai/install.sh | sh"
  @login_command "miosa login"

  @doc """
  Is the `miosa` binary available on `PATH`?

  Returns `true` when `System.find_executable/1` resolves it.
  """
  @spec installed?() :: boolean()
  def installed?, do: executable_path() != nil

  @doc "Absolute path to the `miosa` binary, or `nil` if not on `PATH`."
  @spec executable_path() :: String.t() | nil
  def executable_path, do: System.find_executable(@binary)

  @doc """
  Installed CLI version string (e.g. `"1.4.2"`), or `nil` if the CLI is
  missing or does not respond to `--version`.
  """
  @spec version() :: String.t() | nil
  def version do
    with path when is_binary(path) <- executable_path() do
      case System.cmd(path, ["--version"], stderr_to_stdout: true) do
        {out, 0} -> out |> String.trim() |> take_version()
        _ -> nil
      end
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  The official install command string for the user to run (we do **not** run
  it). Defaults to the npm form; pass `:curl` for the shell-installer form.
  """
  @spec install_command(:npm | :curl) :: String.t()
  def install_command(method \\ :npm)
  def install_command(:curl), do: @curl_install
  def install_command(_), do: @npm_install

  @doc """
  Is the MIOSA **platform** account authenticated for the CLI?

  True when `MIOSA_PLATFORM_API_KEY` is set *or* the CLI has persisted an
  `api_key` in `~/.miosa/config.json`. Delegates to
  `OptimalSystemAgent.MIOSA.Platform.auth_configured?/0`.
  """
  @spec auth_configured?() :: boolean()
  def auth_configured?, do: Platform.auth_configured?()

  @doc "The command the user runs to authenticate the CLI (`miosa login`)."
  @spec login_command() :: String.t()
  def login_command, do: @login_command

  # ── Private ──────────────────────────────────────────────────────

  # `miosa --version` may print "miosa 1.4.2" or just "1.4.2"; keep the last
  # whitespace-delimited token that looks like a version.
  defp take_version(""), do: nil

  defp take_version(out) do
    out
    |> String.split()
    |> Enum.reverse()
    |> Enum.find(out, fn tok -> String.match?(tok, ~r/\d/) end)
  end
end
