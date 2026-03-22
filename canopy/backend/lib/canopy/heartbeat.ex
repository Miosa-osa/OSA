defmodule Canopy.Heartbeat do
  @moduledoc """
  Executes a heartbeat run for an agent.

  Lifecycle:
    1. Resolve adapter from agent config
    2. Create session record
    3. Optionally create git worktree execution workspace
    4. Execute heartbeat via adapter — streams events
    5. Persist each event to DB and broadcast to PubSub
    6. Update session with final token counts and cost
    7. Record cost with BudgetEnforcer
    8. Cleanup workspace and reset agent status
  """
  require Logger

  alias Canopy.Repo
  alias Canopy.Schemas.{Agent, Session, SessionEvent}
  import Ecto.Changeset, only: [change: 2]

  @doc """
  Run a heartbeat for the given agent.

  ## Options
    - `:schedule_id` — UUID of the triggering schedule (optional)
    - `:context`     — instruction string passed to the adapter (default: generic heartbeat prompt)
  """
  def run(agent_id, opts \\ []) do
    schedule_id = opts[:schedule_id]
    context = opts[:context] || "Perform your scheduled heartbeat."

    with %Agent{} = agent <- Repo.get(Agent, agent_id),
         {:ok, adapter_mod} <- Canopy.Adapter.resolve(agent.adapter) do
      session = create_session!(agent, schedule_id)

      agent |> change(status: "working") |> Repo.update!()

      broadcast_workspace(agent, %{
        event: "run.started",
        agent_id: agent.id,
        session_id: session.id,
        agent_name: agent.name
      })

      workspace = resolve_workspace(agent)

      params = %{
        "context" => context,
        "model" => agent.model,
        "working_dir" => workspace.path,
        "workspace_path" => workspace.path,
        "url" => agent.config["url"]
      }

      totals = execute_and_stream(adapter_mod, params, session, agent)

      complete_session!(session, totals)
      agent |> change(status: "idle") |> Repo.update!()

      cleanup_workspace(workspace)

      if totals.cost > 0 do
        Canopy.BudgetEnforcer.record_cost(%{
          agent_id: agent.id,
          session_id: session.id,
          model: agent.model,
          tokens_input: totals.input,
          tokens_output: totals.output,
          cost_cents: totals.cost
        })
      end

      broadcast_workspace(agent, %{
        event: "run.completed",
        agent_id: agent.id,
        session_id: session.id,
        agent_name: agent.name,
        cost_cents: totals.cost
      })

      {:ok, session.id}
    else
      nil -> {:error, :agent_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp create_session!(agent, schedule_id) do
    %Session{}
    |> Session.changeset(%{
      agent_id: agent.id,
      schedule_id: schedule_id,
      model: agent.model,
      status: "active",
      started_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp complete_session!(session, totals) do
    session
    |> change(%{
      status: "completed",
      completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      tokens_input: totals.input,
      tokens_output: totals.output,
      cost_cents: totals.cost
    })
    |> Repo.update!()
  end

  # Returns a map with :path and :strategy keys.
  defp resolve_workspace(agent) do
    if agent.config["workspace_strategy"] == "shared" do
      %{path: ".", strategy: :shared}
    else
      case Canopy.ExecutionWorkspace.create(".", strategy: :worktree) do
        {:ok, ws} -> ws
        {:error, _reason} -> %{path: ".", strategy: :shared}
      end
    end
  end

  defp cleanup_workspace(%{strategy: :shared}), do: :ok

  defp cleanup_workspace(workspace) do
    Canopy.ExecutionWorkspace.cleanup(workspace)
  end

  defp execute_and_stream(adapter_mod, params, session, agent) do
    try do
      adapter_mod.execute_heartbeat(params)
      |> Enum.reduce(%{input: 0, output: 0, cost: 0}, fn event, acc ->
        persist_event!(event, session)

        Canopy.EventBus.broadcast(
          Canopy.EventBus.session_topic(session.id),
          %{
            event: event.event_type,
            data: event.data,
            session_id: session.id,
            agent_id: agent.id
          }
        )

        tokens = event[:tokens] || 0
        cost = estimate_cost(tokens, agent.model)

        %{acc | input: acc.input + tokens, cost: acc.cost + cost}
      end)
    rescue
      e ->
        Logger.error(
          "[Heartbeat] Execution error for agent #{agent.id}: #{Exception.message(e)}\n" <>
            Exception.format_stacktrace(__STACKTRACE__)
        )

        %{input: 0, output: 0, cost: 0}
    end
  end

  defp persist_event!(event, session) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %SessionEvent{}
    |> SessionEvent.changeset(%{
      session_id: session.id,
      event_type: event.event_type,
      data: event.data,
      tokens: event[:tokens] || 0,
      inserted_at: now
    })
    |> Repo.insert!()
  end

  defp broadcast_workspace(agent, payload) do
    Canopy.EventBus.broadcast(Canopy.EventBus.workspace_topic(agent.workspace_id), payload)
  end

  # Rough cost estimation in cents per 1K tokens.
  # Input/output are billed differently in practice; this uses a blended rate
  # for simplicity. Adjust when per-direction token counts are available.
  defp estimate_cost(tokens, model) do
    rate =
      case model do
        m when m in ["claude-opus-4-6", "claude-opus-4-20250514"] -> 1.5
        m when m in ["claude-sonnet-4-6", "claude-sonnet-4-20250514"] -> 0.3
        m when m in ["claude-haiku-4-5", "claude-haiku-4-5-20251001"] -> 0.08
        _ -> 0.3
      end

    round(tokens / 1000 * rate)
  end
end
