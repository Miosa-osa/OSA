defmodule OptimalSystemAgent.Tools.Builtins.CodebaseExplore do
  @moduledoc """
  Composite exploration tool for deep codebase understanding.

  The LLM can call this explicitly for structured codebase analysis at
  three depth levels: quick, standard, deep.

  All internal tool calls use `Tools.execute_direct/2` (lock-free).
  """
  @behaviour MiosaTools.Behaviour

  alias OptimalSystemAgent.Tools.Registry, as: Tools

  # Project config files that identify project type
  @project_configs %{
    "mix.exs" => "Elixir/OTP",
    "package.json" => "Node.js",
    "go.mod" => "Go",
    "Cargo.toml" => "Rust",
    "pyproject.toml" => "Python",
    "requirements.txt" => "Python",
    "Gemfile" => "Ruby",
    "pom.xml" => "Java (Maven)",
    "build.gradle" => "Java (Gradle)",
    "CMakeLists.txt" => "C/C++ (CMake)",
    "Makefile" => "Make-based"
  }

  @impl true
  def available?, do: true

  @impl true
  def safety, do: :read_only

  # Deferred: absent from the default toolbox, discovered mid-turn via
  # `tool_search`. Reason: overlaps dir_list + file_grep, which are always present.
  #
  # Every schema in the default set is re-sent on EVERY request. Measured
  # across 15 SWE-bench Pro transcripts, this tool was called zero times while
  # costing its schema on all 863 turns.
  @impl true
  def should_defer?, do: true

  @impl true
  def name, do: "codebase_explore"

  @impl true
  def description do
    "Explore and understand a codebase structure. Use before modifying code to understand " <>
      "project type, file layout, dependencies, and find relevant files. " <>
      "Depth: quick (structure only), standard (+ config + relevant files), deep (+ MCTS + grep)."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "goal" => %{
          "type" => "string",
          "description" =>
            "What you're trying to understand (e.g., 'authentication flow', 'database schema')"
        },
        "path" => %{
          "type" => "string",
          "description" => "Root directory to explore (default: current directory)"
        },
        "depth" => %{
          "type" => "string",
          "enum" => ["quick", "standard", "deep"],
          "description" =>
            "Exploration depth: quick (structure), standard (+ config + files), deep (+ MCTS + grep)"
        }
      },
      "required" => ["goal"]
    }
  end

  @impl true
  def execute(%{"goal" => goal} = params) do
    path = Path.expand(params["path"] || ".")
    depth = params["depth"] || "standard"

    result = explore(goal, path, depth)
    {:ok, result}
  rescue
    e -> {:error, "Exploration failed: #{Exception.message(e)}"}
  end

  def execute(_), do: {:error, "Missing required parameter: goal"}

  # ── Exploration by Depth ───────────────────────────────────────

  defp explore(goal, path, depth) do
    # Quick: structure + project type
    {structure, root_entries} = list_directory(path)
    {project_type, config_file} = detect_project_type(path, root_entries)

    quick_result = """
    ## Codebase Exploration

    **Project type:** #{project_type}
    **Root:** #{path}

    ### Structure
    #{structure}
    """

    if depth == "quick" do
      String.trim(quick_result)
    else
      # Standard: + config + relevant files
      config_summary = read_config(path, config_file)

      # Extract keywords from goal for file search
      keywords = extract_keywords(goal)
      relevant_files = find_relevant_files(path, keywords)
      top_files = read_top_files(relevant_files, 3)

      standard_result = """
      #{quick_result}
      ### Configuration
      #{if config_summary != "", do: config_summary, else: "_No config file found_"}

      ### Relevant Files
      #{if relevant_files != [], do: Enum.join(relevant_files, "\n"), else: "_No matching files found_"}

      #{if top_files != "", do: "### Key File Contents\n#{top_files}", else: ""}
      """

      if depth == "standard" do
        cap(String.trim(standard_result))
      else
        # Deep: + MCTS + grep
        mcts_result = run_mcts(path, goal, 100)
        grep_results = grep_for_keywords(path, keywords)
        mcts_files = read_top_mcts_files(mcts_result, 5)

        deep_result = """
        #{standard_result}
        ### MCTS Analysis
        #{if mcts_result != "", do: mcts_result, else: "_MCTS not available_"}

        #{if mcts_files != "", do: "### MCTS Top Files\n#{mcts_files}", else: ""}

        ### Code Search Results
        #{if grep_results != "", do: grep_results, else: "_No keyword matches_"}

        ### Patterns Detected
        #{detect_patterns(root_entries, project_type)}
        """

        cap(String.trim(deep_result))
      end
    end
  end

  # ── Internal Tool Wrappers ─────────────────────────────────────

  defp list_directory(path) do
    case Tools.execute_direct("dir_list", %{"path" => path}) do
      {:ok, content} when is_binary(content) ->
        entries =
          content
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            case String.split(line, "\t", parts: 3) do
              [_type, _size, name] -> name
              _ -> line
            end
          end)

        {content, entries}

      _ ->
        {"_Could not list directory: #{path}_", []}
    end
  end

  defp detect_project_type(path, root_entries) do
    Enum.find_value(@project_configs, {"Unknown", nil}, fn {config_file, project_type} ->
      if config_file in root_entries or File.exists?(Path.join(path, config_file)) do
        {project_type, config_file}
      end
    end) || {"Unknown", nil}
  end

  defp read_config(_path, nil), do: ""

  defp read_config(path, config_file) do
    full_path = Path.join(path, config_file)

    case Tools.execute_direct("file_read", %{"path" => full_path}) do
      {:ok, content} when is_binary(content) ->
        # Truncate large configs
        if String.length(content) > 3000 do
          String.slice(content, 0, 3000) <> "\n[truncated]"
        else
          content
        end

      _ ->
        ""
    end
  end

  defp extract_keywords(goal) do
    stop_words = MapSet.new(~w(the a an is are was were be been being have has had do does did
      will would could should may might shall can need to of in for on with at by from as into
      through during before after above below between out off over under again further then
      once that this these those i me my we our you your it its and but or nor not so if when
      what which who how all each every both few more most other some such no only same than
      too very just because about up please let understand find explore look check))

    goal
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s_-]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(fn word -> MapSet.member?(stop_words, word) or String.length(word) < 3 end)
    |> Enum.uniq()
    |> Enum.take(6)
  end

  defp find_relevant_files(path, keywords) do
    patterns =
      Enum.flat_map(keywords, fn kw ->
        ["**/*#{kw}*"]
      end)

    patterns
    |> Enum.flat_map(fn pattern ->
      case Tools.execute_direct("file_glob", %{"pattern" => pattern, "path" => path}) do
        {:ok, content} when is_binary(content) ->
          if String.starts_with?(content, "No files") do
            []
          else
            content
            |> String.split("\n", trim: true)
            |> Enum.reject(fn line ->
              String.contains?(line, "files found") or
                String.contains?(line, "/_build/") or
                String.contains?(line, "/node_modules/") or
                String.contains?(line, "/deps/") or
                String.contains?(line, "/.git/") or
                String.contains?(line, "/target/") or
                String.contains?(line, "/vendor/")
            end)
          end

        _ ->
          []
      end
    end)
    |> Enum.uniq()
    |> Enum.take(15)
  end

  defp read_top_files([], _n), do: ""

  defp read_top_files(files, n) do
    files
    |> Enum.take(n)
    |> Enum.map(fn file ->
      case Tools.execute_direct("file_read", %{"path" => file}) do
        {:ok, content} when is_binary(content) ->
          truncated =
            if String.length(content) > 2000,
              do: String.slice(content, 0, 2000) <> "\n[truncated]",
              else: content

          "#### `#{file}`\n```\n#{truncated}\n```"

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp run_mcts(path, goal, iterations) do
    case Tools.execute_direct("mcts_index", %{
           "goal" => goal,
           "path" => path,
           "max_iterations" => iterations
         }) do
      {:ok, content} when is_binary(content) -> content
      _ -> ""
    end
  rescue
    _ -> ""
  end

  defp read_top_mcts_files(mcts_result, n) when is_binary(mcts_result) and mcts_result != "" do
    # Extract file paths from MCTS output
    files =
      Regex.scan(~r{(/[^\s:]+\.[a-z]+)}, mcts_result)
      |> Enum.map(&List.first/1)
      |> Enum.uniq()
      |> Enum.filter(&File.exists?/1)
      |> Enum.take(n)

    read_top_files(files, n)
  end

  defp read_top_mcts_files(_, _), do: ""

  defp grep_for_keywords(path, keywords) do
    keywords
    |> Enum.take(3)
    |> Enum.map(fn kw ->
      case Tools.execute_direct("file_grep", %{
             "pattern" => kw,
             "path" => path,
             "max_results" => 5
           }) do
        {:ok, content} when is_binary(content) ->
          "**`#{kw}`:**\n#{content}"

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp detect_patterns(root_entries, project_type) do
    patterns = []

    patterns =
      if "test" in root_entries or "tests" in root_entries or "spec" in root_entries,
        do: ["Has test directory" | patterns],
        else: patterns

    patterns =
      if "Dockerfile" in root_entries or "docker-compose.yml" in root_entries,
        do: ["Docker setup present" | patterns],
        else: patterns

    patterns =
      if ".github" in root_entries,
        do: ["GitHub Actions/config present" | patterns],
        else: patterns

    patterns =
      if ".env.example" in root_entries or ".env.sample" in root_entries,
        do: ["Environment variables configured" | patterns],
        else: patterns

    patterns =
      if "Makefile" in root_entries and project_type != "Make-based",
        do: ["Makefile for build automation" | patterns],
        else: patterns

    patterns =
      if "priv" in root_entries,
        do: ["Priv directory (assets/migrations/templates)" | patterns],
        else: patterns

    patterns =
      if "config" in root_entries, do: ["Config directory present" | patterns], else: patterns

    if patterns == [] do
      "_No notable patterns detected_"
    else
      Enum.map_join(patterns, "\n", &"- #{&1}")
    end
  end

  defp cap(text) do
    max = 12_000

    if byte_size(text) > max do
      <<truncated::binary-size(max), _rest::binary>> = text
      # Find last valid UTF-8 boundary by dropping trailing invalid bytes
      truncated =
        case String.chunk(truncated, :valid) do
          [] -> ""
          chunks -> Enum.filter(chunks, &String.valid?/1) |> Enum.join()
        end

      String.trim_trailing(truncated) <> "\n[Output truncated]"
    else
      text
    end
  end
end
