defmodule OptimalSystemAgent.Store.Task do
  @moduledoc """
  Ecto schema for the `task_queue` table.

  Maps 1:1 to the migration in `20260227020000_create_task_queue.exs`.
  Provides changeset validation and conversion helpers between DB records
  (string status) and in-memory task maps (atom status).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @valid_statuses ~w(pending leased completed failed)

  schema "task_queue" do
    field :task_id, :string
    field :agent_id, :string
    field :payload, :map, default: %{}
    field :status, :string, default: "pending"
    field :leased_until, :utc_datetime_usec
    field :leased_by, :string
    field :result, :map
    field :error, :string
    field :attempts, :integer, default: 0
    field :max_attempts, :integer, default: 3
    field :completed_at, :utc_datetime_usec
    timestamps()
  end

  @required [:task_id, :agent_id]
  @optional [:payload, :status, :leased_until, :leased_by, :result, :error,
             :attempts, :max_attempts, :completed_at]

  @doc "Build a changeset for inserting or updating a task."
  def changeset(task \\ %__MODULE__{}, attrs) do
    task
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
    |> validate_number(:max_attempts, greater_than: 0)
    |> unique_constraint(:task_id)
  end

  @doc "Convert a DB record to the in-memory task map used by TaskQueue GenServer."
  @spec to_map(%__MODULE__{}) :: map()
  def to_map(%__MODULE__{} = record) do
    %{
      task_id: record.task_id,
      agent_id: record.agent_id,
      payload: record.payload || %{},
      status: status_to_atom(record.status),
      leased_until: to_datetime(record.leased_until),
      leased_by: record.leased_by,
      result: record.result,
      error: record.error,
      attempts: record.attempts,
      max_attempts: record.max_attempts,
      created_at: to_datetime(record.inserted_at),
      completed_at: to_datetime(record.completed_at)
    }
  end

  @doc "Convert an in-memory task map to DB-compatible attrs (strings for status)."
  @spec from_map(map()) :: map()
  def from_map(task_map) when is_map(task_map) do
    %{
      task_id: task_map[:task_id] || task_map["task_id"],
      agent_id: task_map[:agent_id] || task_map["agent_id"],
      payload: task_map[:payload] || task_map["payload"] || %{},
      status: status_to_string(task_map[:status] || task_map["status"] || :pending),
      leased_until: task_map[:leased_until] || task_map["leased_until"],
      leased_by: task_map[:leased_by] || task_map["leased_by"],
      result: task_map[:result] || task_map["result"],
      error: task_map[:error] || task_map["error"],
      attempts: task_map[:attempts] || task_map["attempts"] || 0,
      max_attempts: task_map[:max_attempts] || task_map["max_attempts"] || 3,
      completed_at: task_map[:completed_at] || task_map["completed_at"]
    }
  end

  # ── Status Conversion ────────────────────────────────────────────

  @doc false
  def status_to_atom("pending"), do: :pending
  def status_to_atom("leased"), do: :leased
  def status_to_atom("completed"), do: :completed
  def status_to_atom("failed"), do: :failed
  def status_to_atom(atom) when is_atom(atom), do: atom

  @doc false
  def to_datetime(%DateTime{} = dt), do: dt
  def to_datetime(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")
  def to_datetime(nil), do: nil

  @doc false
  def status_to_string(:pending), do: "pending"
  def status_to_string(:leased), do: "leased"
  def status_to_string(:completed), do: "completed"
  def status_to_string(:failed), do: "failed"
  def status_to_string(s) when is_binary(s), do: s
end
