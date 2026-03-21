defmodule OptimalSystemAgent.Healing.Session do
  @moduledoc """
  Healing session struct and state machine.

  Represents a single autonomous self-healing lifecycle for a suspended agent.
  Transitions: :pending → :diagnosing → :fixing → :completed | :failed | :escalated

  Duration tracking is available via `duration_ms/1` once the session has a
  `completed_at` timestamp.
  """

  @type status ::
          :pending
          | :diagnosing
          | :fixing
          | :completed
          | :failed
          | :escalated

  @type t :: %__MODULE__{
          id: String.t(),
          agent_id: String.t(),
          status: status(),
          classification: map(),
          budget_usd: float(),
          timeout_ms: non_neg_integer(),
          max_attempts: pos_integer(),
          attempt_count: non_neg_integer(),
          diagnostician_pid: pid() | nil,
          fixer_pid: pid() | nil,
          diagnosis: map() | nil,
          fix_result: map() | nil,
          error: term() | nil,
          started_at: DateTime.t(),
          completed_at: DateTime.t() | nil,
          timer_ref: reference() | nil
        }

  defstruct [
    :id,
    :agent_id,
    :classification,
    :diagnostician_pid,
    :fixer_pid,
    :diagnosis,
    :fix_result,
    :error,
    :completed_at,
    :timer_ref,
    status: :pending,
    budget_usd: 0.50,
    timeout_ms: 300_000,
    max_attempts: 1,
    attempt_count: 0,
    started_at: nil
  ]

  # Valid state transitions
  @transitions %{
    pending: [:diagnosing, :failed, :escalated],
    diagnosing: [:fixing, :failed, :escalated],
    fixing: [:completed, :failed, :escalated],
    completed: [],
    failed: [:diagnosing],
    escalated: []
  }

  @doc "Create a new healing session."
  @spec new(String.t(), map(), keyword()) :: t()
  def new(agent_id, classification, opts \\ []) do
    %__MODULE__{
      id: generate_id(),
      agent_id: agent_id,
      status: :pending,
      classification: classification,
      budget_usd: Keyword.get(opts, :budget_usd, 0.50),
      timeout_ms: Keyword.get(opts, :timeout_ms, 300_000),
      max_attempts: Keyword.get(opts, :max_attempts, 1),
      attempt_count: 0,
      started_at: DateTime.utc_now()
    }
  end

  @doc """
  Transition the session to a new status.

  Returns `{:ok, updated_session}` on valid transitions,
  `{:error, :invalid_transition}` otherwise.
  """
  @spec transition(t(), status()) :: {:ok, t()} | {:error, :invalid_transition}
  def transition(%__MODULE__{status: current} = session, new_status) do
    allowed = Map.get(@transitions, current, [])

    if new_status in allowed do
      updated =
        session
        |> Map.put(:status, new_status)
        |> maybe_set_completed_at(new_status)

      {:ok, updated}
    else
      {:error, :invalid_transition}
    end
  end

  @doc "Returns elapsed milliseconds. Returns nil if session has not completed."
  @spec duration_ms(t()) :: non_neg_integer() | nil
  def duration_ms(%__MODULE__{started_at: start, completed_at: finish})
      when not is_nil(start) and not is_nil(finish) do
    DateTime.diff(finish, start, :millisecond)
  end

  def duration_ms(_session), do: nil

  @doc "Returns true if the session reached a terminal state."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: status in [:completed, :failed, :escalated]

  @doc "Returns true if the session can be retried (failed and under max_attempts)."
  @spec retryable?(t()) :: boolean()
  def retryable?(%__MODULE__{status: :failed, attempt_count: count, max_attempts: max}),
    do: count < max

  def retryable?(_session), do: false

  @doc "Budget allocated for the diagnosis phase (40%)."
  @spec diagnosis_budget(t()) :: float()
  def diagnosis_budget(%__MODULE__{budget_usd: total}), do: Float.round(total * 0.40, 4)

  @doc "Budget allocated for the fixing phase (60%)."
  @spec fix_budget(t()) :: float()
  def fix_budget(%__MODULE__{budget_usd: total}), do: Float.round(total * 0.60, 4)

  # -- Private --

  defp maybe_set_completed_at(session, status) when status in [:completed, :failed, :escalated] do
    %{session | completed_at: DateTime.utc_now()}
  end

  defp maybe_set_completed_at(session, _status), do: session

  defp generate_id do
    ts = System.system_time(:microsecond)
    rand = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
    "heal_#{ts}_#{rand}"
  end
end
