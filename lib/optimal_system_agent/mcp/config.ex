defmodule OptimalSystemAgent.MCP.Config do
  @moduledoc """
  Parse `~/.osa/mcp.json` into a list of `%Server{}` structs.

  The file is Claude-Desktop-compatible: a top-level `mcpServers` object
  whose keys are server names and whose values describe how to reach each
  server. Presence of a `url` selects the `:http_sse` transport; otherwise
  a local `:stdio` subprocess (`command` + `args` + `env`) is used.

  Server names are sanitized to `[a-z0-9_]` so they compose cleanly into the
  `mcp__<server>__<tool>` tool-name convention.

  This module performs pure parsing only — no processes are started here.
  """

  require Logger

  defmodule Server do
    @moduledoc "A single configured MCP server."

    @type transport :: :stdio | :http_sse

    @type t :: %__MODULE__{
            name: String.t(),
            transport: transport(),
            command: String.t() | nil,
            args: [String.t()],
            env: %{String.t() => String.t()},
            url: String.t() | nil,
            headers: %{String.t() => String.t()},
            oauth: map() | nil,
            enabled: boolean(),
            tool_filter: [String.t()] | nil
          }

    defstruct name: nil,
              transport: :stdio,
              command: nil,
              args: [],
              env: %{},
              url: nil,
              headers: %{},
              oauth: nil,
              enabled: true,
              tool_filter: nil
  end

  @doc "Absolute path to the MCP config file (`~/.osa/mcp.json`)."
  @spec config_path() :: String.t()
  def config_path do
    config_dir()
    |> Path.join("mcp.json")
  end

  @doc """
  Load and parse the MCP config.

  Returns `{:ok, [%Server{}]}` on success (an empty list if the file is
  missing — MCP is optional), or `{:error, reason}` on malformed JSON.
  """
  @spec load() :: {:ok, [Server.t()]} | {:error, term()}
  def load(path \\ nil) do
    path = path || config_path()

    case File.read(path) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, decoded} -> {:ok, parse(decoded)}
          {:error, reason} -> {:error, {:invalid_json, reason}}
        end

      {:error, :enoent} ->
        # Missing config is not an error: MCP is opt-in.
        {:ok, []}

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  @doc """
  Like `load/1` but returns `[]` on any error, logging a warning. Convenient
  for boot paths that must never crash on a bad config file.
  """
  @spec load!() :: [Server.t()]
  def load!(path \\ nil) do
    case load(path) do
      {:ok, servers} ->
        servers

      {:error, reason} ->
        Logger.warning("[MCP.Config] Failed to load MCP config: #{inspect(reason)}")
        []
    end
  end

  @doc "Parse an already-decoded config map into `%Server{}` structs."
  @spec parse(map()) :: [Server.t()]
  def parse(%{"mcpServers" => servers}) when is_map(servers) do
    servers
    |> Enum.map(fn {name, spec} -> parse_server(name, spec) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.name)
  end

  def parse(_), do: []

  # ── Private ───────────────────────────────────────────────────────────

  defp parse_server(name, spec) when is_map(spec) do
    sanitized = sanitize_name(name)

    if sanitized == "" do
      Logger.warning("[MCP.Config] Skipping server with empty/invalid name: #{inspect(name)}")
      nil
    else
      url = spec["url"]
      transport = if is_binary(url) and url != "", do: :http_sse, else: :stdio

      %Server{
        name: sanitized,
        transport: transport,
        command: spec["command"],
        args: string_list(spec["args"]),
        env: string_map(spec["env"]),
        url: url,
        headers: string_map(spec["headers"]),
        oauth: spec["oauth"],
        enabled: Map.get(spec, "enabled", true) != false,
        tool_filter: parse_tool_filter(spec["tools"] || spec["tool_filter"])
      }
    end
  end

  defp parse_server(name, _spec) do
    Logger.warning("[MCP.Config] Skipping malformed server spec for #{inspect(name)}")
    nil
  end

  @doc "Sanitize a server name to the `[a-z0-9_]` alphabet used in tool names."
  @spec sanitize_name(String.t()) :: String.t()
  def sanitize_name(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.trim("_")
  end

  def sanitize_name(_), do: ""

  defp string_list(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp string_list(_), do: []

  defp string_map(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp string_map(_), do: %{}

  defp parse_tool_filter(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp parse_tool_filter(_), do: nil

  defp config_dir do
    Application.get_env(:optimal_system_agent, :config_dir, "~/.osa") |> Path.expand()
  end
end
