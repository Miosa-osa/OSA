defmodule OptimalSystemAgent.OpenComputers.Config do
  @moduledoc """
  Loads and caches OpenComputers configuration.

  Primary source: `~/.osa/open_computers.toml` (or `$OSA_OPEN_COMPUTERS_CONFIG`).
  Env vars override individual fields — matches how the rest of OSA handles
  provider-specific config.

  ## TOML schema

      control_url      = "wss://api.miosa.ai/api/v1/opencomputers/hosts/ws"
      host_key         = "oc_host_..."
      fingerprint_path = "~/.osa/open_computers.ed25519"
      modes            = ["direct"]
      heartbeat_ms     = 30000

  ## Env var overrides

      OSA_OPEN_COMPUTERS_CONTROL_URL
      OSA_OPEN_COMPUTERS_HOST_KEY
      OSA_OPEN_COMPUTERS_FINGERPRINT_PATH
  """

  use GenServer
  require Logger

  @default_path "~/.osa/open_computers.toml"
  @default_heartbeat_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get the current cached config."
  def get, do: GenServer.call(__MODULE__, :get)

  @doc "Reload config from disk."
  def reload, do: GenServer.call(__MODULE__, :reload)

  # ── GenServer ──

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, env_or(@default_path, "OSA_OPEN_COMPUTERS_CONFIG"))
    cfg = load(path)
    Logger.info("[OpenComputers.Config] loaded from #{path} (modes=#{inspect(cfg.modes)})")
    {:ok, %{path: path, cfg: cfg}}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state.cfg, state}

  def handle_call(:reload, _from, state) do
    cfg = load(state.path)
    {:reply, cfg, %{state | cfg: cfg}}
  end

  # ── Loader ──

  defp load(path) do
    full_path = Path.expand(path)

    base =
      case File.read(full_path) do
        {:ok, body} ->
          parse_simple(body)

        {:error, :enoent} ->
          Logger.warning("[OpenComputers.Config] #{full_path} not found — using defaults + env")
          %{}

        {:error, reason} ->
          Logger.warning("[OpenComputers.Config] cannot read #{full_path}: #{inspect(reason)}")
          %{}
      end

    %{
      control_url:
        env_or(
          base[:control_url] || "wss://api.miosa.ai/api/v1/opencomputers/hosts/ws",
          "OSA_OPEN_COMPUTERS_CONTROL_URL"
        ),
      host_key: env_or(base[:host_key], "OSA_OPEN_COMPUTERS_HOST_KEY"),
      fingerprint_path:
        env_or(
          base[:fingerprint_path] || "~/.osa/open_computers.ed25519",
          "OSA_OPEN_COMPUTERS_FINGERPRINT_PATH"
        ),
      modes: base[:modes] || ["direct"],
      heartbeat_ms: base[:heartbeat_ms] || @default_heartbeat_ms,
      log_level: base[:log_level] || "info"
    }
  end

  defp env_or(default, env_key) do
    case System.get_env(env_key) do
      nil -> default
      "" -> default
      v -> v
    end
  end

  # Minimal TOML — simple key=value + arrays. Swap in :toml dep later.
  defp parse_simple(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      line = String.trim(line)

      cond do
        line == "" or String.starts_with?(line, "#") ->
          acc

        String.contains?(line, "=") ->
          [k, v] = String.split(line, "=", parts: 2)
          key = k |> String.trim() |> String.to_atom()
          Map.put(acc, key, parse_value(String.trim(v)))

        true ->
          acc
      end
    end)
  end

  defp parse_value("\"" <> rest), do: String.trim_trailing(rest, "\"")

  defp parse_value("[" <> rest) do
    rest
    |> String.trim_trailing("]")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&parse_value/1)
  end

  defp parse_value(other) do
    case Integer.parse(other) do
      {n, ""} -> n
      _ -> other
    end
  end
end
