defmodule OptimalSystemAgent.FileLocking.ClaimsBoard do
  @moduledoc """
  A claims board for parallel work — VSM System 2 (anti-oscillation).

  ## The problem

  Parallel subagents (a `delegate` fan-out wave, a `run_parallel` batch, the
  parent working alongside them) currently have no way to see what a SIBLING
  is doing before starting. Two agents can pick the same file to edit, or the
  same investigation to run, and neither finds out until one of them writes
  over the other's work or both report back having done the same thing twice.
  `Tools.ConflictScope` solves the adjacent, narrower problem — do two calls
  IN THE SAME BATCH, on the SAME session, collide — but it has no notion of a
  different agent's session at all.

  This module is the missing layer: agents (and the coordinating parent)
  REGISTER what they intend to touch — a file, or a task/investigation — and
  anyone can ask "does this collide with an active claim" before starting.

  ## Built on existing primitives, not a new locking system

  * **File claims** delegate entirely to `FileLocking.RegionLock`, claiming
    the WHOLE file (`start_line: 1, end_line: :infinity`, in RegionLock's own
    overlap arithmetic) rather than a specific range. RegionLock already owns
    overlap detection, ETS storage, per-file inactivity expiry, and the
    `IntentBroadcaster` PubSub fan-out — none of that is reimplemented here.
    A whole-file claim conflicts with ANY other claim on that file (a whole-
    file claim or a narrower in-file region claimed via `peer_claim_region`),
    which is exactly the semantics "I'm working on this file" needs.
  * **Path identity** reuses `Tools.ConflictScope.canonical/2` — the same
    symlink-resolving, root-aware normalization the cross-call conflict
    detector uses — so a claim on `./foo.ex` and one on the absolute path to
    the same file are recognized as the same target instead of comparing as
    distinct strings.
  * **Task claims** (an investigation/topic rather than a file) have no
    existing analogue to build on — RegionLock is inherently file+line shaped
    — so this module owns a small, ETS-backed table for them, following the
    same pattern (claim/release/list, PubSub broadcast, expiry) rather than a
    different paradigm.

  ## Surfaced, not silently raced

  `claim_file/3` and `claim_task/3` return `{:conflict, holder}` rather than
  silently granting a colliding claim — the caller decides what to do with
  that (skip the file, negotiate, or proceed anyway). Blocking is opt-in via
  `config :optimal_system_agent, :claims_board_block_on_conflict, true`; the
  default is advisory-only, matching this task's own framing ("surfaced, and
  OPTIONALLY blocks").

  ## Expiry — finishes or dies

  A claim expires the moment its owning agent is no longer a live process
  (`Registry.lookup(SessionRegistry, agent_id) == []`) — checked on a short
  sweep (`@sweep_interval_ms`, default 5s), independent of and in ADDITION to
  RegionLock's own longer inactivity timeout. For a delegated subagent this
  covers both "finishes" and "dies" identically, because its Loop process
  terminates in both cases (`Orchestrator.run_fresh_subagent/1`'s cleanup
  path). A claim also expires via ordinary explicit `release/2`, which is the
  primary path for a long-lived top-level session that is done with one task
  but not with its whole conversation.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.Agent.RunStore
  alias OptimalSystemAgent.FileLocking.IntentBroadcaster
  alias OptimalSystemAgent.FileLocking.RegionLock
  alias OptimalSystemAgent.Tools.ConflictScope

  @task_table :osa_claims_board_tasks
  @file_index_table :osa_claims_board_files

  @sweep_interval_ms 5_000

  # RegionLock's own overlap math is `start <= end2 and start2 <= end`, so
  # claiming the full plausible line range makes a "whole file" claim overlap
  # with literally any narrower in-file region claim on the same file — the
  # exact "I am touching this whole file" semantics wanted, reusing RegionLock
  # unchanged.
  @whole_file_start 1
  @whole_file_end 1_000_000_000

  defstruct [:claim_id, :kind, :agent_id, :target, :note, :claimed_at]

  @type kind :: :file | :task
  @type t :: %__MODULE__{
          claim_id: String.t(),
          kind: kind(),
          agent_id: String.t(),
          target: String.t(),
          note: String.t() | nil,
          claimed_at: DateTime.t()
        }

  # ── Client API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Claim a whole file for `agent_id`. Delegates to `RegionLock.claim_region/4`
  under a full-file sentinel range.

  Returns `{:ok, claim_id}`, or `{:conflict, claim}` naming the existing
  holder — never silently grants a colliding claim.
  """
  @spec claim_file(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:conflict, t()}
  def claim_file(agent_id, file_path, opts \\ [])
      when is_binary(agent_id) and is_binary(file_path) do
    case canonical(file_path) do
      nil ->
        {:conflict,
         %__MODULE__{
           claim_id: "unresolvable",
           kind: :file,
           agent_id: "unknown",
           target: file_path,
           note: "path could not be resolved — treated as unsafe to claim",
           claimed_at: DateTime.utc_now()
         }}

      canon ->
        case RegionLock.claim_region(agent_id, canon, @whole_file_start, @whole_file_end) do
          {:ok, region_id} ->
            :ets.insert(@file_index_table, {region_id, agent_id, canon})

            IntentBroadcaster.broadcast_intent(
              agent_id,
              canon,
              Keyword.get(opts, :note, "claimed the whole file")
            )

            {:ok, region_id}

          {:conflict, holder} ->
            {:conflict,
             %__MODULE__{
               claim_id: holder.region_id,
               kind: :file,
               agent_id: holder.agent_id,
               target: canon,
               note: "lines #{holder.start_line}-#{holder.end_line}",
               claimed_at: holder.claimed_at
             }}
        end
    end
  end

  @doc """
  Claim a task/investigation topic for `agent_id` — the dedupe primitive for
  "don't redo the same investigation" (no file target, RegionLock does not
  apply).

  Two task claims CONFLICT when their descriptions overlap enough (a cheap
  keyword-Jaccard similarity, see `similar?/2` — no LLM call) to plausibly be
  the same underlying investigation. Returns `{:conflict, claim}` rather than
  granting a near-duplicate silently.
  """
  @spec claim_task(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:conflict, t()}
  def claim_task(agent_id, description, opts \\ [])
      when is_binary(agent_id) and is_binary(description) do
    GenServer.call(__MODULE__, {:claim_task, agent_id, description, opts})
  end

  @doc """
  Release a claim (file or task) by id. Idempotent — releasing an unknown or
  already-expired id is a no-op, and releasing a claim owned by a DIFFERENT
  agent is refused silently (matching `RegionLock.release_region/3`'s own
  owner check).
  """
  @spec release(String.t(), String.t()) :: :ok
  def release(agent_id, claim_id) when is_binary(agent_id) and is_binary(claim_id) do
    case :ets.lookup(@file_index_table, claim_id) do
      [{^claim_id, ^agent_id, file_path}] ->
        RegionLock.release_region(agent_id, file_path, claim_id)
        :ets.delete(@file_index_table, claim_id)
        :ok

      _ ->
        GenServer.call(__MODULE__, {:release_task, agent_id, claim_id})
    end
  end

  @doc "Release every claim (file and task) held by `agent_id` — called on finish/death."
  @spec release_all(String.t()) :: :ok
  def release_all(agent_id) when is_binary(agent_id) do
    GenServer.call(__MODULE__, {:release_all, agent_id})
  end

  @doc """
  All currently active claims, file and task alike — the visibility primitive:
  "see active claims before starting". Best-effort; never raises.
  """
  @spec active_claims() :: [t()]
  def active_claims do
    file_claims() ++ task_claims()
  end

  @doc "Active claims for one file, from any agent."
  @spec claims_for_file(String.t()) :: [t()]
  def claims_for_file(file_path) do
    case canonical(file_path) do
      nil -> []
      canon -> file_claims_for(canon)
    end
  end

  @doc """
  Is there an ACTIVE claim on `file_path` from an agent other than `agent_id`?
  Returns the conflicting claim, or `nil`.
  """
  @spec file_conflict(String.t(), String.t()) :: t() | nil
  def file_conflict(agent_id, file_path) do
    file_path
    |> claims_for_file()
    |> Enum.find(&(&1.agent_id != agent_id))
  end

  @doc """
  Is there an active TASK claim, from an agent other than `agent_id`, whose
  description overlaps enough with `description` to plausibly be the same
  investigation? Returns the conflicting claim, or `nil`.
  """
  @spec task_conflict(String.t(), String.t()) :: t() | nil
  def task_conflict(agent_id, description) do
    task_claims()
    |> Enum.reject(&(&1.agent_id == agent_id))
    |> Enum.find(&similar?(&1.target, description))
  end

  @doc "Whether a claim conflict should BLOCK the caller rather than merely be surfaced."
  @spec block_on_conflict?() :: boolean()
  def block_on_conflict? do
    Application.get_env(:optimal_system_agent, :claims_board_block_on_conflict, false) == true
  end

  @doc false
  @spec sweep_now() :: :ok
  def sweep_now, do: GenServer.call(__MODULE__, :sweep_now)

  # ── GenServer ───────────────────────────────────────────────────────

  @impl true
  def init(:ok) do
    ensure_tables()
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:claim_task, agent_id, description, opts}, _from, state) do
    case task_conflict(agent_id, description) do
      nil ->
        claim_id = "task_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

        record = %__MODULE__{
          claim_id: claim_id,
          kind: :task,
          agent_id: agent_id,
          target: description,
          note: Keyword.get(opts, :note),
          claimed_at: DateTime.utc_now()
        }

        :ets.insert(@task_table, {claim_id, record})
        {:reply, {:ok, claim_id}, state}

      conflict ->
        {:reply, {:conflict, conflict}, state}
    end
  end

  def handle_call({:release_task, agent_id, claim_id}, _from, state) do
    case :ets.lookup(@task_table, claim_id) do
      [{^claim_id, %__MODULE__{agent_id: ^agent_id}}] -> :ets.delete(@task_table, claim_id)
      _ -> :ok
    end

    {:reply, :ok, state}
  end

  def handle_call({:release_all, agent_id}, _from, state) do
    do_release_all(agent_id)
    {:reply, :ok, state}
  end

  def handle_call(:sweep_now, _from, state) do
    do_sweep()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    do_sweep()
    schedule_sweep()
    {:noreply, state}
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp ensure_tables do
    for {table, type} <- [{@task_table, :set}, {@file_index_table, :set}] do
      case :ets.whereis(table) do
        :undefined ->
          try do
            :ets.new(table, [:named_table, :public, type])
          rescue
            ArgumentError -> :ok
          end

        _ ->
          :ok
      end
    end
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  # Release every claim whose owning agent is no longer a live process. See
  # the moduledoc's "Expiry" section for why process liveness is the right
  # oracle for a delegated subagent's finish-or-die.
  defp do_sweep do
    dead_agents =
      (task_agent_ids() ++ file_agent_ids())
      |> Enum.uniq()
      |> Enum.reject(&agent_alive?/1)

    Enum.each(dead_agents, &do_release_all/1)
  rescue
    e -> Logger.debug("[ClaimsBoard] sweep failed: #{Exception.message(e)}")
  end

  defp agent_alive?(agent_id) do
    Registry.lookup(OptimalSystemAgent.SessionRegistry, agent_id) != [] or
      run_still_running?(agent_id)
  rescue
    _ -> true
  end

  # Belt-and-suspenders: a run that is `:queued` (admitted to nothing yet, no
  # process registered under its own id until it starts) must not be treated
  # as dead just because it has not registered itself yet.
  defp run_still_running?(agent_id) do
    match?(%{status: :running}, RunStore.get(agent_id))
  rescue
    _ -> false
  end

  defp do_release_all(agent_id) do
    task_ids =
      @task_table
      |> :ets.tab2list()
      |> Enum.filter(fn {_id, %__MODULE__{agent_id: a}} -> a == agent_id end)
      |> Enum.map(fn {id, _} -> id end)

    Enum.each(task_ids, &:ets.delete(@task_table, &1))

    file_claims =
      @file_index_table
      |> :ets.tab2list()
      |> Enum.filter(fn {_region_id, a, _path} -> a == agent_id end)

    Enum.each(file_claims, fn {region_id, ^agent_id, file_path} ->
      RegionLock.release_region(agent_id, file_path, region_id)
      :ets.delete(@file_index_table, region_id)
    end)

    :ok
  rescue
    e ->
      Logger.debug("[ClaimsBoard] release_all(#{agent_id}) failed: #{Exception.message(e)}")
      :ok
  end

  defp task_agent_ids do
    @task_table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, %__MODULE__{agent_id: a}} -> a end)
  rescue
    _ -> []
  end

  defp file_agent_ids do
    @file_index_table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, a, _path} -> a end)
  rescue
    _ -> []
  end

  defp task_claims do
    @task_table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, record} -> record end)
  rescue
    _ -> []
  end

  # Reconstructed from RegionLock directly (the source of truth for file
  # claims) rather than the index alone, so a claim RegionLock has already
  # expired (its own longer inactivity timeout) never shows as active here.
  defp file_claims do
    @file_index_table
    |> :ets.tab2list()
    |> Enum.map(fn {_region_id, _agent_id, path} -> path end)
    |> Enum.uniq()
    |> Enum.flat_map(&file_claims_for/1)
  rescue
    _ -> []
  end

  defp file_claims_for(canon_path) do
    canon_path
    |> RegionLock.list_claims()
    |> Enum.map(fn c ->
      %__MODULE__{
        claim_id: c.region_id,
        kind: :file,
        agent_id: c.agent_id,
        target: canon_path,
        note: "lines #{c.start_line}-#{c.end_line}",
        claimed_at: c.claimed_at
      }
    end)
  end

  defp canonical(path), do: ConflictScope.canonical(path, :cwd)

  # ── Task similarity (cheap keyword-Jaccard, no LLM) ──────────────────
  #
  # No stemming, so two honest paraphrases of the same investigation
  # ("times out" vs "timing out", "under load" vs "under heavy load") share
  # fewer exact tokens than a human reader would expect. 0.5 looked
  # reasonable in isolation but missed real paraphrases in practice; 0.4
  # still requires substantial, non-trivial overlap (most word-pairs of a
  # short description) while catching the common paraphrase shape.

  @similarity_threshold 0.4
  @stopwords ~w(the a an is are was were to of and or for in on at with
                this that these those into onto over under from by as it)

  defp similar?(a, b), do: jaccard(words(a), words(b)) >= @similarity_threshold

  defp jaccard(a, b) do
    if MapSet.size(a) == 0 or MapSet.size(b) == 0 do
      0.0
    else
      inter = MapSet.intersection(a, b) |> MapSet.size()
      union = MapSet.union(a, b) |> MapSet.size()
      inter / union
    end
  end

  defp words(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, " ")
    |> String.split()
    |> Enum.reject(&(byte_size(&1) < 3 or &1 in @stopwords))
    |> MapSet.new()
  end
end
