defmodule OptimalSystemAgent.MCP.Client.Manager do
  @moduledoc """
  Owns the MCP client lifecycle and the aggregate MCP tool registry.

  Reads `~/.osa/mcp.json` via `MCP.Config`, starts one `ServerSession` per
  enabled server under `OptimalSystemAgent.MCP.Supervisor`, aggregates every
  server's discovered tools into a single `mcp_tools` map, and publishes that
  map into `:persistent_term` under the key
  `{OptimalSystemAgent.Tools.Registry, :mcp_tools}` — the exact key
  `Tools.Registry` reads for lock-free tool lookup.

  Server initialization is asynchronous: this GenServer never blocks boot on a
  slow server. Tool discovery arrives later via `report_tools/2` (called by each
  `ServerSession`) and triggers a republish of the aggregate map.

  This IS the `MCP.Manager` referenced by the SDK.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.MCP.Config
  alias OptimalSystemAgent.MCP.Client.{ServerSession, ToolBridge}

  @supervisor OptimalSystemAgent.MCP.Supervisor
  @pt_key {OptimalSystemAgent.Tools.Registry, :mcp_tools}

  defstruct servers: %{}, tools_by_server: %{}

  # ── Public API ────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "List configured servers with their live status."
  @spec list_servers() :: [map()]
  def list_servers do
    GenServer.call(__MODULE__, :list_servers)
  catch
    :exit, _ -> []
  end

  @doc "List all aggregated MCP tools (from :persistent_term)."
  @spec list_tools() :: [map()]
  def list_tools do
    mcp_tools()
    |> Enum.map(fn {name, info} ->
      %{
        name: name,
        server: info.server,
        original_name: info.original_name,
        description: info.description
      }
    end)
  end

  @doc "Reload the MCP config from disk and reconcile running sessions."
  @spec reload() :: :ok
  def reload do
    GenServer.call(__MODULE__, :reload)
  catch
    :exit, _ -> :ok
  end

  @doc "Enable a server by name (starts it if not running)."
  @spec enable_server(String.t()) :: :ok | {:error, term()}
  def enable_server(name) do
    GenServer.call(__MODULE__, {:enable_server, name})
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "Disable a server by name (stops its session)."
  @spec disable_server(String.t()) :: :ok | {:error, term()}
  def disable_server(name) do
    GenServer.call(__MODULE__, {:disable_server, name})
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "Called by a ServerSession once its tools/list result is in."
  @spec report_tools(String.t(), [map()]) :: :ok
  def report_tools(name, tools) do
    GenServer.cast(__MODULE__, {:report_tools, name, tools})
  end

  @doc "Read the current aggregated `mcp_tools` map from :persistent_term."
  @spec mcp_tools() :: %{String.t() => map()}
  def mcp_tools do
    :persistent_term.get(@pt_key, %{})
  end

  # ── GenServer ─────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # Ensure the persistent_term key exists even before any server reports.
    :persistent_term.put(@pt_key, %{})
    {:ok, %__MODULE__{}, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state) do
    {:noreply, load_and_start(state)}
  end

  @impl true
  def handle_call(:list_servers, _from, state) do
    result =
      Enum.map(state.servers, fn {name, server} ->
        %{
          name: name,
          transport: server.transport,
          enabled: server.enabled,
          status: server_status(server),
          tool_count: state.tools_by_server |> Map.get(name, []) |> length()
        }
      end)

    {:reply, result, state}
  end

  def handle_call(:reload, _from, state) do
    {:reply, :ok, load_and_start(state)}
  end

  def handle_call({:enable_server, name}, _from, state) do
    case Map.get(state.servers, name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      server ->
        server = %{server | enabled: true}
        _ = start_session(server)
        {:reply, :ok, %{state | servers: Map.put(state.servers, name, server)}}
    end
  end

  def handle_call({:disable_server, name}, _from, state) do
    case Map.get(state.servers, name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      server ->
        stop_session(name)
        server = %{server | enabled: false}

        state = %{
          state
          | servers: Map.put(state.servers, name, server),
            tools_by_server: Map.delete(state.tools_by_server, name)
        }

        republish(state)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast({:report_tools, name, tools}, state) do
    state = %{state | tools_by_server: Map.put(state.tools_by_server, name, tools)}
    republish(state)
    {:noreply, state}
  end

  # ── Internal ──────────────────────────────────────────────────────────

  defp load_and_start(state) do
    servers = Config.load_startup()
    servers_map = Map.new(servers, fn s -> {s.name, s} end)

    # Stop sessions for servers that vanished from config.
    removed = Map.keys(state.servers) -- Map.keys(servers_map)
    Enum.each(removed, &stop_session/1)

    # (Re)start enabled servers that aren't already running.
    Enum.each(servers, fn server ->
      cond do
        not server.enabled -> stop_session(server.name)
        ServerSession.alive?(server.name) -> :ok
        true -> start_session(server)
      end
    end)

    tools_by_server = Map.take(state.tools_by_server, Map.keys(servers_map))
    new_state = %{state | servers: servers_map, tools_by_server: tools_by_server}
    republish(new_state)
    new_state
  end

  defp start_session(server) do
    case DynamicSupervisor.start_child(@supervisor, ServerSession.child_spec(server)) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} = err ->
        Logger.warning("[MCP.Manager] Failed to start session #{server.name}: #{inspect(reason)}")
        err
    end
  end

  defp stop_session(name) do
    case Registry.lookup(OptimalSystemAgent.MCP.Registry, name) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(@supervisor, pid)
      _ -> :ok
    end
  end

  # Rebuild the aggregate mcp_tools map and publish to :persistent_term.
  defp republish(state) do
    aggregate =
      Enum.reduce(state.tools_by_server, %{}, fn {name, schemas}, acc ->
        Map.merge(acc, ToolBridge.build_tools(name, schemas))
      end)

    :persistent_term.put(@pt_key, aggregate)
    :ok
  end

  defp server_status(%{enabled: false}), do: :disabled

  defp server_status(server) do
    if ServerSession.alive?(server.name) do
      ServerSession.status(server.name)
    else
      :down
    end
  end
end
