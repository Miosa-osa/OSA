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
    :persistent_term.get({__MODULE__, :tools}, [])
  end

  @doc """
  Execute a tool by name without going through the GenServer.

  Uses :persistent_term for tool lookup. Safe to call from inside
  GenServer callbacks or from sub-agent Tasks spawned during orchestration.
  This prevents deadlock when Tools.Registry.execute calls orchestrate,
  which spawns sub-agents that call back into Tools.
  """
  def execute_direct(tool_name, arguments) do
    builtin_tools = :persistent_term.get({__MODULE__, :builtin_tools}, %{})

    case Map.get(builtin_tools, tool_name) do
      nil -> {:error, "Unknown tool: #{tool_name}"}
      mod -> mod.execute(arguments)
    end
  end

  @doc "List tool and skill documentation (for context injection)."
  def list_docs do
    GenServer.call(__MODULE__, :list_docs)
  end

  @doc "Search existing tools and skills by keyword matching against names and descriptions."
  @spec search(String.t()) :: list({String.t(), String.t(), float()})
  def search(query) do
    GenServer.call(__MODULE__, {:search, query})
  end

  @doc "Execute a tool by name with given arguments."
  def execute(tool_name, arguments) do
    GenServer.call(__MODULE__, {:execute, tool_name, arguments}, 60_000)
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

          _ ->
            # YAML parse failed; treat entire content as instructions
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
    {:reply, state.tools, state}
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
        nil -> {:error, "Unknown tool: #{tool_name}"}
        mod -> mod.execute(arguments)
      end

    {:reply, result, state}
  end

  # --- Built-in Tools ---

  defp load_builtin_tools do
    %{
      "file_read" => OptimalSystemAgent.Tools.Builtins.FileRead,
      "file_write" => OptimalSystemAgent.Tools.Builtins.FileWrite,
      "shell_execute" => OptimalSystemAgent.Tools.Builtins.ShellExecute,
      "web_search" => OptimalSystemAgent.Tools.Builtins.WebSearch,
      "memory_save" => OptimalSystemAgent.Tools.Builtins.MemorySave,
      "orchestrate" => OptimalSystemAgent.Tools.Builtins.Orchestrate,
      "create_skill" => OptimalSystemAgent.Tools.Builtins.CreateSkill,
      "budget_status" => OptimalSystemAgent.Tools.Builtins.BudgetStatus,
      "wallet_ops" => OptimalSystemAgent.Tools.Builtins.WalletOps,
      "file_edit" => OptimalSystemAgent.Tools.Builtins.FileEdit,
      "file_glob" => OptimalSystemAgent.Tools.Builtins.FileGlob,
      "file_grep" => OptimalSystemAgent.Tools.Builtins.FileGrep,
      "dir_list" => OptimalSystemAgent.Tools.Builtins.DirList,
      "web_fetch" => OptimalSystemAgent.Tools.Builtins.WebFetch,
      "task_write" => OptimalSystemAgent.Tools.Builtins.TaskWrite
    }
  end

  # --- SKILL.md Loading ---

  defp load_skills do
    dir = Path.expand(skills_dir())

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
    Enum.map(builtin_tools, fn {_name, mod} ->
      %{
        name: mod.name(),
        description: mod.description(),
        parameters: mod.parameters()
      }
    end)
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
