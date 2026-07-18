defmodule OptimalSystemAgent.MCP.ProjectApproval do
  @moduledoc """
  Trust gate for project-scoped MCP servers (repo-committed `.mcp.json`).

  Repo-supplied stdio servers can execute arbitrary code, so they are NEVER
  started automatically. On first sight the operator is prompted; their choice
  is persisted to `~/.osa/mcp_project_choices.json` under the same keys Claude
  Code uses (`enabled_mcpjson_servers`, `disabled_mcpjson_servers`,
  `enable_all_project_mcp_servers`).

  `dialog_copy/0` returns the warning text and option specs; the TUI approval
  dialog (deferred: `priv/rust/tui/src/dialogs/mcp_approval.rs`) renders these
  and calls back into `approve/1`, `approve_all/0`, `reject/1`.
  """

  alias OptimalSystemAgent.MCP.Config

  @doc """
  Copy + option specs for the project-server approval prompt.

  `single_options` is for a lone new server; `multiselect_hint`/pre-selection
  drives the multi-server variant (all pre-selected, Space toggles, Enter
  confirms, Esc rejects all).
  """
  @spec dialog_copy() :: map()
  def dialog_copy do
    %{
      warning:
        "MCP servers may execute code or access system resources. All tool calls require approval.",
      docs_url: "https://osa.dev/docs/mcp",
      single_options: [
        %{value: :yes_all, label: "Use this and all future MCP servers in this project"},
        %{value: :yes, label: "Use this MCP server"},
        %{value: :no, label: "Continue without using this MCP server"}
      ],
      multiselect_hint: "Space to toggle · Enter to confirm · Esc to reject all (all pre-selected)"
    }
  end

  @doc "Path to the persisted project-choice file."
  @spec choices_path() :: String.t()
  def choices_path, do: Path.join(config_dir(), "mcp_project_choices.json")

  @doc "Load persisted project approval choices."
  @spec load_choices() :: map()
  def load_choices do
    case File.read(choices_path()) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, map} when is_map(map) -> map
          _ -> default_choices()
        end

      _ ->
        default_choices()
    end
  end

  @doc "Whether a project-scope server is approved to start."
  @spec approved?(String.t()) :: boolean()
  def approved?(name) do
    choices = load_choices()
    name = to_string(name)

    cond do
      name in list(choices, "disabled_mcpjson_servers") -> false
      Map.get(choices, "enable_all_project_mcp_servers", false) == true -> true
      name in list(choices, "enabled_mcpjson_servers") -> true
      true -> false
    end
  end

  @doc "Whether the operator has already decided about a server."
  @spec decided?(String.t()) :: boolean()
  def decided?(name) do
    choices = load_choices()
    name = to_string(name)

    Map.get(choices, "enable_all_project_mcp_servers", false) == true or
      name in list(choices, "enabled_mcpjson_servers") or
      name in list(choices, "disabled_mcpjson_servers")
  end

  @doc "Approve a single project server."
  @spec approve(String.t()) :: :ok | {:error, term()}
  def approve(name) do
    update(fn c ->
      Map.put(c, "enabled_mcpjson_servers", Enum.uniq([to_string(name) | list(c, "enabled_mcpjson_servers")]))
    end)
  end

  @doc "Approve this and all future project servers."
  @spec approve_all() :: :ok | {:error, term()}
  def approve_all do
    update(fn c -> Map.put(c, "enable_all_project_mcp_servers", true) end)
  end

  @doc "Reject a single project server."
  @spec reject(String.t()) :: :ok | {:error, term()}
  def reject(name) do
    update(fn c ->
      Map.put(c, "disabled_mcpjson_servers", Enum.uniq([to_string(name) | list(c, "disabled_mcpjson_servers")]))
    end)
  end

  @doc "Clear all project-approval choices (osa mcp reset-project-choices)."
  @spec reset() :: :ok | {:error, term()}
  def reset, do: write(default_choices())

  @doc "Project-scope servers the operator has not yet decided about."
  @spec pending() :: [Config.Server.t()]
  def pending do
    Config.load_scope(:project)
    |> Enum.reject(fn s -> decided?(s.name) end)
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp default_choices do
    %{
      "enabled_mcpjson_servers" => [],
      "disabled_mcpjson_servers" => [],
      "enable_all_project_mcp_servers" => false
    }
  end

  defp list(map, key) do
    case Map.get(map, key) do
      l when is_list(l) -> l
      _ -> []
    end
  end

  defp update(fun) do
    load_choices() |> fun.() |> write()
  end

  defp write(map) do
    File.mkdir_p!(Path.dirname(choices_path()))
    File.write(choices_path(), Jason.encode!(map, pretty: true))
  rescue
    e -> {:error, e}
  end

  defp config_dir do
    Application.get_env(:optimal_system_agent, :config_dir, "~/.osa") |> Path.expand()
  end
end
