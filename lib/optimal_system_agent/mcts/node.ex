defmodule OptimalSystemAgent.MCTS.Node do
  @moduledoc """
  A node in the MCTS tree for code indexing.

  Each node represents a file system path that can be explored.
  Tracks visit count, accumulated reward, and child paths.

  ## UCB1 Selection

  Upper Confidence Bound 1 (UCB1) balances exploration vs exploitation:

      UCB1 = (reward / visits) + C × √(ln(parent_visits) / visits)

  - Exploitation term: `reward / visits` — prefer high-reward paths
  - Exploration term: `C × √(...)` — visit unvisited or undervisited nodes

  Unvisited nodes return `:infinity` to ensure they are explored at least once.
  """

  @exploration_constant :math.sqrt(2)

  defstruct [
    :path,           # Absolute file system path
    :type,           # :dir | :file
    :parent,         # Parent node path (nil for root)
    visits: 0,
    reward: 0.0,
    children: [],
    expanded: false,
    content_summary: nil
  ]

  @doc "UCB1 score for child selection during the MCTS selection phase."
  @spec ucb1(t(), non_neg_integer()) :: float() | :infinity
  def ucb1(%__MODULE__{visits: 0}, _parent_visits), do: :infinity

  def ucb1(%__MODULE__{visits: n, reward: r}, parent_visits) when parent_visits > 0 do
    exploitation = r / n
    exploration = @exploration_constant * :math.sqrt(:math.log(max(parent_visits, 1)) / n)
    exploitation + exploration
  end

  def ucb1(_node, _parent_visits), do: 0.0

  @doc "Average reward for this node across all visits."
  @spec avg_reward(t()) :: float()
  def avg_reward(%__MODULE__{visits: 0}), do: 0.0
  def avg_reward(%__MODULE__{visits: n, reward: r}), do: r / n

  @type t :: %__MODULE__{
    path: String.t(),
    type: :dir | :file,
    parent: String.t() | nil,
    visits: non_neg_integer(),
    reward: float(),
    children: [String.t()],
    expanded: boolean(),
    content_summary: String.t() | nil
  }
end
