defmodule OptimalSystemAgent.MIOSA.MCP do
  @moduledoc """
  Register the MIOSA CLI as an MCP server in OSA's MCP config
  (`~/.osa/mcp.json`) so OSA's MCP client auto-discovers MIOSA's commands as
  `mcp__miosa__*` tools.

  The MIOSA CLI speaks MCP over stdio via `miosa mcp serve`, exposing each of
  its platform commands as an MCP tool. We register it with:

  ```json
  {"mcpServers": {"miosa": {"command": "miosa", "args": ["mcp", "serve"]}}}
  ```

  Registration is **gated**: we only write the entry when the CLI is actually
  installed (`MIOSA.CLI.installed?/0`) *and* the platform account is
  authenticated (`MIOSA.CLI.auth_configured?/0`). Writing the entry otherwise
  would spawn a subprocess that immediately fails.

  The write is a **merge**, never a clobber: any other `mcpServers` entries and
  top-level keys in `mcp.json` are preserved. If a `miosa` entry already exists
  it is refreshed idempotently.
  """

  require Logger

  alias OptimalSystemAgent.MCP.Config, as: MCPConfig
  alias OptimalSystemAgent.MIOSA.CLI

  @server_name "miosa"
  @server_spec %{"command" => "miosa", "args" => ["mcp", "serve"]}

  @doc "The canonical `mcpServers` entry for the MIOSA CLI."
  @spec server_spec() :: map()
  def server_spec, do: @server_spec

  @doc """
  Ensure the MIOSA MCP server is registered in `~/.osa/mcp.json`, but only when
  the CLI is installed and authenticated.

  Returns:

    * `{:ok, :registered}`   — entry written or refreshed
    * `{:ok, :already}`      — entry already present and identical
    * `{:ok, :skipped, why}` — gate not met (`:not_installed` | `:not_authenticated`)
    * `{:error, reason}`     — read/parse/write failure
  """
  @spec ensure_registered() ::
          {:ok, :registered | :already} | {:ok, :skipped, atom()} | {:error, term()}
  def ensure_registered do
    cond do
      not CLI.installed?() -> {:ok, :skipped, :not_installed}
      not CLI.auth_configured?() -> {:ok, :skipped, :not_authenticated}
      true -> do_register()
    end
  end

  @doc "Is the MIOSA entry currently present in `mcp.json`?"
  @spec registered?() :: boolean()
  def registered? do
    case read_config() do
      {:ok, config} -> match?(%{"mcpServers" => %{@server_name => _}}, config)
      _ -> false
    end
  end

  # ── Private ──────────────────────────────────────────────────────

  defp do_register do
    with {:ok, config} <- read_config() do
      servers = Map.get(config, "mcpServers", %{})

      if Map.get(servers, @server_name) == @server_spec do
        {:ok, :already}
      else
        merged =
          config
          |> Map.put("mcpServers", Map.put(servers, @server_name, @server_spec))

        write_config(merged)
      end
    end
  end

  # Read + decode mcp.json. A missing file is an empty config (MCP is opt-in),
  # matching MCP.Config.load/1 semantics.
  defp read_config do
    case File.read(config_path()) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, map} when is_map(map) -> {:ok, map}
          {:ok, _} -> {:error, :not_an_object}
          {:error, reason} -> {:error, {:invalid_json, reason}}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  defp write_config(config) do
    path = config_path()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- Jason.encode(config, pretty: true),
         :ok <- File.write(path, json) do
      {:ok, :registered}
    end
  end

  defp config_path, do: MCPConfig.config_path()
end
