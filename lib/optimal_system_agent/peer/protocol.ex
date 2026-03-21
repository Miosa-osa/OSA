defmodule OptimalSystemAgent.Peer.Protocol do
  @moduledoc """
  Core Peer Protocol — structured handoff format for agent-to-agent knowledge transfer.

  A Handoff is the canonical unit of context propagation between agents. It carries
  everything the receiving agent needs to continue work coherently: what was done,
  what was found, what was changed, what decisions were locked in, and what remains
  open. This is not a message — it is a state transfer.

  ## Handoff lifecycle

    1. Completing agent calls `create_handoff/2` to build a Handoff from its state.
    2. Handoff is delivered via `Team.send_message/4` or `Peer.Protocol.deliver/2`.
    3. Receiving agent calls `receive_handoff/2` to integrate context into its own state.

  ## ETS storage

  Handoffs are stored in `:osa_peer_handoffs` keyed by `handoff_id` for retrieval
  by async receivers. The table is public and set-typed — one record per ID.
  """

  require Logger

  @handoffs_table :osa_peer_handoffs

  # ---------------------------------------------------------------------------
  # Structs
  # ---------------------------------------------------------------------------

  @enforce_keys [:id, :from, :to, :created_at]
  defstruct [
    :id,
    :from,
    :to,
    :created_at,
    actions_taken: [],
    discoveries: [],
    files_changed: [],
    decisions_made: [],
    open_questions: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          from: String.t(),
          to: String.t(),
          created_at: DateTime.t(),
          actions_taken: [String.t()],
          discoveries: [String.t()],
          files_changed: [String.t()],
          decisions_made: [String.t()],
          open_questions: [String.t()],
          metadata: map()
        }

  # ---------------------------------------------------------------------------
  # ETS bootstrap
  # ---------------------------------------------------------------------------

  @doc "Create the handoffs ETS table. Called from application.ex or Team.init_tables/0."
  def init_table do
    :ets.new(@handoffs_table, [:named_table, :public, :set])
    :ok
  rescue
    ArgumentError -> :ok
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Build a Handoff struct from raw agent state context.

  `state` is an open map produced by the agent; fields recognised:
    - `:actions_taken`   — list of string summaries of completed actions
    - `:discoveries`     — list of findings the next agent needs to know
    - `:files_changed`   — list of file paths modified during this agent's run
    - `:decisions_made`  — list of architectural/design decisions that are locked in
    - `:open_questions`  — list of unresolved questions for the receiving agent
    - `:metadata`        — arbitrary extra context map

  Unrecognised keys are ignored.
  """
  @spec create_handoff(from :: String.t(), to :: String.t(), state :: map()) :: t()
  def create_handoff(from, to, state \\ %{}) do
    %__MODULE__{
      id: generate_id(),
      from: from,
      to: to,
      created_at: DateTime.utc_now(),
      actions_taken: Map.get(state, :actions_taken, []),
      discoveries: Map.get(state, :discoveries, []),
      files_changed: Map.get(state, :files_changed, []),
      decisions_made: Map.get(state, :decisions_made, []),
      open_questions: Map.get(state, :open_questions, []),
      metadata: Map.get(state, :metadata, %{})
    }
    |> tap(&store/1)
  end

  @doc """
  Integrate a received Handoff into the receiving agent's working context map.

  Returns `{:ok, merged_context}` where `merged_context` is `context` enriched with
  the handoff's fields. Existing context keys are preserved; handoff fields are
  appended (for lists) or merged (for maps).

  Also logs the handoff receipt for audit.
  """
  @spec receive_handoff(handoff :: t(), context :: map()) :: {:ok, map()}
  def receive_handoff(%__MODULE__{} = handoff, context \\ %{}) do
    Logger.info(
      "[Peer.Protocol] #{handoff.to} received handoff #{handoff.id} from #{handoff.from}"
    )

    merged =
      context
      |> Map.update(:prior_actions, handoff.actions_taken, &(&1 ++ handoff.actions_taken))
      |> Map.update(:known_discoveries, handoff.discoveries, &(&1 ++ handoff.discoveries))
      |> Map.update(
        :files_changed,
        handoff.files_changed,
        &((&1 ++ handoff.files_changed) |> Enum.uniq())
      )
      |> Map.update(:prior_decisions, handoff.decisions_made, &(&1 ++ handoff.decisions_made))
      |> Map.update(:open_questions, handoff.open_questions, &(&1 ++ handoff.open_questions))
      |> Map.merge(handoff.metadata, fn _k, existing, _new -> existing end)
      |> Map.put(:last_handoff_id, handoff.id)
      |> Map.put(:last_handoff_from, handoff.from)

    {:ok, merged}
  end

  @doc """
  Deliver a handoff to the receiving agent via PubSub and store in ETS.

  The receiving agent must be subscribed to `\"osa:peer:handoff:<to_agent_id>\"`.
  """
  @spec deliver(handoff :: t(), team_id :: String.t()) :: :ok
  def deliver(%__MODULE__{} = handoff, team_id \\ "default") do
    store(handoff)

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:peer:handoff:#{handoff.to}",
      {:peer_handoff, handoff}
    )

    OptimalSystemAgent.Team.send_message(
      team_id,
      handoff.from,
      handoff.to,
      format_handoff_message(handoff)
    )

    :ok
  rescue
    e ->
      Logger.warning("[Peer.Protocol] Handoff delivery failed: #{Exception.message(e)}")
      :ok
  end

  @doc "Retrieve a previously stored handoff by ID."
  @spec get_handoff(String.t()) :: t() | nil
  def get_handoff(handoff_id) do
    case :ets.lookup(@handoffs_table, handoff_id) do
      [{_, handoff}] -> handoff
      [] -> nil
    end
  rescue
    _ -> nil
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp store(%__MODULE__{} = handoff) do
    :ets.insert(@handoffs_table, {handoff.id, handoff})
  rescue
    _ -> :ok
  end

  defp generate_id do
    "handoff_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp format_handoff_message(%__MODULE__{} = h) do
    sections = [
      "## Handoff from #{h.from}",
      unless(h.actions_taken == [], do: "**Actions taken:**\n" <> bullet_list(h.actions_taken)),
      unless(h.discoveries == [], do: "**Discoveries:**\n" <> bullet_list(h.discoveries)),
      unless(h.files_changed == [], do: "**Files changed:** #{Enum.join(h.files_changed, ", ")}"),
      unless(h.decisions_made == [],
        do: "**Decisions locked in:**\n" <> bullet_list(h.decisions_made)
      ),
      unless(h.open_questions == [],
        do: "**Open questions for you:**\n" <> bullet_list(h.open_questions)
      )
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp bullet_list(items), do: Enum.map_join(items, "\n", &"- #{&1}")
end
