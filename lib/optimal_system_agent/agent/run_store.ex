defmodule OptimalSystemAgent.Agent.RunStore do
  @moduledoc """
  Lightweight subagent run index.

  The orchestrator uses this to keep structured status, completion metadata,
  and a sidechain transcript for each subagent. ETS gives live inspection even
  when a run is active; append-only markdown files under `~/.osa/agent-runs`
  keep completed runs inspectable after the process exits.

  ## Cross-process ownership leases

  `~/.osa/agent-runs` is **machine-global**, but every `osa` invocation is its
  own BEAM with its own ETS table and its own `SessionRegistry`. `rehydrate/0`
  therefore populates a fresh process's index with *other live processes'*
  `:running` rows, and a `Registry.lookup` liveness probe — which can only ever
  see the local node — reports every one of them as dead. That combination let a
  second `osa` invocation cancel (and re-dispatch) runs that were healthily in
  flight in the first one.

  A registry lookup cannot answer a cross-process question, so liveness is no
  longer guessed: each run carries an **ownership lease** on disk next to its
  transcript (`<run>.md.lease.json`) holding a claim, an expiry and a heartbeat
  renewed while the owner lives. Every destructive step (cancel, reconcile,
  re-dispatch) must (re-)acquire that lease *immediately before* it mutates
  anything — see `claim_lease/1`, `renew_lease/1`, `release_lease/1`,
  `lease_state/1`.

  Deliberate properties:

    * A lease is **not** released on unclean shutdown. Self-clearing on crash
      would let a second process race a half-dead worker; instead the lease
      simply stops being renewed and **expires**.
    * The OS-level liveness check (owning pid still exists *and* its start time
      matches, so a recycled pid does not read as alive) is belt-and-braces
      *alongside* the expiry — it can only VETO a steal that expiry already
      permits, never substitute for it.
    * If the heartbeat finds a lease is no longer ours, the run is aborted
      locally rather than left running unowned.
  """

  require Logger

  alias OptimalSystemAgent.Agent.Trajectory
  alias OptimalSystemAgent.ConfigFile

  @table __MODULE__
  @edges_table :"Elixir.OptimalSystemAgent.Agent.RunStore.TreeEdges"

  # Runtime-resolved default so a prebuilt release uses the END USER's home, not
  # the CI runner's baked-in path. The `:agent_runs_dir` app-env override still
  # wins; only this fallback is resolved at call time.
  defp default_runs_dir, do: Path.join(ConfigFile.config_dir(), "agent-runs")

  # Cap on retained TERMINAL (completed/failed/cancelled) rows. Without this the
  # table grows unbounded over long-running/heavy-fan-out sessions, slowing every
  # tab2list-based read and leaking memory. :running rows are never pruned.
  @max_terminal_runs 500

  # ── ownership lease tunables ───────────────────────────────────────────────

  # Local (per-BEAM) index of the runs THIS process holds a lease on. Never
  # populated by rehydrate/0 — rehydration reads other processes' runs and must
  # not imply ownership of them.
  @lease_owners :"Elixir.OptimalSystemAgent.Agent.RunStore.LeaseOwners"

  # A lease older than this without a heartbeat is stealable. Sized so a normal
  # GC pause / slow disk never expires a healthy owner, but a crashed one is
  # reclaimed promptly. Override with `:run_lease_ttl_ms`.
  @default_lease_ttl_ms 60_000

  @heartbeat_name :"Elixir.OptimalSystemAgent.Agent.RunStore.LeaseHeartbeat"

  @lease_lost_reason "ownership lease lost to another process; run aborted locally"

  @type run :: %{
          agent_id: String.t(),
          parent_session_id: String.t(),
          role: String.t(),
          task: String.t(),
          status: :running | :completed | :failed | :cancelled,
          started_at: DateTime.t(),
          completed_at: DateTime.t() | nil,
          duration_ms: non_neg_integer() | nil,
          tool_count: non_neg_integer(),
          tokens_used: non_neg_integer(),
          recent_actions: [String.t()],
          result: map() | nil,
          transcript_path: String.t(),
          resumed_from: String.t() | nil,
          worktree_snapshot_ref: String.t() | nil,
          # W3/D3 — coordinator posture under which the run was dispatched
          # (`:autonomous` for unattended/overdrive fleets, else nil/`:supervised`).
          # Read by the boot FleetResumer to decide which orphaned `:running`
          # runs are safe to re-dispatch. Optional: populated only when a caller
          # passes `:posture` to `start_run/1` (or persists it in the messages
          # meta), so it defaults to nil and the resumer stays safe-by-default.
          posture: atom() | nil
        }

  @doc "Start or replace a run record."
  @spec start_run(map()) :: :ok
  def start_run(attrs) do
    ensure_table()

    agent_id = Map.fetch!(attrs, :agent_id)
    started_at = DateTime.utc_now()
    transcript_path = transcript_path(agent_id)

    run =
      %{
        agent_id: agent_id,
        parent_session_id: Map.fetch!(attrs, :parent_session_id),
        role: Map.get(attrs, :role, "agent"),
        task: Map.get(attrs, :task, ""),
        status: :running,
        started_at: started_at,
        completed_at: nil,
        duration_ms: nil,
        tool_count: 0,
        tokens_used: 0,
        recent_actions: [],
        result: nil,
        transcript_path: transcript_path,
        # P6 peer-resume (sibling handoff): the agent_id of the sibling/peer run
        # whose accumulated context seeded this run's initial messages, or nil
        # for an ordinary fresh spawn / parent-fork. Set by the Orchestrator
        # when `config[:resumed_from]` is present. Purely informational — never
        # read for control flow.
        resumed_from: Map.get(attrs, :resumed_from),
        worktree_snapshot_ref: nil,
        # W3/D3 — optional coordinator posture (see @type). Additive: absent
        # callers leave it nil and nothing changes.
        posture: Map.get(attrs, :posture)
      }

    :ets.insert(@table, {agent_id, run})
    record_edge(agent_id, run.parent_session_id)

    # Claim the cross-process ownership lease for this run BEFORE anyone can
    # observe it as `:running`. A failure here means another live `osa` process
    # already owns this id — we keep the local row (so the caller still gets a
    # transcript) but never register ownership, which keeps every destructive
    # path in this process off the run.
    case claim_lease(agent_id) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[RunStore] could not claim ownership lease for #{agent_id}: #{inspect(reason)}"
        )
    end

    resumed_note =
      if run.resumed_from, do: " resumed_from=#{run.resumed_from}", else: ""

    append(
      agent_id,
      "START role=#{run.role} parent=#{run.parent_session_id}#{resumed_note}\n\n#{run.task}"
    )
  end

  @doc "Record a progress line for a running agent."
  @spec progress(String.t(), String.t(), non_neg_integer()) :: :ok
  def progress(agent_id, action, tool_count \\ 0) do
    update(agent_id, fn run ->
      run
      |> Map.put(:tool_count, max(run.tool_count, tool_count))
      # Newest-first ring of the last 5 actions (CC recentActivities parity);
      # consecutive duplicates collapse so start/end pairs don't double up.
      |> Map.update(:recent_actions, [action], fn
        [^action | _] = actions -> actions
        actions -> Enum.take([action | actions], 5)
      end)
    end)

    append(agent_id, "PROGRESS tools=#{tool_count}\n\n#{action}")
  end

  @doc """
  P8 — attach a durable git-ref worktree snapshot (see
  `Workspace.FastWorktree.snapshot_ref/2`) to a completed run, so `/runs`,
  `task_output`, and the transcript record where the child's final worktree
  state can be inspected/resumed after teardown discarded or merged it.
  Best-effort; a run row that has already been pruned is a no-op.
  """
  @spec attach_worktree_snapshot(String.t(), String.t()) :: :ok
  def attach_worktree_snapshot(agent_id, ref) when is_binary(agent_id) and is_binary(ref) do
    update(agent_id, fn run -> Map.put(run, :worktree_snapshot_ref, ref) end)
    append(agent_id, "WORKTREE_SNAPSHOT ref=#{ref}")
    :ok
  end

  @doc "Mark a run complete and attach the structured result."
  @spec complete(String.t(), map()) :: :ok
  def complete(agent_id, result) do
    now = DateTime.utc_now()

    update(agent_id, fn run ->
      %{
        run
        | status: settled_status(run.status, Map.get(result, :status, :completed)),
          completed_at: run.completed_at || now,
          duration_ms: Map.get(result, :duration_ms) || run.duration_ms,
          tool_count: monotonic(run.tool_count, Map.get(result, :tool_count)),
          tokens_used: monotonic(run.tokens_used, Map.get(result, :tokens_used)),
          result: run.result || result
      }
    end)

    append(
      agent_id,
      "STOP status=#{Map.get(result, :status, :completed)}\n\n#{format_result(result)}"
    )

    # Clean terminal transition — the only place a lease is *released*. An
    # unclean exit deliberately leaves the lease behind to expire (see moduledoc).
    release_lease(agent_id)
    prune_terminal()
    :ok
  end

  @terminal_statuses [:completed, :failed, :cancelled]

  # Terminal states are LATCHED: the first one to land is the truth.
  #
  # `handle_ownership_loss/1` and `reconcile_stale_running/1` both settle a run
  # as `:cancelled` while its loop may still be draining, and that loop's own
  # later `complete/2` (e.g. via `Fleet.finish/3`) used to promote the run right
  # back to `:completed` — reporting aborted work as successful. A run that has
  # already settled keeps the status it settled with.
  defp settled_status(current, _incoming) when current in @terminal_statuses, do: current
  defp settled_status(_current, incoming) when incoming in @terminal_statuses, do: incoming
  defp settled_status(current, _incoming), do: current

  # Counters only ever go up. `complete/2` used to overwrite `tool_count` /
  # `tokens_used` outright while `progress/3` correctly used `max/2`, so a
  # completion carrying a stale (or absent-then-defaulted) count erased real
  # accumulated usage.
  defp monotonic(current, incoming) when is_integer(current) and is_integer(incoming),
    do: max(current, incoming)

  defp monotonic(current, _incoming), do: current

  # Keep only the newest @max_terminal_runs terminal rows; :running rows are
  # always preserved. Bounds table growth over long-lived nodes. Best-effort.
  defp prune_terminal do
    ensure_table()

    terminal =
      @table
      |> :ets.tab2list()
      |> Enum.map(fn {_id, run} -> run end)
      |> Enum.filter(fn run -> run.status in [:completed, :failed, :cancelled] end)

    if length(terminal) > @max_terminal_runs do
      terminal
      |> Enum.sort_by(fn run -> DateTime.to_unix(run.started_at, :millisecond) end, :desc)
      |> Enum.drop(@max_terminal_runs)
      |> Enum.each(fn run -> :ets.delete(@table, run.agent_id) end)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Get a run by agent id."
  @spec get(String.t()) :: run() | nil
  def get(agent_id) do
    ensure_table()

    case :ets.lookup(@table, agent_id) do
      [{^agent_id, run}] -> run
      [] -> nil
    end
  end

  @doc "List known runs, newest first."
  @spec list(keyword()) :: [run()]
  def list(opts \\ []) do
    ensure_table()
    limit = Keyword.get(opts, :limit, 20)
    status = Keyword.get(opts, :status)

    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, run} -> run end)
    |> Enum.filter(fn run -> is_nil(status) or run.status == status end)
    |> Enum.sort_by(fn run -> DateTime.to_unix(run.started_at, :millisecond) end, :desc)
    |> Enum.take(limit)
  end

  @doc """
  W3/D3 — every `:running` row, unbounded (unlike `list/1`, which caps at
  `:limit`). The boot resumer needs the COMPLETE set of in-flight runs to walk
  the parent chain and reconcile, so a 20-row default would silently drop
  orphans. Newest-first.
  """
  @spec all_running() :: [run()]
  def all_running do
    ensure_table()

    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, run} -> run end)
    |> Enum.filter(fn run -> run.status == :running end)
    |> Enum.sort_by(fn run -> DateTime.to_unix(run.started_at, :millisecond) end, :desc)
  end

  @doc """
  W3/D3 — boot reconciliation of stale `:running` rows.

  After a daemon crash/restart the loop processes that owned in-flight runs are
  gone, but their ETS rows (rehydrated from disk, or surviving in a shared
  table) still read `:running` — inflating the `/runs` roster and any
  autonomous-fleet counts. This walks every `:running` row, and for each whose
  owning process is NOT alive marks it terminal (`:cancelled` by default) so the
  counts settle. Rows whose process IS alive (e.g. a run the FleetResumer just
  re-dispatched under its original id) are left untouched.

  `alive_fun` is a LOCAL-node probe and cannot see another `osa` process, so it
  is never trusted on its own: a row only becomes a reconciliation candidate
  once this process can also **acquire its ownership lease**, which is
  re-confirmed immediately before the row is mutated. A run owned by another
  live process is skipped entirely, no matter what the local registry says.

  Options:
    * `:alive_fun`  — `(agent_id -> boolean)` liveness probe. Defaults to a
      `SessionRegistry` lookup. Injectable so the selection logic is unit
      testable without booting real loops.
    * `:claim_fun`  — `(agent_id -> {:ok, term} | {:error, term})` ownership
      acquisition, default `claim_lease/1`. Injectable for tests.
    * `:status`     — terminal status to stamp (`:cancelled` | `:failed`),
      default `:cancelled`.
    * `:reason`     — human note recorded on the row/transcript.

  Returns the list of rows it reconciled. Best-effort; never raises.
  """
  @spec reconcile_stale_running(keyword()) :: [run()]
  def reconcile_stale_running(opts \\ []) do
    ensure_table()
    alive_fun = Keyword.get(opts, :alive_fun, &default_alive?/1)
    claim_fun = Keyword.get(opts, :claim_fun, &claim_lease/1)
    status = Keyword.get(opts, :status, :cancelled)
    reason = Keyword.get(opts, :reason, "reconciled at boot: owning process gone after restart")
    now = DateTime.utc_now()

    all_running()
    |> Enum.reject(fn run -> safe_alive?(alive_fun, run.agent_id) end)
    # Ownership gate — re-confirmed here, immediately before the destructive
    # write below, not merely at selection time.
    |> Enum.filter(fn run -> claimed?(claim_fun, run.agent_id) end)
    |> Enum.map(fn run ->
      reconciled = %{
        run
        | status: status,
          completed_at: now,
          result: Map.merge(run.result || %{}, %{status: status, summary: reason})
      }

      :ets.insert(@table, {run.agent_id, reconciled})
      append(run.agent_id, "RECONCILE status=#{status}\n\n#{reason}")
      Logger.info("[RunStore] reconciled stale :running run #{run.agent_id} -> #{status}")
      # The row is terminal now; drop the lease so the file does not linger.
      release_lease(run.agent_id)
      reconciled
    end)
  rescue
    _ -> []
  end

  defp claimed?(claim_fun, agent_id) do
    case claim_fun.(agent_id) do
      {:ok, _} ->
        true

      {:error, reason} ->
        Logger.info(
          "[RunStore] skipping #{agent_id}: owned by another process (#{inspect(reason)})"
        )

        false

      other ->
        other == true
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  # Default liveness probe: a run is alive iff its agent_id has a live entry in
  # the SessionRegistry. Wrapped so a missing registry (tests) reads as "dead".
  defp default_alive?(agent_id) do
    Registry.lookup(OptimalSystemAgent.SessionRegistry, agent_id) != []
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp safe_alive?(fun, agent_id) do
    fun.(agent_id) == true
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  @doc "Return a transcript as text if it exists."
  @spec transcript(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def transcript(agent_id) do
    path =
      case get(agent_id) do
        %{transcript_path: path} -> path
        nil -> transcript_path(agent_id)
      end

    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, "No transcript found for #{agent_id}"}
      {:error, reason} -> {:error, "Could not read transcript: #{inspect(reason)}"}
    end
  end

  @doc """
  Persist the child Loop's full message history + resume metadata so a run can
  later be resumed with COMPLETE context (CC resumeAgent parity). Stored as ETF
  next to the markdown transcript — shape-preserving and lossless. Best-effort.

  **Written crash-atomically** (temp + fsync + rename, the discipline used by
  `SessionPersistence` / `ProgressLedger`). This file is the ONLY copy of a
  subagent run's resume context: `load_messages/1` has no rebuild path and
  degrades a torn file to `{:error, :not_found}`, i.e. silent, permanent loss of
  the run's context. An in-place `File.write/2` can be torn by a crash or
  `ENOSPC` mid-write; a rename cannot — a reader sees either the whole previous
  version or the whole new one.
  """
  @spec save_messages(String.t(), [map()], map()) :: :ok
  def save_messages(agent_id, messages, meta \\ %{}) when is_list(messages) do
    payload = :erlang.term_to_binary(%{messages: messages, meta: meta})

    case atomic_write(messages_path(agent_id), payload) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.debug("[RunStore] save_messages failed for #{agent_id}: #{inspect(reason)}")
        :ok
    end
  rescue
    e ->
      Logger.debug("[RunStore] save_messages failed for #{agent_id}: #{Exception.message(e)}")
      :ok
  end

  @doc """
  Crash-atomic full-file write: write a temp file in the SAME directory, fsync
  it so the bytes are durable before it is published, then `rename/2` it into
  place (atomic within a filesystem). On any failure the temp file is removed
  and the previous contents are left untouched.
  """
  @spec atomic_write(String.t(), iodata()) :: :ok | {:error, term()}
  def atomic_write(path, contents) do
    tmp = path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, io} <- :file.open(tmp, [:write, :binary, :raw]),
         :ok <- write_and_sync(io, contents),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  defp write_and_sync(io, contents) do
    result =
      with :ok <- :file.write(io, contents) do
        :file.sync(io)
      end

    _ = :file.close(io)
    result
  end

  @doc "Load the saved message history + metadata for a run, if present."
  @spec load_messages(String.t()) :: {:ok, [map()], map()} | {:error, :not_found}
  def load_messages(agent_id) do
    case File.read(messages_path(agent_id)) do
      {:ok, bin} ->
        # :safe — a tampered file cannot create new atoms or run code.
        case :erlang.binary_to_term(bin, [:safe]) do
          %{messages: messages, meta: meta} when is_list(messages) and is_map(meta) ->
            {:ok, messages, meta}

          _ ->
            {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  @doc """
  Deterministic transcript (output-file) path for an agent id — safe to hand to
  the model BEFORE the run row exists (async-launch contract).
  """
  @spec transcript_path_for(String.t()) :: String.t()
  def transcript_path_for(agent_id), do: transcript_path(agent_id)

  defp messages_path(agent_id), do: transcript_path(agent_id) <> ".messages.etf"

  # ── ownership leases ───────────────────────────────────────────────────────
  #
  # Why a lease and not a better liveness guess: the question "is this run still
  # being executed?" is cross-process, and `Registry.lookup/2` is scoped to one
  # BEAM. No amount of tuning makes a local lookup answer a global question, and
  # every wrong answer is destructive (cancel / duplicate dispatch). A lease
  # inverts the burden of proof: a mutation is allowed only when this process
  # can PROVE it owns the run, and the proof lives where every process can see
  # it — on disk beside the run.

  defp lease_path(agent_id), do: transcript_path(agent_id) <> ".lease.json"

  @doc """
  Identity of this process as a lease owner: `%{owner_id:, os_pid:, os_start:,
  host:}`. `owner_id` is unique per BEAM (host, pid, process start time and a
  nanosecond nonce), so a *recycled* OS pid never inherits a previous owner's
  claim. Overridable wholesale via the `:run_lease_identity` app env, which is
  how tests impersonate a second, independent process.
  """
  @spec lease_identity() :: map()
  def lease_identity do
    base = default_identity()

    case Application.get_env(:optimal_system_agent, :run_lease_identity) do
      %{} = override ->
        Map.merge(base, Map.take(override, [:owner_id, :os_pid, :os_start, :host]))

      _ ->
        base
    end
  end

  defp default_identity do
    case :persistent_term.get({__MODULE__, :identity}, nil) do
      nil ->
        pid = self_os_pid()
        host = hostname()

        identity = %{
          owner_id:
            "#{host}:#{pid}:#{proc_start_time(pid) || 0}:#{System.system_time(:nanosecond)}",
          os_pid: pid,
          os_start: proc_start_time(pid),
          host: host
        }

        :persistent_term.put({__MODULE__, :identity}, identity)
        identity

      identity ->
        identity
    end
  end

  defp self_os_pid do
    case Integer.parse(System.pid()) do
      {n, _} -> n
      _ -> 0
    end
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> "unknown-host"
    end
  end

  @doc "Configured lease TTL in ms (`:run_lease_ttl_ms`)."
  @spec lease_ttl_ms() :: pos_integer()
  def lease_ttl_ms do
    case Application.get_env(:optimal_system_agent, :run_lease_ttl_ms, @default_lease_ttl_ms) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_lease_ttl_ms
    end
  end

  @doc """
  Current ownership of a run, from THIS process's point of view:

    * `{:free, nil}`      — no lease on disk (never claimed, or cleanly released)
    * `{:mine, lease}`    — we hold it
    * `{:held, lease}`    — another owner holds it and the claim is still good
    * `{:expired, lease}` — another owner's claim lapsed AND the OS check does
      not contradict that, so it may be stolen

  Note the asymmetry in `:held` vs `:expired`: expiry is the primary signal, and
  the OS liveness check can only keep a lapsed lease `:held` (owner demonstrably
  still alive). It can never expire a lease early.
  """
  @spec lease_state(String.t()) ::
          {:free, nil} | {:mine, map()} | {:held, map()} | {:expired, map()}
  def lease_state(agent_id) when is_binary(agent_id) do
    identity = lease_identity()

    case read_lease(agent_id) do
      nil ->
        {:free, nil}

      lease ->
        cond do
          Map.get(lease, "owner_id") == identity.owner_id -> {:mine, lease}
          lease_expired?(lease) and owner_alive?(lease) != true -> {:expired, lease}
          true -> {:held, lease}
        end
    end
  end

  @doc """
  Read-only: could this process take ownership right now? Used for *selection*
  (which must stay side-effect free); every destructive path still re-acquires
  with `claim_lease/1` immediately before mutating.
  """
  @spec lease_claimable?(String.t()) :: boolean()
  def lease_claimable?(agent_id) when is_binary(agent_id) do
    case lease_state(agent_id) do
      {:held, _} -> false
      _ -> true
    end
  end

  def lease_claimable?(_), do: false

  @doc """
  Acquire (or re-affirm) ownership of a run. Returns `{:ok, lease}` when this
  process owns the run afterwards, `{:error, {:held_by, lease}}` when another
  live owner does.

  The free-slot path uses an `O_EXCL` create so two processes racing a fresh id
  cannot both win. The steal path (expired lease only) writes atomically and
  then RE-READS to confirm our own `owner_id` survived, so two simultaneous
  stealers cannot both believe they won.
  """
  @spec claim_lease(String.t()) :: {:ok, map()} | {:error, term()}
  def claim_lease(agent_id) when is_binary(agent_id), do: do_claim(agent_id, 0)
  def claim_lease(_), do: {:error, :invalid_agent_id}

  defp do_claim(_agent_id, attempt) when attempt > 2, do: {:error, :claim_contended}

  defp do_claim(agent_id, attempt) do
    identity = lease_identity()
    path = lease_path(agent_id)
    _ = File.mkdir_p(Path.dirname(path))

    case create_exclusive(path, encode_lease(agent_id, identity)) do
      :ok ->
        register_owned(agent_id)
        {:ok, read_lease(agent_id)}

      {:error, :eexist} ->
        case lease_state(agent_id) do
          {:mine, _} ->
            _ = atomic_write(path, encode_lease(agent_id, identity))
            register_owned(agent_id)
            {:ok, read_lease(agent_id)}

          {:expired, lease} ->
            steal_lease(agent_id, identity, lease)

          {:held, lease} ->
            {:error, {:held_by, lease}}

          {:free, _} ->
            # The file vanished between the create and the read; retry.
            do_claim(agent_id, attempt + 1)
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp steal_lease(agent_id, identity, previous) do
    case atomic_write(lease_path(agent_id), encode_lease(agent_id, identity)) do
      :ok ->
        # Confirm we, and not a concurrent stealer, own the published file.
        case read_lease(agent_id) do
          nil ->
            {:error, :lease_vanished}

          %{"owner_id" => owner} = lease ->
            if owner == identity.owner_id do
              register_owned(agent_id)

              Logger.info(
                "[RunStore] stole expired lease for #{agent_id} from " <>
                  "#{inspect(Map.get(previous, "owner_id"))}"
              )

              {:ok, lease}
            else
              {:error, {:held_by, lease}}
            end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Heartbeat: extend our claim on a run we own. Returns `{:error, :lost}` when
  the lease is no longer ours — the signal that the run must be aborted.
  """
  @spec renew_lease(String.t()) :: :ok | {:error, term()}
  def renew_lease(agent_id) when is_binary(agent_id) do
    case lease_state(agent_id) do
      {:mine, lease} ->
        atomic_write(
          lease_path(agent_id),
          Jason.encode!(Map.put(lease, "renewed_at", now_ms()))
        )

      {:free, _} ->
        # Our own lease file was removed underneath us (manual cleanup); as the
        # local owner we may re-create it, but only if nobody else claims first.
        case claim_lease(agent_id) do
          {:ok, _} -> :ok
          _ -> {:error, :lost}
        end

      {_, _} ->
        {:error, :lost}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc """
  Release a lease we own. Called ONLY on a clean terminal transition
  (`complete/2`, reconcile). Never call this from a crash/exit path: a lease
  that self-clears on an unclean shutdown lets a second process start racing a
  worker that may still be half-alive. Let it expire instead.
  """
  @spec release_lease(String.t()) :: :ok
  def release_lease(agent_id) when is_binary(agent_id) do
    case lease_state(agent_id) do
      {:mine, _} -> _ = File.rm(lease_path(agent_id))
      _ -> :ok
    end

    unregister_owned(agent_id)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def release_lease(_), do: :ok

  @doc "True iff this process currently holds the lease for `agent_id`."
  @spec owns_lease?(String.t()) :: boolean()
  def owns_lease?(agent_id) when is_binary(agent_id) do
    match?({:mine, _}, lease_state(agent_id))
  end

  def owns_lease?(_), do: false

  @doc """
  `:running` rows that are NOT demonstrably owned by another live process.

  This is what fleet counts and parent-shutdown sweeps must use: `all_running/0`
  reads a machine-global index, so in a second `osa` invocation it includes
  other processes' live runs. Rows with no lease at all (legacy runs, rows
  inserted directly by tests) are treated as local — only a lease actively held
  elsewhere excludes a row.
  """
  @spec all_running_local() :: [run()]
  def all_running_local do
    all_running()
    |> Enum.reject(fn run -> match?({:held, _}, lease_state(run.agent_id)) end)
  rescue
    _ -> []
  end

  # ── heartbeat ──────────────────────────────────────────────────────────────

  @doc false
  @spec heartbeat_tick() :: :ok
  def heartbeat_tick do
    ensure_lease_table()

    @lease_owners
    |> :ets.tab2list()
    |> Enum.each(fn {agent_id} ->
      case renew_lease(agent_id) do
        :ok -> :ok
        {:error, :lost} -> handle_ownership_loss(agent_id)
        {:error, _other} -> :ok
      end
    end)

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc """
  Ownership was lost mid-flight (another process legitimately took over after
  our claim expired). The run must not keep executing unowned: mark the local
  row terminal, note it on the transcript, and abort the loop.
  """
  @spec handle_ownership_loss(String.t()) :: :ok
  def handle_ownership_loss(agent_id) when is_binary(agent_id) do
    Logger.warning("[RunStore] #{@lease_lost_reason} (#{agent_id})")
    unregister_owned(agent_id)

    update(agent_id, fn run ->
      if run.status == :running do
        %{
          run
          | status: :cancelled,
            completed_at: DateTime.utc_now(),
            result:
              Map.merge(run.result || %{}, %{status: :cancelled, summary: @lease_lost_reason})
        }
      else
        run
      end
    end)

    append(agent_id, "LEASE_LOST status=cancelled\n\n#{@lease_lost_reason}")
    abort_run(agent_id)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp abort_run(agent_id) do
    case Application.get_env(:optimal_system_agent, :run_lease_abort_fun) do
      fun when is_function(fun, 1) -> fun.(agent_id)
      _ -> OptimalSystemAgent.Agent.Fleet.stop_node(agent_id)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp ensure_heartbeat do
    if is_nil(Process.whereis(@heartbeat_name)) do
      pid = spawn(fn -> heartbeat_loop() end)

      try do
        Process.register(pid, @heartbeat_name)
      rescue
        _ -> Process.exit(pid, :kill)
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  defp heartbeat_loop do
    interval = max(div(lease_ttl_ms(), 3), 1_000)

    receive do
      :stop -> :ok
    after
      interval ->
        heartbeat_tick()
        heartbeat_loop()
    end
  end

  # ── lease plumbing ─────────────────────────────────────────────────────────

  defp encode_lease(agent_id, identity) do
    now = now_ms()

    Jason.encode!(%{
      "agent_id" => agent_id,
      "owner_id" => identity.owner_id,
      "host" => identity.host,
      "node" => to_string(node()),
      "os_pid" => identity.os_pid,
      "os_start" => identity.os_start,
      "claimed_at" => now,
      "renewed_at" => now,
      "ttl_ms" => lease_ttl_ms()
    })
  end

  defp read_lease(agent_id) do
    with {:ok, bin} <- File.read(lease_path(agent_id)),
         {:ok, %{"owner_id" => _} = lease} <- Jason.decode(bin) do
      lease
    else
      _ -> nil
    end
  end

  defp lease_expired?(lease) do
    renewed = Map.get(lease, "renewed_at")
    ttl = Map.get(lease, "ttl_ms")

    cond do
      not is_integer(renewed) -> true
      not is_integer(ttl) or ttl <= 0 -> now_ms() - renewed > lease_ttl_ms()
      true -> now_ms() - renewed > ttl
    end
  end

  # Belt-and-braces OS check. `true` = the owning process definitely still
  # exists with the same start time; `false` = definitely gone (or the pid was
  # recycled into a different process); `:unknown` = we cannot tell (no procfs,
  # lease written on another host, no recorded start time). Only `true` blocks a
  # steal — an inconclusive answer defers to the expiry that already elapsed.
  defp owner_alive?(lease) do
    pid = Map.get(lease, "os_pid")
    start = Map.get(lease, "os_start")
    host = Map.get(lease, "host")

    cond do
      not procfs?() -> :unknown
      is_binary(host) and host != hostname() -> :unknown
      not is_integer(pid) -> :unknown
      not File.exists?("/proc/#{pid}/stat") -> false
      not is_integer(start) -> :unknown
      proc_start_time(pid) == start -> true
      true -> false
    end
  rescue
    _ -> :unknown
  end

  defp procfs?, do: File.dir?("/proc/self")

  # Field 22 of /proc/<pid>/stat (starttime, in clock ticks since boot). Parsed
  # after the ") " that closes the comm field, since comm may contain spaces.
  defp proc_start_time(pid) when is_integer(pid) do
    with true <- procfs?(),
         {:ok, content} <- File.read("/proc/#{pid}/stat"),
         [_head, rest] <- String.split(content, ") ", parts: 2),
         token when is_binary(token) <- rest |> String.split(" ") |> Enum.at(19),
         {n, _} <- Integer.parse(token) do
      n
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp proc_start_time(_), do: nil

  # O_EXCL|O_CREAT: succeeds only if we created the file, so two processes
  # racing a never-before-claimed run cannot both win.
  defp create_exclusive(path, contents) do
    case :file.open(path, [:write, :binary, :raw, :exclusive]) do
      {:ok, io} -> write_and_sync(io, contents)
      {:error, reason} -> {:error, reason}
    end
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp ensure_lease_table do
    case :ets.whereis(@lease_owners) do
      :undefined ->
        :ets.new(@lease_owners, [:named_table, :public, :set])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp register_owned(agent_id) do
    ensure_lease_table()
    :ets.insert(@lease_owners, {agent_id})
    ensure_heartbeat()
    :ok
  rescue
    _ -> :ok
  end

  defp unregister_owned(agent_id) do
    ensure_lease_table()
    :ets.delete(@lease_owners, agent_id)
    :ok
  rescue
    _ -> :ok
  end

  @doc "Format a structured result for legacy string-return callers."
  @spec format_result(map()) :: String.t()
  def format_result(result) do
    files =
      result
      |> Map.get(:files_changed, [])
      |> case do
        [] -> "none"
        list -> Enum.join(list, ", ")
      end

    commands =
      result
      |> Map.get(:commands_run, [])
      |> case do
        [] -> "none"
        list -> Enum.join(list, "\n")
      end

    """
    Agent #{Map.get(result, :agent_id, "unknown")} #{Map.get(result, :status, :completed)}

    #{Map.get(result, :summary, "")}

    Files changed: #{files}
    Commands run: #{commands}
    Tools: #{Map.get(result, :tool_count, 0)}
    Tokens: #{Map.get(result, :tokens_used, 0)}
    Duration: #{Map.get(result, :duration_ms, 0)}ms
    Transcript: #{Map.get(result, :transcript_path, "unavailable")}
    """
    |> String.trim()
  end

  defp update(agent_id, fun) do
    ensure_table()

    case get(agent_id) do
      nil -> :ok
      run -> :ets.insert(@table, {agent_id, fun.(run)})
    end
  end

  defp append(agent_id, body) do
    path = transcript_path(agent_id)
    File.mkdir_p!(Path.dirname(path))

    # Sidechain transcripts are a durable on-disk artifact under
    # `~/.osa/agent-runs`, written from subagent progress lines, commands run
    # and result summaries — all of which can carry whatever a tool echoed.
    # Redact at the write boundary (the single funnel for every `append/2`
    # caller) so a key a subagent's shell command printed is not persisted.
    body = Trajectory.redact(to_string(body))

    entry = """

    ## #{DateTime.utc_now() |> DateTime.to_iso8601()}

    #{body}
    """

    File.write(path, entry, [:append])
    :ok
  rescue
    e ->
      Logger.debug("[RunStore] transcript append failed for #{agent_id}: #{Exception.message(e)}")
      :ok
  end

  defp transcript_path(agent_id) do
    safe_id = Regex.replace(~r/[^a-zA-Z0-9_\-]/, agent_id, "_")
    Path.join(runs_dir(), "#{safe_id}.md")
  end

  defp runs_dir do
    Application.get_env(:optimal_system_agent, :agent_runs_dir) || default_runs_dir()
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, read_concurrency: true])
        :ok

      _ ->
        :ok
    end

    ensure_edges_table()
  rescue
    ArgumentError -> :ok
  end

  # ── run-tree edge ledger ────────────────────────────────────────────────
  #
  # `prune_terminal/0` evicts terminal run ROWS past @max_terminal_runs, and
  # `list/1` is capped and machine-wide. Neither is a safe basis for a spend
  # rollup: a wide fan-out evicts its own finished nodes, their cost vanishes
  # from the tree total, and an exhausted budget silently un-exhausts itself.
  #
  # So parentage is recorded here instead, in a table that is NEVER pruned and
  # NEVER capped. An edge is two binaries; the whole ledger is orders of
  # magnitude smaller than the run rows it outlives.
  defp ensure_edges_table do
    case :ets.whereis(@edges_table) do
      :undefined ->
        :ets.new(@edges_table, [:named_table, :public, :bag, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp record_edge(agent_id, parent) when is_binary(agent_id) and is_binary(parent) do
    ensure_edges_table()

    # `:bag` keeps duplicates distinct by full tuple, so re-registering the same
    # run under the same parent is idempotent; a re-parent adds a second edge,
    # which the walker tolerates via its `seen` guard.
    :ets.insert(@edges_table, {parent, agent_id})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp record_edge(_, _), do: :ok

  @doc """
  Direct children of `parent` in the run tree, from the unpruned edge ledger.

  Unlike `list/1` this is neither capped nor evictable, so a spend/rollup walk
  built on it cannot lose nodes to `prune_terminal/0`.
  """
  @spec children_of(String.t()) :: [String.t()]
  def children_of(parent) when is_binary(parent) do
    ensure_edges_table()

    @edges_table
    |> :ets.lookup(parent)
    |> Enum.map(fn {_p, child} -> child end)
    |> Enum.uniq()
  rescue
    ArgumentError -> []
  end

  def children_of(_), do: []

  @doc """
  Create the ETS index and rehydrate known runs from disk. Call from the app
  supervisor's boot so the table is owned by the long-lived app master process
  (not a transient task that would take the table down with it). Idempotent.
  """
  @spec init_store() :: :ok
  def init_store do
    ensure_table()
    rehydrate()
    :ok
  end

  @doc """
  Rebuild the ETS run index from `~/.osa/agent-runs/*.md` (+ `.messages.etf`) so
  `/runs` and `task_resume` survive a node restart (CC sidechain rehydrate
  parity). Newest @max_terminal_runs runs only. Best-effort; never raises.
  """
  @spec rehydrate() :: :ok
  def rehydrate do
    ensure_table()
    dir = runs_dir()

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(fn name -> {name, file_mtime(Path.join(dir, name))} end)
        |> Enum.sort_by(fn {_n, dt} -> DateTime.to_unix(dt) end, :desc)
        |> Enum.take(@max_terminal_runs)
        |> Enum.each(fn {name, mtime} ->
          try do
            rehydrate_file(dir, name, mtime)
          rescue
            _ -> :ok
          end
        end)

        :ok

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp rehydrate_file(dir, md_name, mtime) do
    md_path = Path.join(dir, md_name)
    safe_id = String.replace_suffix(md_name, ".md", "")
    etf_path = md_path <> ".messages.etf"

    meta =
      case File.read(etf_path) do
        {:ok, bin} ->
          case safe_term(bin) do
            %{meta: m} when is_map(m) -> m
            _ -> %{}
          end

        _ ->
          %{}
      end

    # Prefer the original (unsanitized) agent_id persisted in meta; the filename
    # is sanitized and would not match RunStore.get(original_id) on resume.
    agent_id = Map.get(meta, :agent_id) || safe_id

    # Never clobber a live/in-memory row.
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, _}] ->
        :ok

      _ ->
        content =
          case File.read(md_path) do
            {:ok, c} -> c
            _ -> ""
          end

        status = rehydrated_status(agent_id, content)

        run = %{
          agent_id: agent_id,
          parent_session_id: Map.get(meta, :parent_session_id) || "unknown",
          role: Map.get(meta, :role) || "agent",
          task: Map.get(meta, :task) || extract_task(content),
          status: status,
          started_at: mtime,
          completed_at: if(status == :running, do: nil, else: mtime),
          duration_ms: nil,
          tool_count: 0,
          tokens_used: 0,
          recent_actions: [],
          result: nil,
          transcript_path: md_path,
          resumed_from: Map.get(meta, :resumed_from),
          posture: Map.get(meta, :posture)
        }

        :ets.insert(@table, {agent_id, run})
        :ok
    end
  end

  defp safe_term(bin) do
    :erlang.binary_to_term(bin, [:safe])
  rescue
    _ -> nil
  end

  # A transcript with no STOP record is ambiguous: its owner may have died
  # mid-run (a genuine orphan) or the run may still be EXECUTING in another live
  # `osa` process — `~/.osa/agent-runs` is machine-global and every invocation
  # rehydrates from it. The ownership lease is the only cross-process authority
  # on which, so it decides. Previously such a run was unconditionally recorded
  # as `:failed`, which silently mislabelled another process's healthy run as
  # dead in this process's index.
  defp rehydrated_status(agent_id, content) do
    case infer_status(content) do
      :failed ->
        if not stop_recorded?(content) and match?({:held, _}, lease_state(agent_id)),
          do: :running,
          else: :failed

      other ->
        other
    end
  rescue
    _ -> :failed
  end

  defp stop_recorded?(content), do: Regex.match?(~r/STOP status=(\w+)/, content)

  defp infer_status(content) do
    case Regex.scan(~r/STOP status=(\w+)/, content) do
      [] ->
        :failed

      matches ->
        [_, token] = List.last(matches)

        case token do
          "completed" -> :completed
          "failed" -> :failed
          "cancelled" -> :cancelled
          _ -> :completed
        end
    end
  end

  defp extract_task(content) do
    case Regex.run(~r/START role=[^\n]*\n\n(.+?)(?:\n\n## |\z)/s, content) do
      [_, task] -> task |> String.trim() |> String.slice(0, 500)
      _ -> ""
    end
  end

  defp file_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: secs}} when is_integer(secs) -> DateTime.from_unix!(secs)
      _ -> DateTime.utc_now()
    end
  end
end
