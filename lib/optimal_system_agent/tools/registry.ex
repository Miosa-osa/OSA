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

  ## Sub-modules
    - Registry.SkillLoader — loads/parses SKILL.md from priv/skills/ and ~/.osa/skills/
    - Registry.Search      — keyword search, applicability scoring, fallback suggestion
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.Tools.Registry.{Search, SkillLoader}

  defstruct builtin_tools: %{}, skills: %{}, tools: []

  # ── GenServer Start ──────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  # ── Public API ────────────────────────────────────────────────────────

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

  Uses :persistent_term for tool lookup. Safe to call from inside GenServer
  callbacks or sub-agent Tasks during orchestration — prevents deadlock.

  MCP tools (prefixed `mcp_`) are routed to MCP.Client.call_tool/2.
  """
  def execute_direct(tool_name, arguments) do
    builtin_tools = :persistent_term.get({__MODULE__, :builtin_tools}, %{})

    case Map.get(builtin_tools, tool_name) do
      nil ->
        mcp_tools = :persistent_term.get({__MODULE__, :mcp_tools}, %{})

        case Map.get(mcp_tools, tool_name) do
          nil -> {:error, "Unknown tool: #{tool_name}"}
          _mcp_info -> {:error, "MCP tools not available in this build"}
        end

      mod ->
        case validate_arguments(mod, arguments) do
          :ok -> mod.execute(arguments)
          {:error, _reason} = error -> error
        end
    end
  end

  @doc """
  Execute a tool by name with given arguments.

  Runs directly in the caller's process (no GenServer serialization) using
  :persistent_term for module lookup.
  """
  def execute(tool_name, arguments) do
    builtin_tools = :persistent_term.get({__MODULE__, :builtin_tools}, %{})

    case Map.get(builtin_tools, tool_name) do
      nil ->
        mcp_tools = :persistent_term.get({__MODULE__, :mcp_tools}, %{})

        case Map.get(mcp_tools, tool_name) do
          nil -> {:error, "Unknown tool: #{tool_name}"}
          _mcp_info -> {:error, "MCP tools not available in this build"}
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
  Validate tool arguments against the module's JSON Schema (from `parameters/0`).

  Returns `:ok` when arguments conform to the schema, or
  `{:error, message}` with a structured description of all validation failures.

  When the `ex_json_schema` dependency is not compiled, validation is skipped
  and `:ok` is returned (fail-open).
  """
  @spec validate_arguments(module(), map()) :: :ok | {:error, String.t()}
  def validate_arguments(mod, arguments) do
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
          Logger.warning(
            "[Tools.Registry] Schema validation error for #{mod.name()}: #{inspect(e)}"
          )

          :ok
      end
    end
  end

  @doc "Discover MCP tools from all running servers and register them. No-op in this build."
  def register_mcp_tools, do: :ok

  @doc "List tool and skill documentation (for context injection)."
  def list_docs do
    GenServer.call(__MODULE__, :list_docs)
  end

  @doc """
  List tool and skill documentation without going through the GenServer.

  Uses :persistent_term for lock-free reads.
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
      skills_dir =
        Path.expand(Application.get_env(:optimal_system_agent, :skills_dir, "~/.osa/skills"))

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
  Same as `active_skills_context/0` but also injects the full workflow instructions
  for any skills whose trigger keywords match the given message.
  """
  @spec active_skills_context(String.t() | nil) :: String.t() | nil
  def active_skills_context(nil), do: active_skills_context()
  def active_skills_context(""), do: active_skills_context()

  def active_skills_context(message) when is_binary(message) do
    base = active_skills_context()
    matched = match_skill_triggers(message)

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

  Returns a list of `{name, skill}` pairs whose trigger keywords appear
  anywhere in the (case-insensitive) message text.
  Skips skills with a wildcard trigger `"*"`.
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
    Search.search(builtin_tools, skills, query)
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
  Filter the full tool list to only tools relevant to the current session context.

  `context` keys: `:language`, `:framework`, `:history`.
  Returns tools in relevance order.
  """
  @spec filter_applicable_tools(map()) :: [map()]
  def filter_applicable_tools(context \\ %{}) do
    Search.filter_applicable_tools(context, list_tools_direct())
  end

  @doc """
  Suggest an alternative tool when `failed_tool` fails.

  Returns `{:ok, alternative_tool_name}` or `:no_alternative`.
  """
  @spec suggest_fallback_tool(String.t()) :: {:ok, String.t()} | :no_alternative
  def suggest_fallback_tool(failed_tool) do
    builtin_tools = :persistent_term.get({__MODULE__, :builtin_tools}, %{})
    Search.suggest_fallback(failed_tool, builtin_tools)
  end

  @doc "Load all skill definitions from priv/skills/. Delegates to SkillLoader."
  @spec load_skill_definitions() :: [map()]
  def load_skill_definitions do
    SkillLoader.load_skill_definitions()
  end

  # ── GenServer Callbacks ───────────────────────────────────────────────

  @impl true
  def init(:ok) do
    builtin_tools = load_builtin_tools()
    skills = SkillLoader.load_skills()
    tools = build_tool_list(builtin_tools, skills)
    compile_dispatcher(builtin_tools, skills)

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

    :persistent_term.put({__MODULE__, :builtin_tools}, builtin_tools)
    :persistent_term.put({__MODULE__, :tools}, tools)

    Logger.info("Registered tool: #{name} (hot reload)")
    {:reply, :ok, %{state | builtin_tools: builtin_tools, tools: tools}}
  end

  def handle_call(:list_tools, _from, state) do
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
    skills = SkillLoader.load_skills()
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
    results = Search.search(state.builtin_tools, state.skills, query)
    {:reply, results, state}
  end

  def handle_call({:execute, tool_name, arguments}, _from, state) do
    result =
      case Map.get(state.builtin_tools, tool_name) do
        nil ->
          mcp_tools = :persistent_term.get({__MODULE__, :mcp_tools}, %{})

          case Map.get(mcp_tools, tool_name) do
            nil -> {:error, "Unknown tool: #{tool_name}"}
            _mcp_info -> {:error, "MCP tools not available in this build"}
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

  # ── Private: Built-in Tools ───────────────────────────────────────────

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

  # ── Private: Tool List Building ───────────────────────────────────────

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

  defp tool_available?(mod) do
    not function_exported?(mod, :available?, 0) or mod.available?()
  end

  # ── Private: Goldrush Dispatcher Compilation ──────────────────────────

  defp compile_dispatcher(builtin_tools, _skills) do
    if map_size(builtin_tools) > 0 do
      tool_filters =
        Enum.map(builtin_tools, fn {name, _mod} ->
          :glc.eq(:tool_name, name)
        end)

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

  # ── Private: Validation Error Formatting ─────────────────────────────

  defp format_validation_errors(tool_name, errors) do
    details =
      Enum.map_join(errors, "\n", fn
        {message, "#" <> path} -> "  - #{path}: #{message}"
        {message, path} when is_binary(path) -> "  - #{path}: #{message}"
        {message, _} -> "  - #{message}"
      end)

    "Tool '#{tool_name}' argument validation failed:\n#{details}"
  end
end
