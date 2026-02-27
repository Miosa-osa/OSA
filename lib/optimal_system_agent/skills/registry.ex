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

  @doc "Search existing skills by keyword matching against names and descriptions."
  @spec search_skills(String.t()) :: list({String.t(), String.t(), float()})
  def search_skills(query) do
    GenServer.call(__MODULE__, {:search_skills, query})
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

  def handle_call({:search_skills, query}, _from, state) do
    results = do_search_skills(query, state.skills, state.markdown_skills)
    {:reply, results, state}
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
      "orchestrate" => OptimalSystemAgent.Skills.Builtins.Orchestrate,
      "create_skill" => OptimalSystemAgent.Skills.Builtins.CreateSkill,
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
  #
  # Compiles a goldrush module (:osa_tool_dispatcher) that validates tool
  # dispatch events. The compiled module runs at BEAM instruction speed.
  #
  # Uses glc:with(query, fun/1) to wrap a wildcard filter with a dispatch handler.

  defp compile_dispatcher(behaviour_skills, _markdown_skills) do
    if map_size(behaviour_skills) > 0 do
      # Build tool name filters from registered skills
      tool_filters = Enum.map(behaviour_skills, fn {name, _mod} ->
        :glc.eq(:tool_name, name)
      end)

      # Compile: match any registered tool name, dispatch via handler
      query = :glc.with(:glc.any(tool_filters), fn event ->
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

  # --- Fallback Dispatch ---

  defp dispatch_builtin("file_read", args), do: OptimalSystemAgent.Skills.Builtins.FileRead.execute(args)
  defp dispatch_builtin("file_write", args), do: OptimalSystemAgent.Skills.Builtins.FileWrite.execute(args)
  defp dispatch_builtin("shell_execute", args), do: OptimalSystemAgent.Skills.Builtins.ShellExecute.execute(args)
  defp dispatch_builtin("web_search", args), do: OptimalSystemAgent.Skills.Builtins.WebSearch.execute(args)
  defp dispatch_builtin("memory_save", args), do: OptimalSystemAgent.Skills.Builtins.MemorySave.execute(args)
  defp dispatch_builtin("orchestrate", args), do: OptimalSystemAgent.Skills.Builtins.Orchestrate.execute(args)
  defp dispatch_builtin("create_skill", args), do: OptimalSystemAgent.Skills.Builtins.CreateSkill.execute(args)
  defp dispatch_builtin(name, _args), do: {:error, "No built-in handler for: #{name}"}

  # --- Skill Search ---

  defp do_search_skills(query, behaviour_skills, markdown_skills) do
    keywords = extract_keywords(query)

    if keywords == [] do
      []
    else
      # Score behaviour-based skills
      behaviour_results =
        Enum.map(behaviour_skills, fn {name, mod} ->
          desc = mod.description()
          score = compute_relevance(keywords, name, desc)
          {name, desc, score}
        end)

      # Score markdown-based skills
      markdown_results =
        Enum.map(markdown_skills, fn {name, skill} ->
          desc = skill.description
          score = compute_relevance(keywords, name, desc)
          {name, desc, score}
        end)

      (behaviour_results ++ markdown_results)
      |> Enum.filter(fn {_name, _desc, score} -> score > 0.0 end)
      |> Enum.sort_by(fn {_name, _desc, score} -> score end, :desc)
    end
  end

  defp extract_keywords(text) do
    # Common stop words to filter out
    stop_words = MapSet.new([
      "a", "an", "the", "is", "are", "was", "were", "be", "been", "being",
      "have", "has", "had", "do", "does", "did", "will", "would", "could",
      "should", "may", "might", "shall", "can", "need", "dare", "ought",
      "used", "to", "of", "in", "for", "on", "with", "at", "by", "from",
      "as", "into", "through", "during", "before", "after", "above", "below",
      "between", "out", "off", "over", "under", "again", "further", "then",
      "once", "that", "this", "these", "those", "i", "me", "my", "we", "our",
      "you", "your", "it", "its", "and", "but", "or", "nor", "not", "so",
      "if", "when", "what", "which", "who", "how", "all", "each", "every",
      "both", "few", "more", "most", "other", "some", "such", "no", "only",
      "same", "than", "too", "very", "just", "because", "about", "up"
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
