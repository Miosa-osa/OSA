defmodule OptimalSystemAgent.MCP.ServerSupervisor do
  @moduledoc """
  Supervises MCP client processes for a single MCP server.

  Started as a child of the application's `MCP.Supervisor` DynamicSupervisor.
  Each server gets its own supervisor managing:
  - MCP.Client GenServer (handshake, tool discovery, request routing)

  The MCP.Connection is started by the Client as needed (via DynamicSupervisor)
  to allow reconnection without restarting the Client state.

  ## Boot Sequence

  On application start, `boot/0` is called to read ~/.osa/mcp.json and start
  a ServerSupervisor for each configured server with `autoConnect: true`.
  """
  use Supervisor

  require Logger

  alias OptimalSystemAgent.MCP.Client

  @doc "Start the supervisor for a single MCP server."
  def start_link(opts) do
    server_name = Keyword.fetch!(opts, :server_name)
    Supervisor.start_link(__MODULE__, opts, name: via(server_name))
  end

  @doc """
  Boot all configured MCP servers.

  Reads ~/.osa/mcp.json, starts a ServerSupervisor for each server
  under the application's MCP.Supervisor DynamicSupervisor.

  Called from Channels.Starter or similar deferred-start process
  after the supervision tree is fully up.
  """
  @spec boot() :: :ok
  def boot do
    servers = Client.load_servers()

    Enum.each(servers, fn {name, config} ->
      start_server(name, config)
    end)

    Logger.info("[MCP.ServerSupervisor] Booted #{map_size(servers)} MCP server(s)")
    :ok
  end

  @doc "Start a single MCP server supervisor under the DynamicSupervisor."
  @spec start_server(String.t(), map()) :: {:ok, pid()} | {:error, term()}
  def start_server(name, config) do
    url = config["url"]
    api_key = config["apiKey"]
    auto_connect = Map.get(config, "autoConnect", false)

    if url do
      opts = [
        server_name: name,
        url: url,
        api_key: api_key,
        auto_connect: auto_connect
      ]

      case DynamicSupervisor.start_child(
             OptimalSystemAgent.MCP.Supervisor,
             {__MODULE__, opts}
           ) do
        {:ok, pid} ->
          Logger.info("[MCP.ServerSupervisor] Started MCP server '#{name}' (#{url})")
          {:ok, pid}

        {:error, {:already_started, pid}} ->
          Logger.debug("[MCP.ServerSupervisor] MCP server '#{name}' already running")
          {:ok, pid}

        {:error, reason} = error ->
          Logger.error("[MCP.ServerSupervisor] Failed to start '#{name}': #{inspect(reason)}")
          error
      end
    else
      Logger.warning("[MCP.ServerSupervisor] No URL configured for MCP server '#{name}'")
      {:error, :no_url}
    end
  end

  @doc "Stop a running MCP server by name."
  @spec stop_server(String.t()) :: :ok | {:error, :not_found}
  def stop_server(name) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, {:mcp_server_sup, name}) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(OptimalSystemAgent.MCP.Supervisor, pid)
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @doc "List all running MCP server names."
  @spec list_servers() :: list(String.t())
  def list_servers do
    # Pattern match all registered MCP server supervisors
    Registry.select(OptimalSystemAgent.SessionRegistry, [
      {{{:mcp_server_sup, :"$1"}, :_, :_}, [], [:"$1"]}
    ])
  end

  # --- Supervisor Callbacks ---

  @impl true
  def init(opts) do
    server_name = Keyword.fetch!(opts, :server_name)
    url = Keyword.fetch!(opts, :url)
    api_key = Keyword.get(opts, :api_key)
    auto_connect = Keyword.get(opts, :auto_connect, false)

    children = [
      {Client,
       server_name: server_name,
       url: url,
       api_key: api_key,
       auto_connect: auto_connect}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp via(name) do
    {:via, Registry, {OptimalSystemAgent.SessionRegistry, {:mcp_server_sup, name}}}
  end
end
