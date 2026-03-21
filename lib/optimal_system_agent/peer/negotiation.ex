defmodule OptimalSystemAgent.Peer.Negotiation do
  @moduledoc """
  Task Negotiation — agents can contest, counter-propose, and accept/reject
  task assignments instead of silently accepting whatever is dispatched.

  Negotiation is a first-class protocol for optimal task-to-agent matching.
  An orchestrator proposes an assignment; the assigned agent may accept silently
  or raise a counter-proposal naming a better-suited teammate. The orchestrator
  or original proposer reviews counter-proposals and accepts or rejects them.

  ## Negotiation lifecycle

    1. `propose_assignment/3`  — orchestrator proposes task→agent.
    2. Assigned agent may call `counter_propose/3` within the timeout window.
    3. Proposer calls `accept_assignment/2` or `reject_assignment/2`.
    4. If no counter-proposal arrives within `@auto_accept_ms`, the assignment
       is auto-accepted and a PubSub notification fires.

  ## ETS storage

  Negotiations stored in `:osa_peer_negotiations`:
  `{negotiation_id, negotiation_record}`.
  History is append-only inside the record; no rows are deleted during the run.
  """

  require Logger

  @negotiations_table :osa_peer_negotiations
  @auto_accept_ms 30_000

  # ---------------------------------------------------------------------------
  # Structs
  # ---------------------------------------------------------------------------

  @type status ::
          :proposed
          | :countered
          | :accepted
          | :rejected
          | :auto_accepted

  @enforce_keys [:id, :task_id, :proposed_agent, :proposed_by, :proposed_at, :status]
  defstruct [
    :id,
    :task_id,
    :proposed_agent,
    :proposed_by,
    :proposed_at,
    :counter_agent,
    :counter_reason,
    :countered_at,
    :resolved_at,
    :auto_accept_ref,
    status: :proposed,
    history: [],
    reason: nil
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          task_id: String.t(),
          proposed_agent: String.t(),
          proposed_by: String.t(),
          proposed_at: DateTime.t(),
          counter_agent: String.t() | nil,
          counter_reason: String.t() | nil,
          countered_at: DateTime.t() | nil,
          resolved_at: DateTime.t() | nil,
          auto_accept_ref: reference() | nil,
          status: status(),
          history: [map()],
          reason: String.t() | nil
        }

  # ---------------------------------------------------------------------------
  # ETS bootstrap
  # ---------------------------------------------------------------------------

  @doc "Create the negotiations ETS table."
  def init_table do
    :ets.new(@negotiations_table, [:named_table, :public, :set])
    :ok
  rescue
    ArgumentError -> :ok
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Propose a task assignment.

  `task_id` identifies the task (must exist in team task list).
  `proposed_agent` is the agent being assigned.
  `reason` is an optional justification string.

  Starts the auto-accept timer. Returns `{:ok, negotiation}`.
  """
  @spec propose_assignment(
          task_id :: String.t(),
          proposed_agent :: String.t(),
          opts :: keyword()
        ) :: {:ok, t()}
  def propose_assignment(task_id, proposed_agent, opts \\ []) do
    proposed_by = Keyword.get(opts, :proposed_by, "orchestrator")
    reason = Keyword.get(opts, :reason)
    timeout_ms = Keyword.get(opts, :timeout_ms, @auto_accept_ms)

    negotiation_id = "neg_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    # Start the auto-accept timer. The timer message goes to the current process
    # (orchestrator / caller). The caller must handle {:auto_accept, negotiation_id}.
    # For fire-and-forget use, pass :timer_pid option with the target pid.
    timer_target = Keyword.get(opts, :timer_pid, self())
    auto_ref = Process.send_after(timer_target, {:auto_accept, negotiation_id}, timeout_ms)

    negotiation = %__MODULE__{
      id: negotiation_id,
      task_id: task_id,
      proposed_agent: proposed_agent,
      proposed_by: proposed_by,
      proposed_at: DateTime.utc_now(),
      status: :proposed,
      reason: reason,
      auto_accept_ref: auto_ref,
      history: [
        %{
          event: :proposed,
          agent: proposed_agent,
          by: proposed_by,
          at: DateTime.utc_now(),
          reason: reason
        }
      ]
    }

    store(negotiation)

    # Notify the proposed agent
    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:peer:negotiation:#{proposed_agent}",
      {:task_proposed, negotiation}
    )

    Logger.info(
      "[Peer.Negotiation] #{proposed_by} proposed task #{task_id} → #{proposed_agent} " <>
        "(neg #{negotiation_id}, auto-accept in #{timeout_ms}ms)"
    )

    {:ok, negotiation}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Counter-propose a better-suited agent for a task.

  The agent receiving the proposal may suggest a different teammate instead.
  `counter_agent` is the suggested replacement.
  `reason` explains why the counter-agent is better suited.

  Returns `{:ok, updated_negotiation}` or `{:error, reason}`.
  """
  @spec counter_propose(
          negotiation_id :: String.t(),
          counter_agent :: String.t(),
          reason :: String.t()
        ) :: {:ok, t()} | {:error, String.t()}
  def counter_propose(negotiation_id, counter_agent, reason) do
    with {:ok, negotiation} <- fetch(negotiation_id),
         :ok <- assert_status(negotiation, [:proposed]) do
      # Cancel auto-accept — a counter is a live response
      cancel_auto_accept(negotiation.auto_accept_ref)

      updated = %{
        negotiation
        | status: :countered,
          counter_agent: counter_agent,
          counter_reason: reason,
          countered_at: DateTime.utc_now(),
          history:
            negotiation.history ++
              [
                %{
                  event: :countered,
                  agent: counter_agent,
                  by: negotiation.proposed_agent,
                  at: DateTime.utc_now(),
                  reason: reason
                }
              ]
      }

      store(updated)

      # Notify the original proposer of the counter
      Phoenix.PubSub.broadcast(
        OptimalSystemAgent.PubSub,
        "osa:peer:negotiation:#{negotiation.proposed_by}",
        {:task_countered, updated}
      )

      Logger.info(
        "[Peer.Negotiation] #{negotiation.proposed_agent} countered neg #{negotiation_id} " <>
          "→ #{counter_agent}: #{reason}"
      )

      {:ok, updated}
    end
  end

  @doc """
  Accept a negotiation — assign the task to the current or counter-proposed agent.

  If the negotiation has a counter-proposal, the counter agent becomes the assignee.
  Otherwise, the originally proposed agent is accepted.

  Returns `{:ok, negotiation}` with `status: :accepted` and `assigned_agent` in metadata.
  """
  @spec accept_assignment(negotiation_id :: String.t(), opts :: keyword()) ::
          {:ok, t()} | {:error, String.t()}
  def accept_assignment(negotiation_id, opts \\ []) do
    with {:ok, negotiation} <- fetch(negotiation_id),
         :ok <- assert_status(negotiation, [:proposed, :countered]) do
      cancel_auto_accept(negotiation.auto_accept_ref)

      assigned = negotiation.counter_agent || negotiation.proposed_agent

      updated = %{
        negotiation
        | status: :accepted,
          resolved_at: DateTime.utc_now(),
          history:
            negotiation.history ++
              [
                %{
                  event: :accepted,
                  agent: assigned,
                  by: Keyword.get(opts, :by, "orchestrator"),
                  at: DateTime.utc_now()
                }
              ]
      }

      store(updated)

      Phoenix.PubSub.broadcast(
        OptimalSystemAgent.PubSub,
        "osa:peer:negotiation:#{assigned}",
        {:task_accepted, updated}
      )

      Logger.info("[Peer.Negotiation] neg #{negotiation_id} accepted — assigned to #{assigned}")
      {:ok, updated}
    end
  end

  @doc """
  Reject an assignment outright — the task will not be assigned to anyone via this negotiation.

  `reason` explains the rejection. The proposer should re-evaluate task decomposition.
  """
  @spec reject_assignment(negotiation_id :: String.t(), reason :: String.t()) ::
          {:ok, t()} | {:error, String.t()}
  def reject_assignment(negotiation_id, reason \\ "rejected") do
    with {:ok, negotiation} <- fetch(negotiation_id),
         :ok <- assert_status(negotiation, [:proposed, :countered]) do
      cancel_auto_accept(negotiation.auto_accept_ref)

      updated = %{
        negotiation
        | status: :rejected,
          resolved_at: DateTime.utc_now(),
          reason: reason,
          history:
            negotiation.history ++
              [
                %{event: :rejected, by: "orchestrator", at: DateTime.utc_now(), reason: reason}
              ]
      }

      store(updated)

      Phoenix.PubSub.broadcast(
        OptimalSystemAgent.PubSub,
        "osa:peer:negotiation:#{negotiation.proposed_agent}",
        {:task_rejected, updated}
      )

      Logger.info("[Peer.Negotiation] neg #{negotiation_id} rejected: #{reason}")
      {:ok, updated}
    end
  end

  @doc """
  Handle an auto-accept timer message `{:auto_accept, negotiation_id}`.

  Call from whatever process owns the timer (typically the orchestrator's
  `handle_info/2`). Idempotent — silently ignores already-resolved negotiations.
  """
  @spec handle_auto_accept(negotiation_id :: String.t()) :: {:ok, t()} | :already_resolved
  def handle_auto_accept(negotiation_id) do
    case fetch(negotiation_id) do
      {:ok, %{status: :proposed} = negotiation} ->
        assigned = negotiation.proposed_agent

        updated = %{
          negotiation
          | status: :auto_accepted,
            resolved_at: DateTime.utc_now(),
            history:
              negotiation.history ++
                [
                  %{event: :auto_accepted, agent: assigned, at: DateTime.utc_now()}
                ]
        }

        store(updated)

        Phoenix.PubSub.broadcast(
          OptimalSystemAgent.PubSub,
          "osa:peer:negotiation:#{assigned}",
          {:task_auto_accepted, updated}
        )

        Logger.info(
          "[Peer.Negotiation] neg #{negotiation_id} auto-accepted → #{assigned} (no counter received)"
        )

        {:ok, updated}

      {:ok, _} ->
        :already_resolved

      {:error, _} ->
        :already_resolved
    end
  end

  @doc "Retrieve a negotiation by ID."
  @spec get_negotiation(String.t()) :: t() | nil
  def get_negotiation(negotiation_id) do
    case fetch(negotiation_id) do
      {:ok, n} -> n
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp store(%__MODULE__{} = n) do
    :ets.insert(@negotiations_table, {n.id, n})
  rescue
    _ -> :ok
  end

  defp fetch(negotiation_id) do
    case :ets.lookup(@negotiations_table, negotiation_id) do
      [{_, n}] -> {:ok, n}
      [] -> {:error, "Negotiation #{negotiation_id} not found"}
    end
  rescue
    _ -> {:error, "Negotiation table unavailable"}
  end

  defp assert_status(%{status: status}, allowed) do
    if status in allowed do
      :ok
    else
      {:error, "Negotiation is #{status}, expected one of: #{inspect(allowed)}"}
    end
  end

  defp cancel_auto_accept(nil), do: :ok
  defp cancel_auto_accept(ref), do: Process.cancel_timer(ref)
end
