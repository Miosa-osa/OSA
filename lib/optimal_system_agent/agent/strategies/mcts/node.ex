defmodule OptimalSystemAgent.Agent.Strategies.MCTS.Node do
  @moduledoc """
  Tree node struct for the MCTS search tree.

  Each node represents a partial reasoning state reached by applying
  a sequence of operations. `wins` and `visits` are updated by
  backpropagation after each simulation.
  """

  @type t :: %__MODULE__{
          id: integer(),
          state: map(),
          operation: atom() | nil,
          visits: integer(),
          wins: float(),
          children: [integer()],
          parent: integer() | nil,
          depth: non_neg_integer(),
          expanded?: boolean()
        }

  defstruct [
    :id,
    :state,
    :operation,
    :parent,
    depth: 0,
    visits: 0,
    wins: 0.0,
    children: [],
    expanded?: false
  ]
end
