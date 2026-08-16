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

  alias OptimalSystemAgent.Agent.AskUserMode
  alias OptimalSystemAgent.Agent.CompactionEvents
  alias OptimalSystemAgent.Agent.Loop.Accounting
  alias OptimalSystemAgent.Agent.Loop.ToolExecutor
  alias OptimalSystemAgent.Agent.Loop.Guardrails
  alias OptimalSystemAgent.Agent.Loop.Checkpoint
  alias OptimalSystemAgent.Agent.Loop.DurableLog
  alias OptimalSystemAgent.Agent.Loop.LLMClient
  alias OptimalSystemAgent.Agent.Loop.MessageHandler
  alias OptimalSystemAgent.Agent.Loop.ReactLoop
  alias OptimalSystemAgent.Agent.Loop.Steer
  alias OptimalSystemAgent.Agent.Loop.Survey
  alias OptimalSystemAgent.Agent.Loop.Telemetry
  alias OptimalSystemAgent.Agent.Loop.TerminalSource
  alias OptimalSystemAgent.Agent.Loop.ToolFilter
  alias OptimalSystemAgent.Agent.Loop.TurnPipeline
  alias OptimalSystemAgent.Agent.Hooks
  alias OptimalSystemAgent.Agent.SessionPersistence
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
    # Tools appended to the array mid-session because a `tool_search` hit
    # surfaced them (`Loop.ToolDiscovery`). Kept separately from `tools` so
    # `ToolFilter` can re-pin them after a narrowing pass: a tool the model was
    # just told it can call must not stop being callable one iteration later.
    # Append-only within a session, and never reordered — see the module doc for
    # why that is what the prompt cache requires.
    discovered_tools: [],
    # Is the `ask_user` tool available to the model this session?
    #
    # OFF by default, everywhere — see `Agent.AskUserMode`. Resolved ONCE in
    # `init/1` and pinned here rather than re-read per request, so the tool
    # array (and therefore the cached prompt prefix) is byte-stable across a
    # session. `/ask-user on` mid-session rewrites it deliberately and pays one
    # cache re-prime, which the command's confirmation says out loud.
    ask_user_enabled: false,
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

  # `init/1` traps exits so `terminate/2` actually runs on a supervisor shutdown
  # (it did not before — see the `terminate/2` comment), which makes this budget
  # load-bearing rather than incidental. It is bounded on purpose: `terminate/2`
  # only ever does local, guarded work (a checkpoint write, a session save, the
  # session-end hook), so 2s is already generous, and it caps how long a quit
  # can block. A loop that is mid-turn does not trap at all (see `during_turn/1`),
  # so this budget is never spent waiting on a running turn —
  # `force_terminate_subagent/1` still reaps a stuck child immediately.
  @shutdown_budget_ms 2_000

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
      type: :worker,
      shutdown: @shutdown_budget_ms
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
    GenServer.call(via(session_id), {:process, message, opts}, turn_timeout(opts))
  end

  # Wall-clock backstop for ONE `{:process, ...}` join.
  #
  # The turn is bounded LOGICALLY by max_turns + max_budget_usd, so a short
  # wall-clock (the old 30s, then 10-min defaults) killed legitimate multi-step
  # work — that is why this became `:infinity`. But `:infinity` is not a bound
  # at all: every caller of `process_message/3` is a *surface* (an HTTP request,
  # a Slack/Telegram/Discord/email delivery, the CLI, a channel worker), and a
  # loop wedged inside one un-cancellable operation (a provider socket that
  # never closes, a tool that never returns) leaves that surface blocked with
  # no ack, forever, holding its process and its user's turn open. Nothing ever
  # times it out and nothing ever tells the user.
  #
  # So: a real, finite, deliberately GENEROUS default. 24h is far past any
  # honest turn (the tightest real bound is the orchestrator's own 2h subagent
  # join) yet still guarantees every caller eventually gets `{:timeout, _}`
  # instead of hanging for the VM's life. An explicit `opts[:timeout]` still
  # wins for callers with a tighter budget (the orchestrator passes one), and
  # an operator who genuinely wants the old behaviour can still set
  # `config :optimal_system_agent, :agent_turn_timeout_ms, :infinity`.
  @default_turn_timeout_ms 24 * 60 * 60 * 1000

  @doc false
  @spec turn_timeout(keyword()) :: pos_integer() | :infinity
  def turn_timeout(opts \\ []) do
    case Keyword.get(opts, :timeout) ||
           Application.get_env(
             :optimal_system_agent,
             :agent_turn_timeout_ms,
             @default_turn_timeout_ms
           ) do
      :infinity -> :infinity
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_turn_timeout_ms
    end
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

  ## Reaching subagents

  The queue is keyed by session id and a subagent Loop runs under its OWN id, so
  a steer aimed at the session the user is actually looking at stopped dead at
  the parent. When the visible work is being done by a teammate — which, with
  delegation defaulting to background, is most of the time — the steer reached
  the one participant that was not doing anything, and the UI's "folding into
  the current turn" was true only in the narrowest sense.

  So the directive is queued for the session AND for every `:running`
  descendant of it (`steer_targets/1`). Each recipient drains its own copy at
  its own next step boundary; the drain is per-session and destructive, so no
  one sees it twice and a child that finishes first simply never picks it up.
  """
  @spec steer(String.t(), String.t()) :: :ok
  def steer(session_id, text) when is_binary(session_id) and is_binary(text) do
    for target <- steer_targets(session_id) do
      Steer.queue(target, text)

      try do
        GenServer.cast(via(target), {:steer, text})
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  The session itself plus every `:running` descendant subagent of it.

  Walks `RunStore.children_of/1` breadth-first, keeping only runs still marked
  `:running` — a finished child has no loop left to fold anything into — and
  guarding against a cycle in the edge ledger, which is append-only and not
  validated. The session id itself is always first and always present, so a
  session with no children behaves exactly as before.
  """
  @spec steer_targets(String.t()) :: [String.t()]
  def steer_targets(session_id) when is_binary(session_id) do
    [session_id | running_descendants([session_id], MapSet.new([session_id]), [])]
  rescue
    _ -> [session_id]
  catch
    :exit, _ -> [session_id]
  end

  defp running_descendants([], _seen, acc), do: Enum.reverse(acc)

  defp running_descendants([id | rest], seen, acc) do
    children =
      id
      |> OptimalSystemAgent.Agent.RunStore.children_of()
      |> Enum.reject(&MapSet.member?(seen, &1))
      |> Enum.filter(&running_run?/1)

    seen = Enum.reduce(children, seen, &MapSet.put(&2, &1))
    running_descendants(rest ++ children, seen, Enum.reverse(children) ++ acc)
  end

  defp running_run?(agent_id) do
    case OptimalSystemAgent.Agent.RunStore.get(agent_id) do
      %{status: :running} -> true
      _ -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
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
  Turn the `ask_user` tool on or off for a session at runtime (`/ask-user`).

  Mirrors `set_coordinator/2` exactly: the sticky store is written FIRST so the
  choice survives (a) a toggle that lands before the turn's loop exists and
  (b) a loop later re-created for the session, then the live loop — if any —
  recomputes its tool array from the preserved unfiltered base. An
  `ask_user_mode` system_event is emitted so the TUI confirms the resulting
  state rather than the state it hoped for.

  Turning it ON mid-session changes the tool array, which re-primes the
  provider's prompt cache once on the next request. That is stated in the
  operator-facing confirmation instead of being absorbed silently.
  """
  @spec set_ask_user(String.t(), boolean()) :: {:ok, boolean()}
  def set_ask_user(session_id, on?) when is_boolean(on?) do
    AskUserMode.put(session_id, on?)

    result =
      try do
        GenServer.call(via(session_id), {:set_ask_user, on?})
      catch
        :exit, _ -> {:ok, on?}
      end

    emit_ask_user_mode(session_id, on?)
    result
  end

  @doc "Is `ask_user` enabled for this session? (falls back to the resolved default)."
  @spec get_ask_user(String.t()) :: {:ok, boolean()}
  def get_ask_user(session_id) do
    try do
      GenServer.call(via(session_id), {:get_ask_user})
    catch
      :exit, _ -> {:ok, AskUserMode.enabled?(session_id)}
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

  @doc """
  Clear the cooperative cancel flag for `session_id` **and its whole
  descendant subtree** — the exact inverse of `cancel/1`.

  `cancel/1` writes a flag for every descendant it can discover (RunStore BFS,
  the cancel table's own `agent:<id>:` prefix, and the live SessionRegistry).
  Until now nothing removed those: the only deletes in the codebase
  (`TurnPipeline.clear_cancel_flag/1`, `ReactLoop`'s two interrupt paths) each
  clear exactly ONE key — the session that was executing a turn. A descendant
  that was flagged but never got to run a turn (already finished, force
  terminated by `cancel/1` itself, or never started) kept its `true` forever:
  `:osa_cancel_flags` grew for the life of the VM, and — worse — the readers in
  `Loop.PermissionBroker` and `Loop.Survey` treat a live flag as "cancelled", so
  a LATER run reusing that id (a resumed delegate, a stable `@name` handle) had
  its permission prompts and `ask_user` surveys auto-denied before it ever
  cleared anything.

  Set and clear are now symmetric: whatever `cancel/1` flags, this un-flags.
  """
  @spec clear_cancel(String.t()) :: :ok
  def clear_cancel(session_id) when is_binary(session_id) do
    Enum.each([session_id | descendant_session_ids(session_id)], &clear_cancel_key/1)

    # Same belt-and-braces sweep `cancel/1` uses to FIND descendants, applied in
    # reverse: any `agent:<session_id>:` key still sitting in the table (flagged
    # via the prefix fold or the registry scan, e.g. a child that had not yet
    # reached RunStore.start_run/1) is cleared too. Without this the two paths
    # are asymmetric and the flags set by the registry scan can never be removed.
    prefix = "agent:#{session_id}:"

    try do
      :ets.foldl(
        fn {key, _val}, acc ->
          if is_binary(key) and String.starts_with?(key, prefix), do: clear_cancel_key(key)
          acc
        end,
        :ok,
        @cancel_table
      )
    rescue
      _ -> :ok
    end

    :ok
  end

  def clear_cancel(_), do: :ok

  defp clear_cancel_key(id) do
    :ets.delete(@cancel_table, id)
    :ok
  rescue
    ArgumentError -> :ok
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
    # Without this, `terminate/2` NEVER runs on a supervisor shutdown: an
    # untrapped `:shutdown` exit signal kills the process outright, so the
    # session-end hook, the background-command reaping, and (since the fix
    # below) the mid-turn save of an unfinished turn were all dead code on the
    # ordinary application-stop path. Trapping makes the child's shutdown budget
    # load-bearing — see `shutdown_budget/1`, which sets it explicitly.
    Process.flag(:trap_exit, true)

    opts = apply_preset(opts)
    extra_tools = Keyword.get(opts, :extra_tools, [])
    session_id = Keyword.fetch!(opts, :session_id)

    # A cancel flag belongs to a RUN, not to an id. Ids are reused on purpose —
    # `Orchestrator.resume_subagent/2` restarts under the ORIGINAL agent id, and
    # a `name:`-addressed teammate ("@smoke-e2e") always gets the same id. If the
    # previous run under this id was cancelled, its flag is still sitting in the
    # table (`cancel/1` force-terminates a subagent, so that process never
    # reaches the delete in ReactLoop/TurnPipeline), and `PermissionBroker`/
    # `Survey` would read it as "this session is cancelled" — auto-denying the
    # fresh run's very first permission prompt or `ask_user` survey before it had
    # a chance to clear anything. A starting loop is by definition not cancelled.
    clear_cancel_key(session_id)

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

    # Spend restore (audit gap C2): the accumulated budget totals must survive a
    # crash so a `max_budget_usd` cap keeps holding on resume. Two durable
    # sources cover the two resume shapes: the crash-recovery checkpoint (fresh
    # mid-turn, then cleared at a clean turn boundary) and the between-turn spend
    # sidecar (rewritten every turn, NOT cleared at turn end). Since spend only
    # grows, taking the MAX of the two is the latest value regardless of which
    # resume path fired — no precedence bug when the checkpoint is absent/zero.
    spend_sidecar = SessionPersistence.load_spend(session_id)

    session_cost_usd =
      max(Map.get(restored, :session_cost_usd, 0.0), spend_sidecar.cost_usd) * 1.0

    session_input_tokens =
      max(Map.get(restored, :session_input_tokens, 0), spend_sidecar.input_tokens)

    session_output_tokens =
      max(Map.get(restored, :session_output_tokens, 0), spend_sidecar.output_tokens)

    session_cache_creation_tokens =
      max(
        Map.get(restored, :session_cache_creation_tokens, 0),
        spend_sidecar.cache_creation_tokens
      )

    session_cache_read_tokens =
      max(Map.get(restored, :session_cache_read_tokens, 0), spend_sidecar.cache_read_tokens)

    # Preserve the ORIGINAL run start across a crash so elapsed-time budgeting and
    # the task brief's `created_at` stay anchored. Fall back to the sidecar, then
    # to now for a fresh session.
    restored_started_at =
      parse_started_at(Map.get(restored, :started_at) || spend_sidecar.started_at)

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

    # `ask_user` availability, resolved ONCE and pinned. Precedence mirrors
    # coordinator/permission mode: an explicit opt (subagent inheritance, an
    # `osa.run --ask-user` flag) wins; then the sticky per-session store the
    # `/ask-user` toggle writes; then env/settings, which default to OFF.
    ask_user_enabled? =
      case Keyword.get(opts, :ask_user) do
        on? when is_boolean(on?) -> on?
        _ -> AskUserMode.enabled?(session_id)
      end

    channel = Keyword.get(opts, :channel, :cli)

    # Publish the channel so every BLOCKING path can ask one question —
    # `Agent.Attendance.attended?/1`, "can a human respond on this session right
    # now" — instead of each one re-deriving an answer from a flag nothing sets.
    # Written here, at the single place a session's channel is decided, so a
    # tool Task (which has no loop state) and a stateless HTTP request resolve
    # the same verdict as the loop itself.
    OptimalSystemAgent.Agent.Attendance.put_channel(session_id, channel)

    state = %__MODULE__{
      session_id: session_id,
      user_id: Keyword.get(opts, :user_id),
      channel: channel,
      # Resolve provider AND model up front. Carrying `model: nil` is not an
      # absence, it is a value that silently disables both cost accounting and
      # compaction — see `Registry.resolved_default_model/1`.
      provider:
        Keyword.get(opts, :provider) ||
          OptimalSystemAgent.Providers.Registry.resolved_default_provider(),
      model:
        Keyword.get(opts, :model) ||
          OptimalSystemAgent.Providers.Registry.resolved_default_model(
            Keyword.get(opts, :provider)
          ),
      messages: messages,
      iteration: iteration,
      plan_mode: plan_mode,
      turn_count: turn_count,
      session_cost_usd: session_cost_usd,
      session_input_tokens: session_input_tokens,
      session_output_tokens: session_output_tokens,
      session_cache_creation_tokens: session_cache_creation_tokens,
      session_cache_read_tokens: session_cache_read_tokens,
      tools:
        all_tools
        |> ToolFilter.filter_for_coordinator(coordinator?)
        |> AskUserMode.filter_tools(ask_user_enabled?)
        |> ToolFilter.filter_for_role_allowlist(%{
          allowed_tools: Keyword.get(opts, :allowed_tools),
          blocked_tools: Keyword.get(opts, :blocked_tools, []),
          permission_tier: Keyword.get(opts, :permission_tier, :full)
        })
        |> ToolFilter.filter_for_env_allowlist(),
      all_tools: all_tools,
      coordinator: coordinator?,
      ask_user_enabled: ask_user_enabled?,
      # Budget cap precedence (audit gap D2 restore half): a cap PERSISTED in the
      # checkpoint wins, so a run started with an explicit $50 cap keeps it across
      # a crash/restart instead of resetting to the app-env default (nil =
      # uncapped). Only when the checkpoint has none do we fall back to an
      # explicit opt, then the app-env default.
      max_budget_usd:
        Map.get(restored, :max_budget_usd) ||
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
      started_at: restored_started_at
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

    # Publish the session's workspace before ANY turn runs, so a tool dispatched
    # by a session created over HTTP (`working_dir` in the create body) resolves
    # the right permission scope even on its very first call.
    OptimalSystemAgent.Workspace.Cwd.put_session_dir(session_id, state.working_dir)

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

  # Restore `started_at` from a persisted iso8601 string, defaulting to now for a
  # fresh session (or an unparseable value) so a resumed run keeps its original
  # start time instead of resetting the clock every crash.
  defp parse_started_at(nil), do: DateTime.utc_now()

  defp parse_started_at(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_started_at(%DateTime{} = dt), do: dt
  defp parse_started_at(_), do: DateTime.utc_now()

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

  # Announce an ask_user availability transition on the Bus, same bridge as
  # `coordinator_mode`: TuiForwarder relays it to the session topic the TUI
  # streams, so the toggle confirms from the BACKEND's resulting state rather
  # than from the TUI's optimistic guess.
  defp emit_ask_user_mode(session_id, enabled) do
    Bus.emit(:system_event, %{
      event: :ask_user_mode,
      session_id: session_id,
      enabled: enabled
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
    effort_level: :xhigh
  ]

  defp apply_preset(opts) do
    case Keyword.get(opts, :preset) do
      preset when preset in [:autonomous, "autonomous"] ->
        if Keyword.get(opts, :effort_level) == nil,
          do: OptimalSystemAgent.Agent.Effort.set(:xhigh)

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
    during_turn(fn ->
      case TurnPipeline.run(message, opts, state) do
        {:reply, reply, state} -> {:reply, reply, state}
        {:dispatch, state, skip_plan} -> dispatch_message(state, skip_plan)
      end
    end)
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
    OptimalSystemAgent.Workspace.Cwd.put_session_dir(state.session_id, dir)
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
    # Bare `/compact` reports progress like every other compaction path.
    #
    # It did not, and it is the form people actually type. `CompactionEvents`
    # were only emitted on the proactive path, so `/compact` with instructions
    # showed a spinner and a chunk counter while bare `/compact` sat there
    # rendering nothing at all — indistinguishable from a hung command for
    # however long the summarizer took.
    #
    # `completed` must fire on EVERY exit from here, including the bounded
    # timeout and the no-op, or the TUI stays in its Compacting state forever.
    # `bounded_compaction/2` always returns, which is what makes the plain
    # sequence safe.
    messages = state.messages
    tokens_before = OptimalSystemAgent.Agent.Compactor.estimate_tokens(messages)
    started_at = System.monotonic_time(:millisecond)

    CompactionEvents.started(state.session_id, :manual, tokens_before)

    # The window MUST come from the registry's honest per-model resolver — the
    # compactor no longer has (and must never regrow) a hardcoded default.
    # Bounded: a wedged summarizer must not hang `/compact` forever — see
    # TurnPipeline.bounded_compaction/2.
    compacted =
      TurnPipeline.bounded_compaction(messages, fn ->
        OptimalSystemAgent.Agent.Compactor.maybe_compact(
          messages,
          Map.get(state, :last_input_tokens, 0),
          state.session_id,
          context_window: OptimalSystemAgent.Agent.Loop.ContextWindow.resolve(state)
        )
      end) || messages

    CompactionEvents.completed(state.session_id,
      tokens_before: tokens_before,
      tokens_after: OptimalSystemAgent.Agent.Compactor.estimate_tokens(compacted),
      messages_before: length(messages),
      messages_after: length(compacted),
      duration_ms: System.monotonic_time(:millisecond) - started_at
    )

    # The summarizer round-trips ran in the bounded task above and staged their
    # priced usage into `Accounting`'s side ledger; bill them to this session
    # now that we are back in the loop process holding the state.
    state = Accounting.absorb_side_spend(state)

    {:reply, :ok, %{state | messages: compacted}}
  end

  # Legacy atom form kept for any pre-instructions caller.
  def handle_call(:proactive_compact, from, state),
    do: handle_call({:proactive_compact, nil}, from, state)

  def handle_call({:proactive_compact, instructions}, _from, state) do
    messages = state.messages || []

    compacted =
      TurnPipeline.bounded_compaction(messages, fn ->
        OptimalSystemAgent.Agent.Loop.ProactiveCompaction.compact(
          messages,
          state.session_id,
          instructions,
          # This handler IS `/compact`. Everything else that reaches
          # `compact/4` is the threshold path and keeps the `:auto` default.
          :manual
        )
      end) || messages

    stats = %{
      messages_before: length(messages),
      messages_after: length(compacted),
      tokens_before: OptimalSystemAgent.Agent.ContextEngine.Router.estimate_tokens(messages),
      tokens_after: OptimalSystemAgent.Agent.ContextEngine.Router.estimate_tokens(compacted)
    }

    # Bill the summarizer round-trips staged by the bounded task above.
    state = Accounting.absorb_side_spend(state)

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
    tools =
      rebuild_advertised_tools(state, coordinator: on?, ask_user_enabled: state.ask_user_enabled)

    {:reply, {:ok, on?}, %{state | coordinator: on?, tools: tools}}
  end

  def handle_call({:get_coordinator}, _from, state) do
    {:reply, {:ok, state.coordinator}, state}
  end

  # In-place ask_user toggle, rebuilt from the same preserved base as the
  # coordinator toggle so the two compose instead of clobbering each other.
  # This is the ONE place the tool array legitimately changes mid-session; the
  # cost (a single prompt-cache re-prime) is named in the reply text.
  def handle_call({:set_ask_user, on?}, _from, state) when is_boolean(on?) do
    tools =
      rebuild_advertised_tools(state, coordinator: state.coordinator, ask_user_enabled: on?)

    {:reply, {:ok, on?}, %{state | ask_user_enabled: on?, tools: tools}}
  end

  def handle_call({:get_ask_user}, _from, state) do
    {:reply, {:ok, state.ask_user_enabled}, state}
  end

  def handle_call({:set_strategy, _strategy_name}, _from, state) do
    {:reply, {:error, :strategies_not_available}, state}
  end

  def handle_call(:get_strategy, _from, state) do
    {:reply, {:ok, :none, %{}}, state}
  end

  # Synchronous durable save, for shutdown paths only.
  #
  # Identical work to `handle_cast({:persist_session, _})` below, but the
  # caller waits for it. `Channels.CLI` exits via `System.halt/1`, which skips
  # `terminate/2` entirely, so the async cast path had no chance to run and the
  # transcript was dropped while the (synchronous) spend flush survived — a
  # session's bill outliving its transcript. See
  # `SessionPersistence.flush_sync/2` for the measurement and the bound.
  #
  # Spend is flushed here too so the two records land together: writing one and
  # not the other is the exact asymmetry this fixes.
  @impl true
  def handle_call({:persist_session_sync, session_id}, _from, state) do
    _ = OptimalSystemAgent.Agent.SessionPersistence.flush_spend(session_id, state)

    result =
      case OptimalSystemAgent.Agent.SessionPersistence.save_from_state(session_id, state) do
        :ok ->
          :ok

        {:ok, _} ->
          :ok

        {:error, reason} ->
          notify_persistence_failure(session_id, state, reason)
          {:error, reason}

        other ->
          notify_persistence_failure(session_id, state, {:unexpected, other})
          {:error, other}
      end

    {:reply, result, state}
  end

  # Mid-session toggles must keep the role allowlist. Rebuilding from
  # `all_tools` without it is how an explorer would get `delegate` back.
  defp rebuild_advertised_tools(state, coordinator: coordinator?, ask_user_enabled: ask?) do
    state.all_tools
    |> ToolFilter.filter_for_coordinator(coordinator?)
    |> AskUserMode.filter_tools(ask?)
    |> ToolFilter.filter_for_role_allowlist(state)
    |> ToolFilter.filter_for_env_allowlist()
  end

  # Durable session save, serialized by THIS process' mailbox.
  #
  # `SessionPersistence.auto_save/1` (the :post_response hook) used to reach in
  # with `:sys.get_state/1` from the hook process; a busy loop made that call
  # time out and the entire save was silently dropped. A cast is queued instead,
  # so a busy loop DEFERS the save rather than losing it, and the state written
  # is the loop's own — never a scraped snapshot.
  #
  # A failed save was previously DISCARDED (`_ = save_from_state(...)`). A full
  # disk, a read-only config dir, or an encode error logged one warning at
  # `:warning` level from deep inside SessionPersistence and the turn was
  # delivered to the user exactly as if it had been persisted — the session then
  # evaporated on the next restart with no signal that anything went wrong.
  # Match the result and SURFACE the failure on the same typed `:system_event` +
  # session PubSub channel every other turn-level fault uses, so the TUI/HTTP
  # consumers can tell the user their conversation is not being saved.
  @impl true
  def handle_cast({:persist_session, session_id}, state) do
    case OptimalSystemAgent.Agent.SessionPersistence.save_from_state(session_id, state) do
      :ok ->
        {:noreply, state}

      {:ok, _} ->
        {:noreply, state}

      {:error, reason} ->
        notify_persistence_failure(session_id, state, reason)
        {:noreply, state}

      other ->
        notify_persistence_failure(session_id, state, {:unexpected, other})
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:inject_agent_result, content}, state) do
    # `scaffold: true` marks this as loop-authored user-role text, NOT something
    # the human typed. `/undo` (drop_last_exchange/1) walks past scaffolding to
    # the last real user turn; without the marker, an `/undo` immediately after
    # a delegation result dropped only this injection and reported `dropped: 1`
    # while changing nothing the user could see.
    injected = %{role: "user", content: content, scaffold: true}
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

        # Same turn, same reasoning as handle_call({:process, _}) — see
        # `during_turn/1`: this callback blocks in LLMClient exactly like a real
        # turn does, so exit trapping must be off for its duration.
        {:reply, _reply, state} = during_turn(fn -> run_and_reply(state) end)
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

  # Termination is split by two independent questions, not by exit reason alone:
  #
  #   1. Is a turn IN FLIGHT (`status: :processing`)?  The `Checkpoint` and the
  #      `DurableLog` are exactly the markers `init/1` reads back to restore an
  #      interrupted turn. Clearing them unconditionally — as all three "clean"
  #      clauses used to — deleted the recovery evidence for a turn that had NOT
  #      finished, so a shutdown that landed mid-turn threw the work away. They
  #      are only safe to clear at a genuine idle boundary.
  #
  #   2. Was the exit ABNORMAL, or clean-but-mid-turn?  Auto-save is registered
  #      on `:post_response` only, so a turn that never reached a response was
  #      never persisted. Save here before the process is gone.
  #
  # Note `init/1` sets `trap_exit`; without it none of this ran on a supervisor
  # shutdown at all (`terminate/2` is not invoked for an untrapped exit signal).
  @impl true
  def terminate(:normal, state), do: end_session(state, :normal)
  def terminate(:shutdown, state), do: end_session(state, :normal)
  def terminate({:shutdown, _}, state), do: end_session(state, :normal)

  def terminate(reason, state) do
    # Abnormal exit — always try to save, and never clear recovery markers.
    # The cancel flag is NOT a recovery marker: it is per-run cooperative state
    # whose only reader is a process that no longer exists, so it must go with
    # the process (see `clear_cancel/1`).
    clear_cancel_key(state.session_id)
    save_unsaved_turn(state, reason)
    fire_session_end(state, reason)
    :ok
  end

  defp end_session(state, hook_reason) do
    clear_cancel_key(state.session_id)

    # The terminal-frame latch belongs to a RUN, not to an id, and ids are
    # reused on purpose (see `init/1`). Leaving the last turn's latch behind
    # lets a fresh loop under the same id inherit a claim it never made.
    OptimalSystemAgent.Agent.TurnTermination.forget(state.session_id)

    # Last chance to make the durable bill match what this process actually
    # spent. The clean-exit branch below DELETES the crash checkpoint, so after
    # this point the sidecar is the only surviving record of the run's spend —
    # writing it before dropping the checkpoint, rather than after, is the whole
    # point. Best-effort: a save problem must never make a stop hang.
    _ = SessionPersistence.flush_spend(state.session_id, state)

    if turn_in_flight?(state) do
      Logger.info(
        "[loop] session #{state.session_id}: clean exit MID-TURN (status " <>
          "#{inspect(Map.get(state, :status))}) — keeping the crash checkpoint and " <>
          "durable step log so the turn can be restored"
      )

      save_unsaved_turn(state, hook_reason)
    else
      Logger.info(
        "[loop] session #{state.session_id}: clean exit at an idle boundary — " <>
          "clearing the crash checkpoint and durable step log"
      )

      Checkpoint.clear_checkpoint(state.session_id)
      DurableLog.clear(state.session_id)
    end

    fire_session_end(state, hook_reason)
    :ok
  end

  # A turn is in flight unless the loop is idle.
  #
  # This was `%{status: :processing}` — a status a real user turn NEVER carries.
  # `TurnPipeline.reset_per_turn_fields/1` stamps `:thinking` at the top of
  # every turn (turn_pipeline.ex) and the turn ends back at `:idle`;
  # `:processing` is written in exactly one place in the whole tree, the
  # synthetic background-task turn in `handle_cast(:poke, …)` above. So for
  # every real turn this answered "no turn in flight", and `end_session/2` took
  # the branch that DELETES `Checkpoint` and `DurableLog` — the two markers
  # `init/1` reads back to restore an interrupted turn, and precisely the
  # recovery evidence the comment above says is only safe to clear at a genuine
  # idle boundary. A `/clear`, a `SessionManager.stop_session/1`, or an
  # application stop landing mid-turn threw the turn's work away silently.
  #
  # Restated over the real domain: `:idle` is the only status that means no
  # turn. Anything else — `:thinking`, `:processing`, or a status added later —
  # is in flight. That direction fails safe: an unrecognised status keeps the
  # recovery markers instead of discarding a turn, which is the asymmetry that
  # matters (a stale checkpoint is cleared at the next turn boundary; a deleted
  # one is gone).
  defp turn_in_flight?(%{status: :idle}), do: false
  defp turn_in_flight?(%{status: status}) when is_atom(status), do: true
  defp turn_in_flight?(_), do: false

  # Best-effort durable save of a turn that never reached `:post_response`.
  # Guarded end-to-end: a save problem must never turn a fast shutdown into a
  # hanging one, and must never mask the original exit reason.
  defp save_unsaved_turn(%{session_id: sid} = state, reason) when is_binary(sid) do
    _ = Checkpoint.checkpoint_state(state)

    case SessionPersistence.save_from_state(sid, state) do
      :ok ->
        Logger.info("[loop] session #{sid}: saved unfinished turn on #{inspect(reason)} exit")
        :ok

      {:ok, _} ->
        :ok

      {:error, save_reason} ->
        notify_persistence_failure(sid, state, save_reason)
        :ok

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp save_unsaved_turn(_state, _reason), do: :ok

  # `trap_exit` turns linked-process exits into ordinary messages. Nothing in
  # this module creates a link on purpose (tool tasks use `async_nolink`), so
  # this clause exists only so a stray EXIT cannot be mistaken for real work —
  # a non-parent link dying must not silently take the session's state with it.
  @impl true
  def handle_info({:EXIT, pid, exit_reason}, state) do
    Logger.debug(
      "[loop] session #{inspect(Map.get(state, :session_id))}: trapped EXIT from " <>
        "#{inspect(pid)} (#{inspect(exit_reason)})"
    )

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Emitted when a durable session save fails. Deliberately `Logger.error` (not
  # `warning`): losing the transcript is a data-loss event, not a hiccup. Goes
  # out on the same typed `:system_event` + session PubSub pair every other
  # turn-level fault uses, so the TUI/HTTP consumers can tell the user their
  # conversation is not being saved instead of showing a normal reply.
  defp notify_persistence_failure(session_id, state, reason) do
    message =
      "Session save FAILED — this turn is not on disk and will be lost on restart " <>
        "(#{inspect(reason)})."

    Logger.error("[loop] session #{session_id}: #{message}")

    payload = %{
      event: :session_persist_failed,
      session_id: session_id,
      reason: inspect(reason),
      message: message
    }

    Bus.emit(:system_event, payload, Observability.annotate(state, source: "agent.loop"))

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{session_id}",
      {:osa_event, Map.put(payload, :type, :system_event)}
    )

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # SessionEnd hook — run synchronously so session-cleanup handlers execute
  # before the process exits. Fully guarded: hook problems never block shutdown.
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

  # Run a turn with exit trapping DISABLED, then restore it.
  #
  # `init/1` traps exits so `terminate/2` runs on a supervisor shutdown. That is
  # only correct while the loop is IDLE — back in its receive loop, where a
  # trapped EXIT is seen immediately. Inside a turn the process is blocked in
  # its callback (ultimately in `LLMClient`'s selective `receive`), and trapping
  # there is actively harmful in two ways:
  #
  #   1. `LLMClient` runs the provider stream in a LINKED `Task.async` plus two
  #      `spawn_link`ed watchers, and its `receive` has no `{:EXIT, _, _}`
  #      clause. Untrapped, a stream task that dies abnormally takes the loop
  #      down at once. Trapped, that exit becomes a message the selective
  #      receive skips — and the turn would block until the 1-hour absolute
  #      timeout instead of failing fast.
  #   2. A shutdown signal arriving mid-turn could not be acted on anyway (the
  #      process cannot reach `terminate/2` from inside the turn), so trapping
  #      would only add dead wait before the supervisor's kill — and would make
  #      `force_terminate_subagent/1` wait out the shutdown budget before it
  #      could unblock a parent joined on a stuck child.
  #
  # Nothing is lost by not trapping here: an abnormal exit RAISED inside the
  # turn still runs `terminate/2` (that path never needed trap_exit), and the
  # mid-turn `Checkpoint`/`DurableLog` markers survive a hard kill precisely
  # because `terminate/2` no longer clears them while a turn is in flight.
  defp during_turn(fun) do
    Process.flag(:trap_exit, false)

    try do
      fun.()
    after
      Process.flag(:trap_exit, true)
    end
  end

  defp dispatch_message(state, skip_plan) do
    if not skip_plan and should_plan?(state) do
      state = %{state | plan_mode: true}
      # Plan mode runs a full investigative ReactLoop of its own, so it spends
      # real tokens. Snapshot before the call for the same delta the reply path
      # takes — otherwise every plan row in the transcript reads 0 tokens for
      # what is often the most expensive turn in a session.
      plan_tokens_before = token_counters(state)

      case MessageHandler.run_plan_mode(state) do
        {:ok, plan_text, state} ->
          state = %{state | status: :idle}

          # Plan-mode returns without going through run_and_reply, so no
          # :post_response fires — persist the plan here (tool_name "plan")
          # so it appears in /sessions resume, transcript, and recap. The
          # user turn was already saved at ingestion by TurnPipeline.
          plan_tokens =
            plan_tokens_before
            |> token_delta(token_counters(state))
            |> Map.values()
            |> Enum.sum()

          OptimalSystemAgent.Store.SessionTranscript.save_turn(
            state.session_id,
            "assistant",
            plan_text,
            tool_name: "plan",
            tokens: plan_tokens
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

  # The four running token counters `Loop.Accounting.record/2` maintains on the
  # loop state. Read as a tuple so a turn's cost is one subtraction, and so a
  # new counter cannot be added to accounting and silently missed here.
  defp token_counters(state) do
    {
      Map.get(state, :session_input_tokens, 0) || 0,
      Map.get(state, :session_output_tokens, 0) || 0,
      Map.get(state, :session_cache_creation_tokens, 0) || 0,
      Map.get(state, :session_cache_read_tokens, 0) || 0
    }
  end

  # Per-turn delta, as the payload keys the `save_transcript` hook reads.
  # Clamped at 0: a session resumed from a checkpoint can restore counters that
  # are lower than the live ones, and a negative "cost" is never meaningful.
  defp token_delta({i0, o0, cw0, cr0}, {i1, o1, cw1, cr1}) do
    %{
      turn_input_tokens: max(i1 - i0, 0),
      turn_output_tokens: max(o1 - o0, 0),
      turn_cache_creation_tokens: max(cw1 - cw0, 0),
      turn_cache_read_tokens: max(cr1 - cr0, 0)
    }
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
    # Same reasoning for tokens: `Loop.Accounting` accumulates its four counters
    # for the whole session, so this turn's cost is the difference across the
    # ReactLoop call. The snapshot is taken here and the delta computed after
    # `ReactLoop.run/1` returns, so every re-entry branch inside it (tool cycles,
    # mid-turn compaction, continuation) falls within the window.
    tokens_before = token_counters(state)

    # Scope the partial-accounting stash to THIS turn. `Accounting.record/2`
    # mirrors each round-trip's absolute counters into the process dictionary so
    # the crash arms below can recover spend that the immutable state thread
    # takes with it on an unwind; clearing it here stops a turn that crashes
    # before its first round-trip from adopting the previous turn's numbers.
    Accounting.forget_partial()

    {response, state} =
      try do
        ReactLoop.run(state)
      rescue
        e ->
          Logger.error(
            "[loop] CRASH in ReactLoop: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
          )

          TerminalSource.halt(
            "I hit an error processing that request. Check the logs for details.",
            Accounting.adopt_partial(state),
            :error
          )
      catch
        :exit, reason ->
          Logger.error("[loop] EXIT in ReactLoop: #{inspect(reason)}")

          TerminalSource.halt(
            "I hit a timeout or process error. This usually means the LLM connection dropped — try again.",
            Accounting.adopt_partial(state),
            :error
          )
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

    # Flush the durable spend sidecar SYNCHRONOUSLY, here, in the loop's own
    # process, with the turn's final accounting already folded into `state`.
    #
    # The turn-boundary save below is the `:post_response` hook
    # (`SessionPersistence.auto_save/1`), which runs in an ASYNC hook process
    # and casts `{:persist_session, id}` back to this loop. Two hops. A session
    # that stops right after its last answer — every headless/benchmark run —
    # can be torn down before either hop lands, leaving the mid-turn checkpoint
    # as the newest sidecar on disk. That checkpoint predates this turn's final
    # LLM round-trip, so the published token/cost figures came out LOW by one
    # round-trip (30k-110k input tokens per task, measured). An instrument whose
    # error runs in our own favour is worse than no instrument.
    #
    # This write is a few hundred bytes and cannot race itself: it is ordered by
    # this process' own execution, not by a mailbox.
    _ = SessionPersistence.flush_spend(state.session_id, state)

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

    # Fire post_response hooks (async, non-blocking).
    #
    # The crash/exit arms above return the PRE-ReactLoop `state` — an unwind
    # takes the immutable state thread with it — but they now merge back the
    # accounting `Accounting.record/2` stashed outside that thread, so a turn
    # that billed three round-trips and crashed on the fourth reports those
    # three here instead of a flat 0. Only accounting is recovered, not the
    # message history; see `Accounting.adopt_partial/1` for why.
    turn_tokens = token_delta(tokens_before, token_counters(state))

    try do
      Hooks.run_async(
        :post_response,
        Map.merge(
          %{
            session_id: state.session_id,
            response: response,
            input: state.current_input || "",
            turn_count: state.turn_count,
            iteration: state.iteration,
            tools_used: Map.get(state.last_meta, :tools_used, []),
            total_tool_calls: state.total_tool_calls
          },
          turn_tokens
        )
      )
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    # `message_id` identifies WHICH assistant message this finalizes: the last
    # generation of the turn (`LLMClient.current_message_id/0`, minted per LLM
    # round-trip in this same process). The client uses it to replace exactly
    # that generation's streamed accumulation — and to drop a repeat delivery
    # of the same finalization instead of appending it a second time.
    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{state.session_id}",
      {:osa_event,
       %{
         type: :agent_response,
         session_id: state.session_id,
         message_id: LLMClient.current_message_id(),
         # Additive: absent on a normal turn, present when the turn ended
         # because every provider call failed rather than because the model
         # answered. Old consumers ignore it; new ones can stop scoring an
         # outage as a model failure.
         turn_error: Map.get(state, :turn_error),
         response: response,
         # WHO wrote `response`. `"agent"` for a real model answer — bit-for-bit
         # what every existing consumer already receives — and `"system"` when a
         # guard, a control-flow stop or an error authored the text instead.
         #
         # This is the fix for a live report: a user typed "ok how about now"
         # and the doom-loop guard's internal advice ("3 consecutive generations
         # produced no tool calls… call a concrete tool to move forward") was
         # rendered as OSA's answer, under the ◈ OSA header, addressed to the
         # model rather than to them.
         response_type: TerminalSource.response_type(state),
         # Additive companion so a client can label WHY the turn ended without
         # parsing the text. nil on a normal answer.
         terminal_source: TerminalSource.label(state)
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
  #
  # "The most recent user turn" is NOT simply "the last message with
  # role == \"user\"". OSA writes several kinds of user-role SCAFFOLDING into
  # history that the user never typed:
  #
  #   * `ReactLoop.finalize_interrupt/2`'s `[Request interrupted by user]`
  #     marker, appended on every Esc/interrupt;
  #   * `inject_agent_result/2`'s delegation-result injection;
  #   * background `<task-notification>` drains.
  #
  # Walking to the last user-role message therefore made `/undo` right after an
  # interrupt (or right after a teammate reported back) drop ONLY the
  # scaffolding — a visible no-op that still reported `dropped: 1`. The user
  # pressed it again and lost a real turn.
  #
  # The walker now skips scaffolding and lands on the last message the user
  # actually authored, dropping the scaffolding along with it.
  @doc false
  @spec drop_last_exchange([map()]) :: {[map()], non_neg_integer()}
  def drop_last_exchange(messages) do
    last_user_idx =
      messages
      |> Enum.with_index()
      |> Enum.filter(fn {m, _i} -> real_user_message?(m) end)
      |> List.last()

    case last_user_idx do
      {_m, idx} -> {Enum.take(messages, idx), length(messages) - idx}
      nil -> {messages, 0}
    end
  end

  # A user-role message the HUMAN authored — i.e. not loop scaffolding.
  defp real_user_message?(m) do
    to_string(Map.get(m, :role) || Map.get(m, "role") || "") == "user" and
      not scaffold_message?(m)
  end

  @doc false
  # Scaffolding is identified two ways, on purpose:
  #
  #   1. An explicit `:scaffold` marker on the message map. This is the
  #      preferred, unambiguous signal and is what every injection site OSA
  #      owns should set.
  #   2. A content match against `ReactLoop.interrupt_markers/0` and the
  #      background-notification envelope, for the injection sites that write
  #      the marker text directly (react_loop.ex is owned elsewhere) and for
  #      transcripts PERSISTED BEFORE the marker existed — those replay from
  #      disk with no flag at all, so a flag-only check would silently keep the
  #      old broken behaviour on every resumed session.
  @spec scaffold_message?(map()) :: boolean()
  def scaffold_message?(m) do
    cond do
      Map.get(m, :scaffold) || Map.get(m, "scaffold") ->
        true

      true ->
        content = to_string(Map.get(m, :content) || Map.get(m, "content") || "")
        trimmed = String.trim(content)

        trimmed in ReactLoop.interrupt_markers() or
          String.starts_with?(trimmed, "<task-notification")
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
