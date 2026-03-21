defmodule OptimalSystemAgent.Peer.Review do
  @moduledoc """
  Peer Review System — blocking review gates on agent work products.

  Before a task can be marked complete, the artifact it produced can be gated
  behind a peer review. The completing agent requests a review; the designated
  reviewer examines the artifact and returns a verdict. Task completion is blocked
  until the review passes.

  ## Review lifecycle

    1. `request_review/3` — completing agent submits artifact for review.
    2. Reviewer receives notification via PubSub.
    3. `submit_review/3` — reviewer posts verdict (`:approve`, `:request_changes`, `:reject`).
    4. If `:approve`, the gate opens and the requesting agent may complete its task.
    5. If `:request_changes` or `:reject`, the requesting agent is notified and must respond.

  ## ETS storage

  Reviews are stored in `:osa_peer_reviews`. The table is public and set-typed:
  `{artifact_id, review_record}`.
  """

  require Logger

  @reviews_table :osa_peer_reviews

  # ---------------------------------------------------------------------------
  # Structs
  # ---------------------------------------------------------------------------

  @type verdict :: :approve | :request_changes | :reject

  @type line_comment :: {pos_integer(), String.t()}

  @enforce_keys [:id, :artifact_id, :from_agent, :to_agent, :artifact, :status, :requested_at]
  defstruct [
    :id,
    :artifact_id,
    :from_agent,
    :to_agent,
    :artifact,
    :requested_at,
    :reviewed_at,
    :reviewer_id,
    status: :pending,
    verdict: nil,
    comments: [],
    summary: nil
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          artifact_id: String.t(),
          from_agent: String.t(),
          to_agent: String.t(),
          artifact: String.t() | map(),
          requested_at: DateTime.t(),
          reviewed_at: DateTime.t() | nil,
          reviewer_id: String.t() | nil,
          status: :pending | :in_review | :approved | :changes_requested | :rejected,
          verdict: verdict() | nil,
          comments: [line_comment()],
          summary: String.t() | nil
        }

  # ---------------------------------------------------------------------------
  # ETS bootstrap
  # ---------------------------------------------------------------------------

  @doc "Create the reviews ETS table."
  def init_table do
    :ets.new(@reviews_table, [:named_table, :public, :set])
    :ok
  rescue
    ArgumentError -> :ok
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Submit an artifact for peer review.

  `artifact` can be a file path string, a content string, or a structured map.
  `reviewer_role` is optional — if omitted, any available reviewer may respond.

  Returns `{:ok, review}` with the created review record.
  """
  @spec request_review(from_agent :: String.t(), to_agent :: String.t(), artifact :: any()) ::
          {:ok, t()}
  def request_review(from_agent, to_agent, artifact) do
    artifact_id = "artifact_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    review = %__MODULE__{
      id: "review_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
      artifact_id: artifact_id,
      from_agent: from_agent,
      to_agent: to_agent,
      artifact: artifact,
      status: :pending,
      requested_at: DateTime.utc_now()
    }

    :ets.insert(@reviews_table, {artifact_id, review})

    # Notify the reviewer via PubSub
    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:peer:review:#{to_agent}",
      {:review_requested, review}
    )

    Logger.info("[Peer.Review] #{from_agent} requested review #{review.id} from #{to_agent}")

    {:ok, review}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Submit a review verdict for an artifact.

  `reviewer` is the agent submitting the review.
  `artifact_id` identifies the artifact under review.
  `review_attrs` is a map with:
    - `:verdict` — required, one of `:approve | :request_changes | :reject`
    - `:comments` — optional list of `{line_number, comment}` tuples
    - `:summary` — optional string summary

  Returns `{:ok, updated_review}` or `{:error, reason}`.
  """
  @spec submit_review(
          reviewer :: String.t(),
          artifact_id :: String.t(),
          review_attrs :: map()
        ) :: {:ok, t()} | {:error, String.t()}
  def submit_review(reviewer, artifact_id, review_attrs) do
    verdict = Map.fetch!(review_attrs, :verdict)

    unless verdict in [:approve, :request_changes, :reject] do
      raise ArgumentError, "verdict must be :approve, :request_changes, or :reject"
    end

    case :ets.lookup(@reviews_table, artifact_id) do
      [] ->
        {:error, "Review for artifact #{artifact_id} not found"}

      [{_, review}] ->
        status = verdict_to_status(verdict)

        updated = %{
          review
          | status: status,
            verdict: verdict,
            reviewer_id: reviewer,
            reviewed_at: DateTime.utc_now(),
            comments: Map.get(review_attrs, :comments, []),
            summary: Map.get(review_attrs, :summary)
        }

        :ets.insert(@reviews_table, {artifact_id, updated})

        # Notify the requesting agent of the verdict
        Phoenix.PubSub.broadcast(
          OptimalSystemAgent.PubSub,
          "osa:peer:review_verdict:#{review.from_agent}",
          {:review_verdict, updated}
        )

        Logger.info(
          "[Peer.Review] #{reviewer} submitted #{verdict} for artifact #{artifact_id} " <>
            "(requested by #{review.from_agent})"
        )

        {:ok, updated}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Check whether an artifact has a passing review (`:approved` status).

  Returns `true` if the review is approved, `false` otherwise.
  If no review exists, returns `false` — unreviewed artifacts do not pass.
  """
  @spec approved?(artifact_id :: String.t()) :: boolean()
  def approved?(artifact_id) do
    case :ets.lookup(@reviews_table, artifact_id) do
      [{_, %{status: :approved}}] -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc "Fetch a review record by artifact ID."
  @spec get_review(artifact_id :: String.t()) :: t() | nil
  def get_review(artifact_id) do
    case :ets.lookup(@reviews_table, artifact_id) do
      [{_, review}] -> review
      [] -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  List all pending reviews assigned to a given agent.

  Returns a list of review structs where `to_agent == reviewer_id` and
  `status == :pending`.
  """
  @spec pending_reviews_for(agent_id :: String.t()) :: [t()]
  def pending_reviews_for(agent_id) do
    :ets.tab2list(@reviews_table)
    |> Enum.map(fn {_, review} -> review end)
    |> Enum.filter(&(&1.to_agent == agent_id and &1.status == :pending))
  rescue
    _ -> []
  end

  @doc """
  Assert that an artifact is approved before proceeding.

  Returns `:ok` if approved, `{:error, :review_pending}` or
  `{:error, :review_rejected}` otherwise. Call this at task-completion boundaries.
  """
  @spec assert_approved(artifact_id :: String.t()) :: :ok | {:error, atom()}
  def assert_approved(artifact_id) do
    case :ets.lookup(@reviews_table, artifact_id) do
      [{_, %{status: :approved}}] ->
        :ok

      [{_, %{status: :rejected}}] ->
        {:error, :review_rejected}

      [{_, %{status: :changes_requested}}] ->
        {:error, :review_changes_requested}

      [{_, _}] ->
        {:error, :review_pending}

      [] ->
        {:error, :no_review_found}
    end
  rescue
    _ -> {:error, :review_table_unavailable}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp verdict_to_status(:approve), do: :approved
  defp verdict_to_status(:request_changes), do: :changes_requested
  defp verdict_to_status(:reject), do: :rejected
end
