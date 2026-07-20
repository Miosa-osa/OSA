defmodule OptimalSystemAgent.Remote.Auth do
  @moduledoc """
  Resolves the MIOSA **account credential** used by the OSA remote CLIENT to
  authenticate to the control-plane client endpoint
  (`wss://api.miosa.ai/api/v1/opencomputers/clients/ws`).

  ## Reuses an existing credential path

  OSA already has a platform-account credential resolver,
  `OptimalSystemAgent.MIOSA.Platform`, which reads the `msk_u_*` platform key
  from `MIOSA_PLATFORM_API_KEY` or `~/.miosa/config.json` (written by
  `miosa login`). That is the SAME account that owns OpenComputers hosts, so the
  remote client reuses it rather than inventing a new login flow. There is no
  new OAuth server flow here.

  ## Resolution order

  `token/0` returns the first credential it finds:

    1. `OSA_REMOTE_TOKEN` environment variable — an explicit per-invocation
       override, handy for scripts, CI, or pointing at a non-default account
       without touching `~/.miosa/config.json`.
    2. `MIOSA.Platform.platform_api_key/0` — the shared platform account
       credential (`MIOSA_PLATFORM_API_KEY` env, then `~/.miosa/config.json`).

  When neither is present, `require_token/0` returns a friendly, actionable
  message instead of raising.
  """

  alias OptimalSystemAgent.MIOSA.Platform

  @env_override "OSA_REMOTE_TOKEN"

  @doc "Name of the per-invocation override environment variable."
  @spec env_override() :: String.t()
  def env_override, do: @env_override

  @doc """
  The resolved MIOSA account credential, or `nil` when none is configured.
  """
  @spec token() :: String.t() | nil
  def token do
    case System.get_env(@env_override) do
      key when is_binary(key) and key != "" -> key
      _ -> Platform.platform_api_key()
    end
  end

  @doc "Is any account credential available?"
  @spec configured?() :: boolean()
  def configured?, do: token() != nil

  @doc """
  Resolve the credential or return a friendly, actionable error string.

  Returns `{:ok, token}` or `{:error, message}`.
  """
  @spec require_token() :: {:ok, String.t()} | {:error, String.t()}
  def require_token do
    case token() do
      key when is_binary(key) and key != "" ->
        {:ok, key}

      _ ->
        {:error,
         "No MIOSA account credential found. Link your account with `miosa login` " <>
           "(writes #{Platform.config_path()}), or set #{Platform.env_var()}, " <>
           "or set #{@env_override} for this invocation."}
    end
  end
end
