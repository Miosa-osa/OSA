defmodule OptimalSystemAgent.StartupContext do
  @moduledoc """
  Bounded startup/context briefing for UI clients.

  The briefing is intentionally shallow: top-level project markers, short git
  status, short command/tool summaries, and best-effort memory hints. Optional
  subsystems degrade to empty values so the endpoint remains usable during boot
  and outside git repositories.
  """

  require Logger

  alias OptimalSystemAgent.Memory
  alias OptimalSystemAgent.Memory.Store
  alias OptimalSystemAgent.Tools.Registry, as: ToolsRegistry

  @git_timeout_ms 500
  @memory_timeout_ms 150
  @max_status_lines 40
  @max_project_files 20
  @max_commands 80
  @max_tools 80
  @max_memory_hints 5

  @project_markers [
    {"mix.exs", "elixir"},
    {"rebar.config", "erlang"},
    {"package.json", "node"},
    {"pnpm-lock.yaml", "node"},
    {"yarn.lock", "node"},
    {"Cargo.toml", "rust"},
    {"go.mod", "go"},
    {"pyproject.toml", "python"},
    {"requirements.txt", "python"},
    {"Gemfile", "ruby"},
    {"composer.json", "php"},
    {"pom.xml", "java"},
    {"build.gradle", "java"},
    {"deno.json", "deno"},
    {"Dockerfile", "docker"},
    {"docker-compose.yml", "docker"},
    {"Makefile", "make"},
    {"README.md", "docs"},
    {".gitignore", "git"}
  ]

  @doc "Build a startup context briefing."
  def build(opts \\ []) do
    cwd = Keyword.get(opts, :cwd) || cwd()
    session_id = normalize_session_id(Keyword.get(opts, :session_id))

    %{
      cwd: cwd,
      working_dir: cwd,
      session_id: session_id,
      git: git_summary(cwd),
      project: project_summary(cwd),
      session: session_summary(session_id),
      memory_hints: memory_hints(),
      capabilities: capabilities(),
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp cwd do
    case File.cwd() do
      {:ok, path} -> path
      {:error, _} -> "."
    end
  end

  defp git_summary(cwd) do
    inside? =
      case run_cmd("git", ["rev-parse", "--is-inside-work-tree"], cwd) do
        {:ok, output} -> String.trim(output) == "true"
        _ -> false
      end

    if inside? do
      branch =
        case run_cmd("git", ["branch", "--show-current"], cwd) do
          {:ok, output} -> output |> String.trim() |> blank_to_nil()
          _ -> nil
        end

      status_lines =
        case run_cmd("git", ["status", "--short"], cwd) do
          {:ok, output} -> split_lines(output, @max_status_lines)
          _ -> []
        end

      %{
        available: true,
        branch: branch,
        status: status_lines,
        status_count: length(status_lines),
        dirty: status_lines != []
      }
    else
      %{available: false, branch: nil, status: [], status_count: 0, dirty: false}
    end
  end

  defp run_cmd(command, args, cwd) do
    task = Task.async(fn -> System.cmd(command, args, cd: cwd, stderr_to_stdout: true) end)

    case Task.yield(task, @git_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {_output, _code}} -> :error
      nil -> :timeout
    end
  rescue
    e ->
      Logger.debug("[StartupContext] #{command} failed: #{Exception.message(e)}")
      :error
  end

  defp project_summary(cwd) do
    entries =
      case File.ls(cwd) do
        {:ok, names} -> names
        {:error, _} -> []
      end

    entry_set = MapSet.new(entries)

    project_files =
      @project_markers
      |> Enum.filter(fn {file, _type} -> MapSet.member?(entry_set, file) end)
      |> Enum.map(fn {file, type} -> %{file: file, type: type} end)
      |> Enum.take(@max_project_files)

    project_types =
      project_files
      |> Enum.map(& &1.type)
      |> Enum.uniq()
      |> Enum.sort()

    directories =
      entries
      |> Enum.filter(fn name -> File.dir?(Path.join(cwd, name)) end)
      |> Enum.reject(&ignored_entry?/1)
      |> Enum.sort()
      |> Enum.take(30)

    %{files: project_files, types: project_types, directories: directories}
  end

  defp session_summary(session_id) do
    sessions = OptimalSystemAgent.Agent.SessionPersistence.list(limit: 50)

    %{
      current_id: session_id,
      saved_count: length(sessions),
      is_new: is_nil(session_id) or not Enum.any?(sessions, &(&1.session_id == session_id))
    }
  rescue
    _ -> %{current_id: session_id, saved_count: 0, is_new: true}
  end

  defp ignored_entry?(name) do
    name in ~w(.git _build deps node_modules target vendor .elixir_ls .next .svelte-kit)
  end

  defp memory_hints do
    if Process.whereis(Store) do
      task = Task.async(fn -> Memory.recent(@max_memory_hints) end)

      case Task.yield(task, @memory_timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, entries}} -> Enum.map(entries, &memory_hint/1)
        _ -> []
      end
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp memory_hint(entry) when is_map(entry) do
    %{
      id: map_get(entry, :id),
      category: map_get(entry, :category),
      scope: map_get(entry, :scope),
      content: entry |> map_get(:content) |> truncate(180),
      updated_at: map_get(entry, :updated_at) || map_get(entry, :created_at)
    }
  end

  defp capabilities do
    commands = command_summaries()
    tools = tool_summaries()

    %{
      endpoints: %{
        tui_output_stream: "/api/v1/tui/output",
        tui_input: "/api/v1/tui/input",
        commands: "/api/v1/commands",
        tools: "/api/v1/tools",
        workspace: "/api/v1/workspace",
        memory_search: "/api/v1/memory/search"
      },
      commands: commands,
      command_count: length(commands),
      tools: tools,
      tool_count: length(tools)
    }
  end

  defp command_summaries do
    OptimalSystemAgent.Channels.CLI.Commands.list_with_descriptions()
    |> Enum.map(fn {name, description} ->
      %{name: name, description: description, category: command_category(name)}
    end)
    |> Enum.take(@max_commands)
  rescue
    _ -> []
  end

  defp tool_summaries do
    ToolsRegistry.list_tools_direct()
    |> Enum.map(fn tool ->
      %{name: map_get(tool, :name), description: map_get(tool, :description)}
    end)
    |> Enum.take(@max_tools)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp command_category(name) do
    cond do
      name in ~w(help status version doctor exit) -> "system"
      name in ~w(clear new compact resume) -> "session"
      name in ~w(model login logout setup persona) -> "config"
      name in ~w(context cost metrics hooks) -> "info"
      name in ~w(sessions export) -> "data"
      name in ~w(agents tools skills memory channels permissions) -> "browse"
      name in ~w(tasks plan coordinator effort fast) -> "workflow"
      true -> "commands"
    end
  end

  defp split_lines(output, limit) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(limit)
  end

  defp normalize_session_id(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_session_id(_), do: nil

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp map_get(map, key) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp truncate(nil, _limit), do: nil

  defp truncate(value, limit) do
    value = to_string(value)

    if String.length(value) > limit do
      String.slice(value, 0, limit) <> "..."
    else
      value
    end
  end
end
