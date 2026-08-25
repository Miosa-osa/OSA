defmodule OptimalSystemAgent.Tools.Builtins.MCTSIndex do
  @moduledoc """
  MCTS-powered codebase indexer tool.

  Exposes `OptimalSystemAgent.MCTS.Indexer` as an agent-callable tool.
  The LLM can call this tool to intelligently explore a codebase and
  surface the most relevant files for a given goal — without reading
  every file exhaustively.

  ## When to use

  Use `mcts_index` instead of `file_glob` + `file_read` loops when:
  - The codebase is large (hundreds of files)
  - You need to find files related to a specific concept or subsystem
  - You want ranked results with relevance scores
  - You have a bounded exploration budget

  ## Returns

  A ranked list of file paths with relevance scores and content previews.
  """

  @behaviour MiosaTools.Behaviour

  @impl true
  def available?, do: true

  @impl true
  def safety, do: :read_only

  @impl true
  def name, do: "mcts_index"

  @impl true
  def description do
    "MCTS-powered codebase indexer. Uses Monte Carlo Tree Search to intelligently " <>
      "explore a directory and rank files by relevance to your goal. Efficient for " <>
      "large codebases — finds relevant code without exhaustive traversal."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "goal" => %{
          "type" => "string",
          "description" =>
            "What you are looking for, in natural language " <>
              "(e.g. 'authentication logic', 'database query handlers', 'signal classification')"
        },
        "root_dir" => %{
          "type" => "string",
          "description" => "Starting directory to index. Defaults to current working directory."
        },
        "max_iterations" => %{
          "type" => "integer",
          "description" =>
            "MCTS exploration budget — number of iterations (default: 50, max: 200). " <>
              "Higher values explore more paths but take longer."
        },
        "max_results" => %{
          "type" => "integer",
          "description" => "Maximum number of files to return ranked by relevance (default: 20)."
        }
      },
      "required" => ["goal"]
    }
  end

  @impl true
  def execute(%{"goal" => _goal}) do
    # OptimalSystemAgent.MCTS.Indexer backend is not present in this build.
    {:error, "MCTS.Indexer backend not present in this build"}
  end
end
