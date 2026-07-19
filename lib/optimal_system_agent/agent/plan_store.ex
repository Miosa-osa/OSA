defmodule OptimalSystemAgent.Agent.PlanStore do
  @moduledoc """
  Pending plan index for the plan → approve → execute round-trip.

  When a session produces a plan (plan mode), the plan text and the original
  user input are stashed here keyed by session id. The TUI shows the plan in
  its `plan_review` dialog and then POSTs `plan_approve` / `plan_reject` /
  `plan_edit` to `/commands/execute`. Those handlers read this store to resume
  execution (approve) or revise (edit) without the client having to echo the
  full plan text back.

  ## Durability

  The plan TEXT itself is the source of truth on disk — a plain markdown file
  living alongside `Agent.ProgressLedger`'s progress file, in the same
  `~/.osa/sessions/` directory and using the same safe-id scheme:

      ~/.osa/sessions/<safe_id>.progress.md  # progress ledger
      ~/.osa/sessions/<safe_id>.plan.md      # plan file (this module)

  This means the plan survives context resets, session restarts, and the
  whole daemon bouncing — an investigative plan-mode turn re-invoked for the
  same session (e.g. via `Agent.PlanMode.edit/2`'s revise round-trip) can
  re-read and incrementally build on the existing draft instead of starting
  from a blank page (see `Context.plan_mode_block/1`).

  The ETS table is now only a *pending-approval index*: it records that a
  plan is awaiting a decision (the original user input + timestamp) so the
  `plan_approve` / `plan_reject` / `plan_edit` HTTP handlers know there is
  something to act on. `take/1` (approve) clears the pending marker but
  deliberately leaves the plan FILE on disk — it stays as a durable record
  even after the plan is approved and execution begins.

  Backed by a lazily-created public ETS table so the pending index survives
  across the stateless HTTP request that consumes it, mirroring `RunStore`'s
  pattern.
  """

  @table :osa_pending_plans

  @sessions_dir Path.expand("~/.osa/sessions")

  @type pending :: %{plan: String.t(), input: String.t(), created_at: DateTime.t()}

  # ---------------------------------------------------------------------------
  # Durable plan file — source of truth
  # ---------------------------------------------------------------------------

  @doc """
  Absolute path to a session's durable plan file.

  Uses the same safe-id scheme as `Agent.ProgressLedger` / `Agent.SessionPersistence`
  so the plan file sits next to the session's progress ledger and full-state JSON.
  """
  @spec plan_file_path(String.t()) :: String.t()
  def plan_file_path(session_id) when is_binary(session_id) do
    Path.join(@sessions_dir, "#{safe_id(session_id)}.plan.md")
  end

  @doc """
  Read the durable plan file directly, independent of the pending-approval
  index. Returns `{:ok, contents}` or `{:error, :not_found}`.
  """
  @spec read_plan_file(String.t()) :: {:ok, String.t()} | {:error, term()}
  def read_plan_file(session_id) when is_binary(session_id) do
    case File.read(plan_file_path(session_id)) do
      {:ok, contents} -> {:ok, contents}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def read_plan_file(_), do: {:error, :not_found}

  @doc """
  Write (replace) the durable plan file for a session. Creates the sessions
  directory if needed. This is the single write path plan text goes through —
  `put/3` calls it so the ETS index and the on-disk file never disagree.
  """
  @spec write_plan_file(String.t(), String.t()) :: :ok | {:error, term()}
  def write_plan_file(session_id, plan) when is_binary(session_id) and is_binary(plan) do
    File.mkdir_p!(@sessions_dir)
    File.write(plan_file_path(session_id), plan)
  end

  def write_plan_file(_, _), do: {:error, :invalid_args}

  # ---------------------------------------------------------------------------
  # Pending-approval index (ETS)
  # ---------------------------------------------------------------------------

  @doc """
  Stash the pending plan and the original user input for a session.

  Writes the plan text to the durable plan file (source of truth) and records
  a pending-approval marker (input + timestamp) in ETS.
  """
  @spec put(String.t(), String.t(), String.t()) :: :ok
  def put(session_id, plan, input)
      when is_binary(session_id) and is_binary(plan) and is_binary(input) do
    ensure_table()
    write_plan_file(session_id, plan)

    :ets.insert(
      @table,
      {session_id, %{input: input, created_at: DateTime.utc_now()}}
    )

    :ok
  end

  def put(_session_id, _plan, _input), do: :ok

  @doc """
  Read the pending plan for a session without removing it. The plan text is
  read live from disk (not cached in ETS), so an out-of-band edit to the plan
  file is always reflected. Returns `nil` if no plan is pending or the plan
  file is missing.
  """
  @spec get(String.t()) :: pending() | nil
  def get(session_id) when is_binary(session_id) do
    ensure_table()

    case :ets.lookup(@table, session_id) do
      [{^session_id, %{input: input, created_at: created_at}}] ->
        case read_plan_file(session_id) do
          {:ok, plan} -> %{plan: plan, input: input, created_at: created_at}
          {:error, _} -> nil
        end

      [] ->
        nil
    end
  end

  def get(_), do: nil

  @doc """
  Read and atomically remove the pending-approval marker for a session.

  The plan FILE is intentionally left on disk — it remains a durable record
  after approval (execution references it) rather than being deleted.
  """
  @spec take(String.t()) :: pending() | nil
  def take(session_id) when is_binary(session_id) do
    pending = get(session_id)
    if pending, do: :ets.delete(@table, session_id)
    pending
  end

  def take(_), do: nil

  @doc "Drop any pending-approval marker for a session (plan file is kept)."
  @spec clear(String.t()) :: :ok
  def clear(session_id) when is_binary(session_id) do
    ensure_table()
    :ets.delete(@table, session_id)
    :ok
  end

  def clear(_), do: :ok

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @spec safe_id(String.t()) :: String.t()
  defp safe_id(session_id) do
    Regex.replace(~r/[^a-zA-Z0-9_\-]/, session_id, "_")
  end
end
