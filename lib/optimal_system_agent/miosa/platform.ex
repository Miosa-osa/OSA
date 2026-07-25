defmodule OptimalSystemAgent.MIOSA.Platform do
  @moduledoc """
  MIOSA **platform account** authentication (`api.miosa.ai`).

  The platform credential — `MIOSA_PLATFORM_API_KEY`, an `msk_u_…` key — gates
  the MIOSA CLI, the persistent cloud sandboxes, and OpenComputers. It is kept
  **strictly distinct** from the inference `MIOSA_API_KEY` (`optimal.miosa.ai`,
  LLM completions) configured during onboarding; the two are never interchanged.

  ## Resolution order

  `platform_api_key/0` returns the first of:

    1. `MIOSA_PLATFORM_API_KEY` environment variable
    2. `api_key` in the MIOSA CLI's own config, `~/.miosa/config.json`

  This mirrors how the `:miosa` sandbox backend resolves its Bearer token, so
  logging in once with `miosa login` (which writes `~/.miosa/config.json`)
  transparently authenticates OSA's platform integrations too.
  """

  require Logger

  @env_var "MIOSA_PLATFORM_API_KEY"
  @config_file "config.json"

  @doc "Name of the platform-auth environment variable."
  @spec env_var() :: String.t()
  def env_var, do: @env_var

  @doc "Absolute path to the MIOSA CLI config file (`~/.miosa/config.json`)."
  @spec config_path() :: String.t()
  def config_path, do: Path.join(config_dir(), @config_file)

  @doc """
  The resolved platform API key, or `nil` if none is configured.

  Checks `MIOSA_PLATFORM_API_KEY` first, then the `api_key` field of
  `~/.miosa/config.json`.
  """
  @spec platform_api_key() :: String.t() | nil
  def platform_api_key do
    case System.get_env(@env_var) do
      key when is_binary(key) and key != "" -> key
      _ -> config_api_key()
    end
  end

  @doc """
  Is a platform account credential available (env var **or** CLI config)?
  """
  @spec auth_configured?() :: boolean()
  def auth_configured?, do: platform_api_key() != nil

  @doc """
  Read the `api_key` persisted by the CLI in `~/.miosa/config.json`.

  Returns `nil` when the file is absent, unreadable, malformed, or has no
  non-empty `api_key`.
  """
  @spec config_api_key() :: String.t() | nil
  def config_api_key do
    with %{"api_key" => key} when is_binary(key) and key != "" <- config() do
      key
    else
      _ -> nil
    end
  end

  @doc """
  Read the MIOSA CLI configuration as a map.

  The CLI owns platform account, tenant, workspace, and endpoint selection.
  OSA reads that same file so platform integrations cannot silently act in a
  different context from the user's active CLI context.
  """
  @spec config() :: map()
  def config do
    with {:ok, raw} <- File.read(config_path()),
         {:ok, config} when is_map(config) <- Jason.decode(raw) do
      config
    else
      _ -> %{}
    end
  end

  @doc "The workspace selected by the MIOSA CLI, if one is active."
  @spec workspace_id() :: String.t() | nil
  def workspace_id do
    case config()["workspace"] do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  @doc "The MIOSA platform endpoint selected by the CLI."
  @spec endpoint() :: String.t()
  def endpoint do
    case config()["endpoint"] do
      value when is_binary(value) and value != "" -> String.trim_trailing(value, "/")
      _ -> "https://api.miosa.ai"
    end
  end

  @doc """
  Persist `key` as the platform credential into `~/.miosa/config.json`,
  merging into any existing config (so other CLI settings are preserved).

  The file is written with `0600` permissions. This is the "point OSA at a
  key" helper — it makes a key supplied out-of-band (or the current env var)
  durable for the CLI and every platform integration.

  Returns `{:ok, path}` or `{:error, reason}`.
  """
  @spec persist_api_key(String.t()) :: {:ok, String.t()} | {:error, term()}
  def persist_api_key(key) when is_binary(key) and key != "" do
    path = config_path()

    existing =
      case File.read(path) do
        {:ok, raw} ->
          case Jason.decode(raw) do
            {:ok, map} when is_map(map) -> map
            _ -> %{}
          end

        _ ->
          %{}
      end

    merged = Map.put(existing, "api_key", key)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- Jason.encode(merged, pretty: true),
         :ok <- File.write(path, json) do
      _ = File.chmod(path, 0o600)
      {:ok, path}
    end
  end

  def persist_api_key(_), do: {:error, :invalid_key}

  # ── Private ──────────────────────────────────────────────────────

  # The MIOSA CLI's config directory. Overridable via app env for tests.
  defp config_dir do
    Application.get_env(:optimal_system_agent, :miosa_cli_config_dir, "~/.miosa")
    |> Path.expand()
  end
end
