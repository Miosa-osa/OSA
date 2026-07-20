defmodule OptimalSystemAgent.Agent.Loop do
  @moduledoc """
  Bounded ReAct agent loop — the core reasoning engine.

  Messages pass through several pre-LLM gates before the LLM is invoked:

    0. Prompt injection check (Guardrails) — hard block, no memory write
    1. Noise filter — disabled (Fix #57); every message reaches the LLM
    2. Genre routing (GenreRouter) — route by signal genre; some genres
       return a canned response without tool invocation
    3. Plan mode — single LLM call with no tools (when plan_mode is active)
    4. Full ReAct loop — LLM + iterative tool calls

  ## Sub-module responsibilities
  - `Loop.ReactLoop`      — bounded Reason-Act iteration, LLM calls, tool execution
  - `Loop.MessageHandler` — turn-level message decoration (nudges, directives, plan mode)
  - `Loop.ToolFilter`     — tool list budget and weight gating before LLM calls
  - `Loop.DoomLoop`       — repeated-failure detection and halt
  - `Loop.Survey`         — interactive user question / polling
  - `Loop.ToolExecutor`   — permission enforcement, hook pipeline, parallel dispatch
  - `Loop.Guardrails`     — prompt injection detection and behavioral heuristics
  - `Loop.LLMClient`      — provider-agnostic LLM call with streaming
  - `Loop.Checkpoint`     — crash-recovery state snapshots
  - `Loop.GenreRouter`    — signal genre routing

  ## Turn / iteration / budget stop taxonomy

  A single turn can end for four INDEPENDENT reasons. Checked per iteration in
  `ReactLoop.run/1` (and around it), each broadcasts a TYPED `:system_event` so
  consumers (TUI, analytics) render it distinctly rather than as a plain
  `agent_response`:

    1. `max_iterations`      — per-turn tool round-trip ceiling. Config
       `:max_iterations` wins; else the effort ceiling (`Effort.max_iterations/0`).
       A genuine backstop, NOT a routine cap. Event: `:max_iterations_reached`.
    2. `max_budget_usd`      — per-session USD spend cap (`Loop.Limits`).
       Default nil = OFF. Event: `:budget_limit_reached`.
    3. `doom_loop_max_calls` — absolute session tool-call cap plus repeated
       failure / identical-call detection (`Loop.DoomLoop`).
       Event: `:tool_call_cap_exceeded` (and `:doom_loop_halt`).
    4. `max_turns`           — cross-turn conversation cap (`Loop.Limits`, turn
       pipeline), enforced before the LLM is invoked.
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Tools.Registry, as: Tools
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Observability

  alias OptimalSystemAgent.Agent.Loop.ToolExecutor
  alias OptimalSystemAgent.Agent.Loop.Guardrails
  alias OptimalSystemAgent.Agent.Loop.Checkpoint
  alias OptimalSystemAgent.Agent.Loop.DurableLog
  alias OptimalSystemAgent.Agent.Loop.MessageHandler
  alias OptimalSystemAgent.Agent.Loop.ReactLoop
  alias OptimalSystemAgent.Agent.Loop.Steer
  alias OptimalSystemAgent.Agent.Loop.Survey
  alias OptimalSystemAgent.Agent.Loop.Telemetry
  alias OptimalSystemAgent.Agent.Loop.ToolFilter
  alias OptimalSystemAgent.Agent.Loop.TurnPipeline
  alias OptimalSystemAgent.Agent.Hooks
  alias OptimalSystemAgent.Agent.TaskNotifications

  defstruct [
    :session_id,
    :user_id,
    :channel,
    :provider,
    :model,
    :effective_context_window,
    :working_dir,
    messages: [],
    iteration: 0,
    overflow_retries: 0,
    recent_failure_signatures: [],
    total_tool_calls: 0,
    # Doom-loop detection counters — explicit state (formerly process-dict).
    # See `Loop.DoomLoop` and its sub-detectors for ownership:
    #   doom_recovery_count     — repeated-failure recovery attempts, reset each turn
    #   graded_escalation_count — graded "change approach" step, persists per session
    #   escalated_this_tick     — per-check guard so nudges don't stack in one tick
    doom_recovery_count: 0,
    graded_escalation_count: 0,
    escalated_this_tick: false,
    auto_continues: 0,
    status: :idle,
    tools: [],
    plan_mode: false,
    plan_mode_enabled: false,
    turn_count: 0,
    last_meta: %{iteration_count: 0, tools_used: []},
    explored_files: MapSet.new(),
    exploration_done: false,
    # :full | :workspace | :read_only | :subagent | :auto
    # default stays :full; :auto (near-zero-prompt unattended execution gated by
    # the safety Guardian) is opt-in via /auto_mode or set_permission_mode auto.
    permission_tier: :full,
    # Higher-level permission MODE selector (Shift+Tab cycle: ask → accept_edits
    # → plan → overdrive). Gates tool calls in ToolExecutor.approve_tool_call/2
    # BEFORE the tier cond:
    #   :ask (default) → tier + Guardian, then interactive prompt for mutating
    #                    tools (the round-trip the TUI permission dialog drives)
    #   :accept_edits  → auto-allow single-file edit/write, else ask/tier
    #   :plan          → read-only (deny mutating tools)
    #   :overdrive     → allow all past the non-bypassable circuit-breaker
    permission_mode: :ask,
    # Subagent fields
    parent_session_id: nil,
    allowed_tools: nil,
    blocked_tools: [],
    system_prompt_override: nil,
    # Reasoning strategy — removed, kept for struct compat
    strategy: nil,
    strategy_state: %{},
    # Per-call signal weight (0.0–1.0 or nil)
    signal_weight: nil,
    # Raw user input for the current turn, set at ingestion by
    # TurnPipeline.prepare_turn/3. Threaded into the :post_response payload
    # (episodic recorder, auto skill creator) so hooks see the USER's text —
    # the old List.last(state.messages) derivation returned the assistant
    # reply because the assistant message had just been appended.
    current_input: nil,
    started_at: nil,
    last_input_tokens: 0,
    # Per-turn correlation id (a prompt.id-style field) minted by
    # `Observability.new_turn_id/0` at turn start. Threaded into the CloudEvent
    # envelope of every lifecycle event so the per-session event stream is a
    # correlated, replayable log (primitive #30).
    turn_id: nil,
    # Per-session token + cost accounting (primitive #29). Always on — see
    # `Loop.Accounting`. `session_cost_usd` is the running spend that makes the
    # `max_budget_usd` cap real; exposed via `get_state` for the TUI/auto-mode.
    session_cost_usd: 0.0,
    session_input_tokens: 0,
    session_output_tokens: 0,
    session_cache_creation_tokens: 0,
    session_cache_read_tokens: 0,
    # Coordinator mode — restricts tools to delegation/messaging/management only
    coordinator: false,
    # The UNFILTERED base tool list (applicable tools ++ extra_tools) captured at
    # init. Preserved so the runtime coordinator toggle can restore full tool
    # access (`tools = filter_for_coordinator(all_tools, coordinator)`) without
    # restarting the session / churning the session id.
    all_tools: [],
    # Budget and turn limits — nil = no limit
    max_budget_usd: nil,
    max_turns: nil,
    # Delegation nesting depth — 0 for a top-level session, incremented for
    # each subagent generation. Read by ToolFilter to strip spawning tools at
    # the max depth (fork-bomb / runaway-cost guard).
    delegation_depth: 0,
    # Tri-mode delegation policy (primitive #34): :disabled | :explicit_only |
    # :proactive. nil defers to `config :optimal_system_agent, :delegation_policy`
    # (default :proactive). Read by ToolFilter + the delegate handler.
    delegation_policy: nil
  ]

  @cancel_table :osa_cancel_flags

  # --- Client API ---

  @doc """
  Override child_spec to use `:transient` restart strategy.
  Loop processes should only restart on crash, not on normal exit.
  """
  def child_spec(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    %{
      id: {__MODULE__, session_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    user_id = Keyword.get(opts, :user_id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {OptimalSystemAgent.SessionRegistry, session_id, user_id}}
    )
  end

  def process_message(session_id, message, opts \\ []) do
    # The agent loop runs up to `max_turns` iterations with tool calls and
    # subagents, and is bounded logically by max_turns + max_budget_usd — not
    # by wall-clock here. The previous 30s (then 10-min) default capped every
    # real task far below the loop's own limits, so multi-step work (e.g.
    # codebase exploration) or an hours-long autonomous run died with
    # {:timeout}. The turn is already bounded logically by max_iterations +
    # max_budget_usd, so the wall-clock is redundant and fatal for long runs:
    # default to `:infinity`. An explicit opts[:timeout] still wins, and the
    # global default is tunable via `:agent_turn_timeout_ms`.
    timeout =
      Keyword.get(opts, :timeout) ||
        Application.get_env(:optimal_system_agent, :agent_turn_timeout_ms, :infinity)

    GenServer.call(via(session_id), {:process, message, opts}, timeout)
  end

  @doc "Get a snapshot of loop state (iteration count, token estimate, status, etc.)."
  def get_state(session_id) do
    GenServer.call(via(session_id), :get_state)
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc "Get metadata from the last process_message call (iteration_count, tools_used)."
  def get_metadata(session_id) do
    GenServer.call(via(session_id), :get_metadata)
  rescue
    _ -> %{iteration_count: 0, tools_used: []}
  catch
    # A subagent already terminated (e.g. `cancel/1` force-terminating it, or
    # Orchestrator's own join-timeout termination — both now legitimate
    # post-conditions of a subagent join, not just a rare race) makes this an
    # ordinary GenServer `:exit`, not a raised exception — `rescue` above
    # never catches it. Orchestrator.get_subagent_stats/1 calls this
    # unconditionally right after a subagent finishes (success OR failure),
    # so this must degrade gracefully instead of crashing the caller.
    :exit, _ -> %{iteration_count: 0, tools_used: []}
  end

  @doc """
  Return the raw message history for a session.

  Used by the Orchestrator to derive real result metadata (commands run,
  final assistant message) from a subagent after it finishes. Safe to call
  from another process — never from inside the loop's own callback.
  """
  @spec get_messages(String.t()) :: [map()]
  def get_messages(session_id) do
    GenServer.call(via(session_id), :get_messages)
  catch
    :exit, _ -> []
  end

  @doc """
  Inject a completed background-agent result into this session's message
  history so the orchestrator LLM can reason about it on its next turn.

  Mirrors Claude Code's completion notification: the result lands in the
  parent's transcript as a synthetic user message. Delivered as a cast so it
  is serialised with the loop's own callbacks and never deadlocks a caller
  that happens to be the loop process itself.
  """
  @spec inject_agent_result(String.t(), String.t()) :: :ok
  def inject_agent_result(session_id, content) when is_binary(content) do
    GenServer.cast(via(session_id), {:inject_agent_result, content})
  catch
    :exit, _ -> :ok
  end

  @doc """
  Queue a mid-turn steer directive for a running session (primitive #32).

  The text is folded into the live ReAct loop at its NEXT step boundary as a
  user-authored system directive, so the agent adapts WITHOUT the turn being
  cancelled and in-flight work being lost — this is the true mid-turn path the
  TUI `/steer` targets while the agent is Processing.

  Transport is the ETS steer queue (`Loop.Steer`), not the process mailbox,
  because the loop process is blocked in `handle_call` for the whole turn and
  would not service a `cast` until the turn ended. The accompanying `{:steer,
  text}` cast only handles the idle case (mailbox free): it drains any still-
  queued steers into history so they are not stranded until the next turn. The
  ETS drain is destructive, so exactly one of the two paths injects each steer.

  Always returns `:ok`; a steer for an unknown/dead session is simply never
  drained.
  """
  @spec steer(String.t(), String.t()) :: :ok
  def steer(session_id, text) when is_binary(session_id) and is_binary(text) do
    Steer.queue(session_id, text)
    GenServer.cast(via(session_id), {:steer, text})
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Poke an IDLE session to service its pending background task notifications
  (WS6). If the loop is mid-turn the cast waits in the mailbox until the turn
  ends — but the running ReactLoop drains the same queue at its next step
  boundary first, so the late poke finds an empty queue and no-ops (drain is
  destructive → exactly-once). If the loop is idle, the notifications become
  a synthetic turn: the agent reacts to the completion unprompted, mirroring
  Claude Code's background-task resume.

  Always returns `:ok`; poking an unknown/dead session is a no-op.
  """
  @spec poke(String.t()) :: :ok
  def poke(session_id) when is_binary(session_id) do
    GenServer.cast(via(session_id), :poke)
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Compact the live session context buffer.

  Returns `:ok` or `{:error, :no_session}`.
  """
  @spec compact(String.t()) :: :ok | {:error, :no_session | term()}
  def compact(session_id) do
    GenServer.call(via(session_id), :compact)
  catch
    :exit, _ -> {:error, :no_session}
  end

  @doc """
  Proactively compact the live session's context buffer using
  `ProactiveCompaction.compact/1` — folds older turns into a high-recall
  summary before the window fills.

  Returns `{:ok, %{messages_before, messages_after, tokens_before, tokens_after}}`
  or `{:error, :no_session}`.
  """
  @spec proactive_compact(String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, :no_session | term()}
  def proactive_compact(session_id, instructions \\ nil) do
    GenServer.call(via(session_id), {:proactive_compact, instructions}, 120_000)
  catch
    :exit, _ -> {:error, :no_session}
  end

  @doc """
  Drop the last exchange from the live session's context buffer — the backend
  half of `/undo`. Removes the most recent `user` turn AND every message after
  it from `state.messages` (what the model sees next turn). Returns
  `{:ok, %{messages_before, messages_after, dropped}}` or `{:error, :no_session}`.
  """
  @spec undo(String.t()) :: {:ok, map()} | {:error, :no_session | term()}
  def undo(session_id) do
    GenServer.call(via(session_id), :undo)
  catch
    :exit, _ -> {:error, :no_session}
  end

  @doc """
  Toggle plan mode for the session.

  Returns `{:ok, enabled?}` or `{:error, :no_session}`.
  """
  @spec toggle_plan_mode(String.t()) :: {:ok, boolean()} | {:error, :no_session | term()}
  def toggle_plan_mode(session_id) do
    GenServer.call(via(session_id), :toggle_plan_mode)
  catch
    :exit, _ -> {:error, :no_session}
  end

  @doc """
  Enable plan mode for the session, saving the current `plan_mode_enabled`
  value so `exit_plan_mode/1` can restore it precisely.

  Returns `{:ok, :entered}`, `{:ok, :already_active}`, or `{:error, :no_session}`.
  """
  @spec enter_plan_mode(String.t()) ::
          {:ok, :entered | :already_active} | {:error, :no_session | term()}
  def enter_plan_mode(session_id) do
    GenServer.call(via(session_id), :enter_plan_mode)
  catch
    :exit, _ -> {:error, :no_session}
  end

  @doc """
  Disable plan mode for the session, restoring the permission state captured
  at `enter_plan_mode/1` time.

  Returns `{:ok, :exited}`, `{:ok, :was_not_active}`, or `{:error, :no_session}`.
  """
  @spec exit_plan_mode(String.t()) ::
          {:ok, :exited | :was_not_active} | {:error, :no_session | term()}
  def exit_plan_mode(session_id) do
    GenServer.call(via(session_id), :exit_plan_mode)
  catch
    :exit, _ -> {:error, :no_session}
  end

  @doc """
  Set the permission tier for a running session
  (`:full | :workspace | :read_only | :subagent | :auto`).

  Used by the HTTP `/commands/execute` auto-mode toggle and the CLI to flip a
  session into near-zero-prompt unattended execution and back to `:full`.
  """
  @spec set_permission_tier(String.t(), atom()) :: {:ok, atom()} | {:error, :no_session}
  def set_permission_tier(session_id, tier) do
    GenServer.call(via(session_id), {:set_permission_tier, tier})
  catch
    :exit, _ -> {:error, :no_session}
  end

  @doc """
  Set the higher-level permission mode for a running session
  (`:ask | :accept_edits | :plan | :overdrive`). `:bypass` is accepted as a
  silent alias for `:overdrive`.

  Used by the HTTP `set_permission_mode <mode>` command (the Shift+Tab cycle and
  `/overdrive`) so the ToolExecutor gate takes effect server-side.

  The chosen mode is ALSO recorded in the sticky per-session
  `Agent.PermissionMode` store BEFORE touching the live loop. That makes the
  choice survive two ways the old behavior lost it: (a) a mode set before the
  turn's loop exists (`{:error, :no_session}` — `Loop.init` will now seed from
  the sticky store), and (b) a loop later (re)created fresh for the session.
  On the `:no_session` race we therefore report `{:ok, mode}` (pending) rather
  than a hard error — the mode WILL apply when the loop starts.
  """
  @spec set_permission_mode(String.t(), atom()) ::
          {:ok, atom()} | {:error, :invalid_mode | :no_session}
  def set_permission_mode(session_id, mode) do
    # Persist first so the choice is sticky even if no live loop picks it up.
    OptimalSystemAgent.Agent.PermissionMode.put(session_id, mode)

    GenServer.call(via(session_id), {:set_permission_mode, mode})
  catch
    :exit, _ ->
      # No live loop yet. The sticky store seeds the mode on Loop.init, so the
      # request is honored — surface it as a pending success, not a lost error.
      if mode in [:ask, :accept_edits, :plan, :overdrive, :bypass] do
        {:ok, mode}
      else
        {:error, :no_session}
      end
  end

  @doc "Get the current permission mode for a running session."
  @spec get_permission_mode(String.t()) :: {:ok, atom()} | {:error, :no_session}
  def get_permission_mode(session_id) do
    GenServer.call(via(session_id), {:get_permission_mode})
  catch
    :exit, _ -> {:error, :no_session}
  end

  @doc """
  Set the coordinator posture for a session IN PLACE, with no session-id change.

  Coordinator mode restricts the live tool list to delegation/messaging/
  management tools (`ToolFilter.filter_for_coordinator/2`); turning it off
  restores the unfiltered `all_tools` captured at init. Unlike the old CLI
  toggle (which restarted the session and churned its id), this re-restricts or
  restores the running loop's `state.tools` live.

  The choice is recorded in the sticky per-session `Agent.CoordinatorMode` store
  BEFORE touching the live loop, so it survives (a) a toggle set before the
  turn's loop exists (`:no_session` race, where `Loop.init/1` seeds from the store)
  and (b) a loop later (re)created fresh for the session. A `coordinator_mode`
  system_event is emitted so the TUI indicator tracks the resulting state.
  """
  @spec set_coordinator(String.t(), boolean()) :: {:ok, boolean()}
  def set_coordinator(session_id, on?) when is_boolean(on?) do
    # Persist first so the choice is sticky even if no live loop picks it up.
    OptimalSystemAgent.Agent.CoordinatorMode.put(session_id, on?)

    result =
      try do
        GenServer.call(via(session_id), {:set_coordinator, on?})
      catch
        # No live loop yet: the sticky store seeds it on Loop.init, so treat as
        # a pending success rather than a lost error (mirrors set_permission_mode).
        :exit, _ -> {:ok, on?}
      end

    emit_coordinator_mode(session_id, on?)
    result
  end

  @doc "Get the current coordinator posture for a session (sticky-store default)."
  @spec get_coordinator(String.t()) :: {:ok, boolean()}
  def get_coordinator(session_id) do
    try do
      GenServer.call(via(session_id), {:get_coordinator})
    catch
      :exit, _ -> {:ok, OptimalSystemAgent.Agent.CoordinatorMode.get(session_id)}
    end
  end

  @doc """
  Cancel a running agent loop for the given session — TRANSITIVELY.

  Sets a flag in an ETS table that ReactLoop.run/1 checks at each iteration.
  Concurrent-safe: ETS reads work even while handle_call blocks the mailbox.

  Cancelling a parent also cancels its WHOLE subtree: every descendant
  subagent (children, grandchildren, ...), not just direct
  `agent:<session_id>:*` children. A grandchild's session id is
  `agent:agent:<session_id>:N:M` and would not match the old flat prefix
  fold, leaving it (and its background shell jobs) running after Esc/interrupt.

  Approach (opencode `run-state.ts:111-143` `cancelBackgroundJobs` /
  `session.ts:608-629` recursive `remove` parity): BFS the
  `RunStore.parent_session_id` chain starting at `session_id`, growing a seen
  set so a malformed/cyclic parent chain still terminates. Every discovered
  descendant gets the cooperative cancel flag AND has its background shell
  jobs killed via `BackgroundManager.cancel_for_sessions/1`.
  """
  def cancel(session_id) do
    :ets.insert(@cancel_table, {session_id, true})
    Logger.info("[loop] Cancel requested for session #{session_id}")

    descendants = descendant_session_ids(session_id)

    Enum.each(descendants, fn id ->
      :ets.insert(@cancel_table, {id, true})
      Logger.info("[loop] Cancel propagated to descendant sub-agent #{id}")
    end)

    subtree = [session_id | descendants]

    try do
      case OptimalSystemAgent.Shell.BackgroundManager.cancel_for_sessions(subtree) do
        n when is_integer(n) and n > 0 ->
          Logger.info(
            "[loop] Cancelled #{n} background shell job(s) for subtree of #{session_id}"
          )

        _ ->
          :ok
      end
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    # Base case retained: single-prefix fold over the cancel table itself
    # and the live SessionRegistry, in case a sub-agent hasn't hit
    # `RunStore.start_run/1` yet (registration race) or was launched by a
    # path that doesn't go through RunStore at all.
    prefix = "agent:#{session_id}:"

    try do
      :ets.foldl(
        fn {key, _val}, acc ->
          if is_binary(key) and String.starts_with?(key, prefix) do
            :ets.insert(@cancel_table, {key, true})
            Logger.info("[loop] Cancel propagated to sub-agent #{key}")
          end

          acc
        end,
        :ok,
        @cancel_table
      )
    rescue
      _ -> :ok
    end

    try do
      Registry.select(OptimalSystemAgent.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
      |> Enum.each(fn key ->
        if is_binary(key) and String.starts_with?(key, prefix) do
          :ets.insert(@cancel_table, {key, true})
          Logger.info("[loop] Cancel propagated to registered sub-agent #{key}")
        end
      end)
    rescue
      _ -> :ok
    end

    # Force-terminate every descendant subagent's LIVE GenServer. Setting the
    # ETS flag alone only unblocks a subagent that is BETWEEN ReactLoop
    # iterations — a subagent stuck inside ONE long op (a slow provider call,
    # a long tool, a nested blocking join) never re-checks the flag, so
    # whoever is joined on it (Orchestrator.execute_and_collect's
    # `Loop.process_message`, a foreground `delegate`, `task_wait`) hangs
    # forever regardless of cancel. Killing the child's GenServer makes any
    # `GenServer.call`/`Task.await` blocked on it fail fast with `:noproc`/
    # `:killed` (already handled as an error by every known caller) instead of
    # waiting out a timeout — this is the actual "cancel reaches a blocked
    # child" fix (opencode `cancelBackgroundJobs`/recursive `remove` parity).
    #
    # Deliberately excludes the ROOT `session_id` unless it is ITSELF a known
    # subagent (has a RunStore `parent_session_id`) — the top-level
    # interactive session must keep running cooperatively on Esc so its
    # in-memory state (history, checkpoints) survives; only subagents, whose
    # sole purpose is answering a join, are safe to hard-kill.
    terminate_targets =
      if subagent_run?(session_id), do: [session_id | descendants], else: descendants

    Enum.each(terminate_targets, &force_terminate_subagent/1)

    :ok
  rescue
    ArgumentError ->
      Logger.warning("[loop] Cancel table not found — agent may not be running")
      {:error, :not_running}
  end

  # True when `id` is a spawned subagent (RunStore row with a parent), not a
  # top-level interactive session. Best-effort — any failure treats `id` as
  # NOT a subagent so we never accidentally hard-kill an unknown/root session.
  defp subagent_run?(id) do
    case OptimalSystemAgent.Agent.RunStore.get(id) do
      %{parent_session_id: parent} when is_binary(parent) and parent != "" -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp force_terminate_subagent(id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, id) do
      [{pid, _}] when is_pid(pid) ->
        Logger.info("[loop] Force-terminating cancelled subagent #{id} to unblock its joiner")

        try do
          DynamicSupervisor.terminate_child(OptimalSystemAgent.SessionSupervisor, pid)
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  @doc false
  # BFS over RunStore's parent_session_id chain from `root_session_id`.
  # Returns every reachable descendant `agent_id`, deepest included
  # (transitive: grandchildren, great-grandchildren, ...). A `seen` set
  # guards against a cyclic/malformed parent chain looping forever — each
  # id is only ever expanded once.
  @spec descendant_session_ids(String.t()) :: [String.t()]
  def descendant_session_ids(root_session_id) do
    runs = OptimalSystemAgent.Agent.RunStore.list(limit: 100_000)

    children_by_parent =
      Enum.reduce(runs, %{}, fn run, acc ->
        parent = Map.get(run, :parent_session_id)
        agent_id = Map.get(run, :agent_id)

        if is_binary(parent) and is_binary(agent_id) do
          Map.update(acc, parent, [agent_id], &[agent_id | &1])
        else
          acc
        end
      end)

    bfs_descendants(children_by_parent, [root_session_id], MapSet.new([root_session_id]), [])
  rescue
    _ -> []
  end

  defp bfs_descendants(_children_by_parent, [], _seen, acc), do: acc

  defp bfs_descendants(children_by_parent, [current | rest], seen, acc) do
    children = Map.get(children_by_parent, current, [])
    new_children = Enum.reject(children, &MapSet.member?(seen, &1))
    new_seen = Enum.reduce(new_children, seen, &MapSet.put(&2, &1))
    bfs_descendants(children_by_parent, rest ++ new_children, new_seen, acc ++ new_children)
  end

  @doc """
  Returns the owner (user_id) stored in the SessionRegistry, or `nil`.
  """
  @spec get_owner(String.t()) :: String.t() | nil
  def get_owner(session_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{_pid, owner}] -> owner
      _ -> nil
    end
  end

  @doc """
  Ask the user interactive questions via the TUI survey dialog.
  Delegates to `Loop.Survey.ask/4`.
  """
  @spec ask_user_question(String.t(), String.t(), list(map()), keyword()) ::
          {:ok, term()} | {:skipped} | {:error, :timeout} | {:error, :cancelled}
  defdelegate ask_user_question(session_id, survey_id, questions, opts \\ []),
    to: Survey,
    as: :ask

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    opts = apply_preset(opts)
    extra_tools = Keyword.get(opts, :extra_tools, [])
    session_id = Keyword.fetch!(opts, :session_id)

    restored = Checkpoint.restore_checkpoint(session_id)

    # Resume history precedence: an explicit :messages opt (CLI --continue) wins,
    # then the crash-recovery checkpoint. The checkpoint is CLEARED at every
    # successful turn boundary, so an HTTP/TUI session resumed AFTER a completed
    # turn (/continue, /resume, /session <id>, directory-scoped POST /sessions)
    # has an EMPTY checkpoint. Fall back to the durable SessionPersistence store
    # (rewritten every turn by the auto_save_session :post_response hook) so the
    # resumed agent actually remembers the prior conversation instead of starting
    # amnesiac — matching the CLI resume path in channels/cli.ex. Note: an
    # explicit `messages: []` (fresh session) is truthy in Elixir and correctly
    # short-circuits the fallback, so new sessions stay empty.
    messages =
      Keyword.get(opts, :messages) ||
        case Map.get(restored, :messages, []) do
          [] -> load_persisted_messages(session_id)
          checkpoint_msgs -> checkpoint_msgs
        end

    resumed? = restored != %{} or messages != []

    iteration = Map.get(restored, :iteration, 0)
    plan_mode = Map.get(restored, :plan_mode, false)
    turn_count = Map.get(restored, :turn_count, 0)

    # Coordinator precedence mirrors permission_mode: an explicit opt
    # (subagent inheritance / CLI --coordinator) wins; then the sticky
    # per-session store (the TUI's runtime toggle, which survives a fresh/late
    # loop); then false. The UNFILTERED base list is captured so the runtime
    # toggle can restore full tool access without a session restart.
    coordinator? =
      Keyword.get(opts, :coordinator) ||
        OptimalSystemAgent.Agent.CoordinatorMode.get(session_id) ||
        false

    all_tools = Tools.filter_applicable_tools(%{history: []}) ++ extra_tools

    state = %__MODULE__{
      session_id: session_id,
      user_id: Keyword.get(opts, :user_id),
      channel: Keyword.get(opts, :channel, :cli),
      provider: Keyword.get(opts, :provider),
      model: Keyword.get(opts, :model),
      messages: messages,
      iteration: iteration,
      plan_mode: plan_mode,
      turn_count: turn_count,
      tools: ToolFilter.filter_for_coordinator(all_tools, coordinator?),
      all_tools: all_tools,
      coordinator: coordinator?,
      max_budget_usd:
        Keyword.get(opts, :max_budget_usd) ||
          Application.get_env(:optimal_system_agent, :max_budget_usd),
      max_turns:
        Keyword.get(opts, :max_turns) || Application.get_env(:optimal_system_agent, :max_turns),
      plan_mode_enabled: Application.get_env(:optimal_system_agent, :plan_mode_enabled, false),
      permission_tier: Keyword.get(opts, :permission_tier, :full),
      # Mode precedence: an explicit opt (subagent inheritance, autonomous
      # preset) wins; then the sticky per-session store (the TUI's runtime
      # overdrive/Shift+Tab choice, which survives a fresh/late loop); then the
      # settings-file default. This is what makes overdrive STICK across a turn
      # whose loop is created after the toggle, or re-created fresh.
      permission_mode:
        Keyword.get(opts, :permission_mode) ||
          OptimalSystemAgent.Agent.PermissionMode.get(session_id) ||
          default_permission_mode(),
      delegation_depth: Keyword.get(opts, :delegation_depth, 0),
      delegation_policy: Keyword.get(opts, :delegation_policy),
      parent_session_id: Keyword.get(opts, :parent_session_id),
      allowed_tools: Keyword.get(opts, :allowed_tools),
      blocked_tools: Keyword.get(opts, :blocked_tools, []),
      system_prompt_override: Keyword.get(opts, :system_prompt_override),
      working_dir:
        Keyword.get(opts, :working_dir) ||
          OptimalSystemAgent.Workspace.Cwd.get(),
      strategy: nil,
      strategy_state: %{},
      started_at: DateTime.utc_now()
    }

    # Durable execution (primitive #27): if a checkpoint is being restored AND
    # the durable step log has completed steps from an interrupted turn, the
    # ReactLoop will auto-resume — re-issued tool calls whose idempotency keys
    # are already recorded replay their result instead of re-executing. The log
    # is intentionally NOT cleared here (it is the resume evidence); it is
    # cleared at the next successful turn boundary / on session end.
    durable_steps = DurableLog.step_count(session_id)

    if restored != %{} do
      Logger.info(
        "[loop] Restored checkpoint for session #{session_id} — iteration=#{iteration}, messages=#{length(messages)}"
      )

      if durable_steps > 0 do
        Logger.info(
          "[loop] Auto-resume: #{durable_steps} durable step(s) recorded for session #{session_id} — completed steps will replay-dedup instead of re-running"
        )
      end
    end

    # SessionStart hook — fire-and-forget; announces the new session.
    fire_session_hook(:session_start, %{
      session_id: session_id,
      user_id: state.user_id,
      channel: state.channel,
      resumed: resumed?,
      resumed_steps: durable_steps
    })

    # Sticky overdrive survives a crash / process restart on purpose (see
    # `PermissionMode` moduledoc — that is what makes it durable). But THIS
    # process never saw the operator toggle it on: a crash never runs
    # `terminate/2`, so nothing cleared it, and this `init/1` is picking the
    # mode back up cold from the on-disk store. Silently auto-running every
    # mutating tool on a resumed session with no re-confirmation and no
    # visible signal is the unsafe part — not the stickiness itself. Surface
    # an un-missable notice on the session's event stream instead of forcing
    # a re-confirm (which would defeat the durable-overdrive behavior within
    # a live session that is working as intended).
    if resumed? and state.permission_mode in [:overdrive, :bypass] do
      notify_resumed_overdrive(state)
    end

    {:ok, state}
  end

  # Emits both the internal Bus event (analytics/telemetry) and the
  # session-scoped PubSub broadcast the TUI/HTTP channels already consume for
  # every other `:system_event` (see the moduledoc's turn/iteration/budget
  # taxonomy) — same shape, new `:overdrive_resumed` event name, so any
  # existing system_event renderer picks it up without new wiring.
  defp notify_resumed_overdrive(state) do
    message =
      "Resuming in overdrive (full auto) — this mode was left on before the process " <>
        "restarted or crashed; tool calls will run without asking."

    Logger.warning(
      "[loop] session #{state.session_id} resumed with sticky :overdrive/:bypass active — notifying, not re-prompting"
    )

    Bus.emit(
      :system_event,
      %{
        event: :overdrive_resumed,
        session_id: state.session_id,
        message: message
      },
      Observability.annotate(state, source: "agent.loop")
    )

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{state.session_id}",
      {:osa_event,
       %{
         type: :system_event,
         event: :overdrive_resumed,
         session_id: state.session_id,
         message: message
       }}
    )

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # Announce a coordinator-mode transition on the Bus. The TuiForwarder bridges
  # `coordinator_mode` (on its allowlist) to the session PubSub topic the TUI
  # streams, so the status-bar chip tracks the resulting state. Bus-only (no
  # direct session broadcast) to avoid the double-emit the forwarder warns about.
  defp emit_coordinator_mode(session_id, active) do
    Bus.emit(:system_event, %{
      event: :coordinator_mode,
      session_id: session_id,
      active: active
    })

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # "autonomous" preset (Change H) — one switch that makes an hours-long
  # hands-off run possible. It ties together the lifted caps: full-auto past the
  # non-bypassable circuit-breaker (:overdrive), max effort, and stall
  # escalate-only (hard_halt? already treats :overdrive as escalate-only). The
  # global caps (max_iterations 2000, doom_loop_max_calls 2000,
  # agent_turn_timeout_ms :infinity, tool_timeout_ms 300s) are already the
  # defaults; the OPTIONAL `max_budget_usd` an operator passes is the deliberate,
  # controlled stop. Explicit opts always win over the preset.
  @autonomous_preset [
    permission_mode: :overdrive,
    effort_level: :max
  ]

  defp apply_preset(opts) do
    case Keyword.get(opts, :preset) do
      preset when preset in [:autonomous, "autonomous"] ->
        if Keyword.get(opts, :effort_level) == nil,
          do: OptimalSystemAgent.Agent.Effort.set(:max)

        Keyword.merge(@autonomous_preset, opts)

      _ ->
        opts
    end
  end

  @impl true
  def handle_call({:process, message}, from, state) do
    handle_call({:process, message, []}, from, state)
  end

  @impl true
  def handle_call({:process, message, opts}, _from, state) do
    # Rewind checkpoint: snapshot conversation + code state *before* this
    # prompt is processed, so the user can later rewind to this point.
    # Best-effort and never allowed to disrupt the turn.
    _ = maybe_rewind_checkpoint(state, message)

    # The per-turn pre-LLM gates (cancel-clear, overrides, turn-increment,
    # budget/turn limits, cache clears, UserPromptSubmit hook, prompt-injection
    # guard, compaction, message build, and genre routing) live in TurnPipeline
    # as named ordered steps. It returns a terminal reply or hands back a
    # `:dispatch` signal for plan-mode / ReactLoop execution.
    case TurnPipeline.run(message, opts, state) do
      {:reply, reply, state} -> {:reply, reply, state}
      {:dispatch, state, skip_plan} -> dispatch_message(state, skip_plan)
    end
  end

  @impl true
  def handle_call(:get_metadata, _from, state) do
    {:reply, state.last_meta, state}
  end

  def handle_call(:get_messages, _from, state) do
    {:reply, state.messages, state}
  end

  def handle_call(:undo, _from, state) do
    messages = state.messages || []
    {kept, dropped} = drop_last_exchange(messages)

    stats = %{
      messages_before: length(messages),
      messages_after: length(kept),
      dropped: dropped
    }

    {:reply, {:ok, stats}, %{state | messages: kept}}
  end

  def handle_call(:get_state, _from, state) do
    uptime = if state.started_at, do: DateTime.diff(DateTime.utc_now(), state.started_at), else: 0

    snap = %{
      session_id: state.session_id,
      iteration: state.iteration,
      tokens_used: used_context_tokens(state),
      tools_called: state.last_meta[:tools_used] || [],
      status: state.status,
      started_at: state.started_at,
      uptime_seconds: uptime,
      provider: state.provider,
      model: state.model,
      effective_context_window: state.effective_context_window,
      spend: OptimalSystemAgent.Agent.Loop.Accounting.snapshot(state)
    }

    {:reply, {:ok, snap}, state}
  end

  @impl true
  def handle_call({:swap_provider, provider, model}, _from, state) do
    provider_atom = normalize_provider(provider)

    cond do
      is_nil(provider_atom) ->
        {:reply, {:error, "unknown provider: #{inspect(provider)}"}, state}

      not is_binary(model) or model == "" ->
        {:reply, {:error, "model is required"}, state}

      not OptimalSystemAgent.Providers.Registry.known_model?(provider_atom, model) ->
        {:reply, {:error, "unknown model \"#{model}\" for provider #{provider_atom}"}, state}

      true ->
        ecw =
          OptimalSystemAgent.Providers.Registry.effective_context_window(model, provider_atom)

        :ets.insert(:osa_session_provider_overrides, {state.session_id, provider_atom, model})

        {:reply, {:ok, %{provider: provider_atom, model: model, context_window: ecw}},
         %{state | provider: provider_atom, model: model, effective_context_window: ecw}}
    end
  end

  # Accept both an atom (CLI path) and a string (HTTP JSON path) provider, and
  # only return a provider that is actually registered.
  defp normalize_provider(provider) when is_atom(provider) and not is_nil(provider) do
    if provider in OptimalSystemAgent.Providers.Registry.list_providers(), do: provider, else: nil
  end

  defp normalize_provider(provider) when is_binary(provider) do
    Enum.find(OptimalSystemAgent.Providers.Registry.list_providers(), fn a ->
      Atom.to_string(a) == provider
    end)
  end

  defp normalize_provider(_), do: nil

  # Update a live session's working_dir (e.g. a later turn sent from a different
  # folder). Publishes into the process dictionary too so any immediate cwd
  # lookup in this process resolves to the new dir.
  @impl true
  def handle_call({:set_working_dir, dir}, _from, state) when is_binary(dir) and dir != "" do
    OptimalSystemAgent.Workspace.Cwd.put_process_override(dir)
    {:reply, :ok, %{state | working_dir: dir}}
  end

  def handle_call({:set_working_dir, _dir}, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:toggle_plan_mode, _from, state) do
    # Route the toggle through the exact same transition as enter/exit so the
    # three entry points can never disagree about plan_mode_enabled or the
    # saved pre-entry value. Toggling reports the resulting boolean.
    {_result, new_state} =
      if state.plan_mode_enabled do
        do_exit_plan_mode(state)
      else
        do_enter_plan_mode(state)
      end

    {:reply, {:ok, new_state.plan_mode_enabled}, new_state}
  end

  def handle_call(:compact, _from, state) do
    compacted =
      OptimalSystemAgent.Agent.Compactor.maybe_compact(
        state.messages,
        Map.get(state, :last_input_tokens, 0),
        state.session_id
      )

    {:reply, :ok, %{state | messages: compacted}}
  end

  # Legacy atom form kept for any pre-instructions caller.
  def handle_call(:proactive_compact, from, state),
    do: handle_call({:proactive_compact, nil}, from, state)

  def handle_call({:proactive_compact, instructions}, _from, state) do
    messages = state.messages || []
    compacted =
      OptimalSystemAgent.Agent.Loop.ProactiveCompaction.compact(
        messages,
        state.session_id,
        instructions
      )

    stats = %{
      messages_before: length(messages),
      messages_after: length(compacted),
      tokens_before: OptimalSystemAgent.Agent.Compactor.estimate_tokens(messages),
      tokens_after: OptimalSystemAgent.Agent.Compactor.estimate_tokens(compacted)
    }

    {:reply, {:ok, stats}, %{state | messages: compacted}}
  end

  def handle_call(:enter_plan_mode, _from, state) do
    {result, new_state} = do_enter_plan_mode(state)
    {:reply, {:ok, result}, new_state}
  end

  def handle_call(:exit_plan_mode, _from, state) do
    {result, new_state} = do_exit_plan_mode(state)
    {:reply, {:ok, result}, new_state}
  end

  def handle_call({:set_permission_tier, tier}, _from, state)
      when tier in [:full, :workspace, :read_only, :subagent, :auto] do
    {:reply, {:ok, tier}, %{state | permission_tier: tier}}
  end

  def handle_call({:set_permission_tier, _tier}, _from, state) do
    {:reply, {:error, :invalid_tier}, state}
  end

  def handle_call({:get_permission_tier}, _from, state) do
    {:reply, {:ok, state.permission_tier}, state}
  end

  # :bypass is a silent alias for :overdrive (the '--dangerously-skip-permissions'
  # entrypoint), so both resolve to the same server-side gate.
  def handle_call({:set_permission_mode, :bypass}, from, state) do
    handle_call({:set_permission_mode, :overdrive}, from, state)
  end

  def handle_call({:set_permission_mode, mode}, _from, state)
      when mode in [:ask, :accept_edits, :plan, :overdrive] do
    {:reply, {:ok, mode}, %{state | permission_mode: mode}}
  end

  def handle_call({:set_permission_mode, _mode}, _from, state) do
    {:reply, {:error, :invalid_mode}, state}
  end

  def handle_call({:get_permission_mode}, _from, state) do
    {:reply, {:ok, state.permission_mode}, state}
  end

  # In-place coordinator toggle: re-restrict (on) or restore (off) the live tool
  # list from the preserved unfiltered base, no session restart. state.coordinator
  # is also read by Agent.Context to inject the "Mode: coordinator" system note.
  def handle_call({:set_coordinator, on?}, _from, state) when is_boolean(on?) do
    tools = ToolFilter.filter_for_coordinator(state.all_tools, on?)
    {:reply, {:ok, on?}, %{state | coordinator: on?, tools: tools}}
  end

  def handle_call({:get_coordinator}, _from, state) do
    {:reply, {:ok, state.coordinator}, state}
  end

  def handle_call({:set_strategy, _strategy_name}, _from, state) do
    {:reply, {:error, :strategies_not_available}, state}
  end

  def handle_call(:get_strategy, _from, state) do
    {:reply, {:ok, :none, %{}}, state}
  end

  @impl true
  def handle_cast({:inject_agent_result, content}, state) do
    injected = %{role: "user", content: content}
    {:noreply, %{state | messages: state.messages ++ [injected]}}
  end

  # Mid-turn steer (primitive #32). This cast is only ever *serviced* when the
  # loop is idle (mailbox free) — during a turn the process is blocked in
  # handle_call and the running ReactLoop drains the ETS steer queue between
  # steps first. When it does run (idle), drain any still-queued steers into
  # history so they are not stranded until the next process_message. The text
  # argument is redundant with the ETS queue (populated by `steer/2`) and is
  # kept only to make the message self-describing; draining is what applies it,
  # which guarantees no double injection.
  @impl true
  def handle_cast({:steer, _text}, state) do
    case Steer.drain(state.session_id) do
      [] ->
        {:noreply, state}

      texts ->
        {:noreply, %{state | messages: state.messages ++ Steer.to_messages(texts)}}
    end
  end

  # WS6 — idle poke. Serviced only when the mailbox is free (loop idle): drain
  # pending task notifications into history and run a SYNTHETIC turn so the
  # agent reacts to background completions unprompted. When the queue is empty
  # (a busy turn's ReactLoop already drained it beside Steer) this no-ops.
  # run_and_reply/1 broadcasts the response on the session topic, so the TUI
  # renders the reaction even though no HTTP caller is waiting on a reply.
  # iteration resets to 0 exactly like TurnPipeline does for a real turn.
  @impl true
  def handle_cast(:poke, %{status: :idle} = state) do
    case TaskNotifications.drain(state.session_id) do
      [] ->
        {:noreply, state}

      notifs ->
        TaskNotifications.announce(state.session_id, notifs)

        state = %{
          state
          | messages: state.messages ++ TaskNotifications.to_messages(notifs),
            iteration: 0,
            status: :processing,
            current_input: "[background task notification]"
        }

        {:reply, _reply, state} = run_and_reply(state)
        {:noreply, state}
    end
  end

  def handle_cast(:poke, state), do: {:noreply, state}

  @impl true
  def handle_cast({:rewind_conversation, messages, meta}, state) do
    new_state = %{
      state
      | messages: messages,
        iteration: Map.get(meta, :iteration, state.iteration),
        plan_mode: Map.get(meta, :plan_mode, state.plan_mode),
        turn_count: Map.get(meta, :turn_count, state.turn_count)
    }

    Checkpoint.checkpoint_state(new_state)
    {:noreply, new_state}
  end

  @impl true
  def terminate(:normal, state) do
    fire_session_end(state)
    Checkpoint.clear_checkpoint(state.session_id)
    DurableLog.clear(state.session_id)
    :ok
  end

  def terminate(:shutdown, state) do
    fire_session_end(state)
    Checkpoint.clear_checkpoint(state.session_id)
    DurableLog.clear(state.session_id)
    :ok
  end

  def terminate({:shutdown, _}, state) do
    fire_session_end(state)
    Checkpoint.clear_checkpoint(state.session_id)
    DurableLog.clear(state.session_id)
    :ok
  end

  def terminate(reason, state) do
    fire_session_end(state, reason)
    :ok
  end

  # SessionEnd hook — run synchronously so session-cleanup handlers execute
  # before the process exits. Fully guarded: hook problems never block shutdown.
  defp fire_session_end(state, reason \\ :normal)

  defp fire_session_end(%{session_id: sid} = state, reason) when is_binary(sid) do
    # WS6 — orphan reaping: a dying session must not leave its background
    # shell commands running with nobody left to notify. Best-effort.
    try do
      OptimalSystemAgent.Shell.BackgroundManager.kill_for_session(sid)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    try do
      Hooks.run(:session_end, %{
        session_id: sid,
        user_id: Map.get(state, :user_id),
        channel: Map.get(state, :channel),
        reason: reason,
        turn_count: Map.get(state, :turn_count, 0)
      })
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  defp fire_session_end(_state, _reason), do: :ok

  # SessionStart hook helper — never blocks or crashes loop init.
  defp fire_session_hook(event, payload) do
    Hooks.run_async(event, payload)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # --- Message Dispatch ---

  defp dispatch_message(state, skip_plan) do
    if not skip_plan and should_plan?(state) do
      state = %{state | plan_mode: true}

      case MessageHandler.run_plan_mode(state) do
        {:ok, plan_text, state} ->
          state = %{state | status: :idle}

          # Plan-mode returns without going through run_and_reply, so no
          # :post_response fires — persist the plan here (tool_name "plan")
          # so it appears in /sessions resume, transcript, and recap. The
          # user turn was already saved at ingestion by TurnPipeline.
          OptimalSystemAgent.Store.SessionTranscript.save_turn(
            state.session_id,
            "assistant",
            plan_text,
            tool_name: "plan"
          )

          Telemetry.emit_context_pressure(state)

          Phoenix.PubSub.broadcast(
            OptimalSystemAgent.PubSub,
            "osa:session:#{state.session_id}",
            {:osa_event, %{type: :done, session_id: state.session_id}}
          )

          {:reply, {:plan, plan_text}, state}

        {:error, _reason, state} ->
          run_and_reply(state)
      end
    else
      run_and_reply(state)
    end
  end

  defp run_and_reply(state) do
    Logger.info("[loop] Entering ReactLoop for session #{state.session_id}")

    turn_started_ms = System.monotonic_time(:millisecond)
    # Per-turn baselines: `state.messages` and `state.total_tool_calls` both
    # accumulate for the whole session, so the end-of-turn recap must diff
    # against these snapshots — otherwise a trivial turn 5 reports every tool
    # any earlier turn ever used.
    msg_len_before = length(state.messages)
    tool_calls_before = Map.get(state, :total_tool_calls, 0)

    {response, state} =
      try do
        ReactLoop.run(state)
      rescue
        e ->
          Logger.error(
            "[loop] CRASH in ReactLoop: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
          )

          {"I hit an error processing that request. Check the logs for details.", state}
      catch
        :exit, reason ->
          Logger.error("[loop] EXIT in ReactLoop: #{inspect(reason)}")

          {"I hit a timeout or process error. This usually means the LLM connection dropped — try again.",
           state}
      end

    response = maybe_scrub_prompt_leak(response)
    response = maybe_strip_dead_phrases(response)

    # Per-turn tool telemetry: scan ONLY the messages this turn appended.
    # `turn_tool_names` is per-call (not uniq'd) so counts reflect tool USES.
    turn_tool_names = Telemetry.tools_used_since(state.messages, msg_len_before)
    substantive_names = Telemetry.substantive_tools(turn_tool_names)

    # Substantive tool USES this turn (Claude Code's toolUseCount semantics,
    # matching doom_loop's call_count). If mid-turn compaction rewrote the
    # message list (length shrank below the snapshot), fall back to the
    # doom-loop live counter delta so the count still reflects this turn only.
    turn_tool_calls =
      if length(state.messages) >= msg_len_before do
        length(substantive_names)
      else
        max(Map.get(state, :total_tool_calls, 0) - tool_calls_before, 0)
      end

    meta = %{
      iteration_count: state.iteration,
      tools_used: Enum.uniq(turn_tool_names)
    }

    # WS5 — an interrupted turn already ends with the USER-role interrupt
    # marker appended by ReactLoop.finalize_interrupt; appending the marker
    # again here as an ASSISTANT message would flip its role for the model.
    new_messages =
      if response in ReactLoop.interrupt_markers() do
        state.messages
      else
        state.messages ++ [%{role: "assistant", content: response}]
      end

    state = %{
      state
      | messages: new_messages,
        status: :idle,
        last_meta: meta
    }

    Telemetry.emit_context_pressure(state)

    # Turn-end lifecycle event (primitive #30) — correlated to the turn_id minted
    # at turn start, so the per-session event stream brackets each turn.
    Observability.turn_end(state, response)

    Bus.emit(
      :agent_response,
      %{
        session_id: state.session_id,
        response: response,
        agent: state.session_id
      },
      Observability.annotate(state, source: "agent.loop")
    )

    # Fire post_response hooks (async, non-blocking)
    try do
      Hooks.run_async(:post_response, %{
        session_id: state.session_id,
        response: response,
        input: state.current_input || "",
        turn_count: state.turn_count,
        iteration: state.iteration,
        tools_used: Map.get(state.last_meta, :tools_used, []),
        total_tool_calls: state.total_tool_calls
      })
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{state.session_id}",
      {:osa_event,
       %{
         type: :agent_response,
         session_id: state.session_id,
         response: response,
         response_type: "agent"
       }}
    )

    # Persistent "✻ Worked for Xm Ys · N tool uses" recap line — committed to
    # the transcript when the turn ends (what the TUI-side Activity timer
    # otherwise drops). Shared contract:
    # %{type: :turn_recap, elapsed_ms, tool_calls, tools_used} where
    # `tool_calls` = substantive tool USES made by THIS turn (per-call count,
    # internal bookkeeping tools filtered server-side) and `tools_used` = this
    # turn's distinct substantive tool names. `elapsed_ms` stays
    # server-monotonic and is only the TUI's fallback — the displayed elapsed
    # comes from the client spinner clock so it never jumps backwards.
    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{state.session_id}",
      {:osa_event,
       %{
         type: :turn_recap,
         session_id: state.session_id,
         elapsed_ms: System.monotonic_time(:millisecond) - turn_started_ms,
         tool_calls: turn_tool_calls,
         tools_used: Enum.uniq(substantive_names)
       }}
    )

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{state.session_id}",
      {:osa_event, %{type: :done, session_id: state.session_id}}
    )

    # Turn completed successfully — the per-step durable log for this turn is no
    # longer needed for resume. Clear it so files stay per-turn and small; the
    # next turn (fresh iteration/turn_count) starts with an empty log.
    DurableLog.clear(state.session_id)

    {:reply, {:ok, response}, state}
  end

  # --- Output Guardrails ---

  defp maybe_scrub_prompt_leak(response) do
    if Guardrails.response_contains_prompt_leak?(response) do
      Logger.warning(
        "[loop] Output guardrail: LLM response contained system prompt content — replacing with refusal"
      )

      Guardrails.prompt_extraction_refusal()
    else
      response
    end
  end

  defp maybe_strip_dead_phrases(response) when is_binary(response) do
    if Guardrails.contains_dead_phrase?(response) do
      Logger.info("[loop] Output guardrail: stripping dead phrases from response")
      Guardrails.strip_dead_phrases(response)
    else
      response
    end
  end

  defp maybe_strip_dead_phrases(response), do: response

  # --- Helpers ---

  defp via(session_id), do: {:via, Registry, {OptimalSystemAgent.SessionRegistry, session_id}}

  # Current context occupancy for `get_state` / the `/context` breakdown: prefer
  # the provider-reported input tokens (real usage) and fall back to the
  # char/word estimate when the provider returns none (glm/Ollama), matching the
  # status-bar context-pressure telemetry rather than always estimating.
  defp used_context_tokens(state) do
    case Map.get(state, :last_input_tokens, 0) do
      n when is_integer(n) and n > 0 -> n
      _ -> Telemetry.estimate_tokens(state)
    end
  end

  # permission_mode (CC-parity): the session's starting mode when none is passed
  # explicitly. Delegates to Permissions.default_mode/0 — the single source of
  # truth — which honors the CC key `permissions.defaultMode` first and falls
  # back to the legacy top-level `permission_mode` string enum. Unknown/unset
  # -> :ask (the safe default).
  defp default_permission_mode do
    OptimalSystemAgent.Permissions.default_mode()
  end

  # /undo backend: split off the most recent user turn and everything after it.
  # Returns {kept_messages, dropped_count}. No user turn -> unchanged, 0 dropped.
  defp drop_last_exchange(messages) do
    last_user_idx =
      messages
      |> Enum.with_index()
      |> Enum.filter(fn {m, _i} ->
        to_string(Map.get(m, :role) || Map.get(m, "role") || "") == "user"
      end)
      |> List.last()

    case last_user_idx do
      {_m, idx} -> {Enum.take(messages, idx), length(messages) - idx}
      nil -> {messages, 0}
    end
  end

  defp should_plan?(state), do: state.plan_mode_enabled and not state.plan_mode

  # Single source of truth for the plan-mode state transition, shared by
  # :enter_plan_mode, :exit_plan_mode, and :toggle_plan_mode. Returns
  # `{result, new_state}`.
  defp do_enter_plan_mode(%{plan_mode_enabled: true} = state) do
    # Already active — idempotent; leave the saved pre-entry value untouched.
    {:already_active, state}
  end

  defp do_enter_plan_mode(state) do
    new_state = %{
      state
      | plan_mode_enabled: true,
        # Capture the pre-entry value so exit can restore it precisely.
        strategy_state:
          Map.put(state.strategy_state, :plan_mode_pre_entry, state.plan_mode_enabled)
    }

    {:entered, new_state}
  end

  defp do_exit_plan_mode(%{plan_mode_enabled: false} = state) do
    {:was_not_active, state}
  end

  defp do_exit_plan_mode(state) do
    pre_entry = Map.get(state.strategy_state, :plan_mode_pre_entry, false)

    new_state = %{
      state
      | plan_mode_enabled: pre_entry,
        strategy_state: Map.delete(state.strategy_state, :plan_mode_pre_entry)
    }

    {:exited, new_state}
  end

  # --- Backward-compatible delegations ---

  @doc false
  defdelegate checkpoint_state(state), to: Checkpoint

  @doc false
  defdelegate restore_checkpoint(session_id), to: Checkpoint

  # Durable resume fallback: load the persisted conversation for a session from
  # the SessionPersistence store (JSON under ~/.osa/sessions, rewritten every
  # turn by the auto_save_session :post_response hook). Used by init/1 when the
  # crash-recovery checkpoint is empty — i.e. a session resumed after a completed
  # turn — so HTTP/TUI /continue and /resume restore real agent context, not just
  # the on-screen transcript. Returns [] on any miss/error.
  defp load_persisted_messages(session_id) do
    case OptimalSystemAgent.Agent.SessionPersistence.load(session_id) do
      {:ok, msgs} when is_list(msgs) -> msgs
      _ -> []
    end
  end

  @doc false
  defdelegate clear_checkpoint(session_id), to: Checkpoint

  @doc """
  Apply a restored conversation to a *live* loop process, if one is running.
  No-op (returns `:ok`) when the session has no running loop — callers still
  restore via the crash-recovery checkpoint for the next resume.
  """
  def rewind_conversation(session_id, messages, meta \\ %{}) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{_pid, _} | _] ->
        GenServer.cast(via(session_id), {:rewind_conversation, messages, meta})
        :ok

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # Best-effort rewind checkpoint before a user prompt. Wrapped so a snapshot
  # failure can never break the turn.
  defp maybe_rewind_checkpoint(state, message) do
    Checkpoint.create_rewind_checkpoint(state, label: message)
  rescue
    _ -> {:error, :snapshot_failed}
  end

  @doc false
  defdelegate needs_verification_gate?(state), to: Guardrails

  @doc false
  defdelegate permission_tier_allows?(tier, tool), to: ToolExecutor
end
