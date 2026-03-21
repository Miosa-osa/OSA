defmodule OptimalSystemAgent.Decisions.Pivot do
  @moduledoc """
  Atomic pivot chains for decision graph reversals.

  A pivot represents the moment an agent or team recognises that a prior
  decision was wrong, incomplete, or superseded by new information. Rather
  than erasing history, a pivot creates an explicit audit trail:

      old_decision  -[:supersedes]->  revisit_node
      revisit_node  -[:leads_to]->    observation_node
      observation_node -[:leads_to]-> new_decision

  The original node is marked `:superseded` so it remains queryable but
  is no longer considered active.

  ## Atomicity

  All four operations (status update + 3 node inserts + 3 edge inserts) are
  grouped in a single Ecto.Multi so that a partial failure leaves no dangling
  nodes. On error the entire chain is rolled back.
  """

  require Logger

  alias OptimalSystemAgent.Decisions.Graph
  alias OptimalSystemAgent.Store.{Repo, DecisionNode, DecisionEdge}
  alias OptimalSystemAgent.Utils.ID
  import Ecto.Multi

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Execute a pivot from an existing decision to a new one.

  Parameters:
    - `old_node_id`        — ID of the decision being superseded
    - `reason`             — human-readable rationale for the pivot
    - `new_decision_attrs` — attrs map for the replacement decision node;
                             must include `:title` and will inherit `:team_id`,
                             `:session_id`, `:agent_name` from the old node
                             unless overridden

  Returns `{:ok, %{new_decision: node_map, chain: [node_map]}}` on success,
  or `{:error, step, reason, changes}` on failure.
  """
  @spec create_pivot(String.t(), String.t(), map()) ::
          {:ok, %{new_decision: map(), chain: [map()]}}
          | {:error, atom(), term(), map()}
  def create_pivot(old_node_id, reason, new_decision_attrs)
      when is_binary(old_node_id) and is_binary(reason) do
    case Graph.get_node(old_node_id) do
      {:error, :not_found} ->
        {:error, :fetch_old_node, :not_found, %{}}

      {:ok, old_node} ->
        revisit_id = ID.generate("dg")
        observation_id = ID.generate("dg")
        new_decision_id = ID.generate("dg")

        edge_supersedes_id = ID.generate("de")
        edge_leads_to_obs_id = ID.generate("de")
        edge_leads_to_new_id = ID.generate("de")

        shared = %{
          team_id: old_node.team_id,
          session_id: Map.get(new_decision_attrs, :session_id, old_node.session_id),
          agent_name: Map.get(new_decision_attrs, :agent_name, old_node.agent_name)
        }

        revisit_params =
          %{
            id: revisit_id,
            type: :revisit,
            title: "Revisit: #{old_node.title}",
            description: reason,
            status: :active,
            confidence: old_node.confidence,
            metadata: %{pivoted_from: old_node_id}
          }
          |> Map.merge(shared)

        observation_params =
          %{
            id: observation_id,
            type: :observation,
            title: "Observation: #{String.slice(reason, 0, 80)}",
            description: reason,
            status: :active,
            confidence: old_node.confidence,
            metadata: %{pivot_reason: reason}
          }
          |> Map.merge(shared)

        new_decision_params =
          new_decision_attrs
          |> Map.put(:id, new_decision_id)
          |> Map.put(:type, :decision)
          |> Map.put_new(:status, :active)
          |> Map.put_new(:confidence, 1.0)
          |> Map.put_new(:metadata, %{})
          |> Map.merge(shared)

        multi =
          new()
          # 1. Mark old node as superseded
          |> run(:supersede_old, fn _repo, _changes ->
            update_node_status(old_node_id, :superseded)
          end)
          # 2. Create revisit node
          |> run(:revisit_node, fn _repo, _changes ->
            %DecisionNode{}
            |> DecisionNode.changeset(revisit_params)
            |> Repo.insert()
          end)
          # 3. Create observation node
          |> run(:observation_node, fn _repo, _changes ->
            %DecisionNode{}
            |> DecisionNode.changeset(observation_params)
            |> Repo.insert()
          end)
          # 4. Create new decision node
          |> run(:new_decision_node, fn _repo, _changes ->
            %DecisionNode{}
            |> DecisionNode.changeset(new_decision_params)
            |> Repo.insert()
          end)
          # 5. Edge: old_decision -[:supersedes]-> revisit
          |> run(:edge_supersedes, fn _repo, _changes ->
            %DecisionEdge{}
            |> DecisionEdge.changeset(%{
              id: edge_supersedes_id,
              source_id: old_node_id,
              target_id: revisit_id,
              type: :supersedes,
              rationale: reason,
              weight: 1.0
            })
            |> Repo.insert()
          end)
          # 6. Edge: revisit -[:leads_to]-> observation
          |> run(:edge_leads_to_obs, fn _repo, _changes ->
            %DecisionEdge{}
            |> DecisionEdge.changeset(%{
              id: edge_leads_to_obs_id,
              source_id: revisit_id,
              target_id: observation_id,
              type: :leads_to,
              rationale: reason,
              weight: 1.0
            })
            |> Repo.insert()
          end)
          # 7. Edge: observation -[:leads_to]-> new_decision
          |> run(:edge_leads_to_new, fn _repo, _changes ->
            %DecisionEdge{}
            |> DecisionEdge.changeset(%{
              id: edge_leads_to_new_id,
              source_id: observation_id,
              target_id: new_decision_id,
              type: :leads_to,
              rationale: "Pivot resolved",
              weight: 1.0
            })
            |> Repo.insert()
          end)

        case Repo.transaction(multi) do
          {:ok, changes} ->
            # Warm ETS cache for all new nodes and edges
            revisit_map = Graph.node_to_map(changes.revisit_node)
            obs_map = Graph.node_to_map(changes.observation_node)
            new_map = Graph.node_to_map(changes.new_decision_node)

            for node_map <- [revisit_map, obs_map, new_map] do
              send(self(), {:cache_dg_node, node_map})
            end

            for edge <- [
                  changes.edge_supersedes,
                  changes.edge_leads_to_obs,
                  changes.edge_leads_to_new
                ] do
              send(self(), {:cache_dg_edge, Graph.edge_to_map(edge)})
            end

            Logger.info(
              "[Decisions.Pivot] pivot complete: #{old_node_id} -> #{revisit_id} -> #{observation_id} -> #{new_decision_id}"
            )

            {:ok,
             %{
               new_decision: new_map,
               chain: [
                 changes.supersede_old,
                 revisit_map,
                 obs_map,
                 new_map
               ]
             }}

          {:error, step, reason, changes} ->
            Logger.warning("[Decisions.Pivot] pivot failed at step #{step}: #{Kernel.inspect(reason)}")
            {:error, step, reason, changes}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp update_node_status(node_id, status) do
    case Graph.update_node(node_id, %{status: status}) do
      {:ok, updated} -> {:ok, updated}
      {:error, reason} -> {:error, reason}
    end
  end
end
