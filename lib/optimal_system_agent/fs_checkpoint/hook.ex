defmodule OptimalSystemAgent.FSCheckpoint.Hook do
  @moduledoc """
  Pre-tool-use hook that snapshots files before destructive operations.

  Registered by `FSCheckpoint.Server.init/1` at priority 11 so it runs
  after the security check (p10) but before most other hooks.
  """

  alias OptimalSystemAgent.FSCheckpoint.{Config, Server}

  @spec pre_tool_use(map()) :: {:ok, map()} | :skip
  def pre_tool_use(%{tool_name: tool_name, arguments: args} = payload) do
    unless Config.enabled?() do
      {:ok, payload}
    else
      paths = extract_paths(tool_name, args)

      if paths != [] do
        session_id = Map.get(payload, :session_id, "unknown")
        Server.snapshot(session_id, tool_name, paths)
      end

      {:ok, payload}
    end
  end

  def pre_tool_use(payload), do: {:ok, payload}

  # ── Private: path extraction by tool ─────────────────────────────────

  defp extract_paths(tool_name, args) when tool_name in ~w(file_write file_edit) do
    case Map.get(args, "path") || Map.get(args, :path) do
      nil -> []
      path -> expand_if_exists(path)
    end
  end

  defp extract_paths("multi_file_edit", args) do
    edits = Map.get(args, "edits") || Map.get(args, :edits) || []

    edits
    |> Enum.map(fn edit -> Map.get(edit, "path") || Map.get(edit, :path) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&expand_if_exists/1)
  end

  defp extract_paths("shell_execute", args) do
    command = Map.get(args, "command") || Map.get(args, :command) || ""

    if Enum.any?(Config.shell_destructive_patterns(), &String.contains?(command, &1)) do
      # Cannot reliably extract target paths from arbitrary shell commands.
      # Future enhancement: parse common patterns like `rm /path` or `mv src dst`.
      []
    else
      []
    end
  end

  defp extract_paths(_tool, _args), do: []

  defp expand_if_exists(path) do
    expanded = Path.expand(path)
    if File.regular?(expanded), do: [expanded], else: []
  end
end
