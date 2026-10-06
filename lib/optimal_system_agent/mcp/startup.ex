defmodule OptimalSystemAgent.MCP.Startup do
  @moduledoc """
  MCP server auto-discovery and connection at boot.

  Reads ~/.osa/mcp.json, connects to configured MCP servers,
  and registers their tools with the Tools.Registry.

  Called by Channels.Starter during deferred boot.
  """
  require Logger

  @doc """
  Start all MCP servers marked with `autoConnect: true` in mcp.json.

  Falls back to app-config SORX connection if mcp.json is missing or
  does not include a SORX entry. Errors are logged as warnings — a
  missing MCP server must never crash the boot sequence.
  """
  @spec start_configured_servers() :: :ok
  def start_configured_servers do
    servers = OptimalSystemAgent.MCP.Client.load_servers()

    if map_size(servers) == 0 do
      Logger.info("[MCP.Startup] No MCP servers configured in mcp.json — trying app-config SORX fallback")
      connect_sorx()
    else
      started =
        servers
        |> Enum.filter(fn {_name, config} -> Map.get(config, "autoConnect", false) end)
        |> Enum.map(fn {name, config} -> start_server(name, config) end)
        |> Enum.count(fn result -> result == :ok end)

      Logger.info("[MCP.Startup] Started #{started}/#{map_size(servers)} configured MCP servers")

      # If SORX wasn't in mcp.json, try the app-config fallback
      unless Map.has_key?(servers, "sorx") do
        connect_sorx()
      end
    end

    :ok
  end

  @doc """
  Connect specifically to the SORX execution engine using app config.

  Uses `sorx_mcp_endpoint` and `sorx_api_key` from the :optimal_system_agent
  application config. This is the fallback path when SORX is not listed in
  mcp.json.
  """
  @spec connect_sorx() :: :ok | {:error, term()}
  def connect_sorx do
    endpoint = Application.get_env(:optimal_system_agent, :sorx_mcp_endpoint)
    api_key = Application.get_env(:optimal_system_agent, :sorx_api_key)

    if endpoint do
      config = %{
        "url" => endpoint,
        "apiKey" => api_key || "",
        "autoConnect" => true,
        "description" => "SORX execution engine (app-config fallback)"
      }

      start_server("sorx", config)
    else
      Logger.debug("[MCP.Startup] No SORX endpoint configured — skipping")
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp start_server(name, %{"url" => url} = config) do
    api_key = Map.get(config, "apiKey", "")

    child_spec = %{
      id: {:mcp_client, name},
      start: {__MODULE__, :connect_sse, [name, url, api_key]},
      restart: :transient
    }

    case DynamicSupervisor.start_child(OptimalSystemAgent.MCP.Supervisor, child_spec) do
      {:ok, _pid} ->
        Logger.info("[MCP.Startup] Connected to MCP server '#{name}' at #{url}")
        :ok

      {:error, {:already_started, _pid}} ->
        Logger.debug("[MCP.Startup] MCP server '#{name}' already running")
        :ok

      {:error, reason} ->
        Logger.warning("[MCP.Startup] Failed to connect to MCP server '#{name}': #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp start_server(name, config) do
    Logger.warning("[MCP.Startup] MCP server '#{name}' has no url — skipping (config: #{inspect(config)})")
    {:error, :no_url}
  end

  @doc false
  def connect_sse(name, url, api_key) do
    # Spawn a lightweight process that holds the connection metadata.
    # Actual SSE streaming will be added when the MCP.Client gains
    # full SSE transport support; for now we register the server so
    # tools can be discovered via polling or manual reload.
    Task.start_link(fn ->
      Process.flag(:trap_exit, true)
      Logger.info("[MCP.Startup] SSE client '#{name}' registered (url=#{url}, auth=#{if api_key != "", do: "yes", else: "none"})")

      receive do
        {:EXIT, _from, reason} ->
          Logger.info("[MCP.Startup] SSE client '#{name}' shutting down: #{inspect(reason)}")
      end
    end)
  end
end
