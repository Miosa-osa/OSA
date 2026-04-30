defmodule OptimalSystemAgent.Agent.Strategies.MCTS.Simulation do
  @moduledoc """
  Core MCTS algorithms: selection (UCT), expansion, simulation/rollout,
  backpropagation, operation application, and heuristic scoring.
  """

  alias OptimalSystemAgent.Agent.Strategies.MCTS.{Node, Tree}

  @exploration_constant :math.sqrt(2)

  @operations [
    :decompose,
    :analyze,
    :synthesize,
    :compare,
    :abstract,
    :specialize,
    :verify,
    :refute,
    :transform,
    :evaluate
  ]

  @default_max_depth 20

  # ── SELECT: walk down tree using UCT ─────────────────────────────

  @doc "Return the leaf node ID to expand next, chosen by UCT traversal from `node_id`."
  @spec select(Tree.t(), integer()) :: integer()
  def select(tree, node_id) do
    node = Tree.get(tree, node_id)

    cond do
      not node.expanded? ->
        node_id

      node.children == [] ->
        node_id

      true ->
        best_child_id =
          Enum.max_by(node.children, fn child_id ->
            child = Tree.get(tree, child_id)
            uct(child, node.visits)
          end)

        select(tree, best_child_id)
    end
  end

  # ── UCT formula ──────────────────────────────────────────────────

  @doc false
  @spec uct(Node.t(), integer()) :: float() | :infinity
  def uct(%Node{visits: 0}, _parent_visits), do: :infinity

  def uct(%Node{visits: visits, wins: wins}, parent_visits) do
    exploitation = wins / visits
    exploration = @exploration_constant * :math.sqrt(:math.log(parent_visits) / visits)
    exploitation + exploration
  end

  # ── EXPAND: add child nodes for untried operations ───────────────

  @doc """
  Expand `node_id` by adding one child per untried operation.
  Returns `{updated_tree, child_id}` where `child_id` is a randomly selected
  new child to simulate from (or `node_id` itself at max depth).
  """
  @spec expand(Tree.t(), integer(), non_neg_integer()) :: {Tree.t(), integer()}
  def expand(tree, node_id, max_depth) do
    node = Tree.get(tree, node_id)

    if node.depth >= max_depth do
      tree = Tree.put(tree, %{node | expanded?: true})
      {tree, node_id}
    else
      existing_ops =
        MapSet.new(
          Enum.map(node.children, fn cid ->
            Tree.get(tree, cid).operation
          end)
        )

      untried = Enum.reject(@operations, &MapSet.member?(existing_ops, &1))

      {tree, child_ids} =
        Enum.reduce(untried, {tree, []}, fn op, {t, ids} ->
          child_state = apply_operation(node.state, op)
          {t2, cid} = Tree.add_child(t, node_id, op, child_state)
          {t2, [cid | ids]}
        end)

      tree = Tree.put(tree, %{Tree.get(tree, node_id) | expanded?: true})

      selected =
        case child_ids do
          [] -> node_id
          ids -> Enum.random(ids)
        end

      {tree, selected}
    end
  end

  # ── SIMULATE: random rollout to terminal state ───────────────────

  @doc "Run a random rollout from `node_id` and return a score in [0.0, 1.0]."
  @spec simulate(Tree.t(), integer(), non_neg_integer(), (map() -> float()) | nil) :: float()
  def simulate(tree, node_id, max_depth, scorer) do
    node = Tree.get(tree, node_id)
    rollout(node.state, node.depth, max_depth, scorer)
  end

  defp rollout(state, depth, max_depth, scorer) do
    if depth >= max_depth or terminal?(state) do
      score_state(state, scorer)
    else
      op = Enum.random(@operations)
      new_state = apply_operation(state, op)
      rollout(new_state, depth + 1, max_depth, scorer)
    end
  end

  # ── BACKPROPAGATE: update wins/visits up to root ─────────────────

  @doc "Propagate `score` from `node_id` up to the root, incrementing visits and wins."
  @spec backpropagate(Tree.t(), integer(), float()) :: Tree.t()
  def backpropagate(tree, node_id, score) do
    node = Tree.get(tree, node_id)
    updated = %{node | visits: node.visits + 1, wins: node.wins + score}
    tree = Tree.put(tree, updated)

    case updated.parent do
      nil -> tree
      parent_id -> backpropagate(tree, parent_id, score)
    end
  end

  # ── Operation application ────────────────────────────────────────

  @doc """
  Apply `operation` to `state`, returning an updated state with the operation
  appended to `reasoning` and `insights`, and `depth` incremented.
  """
  @spec apply_operation(map(), atom()) :: map()
  def apply_operation(state, :decompose),
    do: append(state, :decompose, "Decomposed: identified sub-components of the problem")

  def apply_operation(state, :analyze),
    do: append(state, :analyze, "Analyzed: examined structure and relationships")

  def apply_operation(state, :synthesize),
    do: append(state, :synthesize, "Synthesized: combined partial results")

  def apply_operation(state, :compare),
    do: append(state, :compare, "Compared: evaluated alternatives and trade-offs")

  def apply_operation(state, :abstract),
    do: append(state, :abstract, "Abstracted: generalized to find broader patterns")

  def apply_operation(state, :specialize),
    do: append(state, :specialize, "Specialized: applied general principles to specific case")

  def apply_operation(state, :verify),
    do: append(state, :verify, "Verified: checked correctness and consistency")

  def apply_operation(state, :refute),
    do: append(state, :refute, "Refuted: found weaknesses or counterexamples")

  def apply_operation(state, :transform),
    do: append(state, :transform, "Transformed: reframed the problem representation")

  def apply_operation(state, :evaluate),
    do: append(state, :evaluate, "Evaluated: assessed quality and feasibility")

  defp append(state, op, insight) do
    %{
      state
      | reasoning: state.reasoning ++ [op],
        insights: state.insights ++ [insight],
        depth: state.depth + 1
    }
  end

  # ── Scoring ──────────────────────────────────────────────────────

  defp terminal?(state), do: length(state.reasoning) >= @default_max_depth

  defp score_state(state, nil), do: heuristic_score(state)
  defp score_state(state, scorer) when is_function(scorer, 1), do: scorer.(state)

  @doc """
  Heuristic scoring function for terminal states.

  Scores 0.0-1.0 based on:
  - Operation diversity (unique operations used)
  - Reasoning depth (longer chains = more thorough)
  - Structural quality (presence of key operations)
  - Coherence (penalty for immediate repetition)
  """
  @spec heuristic_score(map()) :: float()
  def heuristic_score(state) do
    ops = state.reasoning

    if ops == [] do
      0.0
    else
      unique_count = ops |> Enum.uniq() |> length()
      diversity = unique_count / length(@operations)

      depth_score = min(length(ops) / @default_max_depth, 1.0)

      has_verify = :verify in ops
      has_synthesize = :synthesize in ops
      has_evaluate = :evaluate in ops
      has_decompose = :decompose in ops

      structure_bonus =
        Enum.count([has_verify, has_synthesize, has_evaluate, has_decompose], & &1) / 4

      repetition_count =
        ops
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.count(fn [a, b] -> a == b end)

      repetition_penalty =
        if length(ops) > 1, do: repetition_count / (length(ops) - 1), else: 0.0

      raw =
        0.3 * diversity +
          0.2 * depth_score +
          0.3 * structure_bonus +
          0.2 * (1.0 - repetition_penalty)

      max(0.0, min(1.0, raw))
    end
  end
end
