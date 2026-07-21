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

  alias OptimalSystemAgent.MCP.{Config, ProjectApproval, Virtualization}
  alias OptimalSystemAgent.MCP.Client.{ServerSession, ToolBridge}

  @supervisor OptimalSystemAgent.MCP.Supervisor
  @pt_key {OptimalSystemAgent.Tools.Registry, :mcp_tools}

  # How long after boot to snapshot the connect wave for the single calm summary
  # line. Long enough for most servers to either finish their handshake or start
  # failing (npx spawn + handshake), short enough to be reassuring. Overridable
  # in tests / by operators via `:mcp_boot_summary_ms`.
  @boot_summary_ms 5_000

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
    state = load_and_start(state)
    # Sessions connect asynchronously; snapshot the outcome once after the connect
    # wave has had time to settle and emit ONE calm summary line instead of the
    # per-server warnings (now debug).
    Process.send_after(self(), :boot_summary, boot_summary_ms())
    {:noreply, state}
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
          source: Map.get(server, :source, :osa),
          tool_count: state.tools_by_server |> Map.get(name, []) |> length()
        }
      end)

    {:reply, result, state}
  end

  def handle_call(:reload, _from, state) do
    {:reply, :ok, load_and_start(state)}
  end

  def handle_call({:enable_server, name}, _from, state) do
    # Resolve from live state first; fall back to on-disk config so a
    # project-scope server that boot deliberately withheld (unapproved) is
    # still visible here and can be explicitly REFUSED rather than silently
    # "not found" — closing the approval-bypass path.
    server = Map.get(state.servers, name) || find_config_server(name)

    cond do
      is_nil(server) ->
        {:reply, {:error, :not_found}, state}

      not enable_authorized?(server) ->
        {:reply, {:error, :requires_approval}, state}

      true ->
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

  # Post-boot reconcile: count how many ENABLED servers actually reached `:ready`
  # versus how many are still unavailable (connecting/failed/dormant/down) and
  # log a single calm summary line. The per-server detail lives at debug (and in
  # `MCP list_servers` / `osa doctor`), so nothing actionable is lost.
  @impl true
  def handle_info(:boot_summary, state) do
    statuses =
      state.servers
      |> Map.values()
      |> Enum.filter(& &1.enabled)
      |> Enum.map(&{&1.name, server_status(&1)})

    case statuses do
      [] ->
        :ok

      _ ->
        Logger.info(boot_summary_line(statuses))

        unavailable = for {name, s} <- statuses, s != :ready, do: name

        if unavailable != [] do
          Logger.debug("[MCP] unavailable servers: #{Enum.join(unavailable, ", ")}")
        end
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

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

  # Whether a server may be started via the enable path. Project-scope servers
  # (repo-committed `.mcp.json`) require operator approval, mirroring the
  # boot-time gate in `Config.load_startup/0`; user/local scopes are trusted.
  # Public + @doc false so the gate decision is unit-testable in isolation.
  @doc false
  @spec enable_authorized?(Config.Server.t() | map()) :: boolean()
  def enable_authorized?(%{scope: :project} = server),
    do: ProjectApproval.approved?(server.name)

  def enable_authorized?(_server), do: true

  # Find a configured server by (sanitized) name across all scopes, including
  # project servers that boot filtered out for lack of approval.
  defp find_config_server(name) do
    Config.load_all() |> Enum.find(fn s -> s.name == name end)
  end

  defp start_session(server) do
    case DynamicSupervisor.start_child(@supervisor, ServerSession.child_spec(server)) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} = err ->
        # Expected for an optional/misconfigured server; debug, not warning. The
        # boot summary reports the aggregate connected/unavailable count instead.
        Logger.debug("[MCP.Manager] Failed to start session #{server.name}: #{inspect(reason)}")
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
  # Each server's configured `tool_filter` allowlist is enforced here, so a
  # server that discovers more tools than it is permitted to expose is trimmed
  # to its allowlist before any tool reaches the agent.
  #
  # Tool virtualization (steal-list 11g): after aggregating every server's
  # tools, `Virtualization.apply_decision/1` stamps a uniform `:should_defer?`
  # based on the TOTAL count. Above the configured threshold the whole MCP
  # toolset is deferred (discovered via `tool_search`, invoked via `use_tool`);
  # at/below it the tools inject directly, keeping small-toolset prompts
  # unchanged.
  defp republish(state) do
    aggregate =
      Enum.reduce(state.tools_by_server, %{}, fn {name, schemas}, acc ->
        tool_filter = state.servers |> Map.get(name) |> server_tool_filter()
        Map.merge(acc, ToolBridge.build_tools(name, schemas, tool_filter))
      end)
      |> Virtualization.apply_decision()

    :persistent_term.put(@pt_key, aggregate)
    :ok
  end

  defp server_tool_filter(%{tool_filter: tool_filter}), do: tool_filter
  defp server_tool_filter(_), do: nil

  defp server_status(%{enabled: false}), do: :disabled

  defp server_status(server) do
    if ServerSession.alive?(server.name) do
      ServerSession.status(server.name)
    else
      :down
    end
  end

  # Build the single calm boot-summary line from `[{name, status}]`. A server is
  # "connected" iff its status is `:ready`; everything else counts as unavailable.
  # Pure and public (@doc false) so it is unit-testable without booting the app.
  #
  #   0/2  → "[MCP] connected 0 of 2 servers (2 unavailable, run 'osa doctor' for details)"
  #   2/2  → "[MCP] connected 2 of 2 servers"
  @doc false
  @spec boot_summary_line([{String.t(), atom()}]) :: String.t()
  def boot_summary_line(statuses) do
    total = length(statuses)
    ready = Enum.count(statuses, fn {_name, status} -> status == :ready end)
    unavailable = total - ready

    note =
      if unavailable > 0 do
        " (#{unavailable} unavailable, run 'osa doctor' for details)"
      else
        ""
      end

    "[MCP] connected #{ready} of #{total} servers" <> note
  end

  defp boot_summary_ms do
    Application.get_env(:optimal_system_agent, :mcp_boot_summary_ms, @boot_summary_ms)
  end
end
