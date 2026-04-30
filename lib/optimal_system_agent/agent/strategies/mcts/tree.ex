defmodule OptimalSystemAgent.Agent.Strategies.MCTS.Tree do
  @moduledoc """
  Flat map-backed tree for MCTS.

  Nodes are stored in a map keyed by integer ID. All mutations return
  a new `Tree` struct — the data structure is fully immutable.
  """

  alias OptimalSystemAgent.Agent.Strategies.MCTS.Node

  @type t :: %__MODULE__{
          nodes: %{integer() => Node.t()},
          next_id: integer()
        }

  defstruct nodes: %{}, next_id: 0

  @doc "Create a new tree with `initial_state` as the root node. Returns `{tree, root_id}`."
  @spec new(map()) :: {t(), integer()}
  def new(initial_state) do
    root = %Node{id: 0, state: initial_state, operation: nil, depth: 0}
    tree = %__MODULE__{nodes: %{0 => root}, next_id: 1}
    {tree, 0}
  end

  @doc "Retrieve a node by ID. Returns `nil` if not found."
  @spec get(t(), integer()) :: Node.t() | nil
  def get(%__MODULE__{nodes: nodes}, id), do: Map.get(nodes, id)

  @doc "Store (insert or replace) a node in the tree."
  @spec put(t(), Node.t()) :: t()
  def put(%__MODULE__{nodes: nodes} = tree, %Node{id: id} = node) do
    %{tree | nodes: Map.put(nodes, id, node)}
  end

  @doc """
  Append a new child node to `parent_id` with the given `operation` and `state`.
  Returns `{updated_tree, child_id}`.
  """
  @spec add_child(t(), integer(), atom(), map()) :: {t(), integer()}
  def add_child(%__MODULE__{next_id: next_id} = tree, parent_id, operation, state) do
    parent = get(tree, parent_id)

    child = %Node{
      id: next_id,
      state: state,
      operation: operation,
      parent: parent_id,
      depth: parent.depth + 1
    }

    updated_parent = %{parent | children: parent.children ++ [next_id]}

    tree =
      tree
      |> put(updated_parent)
      |> put(child)

    {%{tree | next_id: next_id + 1}, next_id}
  end
end
