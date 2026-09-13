defmodule OptimalSystemAgent.Security.AttackTree do
  @moduledoc """
  Evidence-guided attack tree (EGATS-lite).

  Difficulty assessment (TDA, which OSA already has) plus an evidence-guided
  attack tree beats simply adding more tools. This module is that tree: each vuln class is a node, UCB picks the
  next class to work, and TDA can flip the whole tree from exploit to explore.

  No live target. The agent records visits/wins; `select/1` names the next
  class. Basics-first bias: access-control and injection start with a prior
  so IDOR/SQLi get tried before exotic bugs.
  """

  alias OptimalSystemAgent.Security.TaskDifficultyAssessment

  @classes ~w(idor auth_bypass sqli xss command_injection ssrf csrf business_logic ssti xxe path_traversal)a

  @prior %{
    idor: 2.0,
    auth_bypass: 2.0,
    sqli: 1.5,
    xss: 1.2,
    business_logic: 1.5,
    command_injection: 1.0,
    ssrf: 1.0,
    csrf: 0.8,
    ssti: 0.6,
    xxe: 0.6,
    path_traversal: 0.8
  }

  @type class_node :: %{
          class: atom(),
          visits: non_neg_integer(),
          wins: non_neg_integer(),
          status: :pending | :active | :exhausted | :confirmed
        }

  @type tree :: %{nodes: %{atom() => class_node()}, total_visits: non_neg_integer()}

  @doc "A fresh tree with basics-first priors (visits seeded, wins zero)."
  @spec new() :: tree()
  def new do
    nodes =
      Map.new(@classes, fn class ->
        {class,
         %{
           class: class,
           visits: 0,
           wins: 0,
           status: :pending
         }}
      end)

    %{nodes: nodes, total_visits: 0}
  end

  @doc "UCB-1 selection with prior bonus. Skips exhausted nodes."
  @spec select(tree()) :: {:ok, atom(), tree()} | :done
  def select(%{nodes: nodes, total_visits: n} = tree) do
    open = Enum.filter(nodes, fn {_k, v} -> v.status != :exhausted end)

    case open do
      [] ->
        :done

      list ->
        {class, _} =
          Enum.max_by(list, fn {k, node} ->
            ucb(node, n) + Map.get(@prior, k, 0.0)
          end)

        node = nodes[class]
        updated = %{node | visits: node.visits + 1, status: :active}
        {:ok, class, %{tree | nodes: Map.put(nodes, class, updated), total_visits: n + 1}}
    end
  end

  @doc "Record a win (confirmed finding) or miss for a class."
  @spec record(tree(), atom(), :win | :miss | :exhausted) :: tree()
  def record(%{nodes: nodes} = tree, class, outcome) when is_atom(class) do
    case Map.get(nodes, class) do
      nil ->
        tree

      node ->
        node =
          case outcome do
            :win -> %{node | wins: node.wins + 1, status: :confirmed}
            :miss -> node
            :exhausted -> %{node | status: :exhausted}
          end

        %{tree | nodes: Map.put(nodes, class, node)}
    end
  end

  @doc """
  Ask TDA whether to keep exploiting the current class or explore another.
  Returns `{:exploit, class}` or `{:explore, next_class, tree}`.
  """
  @spec next(tree(), atom(), map()) ::
          {:exploit, atom()} | {:explore, atom(), tree()} | :done
  def next(tree, current, tda_opts) when is_atom(current) do
    case TaskDifficultyAssessment.assess(tda_opts) do
      {:ok, %{decision: :exploit}} ->
        {:exploit, current}

      {:ok, %{decision: :explore}} ->
        case select(tree) do
          {:ok, class, new_tree} -> {:explore, class, new_tree}
          :done -> :done
        end

      {:error, _} ->
        case select(tree) do
          {:ok, class, new_tree} -> {:explore, class, new_tree}
          :done -> :done
        end
    end
  end

  @doc "Snapshot for prompts: class, visits, wins, status."
  @spec render(tree()) :: String.t()
  def render(%{nodes: nodes, total_visits: n}) do
    rows =
      nodes
      |> Enum.sort_by(fn {_k, v} -> {-v.wins, -v.visits} end)
      |> Enum.map(fn {k, v} ->
        "  #{k}  visits=#{v.visits} wins=#{v.wins} #{v.status}"
      end)
      |> Enum.join("\n")

    "<attack_tree visits=#{n}>\n#{rows}\n</attack_tree>"
  end

  defp ucb(%{visits: 0}, _n), do: 1.0e9

  defp ucb(%{visits: visits, wins: wins}, n) do
    mean = wins / max(visits, 1)
    mean + :math.sqrt(2 * :math.log(max(n, 1)) / visits)
  end
end
