defmodule OptimalSystemAgent.Runtime.SessionTeardown do
  @moduledoc """
  The single place a session's per-session state is released.

  OSA accumulated seven per-session cleanup functions that were correct,
  tested — and **never called from production code**. Each one owned a slice of
  ETS keyed by `session_id`, so every session that ever ran left its slice
  behind for the life of the daemon. `run/1` is the teardown path that finally
  calls them, wired into `Runtime.SessionManager.untrack_session/1` (reached
  from `stop_session/1`) so a session's state dies with the session.

  ## What is torn down

  Only **ephemeral, derived, in-memory** state — every entry below is
  reconstructed from the transcript on the next turn, so dropping it can never
  lose user-visible information:

    * `Agent.Context.WorldState.reset/1` — the worst of the seven: its ledger
      row holds not just per-section digests but the rendered **payload text**
      of every world-state section emitted this session. Retiring it is the
      single largest per-session reclaim here. Teardown ONLY drops the ledger
      row; `assemble/3`, `invalidate/2` and the emit/diff semantics that
      `Agent.Context`'s hot path depends on are untouched.
    * `Agent.Safety.Guardian.reset/1` — block/pause counters.
    * `Agent.Loop.GoalTracker.reset/1` — the session's goal row.
    * `Agent.Loop.VerificationEvidence.reset/1` — collected evidence.
    * `Tools.Registry.SkillTouch.reset/1` — per-session skill touches.
    * `Agent.CoordinatorMode.clear/1` — coordinator-mode flag.
    * `Agent.Loop.PermissionBroker.clear_session/1` — session-scoped allows.
      (Grants are session-scoped by definition, so they must not outlive it —
      this one is a correctness fix as much as a memory one.)
    * `Agent.Compactor.forget_session/1` — the session's persisted structured
      compaction summary. Like the permission grants above, this is a
      confidentiality fix first: the summary is verbatim conversation content
      and must not survive the session that produced it.

  ## What is deliberately NOT torn down

  Durable resume artifacts, which a later `/resume` of this same session id
  still needs and which have their own retention:

    * `Agent.Loop.ToolResultStorage.cleanup/1` — offloaded tool-result files the
      restored transcript still points at.
    * `Agent.Loop.Checkpoint.clear_rewind_checkpoints/1` — rewind targets.
    * `Agent.SessionPersistence` files — bounded by `purge_expired/0`.

  Deleting those on stop would turn a stop/resume cycle into data loss, which is
  strictly worse than the memory they hold.

  Every step is independently guarded: one raising cleanup must not stop the
  other six from running.
  """

  require Logger

  alias OptimalSystemAgent.Agent.AskUserMode
  alias OptimalSystemAgent.Agent.Compactor
  alias OptimalSystemAgent.Agent.Context.WorldState
  alias OptimalSystemAgent.Agent.CoordinatorMode
  alias OptimalSystemAgent.Agent.Loop.GoalTracker
  alias OptimalSystemAgent.Agent.Loop.PermissionBroker
  alias OptimalSystemAgent.Agent.Loop.VerificationEvidence
  alias OptimalSystemAgent.Agent.Safety.Guardian
  alias OptimalSystemAgent.Tools.Registry.SkillTouch

  @doc """
  Release every piece of ephemeral per-session state for `session_id`.

  Idempotent, safe on an unknown session, and never raises. Returns the list of
  steps that ran, so tests can assert coverage rather than trusting the list
  above to stay in sync.
  """
  @spec run(String.t() | nil) :: [atom()]
  def run(nil), do: []

  def run(session_id) when is_binary(session_id) do
    Enum.filter(steps(), fn {name, fun} -> safe(name, session_id, fun) end)
    |> Enum.map(fn {name, _} -> name end)
  end

  def run(_), do: []

  @doc """
  The teardown steps as `{name, fun}` pairs.

  Public so a test can assert that every zero-caller cleanup is actually wired
  in — the failure mode being fixed here is precisely a cleanup that exists and
  is never reached.
  """
  @spec steps() :: [{atom(), (String.t() -> any())}]
  def steps do
    [
      {:world_state, &WorldState.reset/1},
      {:guardian, &Guardian.reset/1},
      {:goal_tracker, &GoalTracker.reset/1},
      {:verification_evidence, &VerificationEvidence.reset/1},
      {:skill_touch, &SkillTouch.reset/1},
      {:coordinator_mode, &CoordinatorMode.clear/1},
      # The sticky `/ask-user` choice. Cleared with the session so a recycled
      # session id cannot inherit a stranger's "on" — the direction that would
      # let a run block on a question its operator never enabled.
      {:ask_user_mode, &AskUserMode.clear/1},
      {:permission_broker, &PermissionBroker.clear_session/1},
      {:compactor_summary, &Compactor.forget_session/1},
      # Staged-but-unabsorbed compaction spend. Dropping it loses at most the
      # last summarizer call of a dying session; LEAVING it would let a later
      # session that reused the id absorb — and be billed for — spend it never
      # made, which is the worse error for a figure we publish.
      {:side_spend, &OptimalSystemAgent.Agent.Loop.Accounting.forget_side_spend/1}
    ]
  end

  defp safe(name, session_id, fun) do
    fun.(session_id)
    true
  rescue
    e ->
      Logger.debug("[session_teardown] #{name} failed for #{session_id}: #{Exception.message(e)}")
      false
  catch
    _, _ -> false
  end
end
