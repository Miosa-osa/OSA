defmodule OptimalSystemAgent.Tools.Registry do
  @moduledoc """
  Tool and skill registry — manages callable tools (Elixir modules) and discovers SKILL.md skill files.

  Tools/skills can be registered in three ways:
  1. Built-in tools (implement Tools.Behaviour)
  2. SKILL.md files from ~/.osa/skills/ (markdown-defined, parsed at boot)
  3. MCP server tools (auto-discovered from ~/.osa/mcp.json)

  The registry maintains a goldrush-compiled :osa_tool_dispatcher module
  that dispatches tool calls at BEAM instruction speed.

  ## Hot Code Reload
  When a new tool is registered via `register/1`, the goldrush tool dispatcher
  is recompiled automatically. New tools become available immediately.
  """
  use GenServer
  require Logger

  defp skills_dir, do: Application.get_env(:optimal_system_agent, :skills_dir, "~/.osa/skills")

  defstruct builtin_tools: %{}, skills: %{}, tools: []

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Register a tool module implementing Tools.Behaviour."
  def register(skill_module) do
    GenServer.call(__MODULE__, {:register_module, skill_module})
  end

  @doc "List all available tools (for LLM function calling)."
  def list_tools do
    GenServer.call(__MODULE__, :list_tools)
  end

  @doc """
  List all available tools without going through the GenServer.

  Uses :persistent_term for lock-free reads. Safe to call from inside
  GenServer callbacks (e.g., during orchestration) without deadlocking.
  """
  def list_tools_direct do
    # Re-filter at read time in case availability changed (e.g., env var set after boot)
    builtin_tools = :persistent_term.get({__MODULE__, :builtin_tools}, %{})

    builtin =
      builtin_tools
      |> Enum.filter(fn {_name, mod} -> tool_available?(mod) end)
      |> Enum.map(fn {_name, mod} ->
        %{
          name: mod.name(),
          description: mod.description(),
          parameters: mod.parameters()
        }
      end)

    # Append MCP tools (lock-free, registered asynchronously after boot)
    mcp_tools = :persistent_term.get({__MODULE__, :mcp_tools}, %{})

    mcp =
      Enum.map(mcp_tools, fn {prefixed_name, info} ->
        %{
          name: prefixed_name,
          description: Map.get(info, :description, "MCP tool: #{info.original_name}"),
          parameters: Map.get(info, :input_schema, %{"type" => "object", "properties" => %{}})
        }
      end)

    builtin ++ mcp
  end

  @doc """
  Execute a tool by name without going through the GenServer.

  Uses :persistent_term for tool lookup. Safe to call from inside
  GenServer callbacks or from sub-agent Tasks spawned during orchestration.
  This prevents deadlock when Tools.Registry.execute calls orchestrate,
  which spawns sub-agents that call back into Tools.

  MCP tools (prefixed `mcp_`) are routed to MCP.Client.call_tool/2.
  """
  def execute_direct(tool_name, arguments) do
    builtin_tools = :persistent_term.get({__MODULE__, :builtin_tools}, %{})

    case Map.get(builtin_tools, tool_name) do
      nil ->
        mcp_tools = :persistent_term.get({__MODULE__, :mcp_tools}, %{})

        case Map.get(mcp_tools, tool_name) do
          nil ->
            {:error, "Unknown tool: #{tool_name}"}

          _mcp_info ->
            {:error, "MCP tools not available in this build"}
        end

      mod ->
        case validate_arguments(mod, arguments) do
          :ok ->
            mod.execute(arguments)

          {:error, _reason} = error ->
            error
        end
    end
  end

  @doc """
  Validate tool arguments against the module's JSON Schema (from `parameters/0`).

  Returns `:ok` when arguments conform to the schema, or
  `{:error, message}` with a structured description of all validation failures.

  When the `ex_json_schema` dependency is not compiled (optional dep),
  validation is skipped and `:ok` is returned (fail-open).
  """
  @spec validate_arguments(module(), map()) :: :ok | {:error, String.t()}
  def validate_arguments(mod, arguments) do
    # Use apply/3 to avoid compile-time "undefined function" warnings when
    # ex_json_schema is not fetched. Code.ensure_loaded? guards the runtime call.
    unless Code.ensure_loaded?(ExJsonSchema.Schema) do
      :ok
    else
      schema = mod.parameters()

      try do
        resolved = apply(ExJsonSchema.Schema, :resolve, [schema])

        case apply(ExJsonSchema.Validator, :validate, [resolved, arguments]) do
          :ok ->
            :ok

          {:error, errors} ->
            message = format_validation_errors(mod.name(), errors)
            {:error, message}
        end
      rescue
        e ->
          Logger.warning("[Tools.Registry] Schema validation error for #{mod.name()}: #{inspect(e)}")
          # Fail open: if the schema itself is malformed, let the tool handle its own args
          :ok
      end
    end
  end

  # Format ExJsonSchema validation errors into a structured, LLM-readable message.
  defp format_validation_errors(tool_name, errors) do
    details =
      Enum.map_join(errors, "\n", fn
        {message, "#" <> path} ->
          "  - #{path}: #{message}"

        {message, path} when is_binary(path) ->
          "  - #{path}: #{message}"

        {message, _} ->
          "  - #{message}"
      end)

    "Tool '#{tool_name}' argument validation failed:\n#{details}"
  end

  @doc """
  Discover MCP tools from all running servers and register them.

  Called from Application after MCP servers start. Idempotent — safe to
  call multiple times (e.g. after reloading mcp.json).
  """
  def register_mcp_tools do
    # MCP not available in this build — no-op
    :ok
  end

  @doc "List tool and skill documentation (for context injection)."
  def list_docs do
    GenServer.call(__MODULE__, :list_docs)
  end

  @doc """
  List tool and skill documentation without going through the GenServer.

  Uses :persistent_term for lock-free reads. Safe to call from inside
  GenServer callbacks (e.g., during context building in Loop) without
  deadlocking or timing out under concurrent load.
  """
  def list_docs_direct do
    builtin_tools = :persistent_term.get({__MODULE__, :builtin_tools}, %{})
    skills = :persistent_term.get({__MODULE__, :skills}, %{})
    tool_docs = Enum.map(builtin_tools, fn {name, mod} -> {name, mod.description()} end)
    skill_docs = Enum.map(skills, fn {name, skill} -> {name, skill.description} end)
    tool_docs ++ skill_docs
  end

  @doc "Reload skills from disk (~/.osa/skills/) and recompile the dispatcher."
  def reload_skills do
    GenServer.call(__MODULE__, :reload_skills)
  end

  @doc """
  Returns a formatted string of all active custom skills for prompt injection.

  Used by Context.build to inform the LLM about available custom skills.
  Returns nil if no custom skills are loaded.
  """
  @spec active_skills_context() :: String.t() | nil
  def active_skills_context do
    skills = :persistent_term.get({__MODULE__, :skills}, %{})

    if map_size(skills) == 0 do
      nil
    else
      skills_dir = Path.expand(Application.get_env(:optimal_system_agent, :skills_dir, "~/.osa/skills"))

      active =
        Enum.reject(skills, fn {name, _skill} ->
          File.exists?(Path.join([skills_dir, name, ".disabled"]))
        end)

      if active == [] do
        nil
      else
        lines =
          Enum.map_join(active, "\n", fn {name, skill} ->
            "- **#{name}**: #{skill.description}"
          end)

        "## Custom Skills\n\nThe following skills are available:\n#{lines}"
      end
    end
  rescue
    _ -> nil
  end

  @doc """
  Filter the full tool list to only tools relevant to the current session context.

  `context` is a map with optional keys:
    - `:language`  — detected language (e.g. "python", "elixir", "javascript")
    - `:framework` — detected framework (e.g. "phoenix", "react", "django")
    - `:history`   — list of recently used tool names (strings)

  Rules applied:
  - Runtime-specific tools (e.g. shell_execute variants) are prioritised by language.
  - Recently used tools are promoted (appear first in results).
  - Unrelated language tools are deprioritised but never removed (graceful fallback).

  Returns a list of tool maps in relevance order, same shape as `list_tools_direct/0`.
  """
  @spec filter_applicable_tools(map()) :: [map()]
  def filter_applicable_tools(context \\ %{}) do
    all_tools = list_tools_direct()
    language = Map.get(context, :language, nil)
    framework = Map.get(context, :framework, nil)
    recent = Map.get(context, :history, []) |> MapSet.new()

    # Score each tool for applicability given the context
    scored =
      Enum.map(all_tools, fn tool ->
        score = tool_applicability_score(tool, language, framework, recent)
        {tool, score}
      end)

    # Sort: highest score first; tools with same score keep stable order
    scored
    |> Enum.sort_by(fn {_tool, score} -> -score end)
    |> Enum.map(fn {tool, _score} -> tool end)
  end

  @doc """
  Suggest an alternative tool when `failed_tool` fails.

  Returns `{:ok, alternative_tool_name}` when a known fallback exists,
  or `:no_alternative` when no substitution is available.

  Fallback map (ordered by preference):
    shell_execute  → file_read (read-only inspection as a safer fallback)
    web_search     → web_fetch
    web_fetch      → web_search
    file_write     → multi_file_edit
    multi_file_edit → file_write
    file_edit      → multi_file_edit
    semantic_search → session_search
    session_search  → memory_recall
  """
  @spec suggest_fallback_tool(String.t()) :: {:ok, String.t()} | :no_alternative
  def suggest_fallback_tool(failed_tool) do
    fallbacks = %{
      "shell_execute" => "file_read",
      "web_search" => "web_fetch",
      "web_fetch" => "web_search",
      "file_write" => "multi_file_edit",
      "multi_file_edit" => "file_write",
      "file_edit" => "multi_file_edit",
      "semantic_search" => "session_search",
      "session_search" => "memory_recall"
    }

    case Map.get(fallbacks, failed_tool) do
      nil ->
        :no_alternative

      alt ->
        builtin_tools = :persistent_term.get({__MODULE__, :builtin_tools}, %{})

        if Map.has_key?(builtin_tools, alt) do
          Logger.info("[Tools.Registry] Fallback for '#{failed_tool}': '#{alt}'")
          {:ok, alt}
        else
          :no_alternative
        end
    end
  end

  @doc """
  Same as `active_skills_context/0` but also injects the full workflow instructions
  for any skills whose trigger keywords match the given message.

  When a user message matches a skill's triggers, the agent receives the full
  SKILL.md instruction body in the system prompt for that turn — no file_read needed.
  """
  @spec active_skills_context(String.t() | nil) :: String.t() | nil
  def active_skills_context(nil), do: active_skills_context()
  def active_skills_context(""), do: active_skills_context()

  def active_skills_context(message) when is_binary(message) do
    base = active_skills_context()
    matched = match_skill_triggers(message)

    # Emit a bus event so TUI and command center can show which skills are active.
    if matched != [] do
      skill_names = Enum.map(matched, fn {name, _} -> name end)

      try do
        OptimalSystemAgent.Events.Bus.emit(:system_event, %{
          event: :skills_triggered,
          skills: skill_names,
          message_preview: String.slice(message, 0, 120)
        })
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    injected =
      Enum.flat_map(matched, fn {_name, skill} ->
        inst = skill.instructions |> to_string() |> String.trim()
        if inst != "", do: ["### Active Skill: #{skill.name}\n\n#{inst}"], else: []
      end)
      |> Enum.join("\n\n")

    cond do
      is_nil(base) and injected == "" -> nil
      is_nil(base) -> injected
      injected == "" -> base
      true -> base <> "\n\n" <> injected
    end
  rescue
    _ -> active_skills_context()
  end

  @doc """
  Match a message against all loaded skill trigger keywords.

  Returns a list of `{name, skill}` pairs from the skills map whose trigger
  keywords appear anywhere in the (case-insensitive) message text.
  Skips skills with a wildcard trigger `"*"` to avoid injecting everything.
  """
  @spec match_skill_triggers(String.t()) :: [{String.t(), map()}]
  def match_skill_triggers(message) when is_binary(message) do
    skills = :persistent_term.get({__MODULE__, :skills}, %{})
    message_lower = String.downcase(message)

    Enum.filter(skills, fn {_name, skill} ->
      triggers = Map.get(skill, :triggers, [])

      Enum.any?(triggers, fn t ->
        t = to_string(t)
        t != "*" and t != "" and String.contains?(message_lower, String.downcase(t))
      end)
    end)
  rescue
    _ -> []
  end

  def match_skill_triggers(_), do: []

  @doc "Search existing tools and skills by keyword matching against names and descriptions."
  @spec search(String.t()) :: list({String.t(), String.t(), float()})
  def search(query) do
    builtin_tools = :persistent_term.get({__MODULE__, :builtin_tools}, %{})
    skills = :persistent_term.get({__MODULE__, :skills}, %{})
    do_search(query, builtin_tools, skills)
  end

  @doc "Return a single skill map by name, or nil if not found."
  @spec get_skill(String.t()) :: map() | nil
  def get_skill(name) do
    :persistent_term.get({__MODULE__, :skills}, %{}) |> Map.get(name)
  end

  @doc "Return all loaded skills as a list."
  @spec list_skills() :: [map()]
  def list_skills do
    :persistent_term.get({__MODULE__, :skills}, %{})
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Execute a tool by name with given arguments.

  Runs directly in the caller's process (no GenServer serialization) using
  :persistent_term for module lookup. This prevents deadlocks when multiple
  sessions execute tools concurrently.
  """
  def execute(tool_name, arguments) do
    builtin_tools = :persistent_term.get({__MODULE__, :builtin_tools}, %{})

    case Map.get(builtin_tools, tool_name) do
      nil ->
        mcp_tools = :persistent_term.get({__MODULE__, :mcp_tools}, %{})

        case Map.get(mcp_tools, tool_name) do
          nil ->
            {:error, "Unknown tool: #{tool_name}"}

          _mcp_info ->
            {:error, "MCP tools not available in this build"}
        end

      mod ->
        case validate_arguments(mod, arguments) do
          :ok -> mod.execute(arguments)
          {:error, _reason} = error -> error
        end
    end
  rescue
    e ->
      {:error, "Tool execution error: #{Exception.message(e)}"}
  end

  @doc """
  Load all skill definitions from priv/skills/.

  Walks the priv/skills/ directory tree, finds all .md files, and parses
  YAML frontmatter metadata (skill name, triggers, priority, category).
  Returns a list of skill definition maps. Returns an empty list if the
  priv/skills/ directory does not exist.

  Each returned map contains:
    - `:name` - skill identifier (from frontmatter or derived from filename)
    - `:description` - short description of the skill
    - `:category` - category derived from parent directory (e.g., "core", "reasoning")
    - `:triggers` - list of trigger keywords/patterns
    - `:priority` - integer priority (lower = higher priority, default 5)
    - `:instructions` - full markdown body (the prompt content)
    - `:source_path` - relative path within priv/skills/
    - `:metadata` - any additional frontmatter fields as a map
  """
  @spec load_skill_definitions() :: [map()]
  def load_skill_definitions do
    skills_path = resolve_priv_skills_path()

    if skills_path && File.dir?(skills_path) do
      skills_path
      |> find_md_files()
      |> Enum.map(fn path -> parse_skill_definition(path, skills_path) end)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  # Resolve the priv/skills/ directory path. Returns nil if priv dir cannot be found.
  defp resolve_priv_skills_path do
    case :code.priv_dir(:optimal_system_agent) do
      {:error, _} ->
        # Fallback: try to find priv relative to the project root
        app_dir = Application.app_dir(:optimal_system_agent)

        if app_dir do
          Path.join(app_dir, "priv/skills")
        else
          # Last resort: relative path for development
          Path.join([File.cwd!(), "priv", "skills"])
        end

      priv_dir ->
        Path.join(to_string(priv_dir), "skills")
    end
  rescue
    _ ->
      # During compilation or when app is not started, use relative path
      Path.join([File.cwd!(), "priv", "skills"])
  end

  # Recursively find all .md files under the given directory.
  defp find_md_files(dir) do
    Path.wildcard(Path.join(dir, "**/*.md"))
  end

  # Parse a single skill definition file into a structured map.
  defp parse_skill_definition(path, base_path) do
    content = File.read!(path)
    relative_path = Path.relative_to(path, base_path)

    # Derive category from directory structure
    # e.g., "core/brainstorming.md" -> "core"
    #        "lats/SKILL.md" -> "lats"
    category = derive_category(relative_path)

    case String.split(content, "---", parts: 3) do
      ["", frontmatter, body] ->
        case YamlElixir.read_from_string(frontmatter) do
          {:ok, meta} ->
            build_skill_def(meta, body, relative_path, category)

          {:error, reason} ->
            Logger.debug("[Tools.Registry] YAML frontmatter parse failed for #{relative_path}: #{inspect(reason)} — treating as plain content")
            build_skill_def_from_content(content, relative_path, category)

          _ ->
            # Unexpected YamlElixir return — treat entire content as instructions
            build_skill_def_from_content(content, relative_path, category)
        end

      _ ->
        # No frontmatter; treat entire content as instructions
        build_skill_def_from_content(content, relative_path, category)
    end
  rescue
    e ->
      Logger.warning("Failed to parse skill definition at #{path}: #{inspect(e)}")
      nil
  end

  # Build a skill definition map from parsed YAML frontmatter and body.
  defp build_skill_def(meta, body, relative_path, category) do
    # Normalize the skill name from various frontmatter key conventions
    name =
      meta["name"] ||
        meta["skill_name"] ||
        meta["skill"] ||
        derive_name_from_path(relative_path)

    # Normalize triggers from various frontmatter key conventions
    triggers = normalize_triggers(meta)

    # Extract priority (default 5). Handles integer, numeric string, or named levels.
    priority =
      case meta["priority"] do
        p when is_integer(p) -> p
        p when is_binary(p) -> parse_priority(p)
        _ -> 5
      end

    # Collect additional metadata (everything not in our standard keys)
    standard_keys =
      ~w(name skill_name skill description trigger triggers trigger_keywords priority tools)

    metadata = Map.drop(meta, standard_keys)

    %{
      name: to_string(name),
      description: to_string(meta["description"] || ""),
      category: category,
      triggers: triggers,
      priority: priority,
      instructions: String.trim(body),
      source_path: relative_path,
      metadata: metadata
    }
  end

  # Build a skill definition from raw content (no frontmatter).
  defp build_skill_def_from_content(content, relative_path, category) do
    %{
      name: derive_name_from_path(relative_path),
      description: content |> String.slice(0, 100) |> String.trim(),
      category: category,
      triggers: [],
      priority: 5,
      instructions: content,
      source_path: relative_path,
      metadata: %{}
    }
  end

  # Parse a priority value from a string. Supports numeric strings and named levels.
  defp parse_priority(str) do
    case Integer.parse(str) do
      {n, ""} ->
        n

      _ ->
        case String.downcase(String.trim(str)) do
          "critical" -> 0
          "high" -> 1
          "medium" -> 3
          "low" -> 7
          _ -> 5
        end
    end
  end

  # Normalize triggers from the various frontmatter key conventions used across skill files.
  # Handles: "trigger" (string or pipe-delimited), "triggers" (list or ["*"]),
  # "trigger_keywords" (list of phrases).
  defp normalize_triggers(meta) do
    cond do
      is_list(meta["triggers"]) ->
        List.flatten(meta["triggers"]) |> Enum.map(&to_string/1)

      is_list(meta["trigger_keywords"]) ->
        List.flatten(meta["trigger_keywords"]) |> Enum.map(&to_string/1)

      is_binary(meta["trigger"]) ->
        # May be pipe-delimited (e.g., "security|vulnerability|CVE") or a single keyword
        meta["trigger"]
        |> String.split(~r/[|,]/, trim: true)
        |> Enum.map(&String.trim/1)

      true ->
        []
    end
  end

  # Derive category from the relative path.
  # "core/brainstorming.md" -> "core"
  # "lats/SKILL.md" -> "standalone"
  # "reasoning/extended-thinking.md" -> "reasoning"
  @known_skill_categories ~w(core automation reasoning)
  defp derive_category(relative_path) do
    parts = Path.split(relative_path)

    case parts do
      [dir, _file] when dir in @known_skill_categories -> dir
      [_dir, "SKILL.md"] -> "standalone"
      _ -> "standalone"
    end
  end

  # Derive a skill name from the file path.
  # "core/brainstorming.md" -> "brainstorming"
  # "lats/SKILL.md" -> "lats"
  defp derive_name_from_path(relative_path) do
    filename = Path.basename(relative_path, ".md")

    if filename == "SKILL" do
      # Use the parent directory name
      relative_path |> Path.dirname() |> Path.basename()
    else
      filename
    end
  end

  @impl true
  def init(:ok) do
    builtin_tools = load_builtin_tools()
    skills = load_skills()
    tools = build_tool_list(builtin_tools, skills)
    compile_dispatcher(builtin_tools, skills)

    # Store in :persistent_term for lock-free reads (avoids GenServer deadlock
    # when orchestrator sub-agents need tools/execution during a handle_call)
    :persistent_term.put({__MODULE__, :builtin_tools}, builtin_tools)
    :persistent_term.put({__MODULE__, :skills}, skills)
    :persistent_term.put({__MODULE__, :tools}, tools)

    Logger.info(
      "Tools registry: #{map_size(builtin_tools)} tools, #{map_size(skills)} skills, #{length(tools)} LLM tools"
    )

    {:ok, %__MODULE__{builtin_tools: builtin_tools, skills: skills, tools: tools}}
  end

  @impl true
  def handle_call({:register_module, skill_module}, _from, state) do
    name = skill_module.name()
    builtin_tools = Map.put(state.builtin_tools, name, skill_module)
    tools = build_tool_list(builtin_tools, state.skills)
    compile_dispatcher(builtin_tools, state.skills)

    # Update persistent_term for lock-free reads
    :persistent_term.put({__MODULE__, :builtin_tools}, builtin_tools)
    :persistent_term.put({__MODULE__, :tools}, tools)

    Logger.info("Registered tool: #{name} (hot reload)")
    {:reply, :ok, %{state | builtin_tools: builtin_tools, tools: tools}}
  end

  def handle_call(:list_tools, _from, state) do
    # Include MCP tools from persistent_term (registered asynchronously after boot)
    mcp_tools = :persistent_term.get({__MODULE__, :mcp_tools}, %{})

    mcp =
      Enum.map(mcp_tools, fn {prefixed_name, info} ->
        %{
          name: prefixed_name,
          description: Map.get(info, :description, "MCP tool: #{info.original_name}"),
          parameters: Map.get(info, :input_schema, %{"type" => "object", "properties" => %{}})
        }
      end)

    {:reply, state.tools ++ mcp, state}
  end

  def handle_call(:reload_skills, _from, state) do
    skills = load_skills()
    tools = build_tool_list(state.builtin_tools, skills)
    compile_dispatcher(state.builtin_tools, skills)

    :persistent_term.put({__MODULE__, :skills}, skills)
    :persistent_term.put({__MODULE__, :tools}, tools)

    Logger.info("Tools registry reloaded: #{map_size(skills)} skills")
    {:reply, :ok, %{state | skills: skills, tools: tools}}
  end

  def handle_call(:list_docs, _from, state) do
    tool_docs = Enum.map(state.builtin_tools, fn {name, mod} -> {name, mod.description()} end)
    skill_docs = Enum.map(state.skills, fn {name, skill} -> {name, skill.description} end)
    {:reply, tool_docs ++ skill_docs, state}
  end

  def handle_call({:search, query}, _from, state) do
    results = do_search(query, state.builtin_tools, state.skills)
    {:reply, results, state}
  end

  def handle_call({:execute, tool_name, arguments}, _from, state) do
    result =
      case Map.get(state.builtin_tools, tool_name) do
        nil ->
          # Builtin miss — fall through to MCP tools stored in :persistent_term
          mcp_tools = :persistent_term.get({__MODULE__, :mcp_tools}, %{})

          case Map.get(mcp_tools, tool_name) do
            nil ->
              {:error, "Unknown tool: #{tool_name}"}

            _mcp_info ->
              {:error, "MCP tools not available in this build"}
          end

        mod ->
          case validate_arguments(mod, arguments) do
            :ok -> mod.execute(arguments)
            {:error, _reason} = error -> error
          end
      end

    {:reply, result, state}
  end

  def handle_call(msg, _from, state) do
    Logger.warning("Tools.Registry received unexpected call: #{inspect(msg)}")
    {:reply, {:error, :unknown_call}, state}
  end

  # --- Built-in Tools ---

  defp load_builtin_tools do
    %{
      "file_read" => OptimalSystemAgent.Tools.Builtins.FileRead,
      "file_write" => OptimalSystemAgent.Tools.Builtins.FileWrite,
      "file_edit" => OptimalSystemAgent.Tools.Builtins.FileEdit,
      "file_glob" => OptimalSystemAgent.Tools.Builtins.FileGlob,
      "file_grep" => OptimalSystemAgent.Tools.Builtins.FileGrep,
      "dir_list" => OptimalSystemAgent.Tools.Builtins.DirList,
      "shell_execute" => OptimalSystemAgent.Tools.Builtins.ShellExecute,
      "task_write" => OptimalSystemAgent.Tools.Builtins.TaskWrite,
      "ask_user" => OptimalSystemAgent.Tools.Builtins.AskUser,
      "memory_save" => OptimalSystemAgent.Tools.Builtins.MemorySave,
      "memory_recall" => OptimalSystemAgent.Tools.Builtins.MemoryRecall,
      "session_search" => OptimalSystemAgent.Tools.Builtins.SessionSearch,
      "git" => OptimalSystemAgent.Tools.Builtins.Git,
      "multi_file_edit" => OptimalSystemAgent.Tools.Builtins.MultiFileEdit,
      "web_fetch" => OptimalSystemAgent.Tools.Builtins.WebFetch,
      "web_search" => OptimalSystemAgent.Tools.Builtins.WebSearch,
      "download" => OptimalSystemAgent.Tools.Builtins.Download,
      "code_symbols" => OptimalSystemAgent.Tools.Builtins.CodeSymbols,
      "create_skill" => OptimalSystemAgent.Tools.Builtins.CreateSkill,
      "list_skills" => OptimalSystemAgent.Tools.Builtins.ListSkills,
      "delegate" => OptimalSystemAgent.Tools.Builtins.Delegate,
      "list_agents" => OptimalSystemAgent.Tools.Builtins.ListAgents,
      "create_agent" => OptimalSystemAgent.Tools.Builtins.CreateAgent,
      "team_tasks" => OptimalSystemAgent.Tools.Builtins.TeamTasks,
      "message_agent" => OptimalSystemAgent.Tools.Builtins.MessageAgent,
      "computer_use" => OptimalSystemAgent.Tools.Builtins.ComputerUse,
      "verify_loop" => OptimalSystemAgent.Verification.Tools.VerifyLoop,
      "spawn_conversation" => OptimalSystemAgent.Conversations.Tools.SpawnConversation,
      "start_speculative" => OptimalSystemAgent.Speculative.Tools.StartSpeculative,
      "peer_review" => OptimalSystemAgent.Tools.Builtins.PeerReview,
      "peer_claim_region" => OptimalSystemAgent.Tools.Builtins.PeerClaimRegion,
      "peer_negotiate_task" => OptimalSystemAgent.Tools.Builtins.PeerNegotiateTask,
      "cross_team_query" => OptimalSystemAgent.Tools.Builtins.CrossTeamQuery
    }
  end

  # --- SKILL.md Loading ---

  defp load_skills do
    # Load built-in skills from priv/skills/ first (lower priority)
    priv_dir = resolve_priv_skills_path()

    priv_skills =
      load_skill_definitions()
      |> Enum.reduce(%{}, fn skill, acc ->
        # Store absolute path so the LLM can read the full skill instructions via file_read
        abs_path =
          if priv_dir, do: Path.join(priv_dir, skill.source_path), else: skill.source_path

        entry = %{
          name: skill.name,
          description: skill.description,
          triggers: skill.triggers,
          tools: [],
          path: abs_path
        }

        Map.put(acc, skill.name, entry)
      end)

    # Load user skills from ~/.osa/skills/ (higher priority — override priv skills)
    user_dir = Path.expand(skills_dir())

    user_skills =
      if File.dir?(user_dir) do
        user_dir
        |> File.ls!()
        |> Enum.filter(&File.dir?(Path.join(user_dir, &1)))
        |> Enum.reduce(%{}, fn skill_dir, acc ->
          skill_file = Path.join([user_dir, skill_dir, "SKILL.md"])

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

    # User skills override built-in skills with the same name
    Map.merge(priv_skills, user_skills)
  end

  defp parse_skill_file(path) do
    content = File.read!(path)

    case String.split(content, "---", parts: 3) do
      ["", frontmatter, _body] ->
        case YamlElixir.read_from_string(frontmatter) do
          {:ok, meta} ->
            {:ok,
             %{
               name: meta["name"] || Path.basename(Path.dirname(path)),
               description: meta["description"] || "",
               triggers: meta["triggers"] || [],
               tools: meta["tools"] || [],
               path: path
             }}

          _ ->
            :error
        end

      _ ->
        {:ok,
         %{
           name: Path.basename(Path.dirname(path)),
           description: String.slice(content, 0, 100),
           triggers: [],
           tools: [],
           path: path
         }}
    end
  end

  # --- Tool List Building ---

  defp build_tool_list(builtin_tools, _skills) do
    builtin_tools
    |> Enum.filter(fn {_name, mod} -> tool_available?(mod) end)
    |> Enum.map(fn {_name, mod} ->
      %{
        name: mod.name(),
        description: mod.description(),
        parameters: mod.parameters()
      }
    end)
  end

  # Check the optional available?/0 callback — defaults to true when not implemented
  defp tool_available?(mod) do
    not function_exported?(mod, :available?, 0) or mod.available?()
  end

  # --- Goldrush Dispatcher Compilation ---
  #
  # Compiles a goldrush module (:osa_tool_dispatcher) that validates tool
  # dispatch events. The compiled module runs at BEAM instruction speed.
  #
  # Uses glc:with(query, fun/1) to wrap a wildcard filter with a dispatch handler.

  defp compile_dispatcher(builtin_tools, _skills) do
    if map_size(builtin_tools) > 0 do
      # Build tool name filters from registered tools
      tool_filters =
        Enum.map(builtin_tools, fn {name, _mod} ->
          :glc.eq(:tool_name, name)
        end)

      # Compile: match any registered tool name, dispatch via handler
      query =
        :glc.with(:glc.any(tool_filters), fn event ->
          _ = :gre.fetch(:tool_name, event)
          :ok
        end)

      case :glc.compile(:osa_tool_dispatcher, query) do
        {:ok, _} -> :ok
        error -> Logger.warning("Failed to compile :osa_tool_dispatcher: #{inspect(error)}")
      end
    end
  rescue
    _ -> :ok
  end


  # --- Tool Applicability Scoring ---

  # Scores a tool for relevance given the session context.
  # Higher = more relevant. Recently used tools get a +0.3 boost.
  # Language/framework-specific tools get +0.4 or +0.2 for partial match.
  # Unrelated language tools get -0.2 (deprioritised but still accessible).
  defp tool_applicability_score(tool, language, framework, recent_set) do
    name = tool.name
    desc = String.downcase(tool.description)

    recent_bonus = if MapSet.member?(recent_set, name), do: 0.3, else: 0.0

    language_score =
      cond do
        is_nil(language) ->
          0.0

        String.contains?(desc, language) or String.contains?(name, language) ->
          0.4

        language_conflicts?(name, language) ->
          -0.2

        true ->
          0.0
      end

    framework_score =
      cond do
        is_nil(framework) ->
          0.0

        String.contains?(desc, framework) or String.contains?(name, framework) ->
          0.2

        true ->
          0.0
      end

    recent_bonus + language_score + framework_score
  end

  # Returns true when a tool name implies a language runtime that conflicts with
  # the detected session language (e.g. node_execute when language is "python").
  @language_tool_hints %{
    "python" => ["python"],
    "javascript" => ["node", "javascript", "js"],
    "typescript" => ["node", "typescript", "ts"],
    "ruby" => ["ruby"],
    "elixir" => ["elixir", "mix"],
    "go" => ["golang", "go_"],
    "rust" => ["rust", "cargo"]
  }

  defp language_conflicts?(tool_name, language) do
    lang_lower = String.downcase(language)
    own_hints = Map.get(@language_tool_hints, lang_lower, [])

    Enum.any?(@language_tool_hints, fn {lang, hints} ->
      lang != lang_lower and
        Enum.any?(hints, fn hint -> String.contains?(tool_name, hint) end) and
        # Only flag conflict when we actually know our language's hints
        own_hints != []
    end)
  end

  # --- Skill Search ---

  defp do_search(query, builtin_tools, skills) do
    keywords = extract_keywords(query)

    if keywords == [] do
      []
    else
      # Score builtin tools
      builtin_results =
        Enum.map(builtin_tools, fn {name, mod} ->
          desc = mod.description()
          score = compute_relevance(keywords, name, desc)
          {name, desc, score}
        end)

      # Score SKILL.md-based skills
      skill_results =
        Enum.map(skills, fn {name, skill} ->
          desc = skill.description
          score = compute_relevance(keywords, name, desc)
          {name, desc, score}
        end)

      (builtin_results ++ skill_results)
      |> Enum.filter(fn {_name, _desc, score} -> score > 0.0 end)
      |> Enum.sort_by(fn {_name, _desc, score} -> score end, :desc)
    end
  end

  defp extract_keywords(text) do
    # Common stop words to filter out
    stop_words =
      MapSet.new([
        "a",
        "an",
        "the",
        "is",
        "are",
        "was",
        "were",
        "be",
        "been",
        "being",
        "have",
        "has",
        "had",
        "do",
        "does",
        "did",
        "will",
        "would",
        "could",
        "should",
        "may",
        "might",
        "shall",
        "can",
        "need",
        "dare",
        "ought",
        "used",
        "to",
        "of",
        "in",
        "for",
        "on",
        "with",
        "at",
        "by",
        "from",
        "as",
        "into",
        "through",
        "during",
        "before",
        "after",
        "above",
        "below",
        "between",
        "out",
        "off",
        "over",
        "under",
        "again",
        "further",
        "then",
        "once",
        "that",
        "this",
        "these",
        "those",
        "i",
        "me",
        "my",
        "we",
        "our",
        "you",
        "your",
        "it",
        "its",
        "and",
        "but",
        "or",
        "nor",
        "not",
        "so",
        "if",
        "when",
        "what",
        "which",
        "who",
        "how",
        "all",
        "each",
        "every",
        "both",
        "few",
        "more",
        "most",
        "other",
        "some",
        "such",
        "no",
        "only",
        "same",
        "than",
        "too",
        "very",
        "just",
        "because",
        "about",
        "up"
      ])

    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(fn word -> MapSet.member?(stop_words, word) or String.length(word) < 2 end)
    |> Enum.uniq()
  end

  defp compute_relevance(keywords, name, description) do
    name_lower = String.downcase(name)
    desc_lower = String.downcase(description)

    # Split name on separators for token matching
    name_tokens =
      name_lower
      |> String.replace(~r/[-_]/, " ")
      |> String.split(~r/\s+/, trim: true)

    total_keywords = length(keywords)

    if total_keywords == 0 do
      0.0
    else
      # Name exact match gets highest weight
      name_exact_matches =
        Enum.count(keywords, fn kw -> name_lower == kw end)

      # Name token matches (e.g., keyword "file" matches name "file_read")
      name_token_matches =
        Enum.count(keywords, fn kw ->
          Enum.any?(name_tokens, fn token -> token == kw end)
        end)

      # Name substring matches (keyword appears anywhere in name)
      name_substring_matches =
        Enum.count(keywords, fn kw -> String.contains?(name_lower, kw) end)

      # Description matches
      desc_matches =
        Enum.count(keywords, fn kw -> String.contains?(desc_lower, kw) end)

      # Weighted score: name exact > name token > name substring > description
      raw_score =
        (name_exact_matches * 1.0 +
           name_token_matches * 0.7 +
           name_substring_matches * 0.5 +
           desc_matches * 0.3) / total_keywords

      # Clamp to 0.0-1.0
      min(raw_score, 1.0) |> Float.round(2)
    end
  end
end
