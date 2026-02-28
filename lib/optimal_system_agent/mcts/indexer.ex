defmodule OptimalSystemAgent.MCTS.Indexer do
  @moduledoc """
  MCTS-based codebase indexer.

  Uses Monte Carlo Tree Search to intelligently explore a directory tree
  and surface the most relevant files for a given goal. Unlike exhaustive
  traversal, MCTS prioritizes high-value paths using UCB1 selection,
  allowing it to find relevant code with a bounded exploration budget.

  ## Algorithm

  Each iteration runs four phases:

  1. **Select** — Walk from root, always choosing the child with the
     highest UCB1 score. Unexplored children return `:infinity`,
     ensuring they are visited at least once.

  2. **Expand** — When a directory node has not been expanded, list its
     children and initialize them as new nodes, pre-scored by filename
     relevance to the goal keywords.

  3. **Simulate** — Estimate the reward of the selected node by combining:
     - Extension weight (code > config > docs)
     - Filename keyword match against goal
     - Content keyword match (if file was read)
     - Depth penalty (prefer shallower paths)

  4. **Backpropagate** — Update visit counts and cumulative rewards from
     the selected node up to the root (with 50% reward decay per level).

  ## Relevance Scoring

  Files are scored on a [0.0, 1.0] scale:
  - `ext_score × 0.3` — file type quality
  - `name_score × 0.4` — keyword match in filename/parent dir
  - `content_score × 0.3` — keyword match in file content
  - minus `depth_penalty` — discourages deeply nested files
  """

  alias OptimalSystemAgent.MCTS.Node
  require Logger

  @default_max_iterations 50
  @default_max_depth 6
  @default_max_results 20

  @code_extensions ~w(.ex .exs .ts .tsx .js .jsx .mjs .go .py .rs .rb .java .kt .swift .c .cpp .h .cs .php .scala .clj .elm .zig .nim)
  @config_extensions ~w(.json .yaml .yml .toml .env .config .ini .conf)
  @doc_extensions ~w(.md .txt .rst .org)

  @skip_dirs ~w(.git node_modules _build deps .elixir_ls .hex priv/static vendor .cache __pycache__ .venv target dist build coverage .nyc_output)
  @skip_extensions ~w(.beam .lock .png .jpg .jpeg .gif .ico .svg .woff .woff2 .ttf .eot .map .zip .tar .gz .bz2 .rar .7z .pdf .DS_Store)

  @doc """
  Index a codebase using MCTS.

  ## Parameters

  - `goal` — Natural language description of what to find (e.g., "authentication logic")
  - `root_dir` — Starting directory path
  - `opts` — Keyword options:
    - `:max_iterations` — MCTS iterations (default: #{@default_max_iterations}, max: 500)
    - `:max_depth` — Maximum directory depth (default: #{@default_max_depth})
    - `:max_results` — Files to return (default: #{@default_max_results})

  ## Returns

  `{:ok, %{files: [...], summary: String.t(), total_explored: integer()}}`

  Each file entry: `%{path: String.t(), relevance: float(), visits: integer(), summary: String.t() | nil}`
  """
  @spec run(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def run(goal, root_dir, opts \\ []) do
    root_dir = Path.expand(root_dir)
    max_iter = min(Keyword.get(opts, :max_iterations, @default_max_iterations), 500)
    max_depth = Keyword.get(opts, :max_depth, @default_max_depth)
    max_results = Keyword.get(opts, :max_results, @default_max_results)

    unless File.dir?(root_dir) do
      {:error, "Directory not found: #{root_dir}"}
    else
      keywords = extract_keywords(goal)

      Logger.debug("[MCTS.Indexer] Starting: goal=#{inspect(keywords)}, dir=#{root_dir}, iter=#{max_iter}")

      root = %Node{path: root_dir, type: :dir, parent: nil}
      tree = %{root_dir => root}

      tree = run_iterations(tree, root_dir, keywords, max_iter, max_depth)

      results =
        tree
        |> Enum.filter(fn {_path, node} -> node.type == :file and node.visits > 0 end)
        |> Enum.sort_by(fn {_path, node} -> Node.avg_reward(node) end, :desc)
        |> Enum.take(max_results)
        |> Enum.map(fn {path, node} ->
          %{
            path: path,
            relevance: Float.round(Node.avg_reward(node), 3),
            visits: node.visits,
            summary: node.content_summary
          }
        end)

      total_nodes = map_size(tree)
      visited_files = Enum.count(tree, fn {_, n} -> n.type == :file and n.visits > 0 end)

      summary =
        "MCTS explored #{total_nodes} paths (#{visited_files} files read) in #{max_iter} iterations. " <>
          "Returning top #{length(results)} files for goal: \"#{goal}\""

      {:ok, %{files: results, summary: summary, total_explored: total_nodes}}
    end
  end

  # ---------------------------------------------------------------------------
  # MCTS core loop
  # ---------------------------------------------------------------------------

  defp run_iterations(tree, root_path, keywords, max_iter, max_depth) do
    Enum.reduce(1..max_iter, tree, fn _i, acc_tree ->
      {selected_path, acc_tree} = select_and_expand(acc_tree, root_path, keywords, max_depth, 0)
      reward = simulate(acc_tree, selected_path, keywords)
      backpropagate(acc_tree, selected_path, reward)
    end)
  end

  # Selection + Expansion: walk tree by UCB1, expand dirs when reached
  defp select_and_expand(tree, path, _keywords, max_depth, depth) when depth >= max_depth do
    {path, tree}
  end

  defp select_and_expand(tree, path, keywords, max_depth, depth) do
    node = Map.get(tree, path)

    cond do
      is_nil(node) ->
        {path, tree}

      node.type == :file ->
        # Leaf — read it on first visit to populate content_summary
        tree = if node.visits == 0, do: read_file_node(tree, path, keywords), else: tree
        {path, tree}

      not node.expanded ->
        # Expand directory
        tree = expand_dir(tree, path, keywords)
        node = Map.get(tree, path)

        if node.children == [] do
          {path, tree}
        else
          best = select_best_child(tree, node.children, max(node.visits, 1))
          select_and_expand(tree, best, keywords, max_depth, depth + 1)
        end

      node.children == [] ->
        {path, tree}

      true ->
        best = select_best_child(tree, node.children, max(node.visits, 1))
        select_and_expand(tree, best, keywords, max_depth, depth + 1)
    end
  end

  defp select_best_child(tree, children, parent_visits) do
    children
    |> Enum.map(fn child_path ->
      node = Map.get(tree, child_path, %Node{path: child_path, type: :file})
      score = Node.ucb1(node, parent_visits)
      numeric = if score == :infinity, do: 1_000_000.0, else: score
      {child_path, numeric}
    end)
    |> Enum.max_by(fn {_path, score} -> score end)
    |> elem(0)
  end

  # Expand a directory: list children, initialize nodes with filename pre-score
  defp expand_dir(tree, dir_path, keywords) do
    children =
      case File.ls(dir_path) do
        {:ok, entries} ->
          entries
          |> Enum.reject(&skip_entry?/1)
          |> Enum.map(&Path.join(dir_path, &1))
          |> Enum.filter(&File.exists?/1)

        _ ->
          []
      end

    tree =
      Enum.reduce(children, tree, fn child_path, acc ->
        if Map.has_key?(acc, child_path) do
          acc
        else
          type = if File.dir?(child_path), do: :dir, else: :file
          name_score = filename_relevance(child_path, keywords)

          # Pre-initialize with filename score so UCB1 considers it immediately
          {initial_reward, initial_visits} =
            if name_score > 0.0, do: {name_score, 1}, else: {0.0, 0}

          node = %Node{
            path: child_path,
            type: type,
            parent: dir_path,
            reward: initial_reward,
            visits: initial_visits
          }

          Map.put(acc, child_path, node)
        end
      end)

    updated_parent = %{Map.get(tree, dir_path) | children: children, expanded: true}
    Map.put(tree, dir_path, updated_parent)
  end

  # Read a file on first visit; populate content_summary for reward calculation
  defp read_file_node(tree, path, keywords) do
    summary =
      case File.read(path) do
        {:ok, content} ->
          preview = String.slice(content, 0, 600)
          symbols = count_symbols(content, Path.extname(path))
          kw_hits = Enum.count(keywords, &String.contains?(String.downcase(preview), &1))
          "symbols:#{symbols} kw_hits:#{kw_hits} | #{String.slice(preview, 0, 200)}"

        _ ->
          nil
      end

    node = Map.get(tree, path)
    updated = %{node | content_summary: summary}
    Map.put(tree, path, updated)
  end

  # ---------------------------------------------------------------------------
  # Simulation — estimate reward without full tree traversal
  # ---------------------------------------------------------------------------

  defp simulate(tree, path, keywords) do
    node = Map.get(tree, path)
    if is_nil(node), do: 0.0, else: do_simulate(node, keywords)
  end

  defp do_simulate(%Node{type: :dir} = node, keywords) do
    filename_relevance(node.path, keywords) * 0.5
  end

  defp do_simulate(%Node{type: :file} = node, keywords) do
    ext_score = file_type_score(Path.extname(node.path))
    name_score = filename_relevance(node.path, keywords)
    content_score = content_relevance(node.content_summary, keywords)
    penalty = depth_penalty(node.path)

    raw = ext_score * 0.3 + name_score * 0.4 + content_score * 0.3 - penalty
    max(raw, 0.0)
  end

  # ---------------------------------------------------------------------------
  # Backpropagation — update rewards from leaf to root
  # ---------------------------------------------------------------------------

  defp backpropagate(tree, path, reward) do
    node = Map.get(tree, path)

    if is_nil(node) do
      tree
    else
      updated = %{node | visits: node.visits + 1, reward: node.reward + reward}
      tree = Map.put(tree, path, updated)

      case node.parent do
        nil -> tree
        parent_path -> backpropagate(tree, parent_path, reward * 0.5)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Scoring helpers
  # ---------------------------------------------------------------------------

  defp filename_relevance(path, keywords) do
    basename = path |> Path.basename(Path.extname(path)) |> String.downcase()
    dir_part = path |> Path.dirname() |> Path.basename() |> String.downcase()

    matches =
      Enum.count(keywords, fn kw ->
        String.contains?(basename, kw) or String.contains?(dir_part, kw)
      end)

    min(matches * 0.3, 1.0)
  end

  defp content_relevance(nil, _keywords), do: 0.0
  defp content_relevance("", _keywords), do: 0.0

  defp content_relevance(summary, keywords) do
    lower = String.downcase(summary)
    matches = Enum.count(keywords, &String.contains?(lower, &1))
    min(matches * 0.2, 1.0)
  end

  defp file_type_score(ext) when ext in @code_extensions, do: 1.0
  defp file_type_score(ext) when ext in @config_extensions, do: 0.5
  defp file_type_score(ext) when ext in @doc_extensions, do: 0.3
  defp file_type_score(_), do: 0.1

  defp depth_penalty(path) do
    # Penalize paths deeper than 3 levels (arbitrary project root depth)
    depth = path |> Path.split() |> length()
    max((depth - 3) * 0.05, 0.0)
  end

  defp count_symbols(content, ext) when ext in [".ex", ".exs"] do
    content
    |> String.split("\n")
    |> Enum.count(&Regex.match?(~r/^\s*def[pf]?\s+\w+/, &1))
  end

  defp count_symbols(content, ext) when ext in [".ts", ".tsx", ".js", ".jsx", ".mjs"] do
    content
    |> String.split("\n")
    |> Enum.count(&Regex.match?(~r/\b(function|const|class|export)\b/, &1))
  end

  defp count_symbols(content, ".go") do
    content
    |> String.split("\n")
    |> Enum.count(&Regex.match?(~r/^func\s+\w+/, &1))
  end

  defp count_symbols(content, ".py") do
    content
    |> String.split("\n")
    |> Enum.count(&Regex.match?(~r/^\s*def\s+\w+/, &1))
  end

  defp count_symbols(content, ext) when ext in [".rs", ".c", ".cpp"] do
    content
    |> String.split("\n")
    |> Enum.count(&Regex.match?(~r/^(pub\s+)?fn\s+\w+|^\w+\s+\w+\s*\(/, &1))
  end

  defp count_symbols(_content, _ext), do: 0

  defp skip_entry?(name) do
    String.starts_with?(name, ".") or
      name in @skip_dirs or
      Path.extname(name) in @skip_extensions
  end

  defp extract_keywords(text) do
    stop_words = ~w(the and for with from that this into over under about what when how can will should would could)

    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s_\-]/, " ")
    |> String.split(~r/[\s_\-]+/, trim: true)
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.reject(&(&1 in stop_words))
    |> Enum.uniq()
  end
end
