defmodule OptimalSystemAgent.Tools.Builtins.ClaimsBoard do
  @moduledoc """
  Model-facing entry point for `FileLocking.ClaimsBoard` — see that module's
  doc for the full design (VSM System 2, anti-oscillation for parallel work).

  Actions:

    * `claim` (kind `file` or `task`) — register what this agent is about to
      work on. Returns a conflict (rather than silently granting it) when
      another agent already holds an overlapping claim.
    * `release` — free a claim by id.
    * `list`    — see every active claim, file and task alike, from every
      agent — the visibility primitive: "see active claims before starting".
  """

  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.FileLocking.ClaimsBoard, as: Board
  alias OptimalSystemAgent.Tools.UseContext

  @impl true
  def name, do: "claims_board"

  @impl true
  def search_hint,
    do: "claim file task investigation coordinate parallel agents avoid duplicate work conflict"

  @impl true
  def description do
    "See and register active work claims (files or task topics) across ALL agents working " <>
      "in parallel, so two agents don't edit the same file or redo the same investigation. " <>
      "Call `list` before starting parallel/delegated work; call `claim` before starting on a " <>
      "specific file or investigation; call `release` when done."
  end

  @impl true
  def safety, do: :write_safe

  @impl true
  def read_only?(%{"action" => "list"}, _ctx), do: true
  def read_only?(_input, _ctx), do: false

  @impl true
  def destructive?(_input, _ctx), do: false

  # Claims must serialize against each other the same way `peer_claim_region`
  # does — concurrent claim decisions are mediated by the ClaimsBoard/RegionLock
  # GenServers, not by the tool executor's own batching.
  @impl true
  def concurrency_safe?(%{"action" => "list"}, _ctx), do: true
  def concurrency_safe?(_input, _ctx), do: false

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["action"],
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["claim", "release", "list"],
          "description" => "claim: register intent, release: free a claim, list: see all claims"
        },
        "kind" => %{
          "type" => "string",
          "enum" => ["file", "task"],
          "description" =>
            "Required for 'claim'. 'file': claim a whole file. 'task': claim an " <>
              "investigation/topic (no file target)."
        },
        "target" => %{
          "type" => "string",
          "description" =>
            "Required for 'claim'. Absolute file path (kind=file) or a short " <>
              "description of the task/investigation (kind=task)."
        },
        "note" => %{
          "type" => "string",
          "description" => "Optional human-readable note on what you intend to do."
        },
        "claim_id" => %{
          "type" => "string",
          "description" => "Claim id returned by a prior 'claim'. Required for 'release'."
        }
      }
    }
  end

  @impl true
  def execute(%{"action" => "claim", "kind" => "file", "target" => path} = args, ctx) do
    agent_id = agent_id(ctx, args)

    case Board.claim_file(agent_id, path, note: Map.get(args, "note")) do
      {:ok, claim_id} ->
        {:ok, "Claimed file #{path}. claim_id: `#{claim_id}`. Call `release` when done."}

      {:conflict, holder} ->
        conflict_result(holder, "file #{path}")
    end
  end

  def execute(%{"action" => "claim", "kind" => "task", "target" => description} = args, ctx) do
    agent_id = agent_id(ctx, args)

    case Board.claim_task(agent_id, description, note: Map.get(args, "note")) do
      {:ok, claim_id} ->
        {:ok,
         "Claimed task #{inspect(description)}. claim_id: `#{claim_id}`. Call `release` when done."}

      {:conflict, holder} ->
        conflict_result(holder, "task #{inspect(description)}")
    end
  end

  def execute(%{"action" => "claim", "kind" => other}, _ctx) do
    {:error, "Invalid kind '#{other}'. Use: file, task"}
  end

  def execute(%{"action" => "claim"}, _ctx) do
    {:error, "Missing required parameters: kind, target"}
  end

  def execute(%{"action" => "release", "claim_id" => claim_id} = args, ctx) do
    agent_id = agent_id(ctx, args)
    Board.release(agent_id, claim_id)
    {:ok, "Released claim `#{claim_id}`."}
  end

  def execute(%{"action" => "release"}, _ctx) do
    {:error, "Missing required parameter: claim_id is required for 'release'."}
  end

  def execute(%{"action" => "list"}, _ctx) do
    case Board.active_claims() do
      [] ->
        {:ok, "No active claims."}

      claims ->
        lines =
          claims
          |> Enum.sort_by(& &1.claimed_at, {:desc, DateTime})
          |> Enum.map_join("\n", fn c ->
            note = if c.note, do: " (#{c.note})", else: ""

            "- `#{c.claim_id}` [#{c.kind}] #{c.agent_id}: #{c.target}#{note} — " <>
              "claimed #{Calendar.strftime(c.claimed_at, "%H:%M:%S")}"
          end)

        {:ok, "## Active claims\n\n#{lines}"}
    end
  end

  def execute(_, _ctx), do: {:error, "Missing required parameter: action"}

  # ── Private ───────────────────────────────────────────────────────────

  defp agent_id(%UseContext{session_id: sid}, _args) when is_binary(sid) and sid != "", do: sid
  defp agent_id(_ctx, args), do: Map.get(args, "__session_id__", "unknown")

  defp conflict_result(holder, what) do
    blocked? = Board.block_on_conflict?()

    message =
      "Conflict: #{what} is already claimed by agent #{holder.agent_id} " <>
        "(claim `#{holder.claim_id}`#{if holder.note, do: ", #{holder.note}", else: ""}). " <>
        if blocked?,
          do: "This claim was NOT granted — coordinate with that agent or pick different work.",
          else:
            "This is advisory: your claim was NOT granted, but nothing prevents you from " <>
              "proceeding anyway. Prefer coordinating with that agent, or picking different " <>
              "work, over racing it."

    if blocked?, do: {:error, message}, else: {:ok, message}
  end
end
