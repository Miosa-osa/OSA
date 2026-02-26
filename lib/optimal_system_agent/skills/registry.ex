defmodule OptimalSystemAgent.Skills.Registry do
  @moduledoc """
  Skill discovery, registration, and dispatch.

  Skills can be registered in three ways:
  1. Built-in skills (always available, implement Skills.Behaviour)
  2. SKILL.md files from ~/.osa/skills/ (markdown-defined, parsed at boot)
  3. MCP server tools (auto-discovered from ~/.osa/mcp.json)

  The registry maintains a goldrush-compiled :osa_tool_dispatcher module
  that dispatches tool calls at BEAM instruction speed.

  ## Hot Code Reload
  When a new skill is registered via `register/1`, the goldrush tool dispatcher
  is recompiled automatically. New skills become available immediately.
  """
  use GenServer
  require Logger

  @skills_dir Application.compile_env(:optimal_system_agent, :skills_dir, "~/.osa/skills")

  defstruct skills: %{}, markdown_skills: %{}, tools: []

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Register a skill module implementing Skills.Behaviour."
  def register(skill_module) do
    GenServer.call(__MODULE__, {:register_module, skill_module})
  end

  @doc "List all available tools (for LLM function calling)."
  def list_tools do
    GenServer.call(__MODULE__, :list_tools)
  end

  @doc "List skill documentation (for context injection)."
  def list_skill_docs do
    GenServer.call(__MODULE__, :list_skill_docs)
  end

  @doc "Execute a tool by name with given arguments."
  def execute(tool_name, arguments) do
    GenServer.call(__MODULE__, {:execute, tool_name, arguments}, 60_000)
  end

  @impl true
  def init(:ok) do
    # Load built-in skills
    builtin = load_builtin_skills()

    # Load markdown SKILL.md files
    markdown = load_skill_files()

    # Build unified tool list
    tools = build_tool_list(builtin, markdown)

    # Compile goldrush tool dispatcher
    compile_dispatcher(builtin, markdown)

    Logger.info("Skills registry: #{map_size(builtin)} built-in, #{map_size(markdown)} markdown, #{length(tools)} total tools")
    {:ok, %__MODULE__{skills: builtin, markdown_skills: markdown, tools: tools}}
  end

  @impl true
  def handle_call({:register_module, skill_module}, _from, state) do
    name = skill_module.name()
    skills = Map.put(state.skills, name, skill_module)
    tools = build_tool_list(skills, state.markdown_skills)
    compile_dispatcher(skills, state.markdown_skills)
    Logger.info("Registered skill: #{name} (hot reload)")
    {:reply, :ok, %{state | skills: skills, tools: tools}}
  end

  def handle_call(:list_tools, _from, state) do
    {:reply, state.tools, state}
  end

  def handle_call(:list_skill_docs, _from, state) do
    module_docs = Enum.map(state.skills, fn {name, mod} -> {name, mod.description()} end)
    md_docs = Enum.map(state.markdown_skills, fn {name, skill} -> {name, skill.description} end)
    {:reply, module_docs ++ md_docs, state}
  end

  def handle_call({:execute, tool_name, arguments}, _from, state) do
    result =
      cond do
        # Check behaviour-based skills first
        mod = Map.get(state.skills, tool_name) ->
          mod.execute(arguments)

        # Check markdown skills (dispatch to built-in handler)
        _skill = Map.get(state.markdown_skills, tool_name) ->
          dispatch_builtin(tool_name, arguments)

        true ->
          {:error, "Unknown tool: #{tool_name}"}
      end

    {:reply, result, state}
  end

  # --- Built-in Skills ---

  defp load_builtin_skills do
    %{
      "file_read" => OptimalSystemAgent.Skills.Builtins.FileRead,
      "file_write" => OptimalSystemAgent.Skills.Builtins.FileWrite,
      "shell_execute" => OptimalSystemAgent.Skills.Builtins.ShellExecute,
      "web_search" => OptimalSystemAgent.Skills.Builtins.WebSearch,
      "memory_save" => OptimalSystemAgent.Skills.Builtins.MemorySave,
    }
  end

  # --- SKILL.md Loading ---

  defp load_skill_files do
    dir = Path.expand(@skills_dir)

    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&File.dir?(Path.join(dir, &1)))
      |> Enum.reduce(%{}, fn skill_dir, acc ->
        skill_file = Path.join([dir, skill_dir, "SKILL.md"])

        if File.exists?(skill_file) do
          case parse_skill_file(skill_file) do
            {:ok, skill} -> Map.put(acc, skill.name, skill)
            :error -> acc
          end
        else
          acc
        end
      end)
    else
      %{}
    end
  end

  defp parse_skill_file(path) do
    content = File.read!(path)

    case String.split(content, "---", parts: 3) do
      ["", frontmatter, body] ->
        case YamlElixir.read_from_string(frontmatter) do
          {:ok, meta} ->
            {:ok,
             %{
               name: meta["name"] || Path.basename(Path.dirname(path)),
               description: meta["description"] || "",
               instructions: String.trim(body),
               tools: meta["tools"] || []
             }}

          _ ->
            :error
        end

      _ ->
        {:ok,
         %{
           name: Path.basename(Path.dirname(path)),
           description: String.slice(content, 0, 100),
           instructions: content,
           tools: []
         }}
    end
  end

  # --- Tool List Building ---

  defp build_tool_list(behaviour_skills, markdown_skills) do
    behaviour_tools =
      Enum.map(behaviour_skills, fn {_name, mod} ->
        %{
          name: mod.name(),
          description: mod.description(),
          parameters: mod.parameters()
        }
      end)

    markdown_tools =
      Enum.map(markdown_skills, fn {name, skill} ->
        %{
          name: name,
          description: skill.description,
          parameters: %{"type" => "object", "properties" => %{}, "required" => []}
        }
      end)

    behaviour_tools ++ markdown_tools
  end

  # --- Goldrush Dispatcher Compilation ---

  defp compile_dispatcher(behaviour_skills, _markdown_skills) do
    rules =
      Enum.map(behaviour_skills, fn {name, _mod} ->
        {:glc, :eq, :tool_name, name, fn event ->
          Map.get(event, :handler_fn, fn _ -> :ok end).(event)
        end}
      end)

    if rules != [] do
      case :glc.compile(:osa_tool_dispatcher, rules) do
        {:ok, _} -> :ok
        error -> Logger.warning("Failed to compile :osa_tool_dispatcher: #{inspect(error)}")
      end
    end
  rescue
    _ -> :ok
  end

  # --- Fallback Dispatch ---

  defp dispatch_builtin("file_read", args), do: OptimalSystemAgent.Skills.Builtins.FileRead.execute(args)
  defp dispatch_builtin("file_write", args), do: OptimalSystemAgent.Skills.Builtins.FileWrite.execute(args)
  defp dispatch_builtin("shell_execute", args), do: OptimalSystemAgent.Skills.Builtins.ShellExecute.execute(args)
  defp dispatch_builtin("web_search", args), do: OptimalSystemAgent.Skills.Builtins.WebSearch.execute(args)
  defp dispatch_builtin("memory_save", args), do: OptimalSystemAgent.Skills.Builtins.MemorySave.execute(args)
  defp dispatch_builtin(name, _args), do: {:error, "No built-in handler for: #{name}"}
end
