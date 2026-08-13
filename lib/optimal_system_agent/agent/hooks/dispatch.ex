defmodule OptimalSystemAgent.Agent.Hooks.Dispatch do
  @moduledoc """
  Hook **dispatch engine** — the pure mechanism behind the hook system.

  This module owns everything about *how* hooks are stored, ordered, executed
  and measured. It knows nothing about *which* concrete hooks exist — that is
  the job of `OptimalSystemAgent.Agent.Hooks.Handlers`. Keeping the engine and
  the handlers separate means new lifecycle events or new return semantics can
  be added here without touching business logic, and new handlers can be added
  there without understanding the execution machinery.

  Responsibilities:
    * **Registration** — `insert/5` writes hook definitions into ETS.
    * **Ordering** — hooks run in ascending `priority` (lower = first).
    * **Return-value control** — `run_chain/3` interprets each handler's return
      value to allow / deny / rewrite-input / rewrite-output / inject-context,
      matching Claude Code's hook model.
    * **Timeout** — a handler may opt into a wall-clock timeout via
      `timeout_ms:`; on expiry it is abandoned (fail-open by default, or
      fail-closed with `fail_closed: true`).
    * **Fail-closed isolation** — a crashing handler never crashes the chain;
      a crash is fail-open per hook, but `run/2` callers (e.g. the tool
      executor) fail closed when the whole engine is unreachable.
    * **Metrics** — per-event call counts, cumulative time and block counts.

  ## Handler return protocol

  Each handler receives a payload map and returns one of:

      {:ok, payload}                — allow; continue with (modified) payload
      :allow | :continue | :skip    — allow; continue with payload unchanged
      {:block, reason}              — deny; stop the chain (pre-events)
      {:deny, reason}               — deny; alias of {:block, reason}
      {:rewrite_input, new_input}   — replace :arguments (or :message); continue
      {:rewrite_output, new_output} — replace :result; continue
      {:inject_context, content}    — append to :injected_context; continue

  `run/2` returns `{:ok, final_payload}` or `{:blocked, reason}`. The final
  payload carries any rewrites (`:arguments`, `:message`, `:result`) and the
  accumulated `:injected_context` list so call-sites can act on them.

  ## Storage

    * Hook definitions live in ETS `:osa_hooks` (bag, read_concurrency).
      Row shape: `{event, name, priority, handler, opts}`.
    * Metrics counters live in ETS `:osa_hooks_metrics` (set, write_concurrency).

  Execution reads directly from ETS in the caller's process — there is no
  GenServer on the hot path.
  """

  require Logger

  alias OptimalSystemAgent.Events.Bus

  @hooks_table :osa_hooks
  @metrics_table :osa_hooks_metrics

  @default_timeout_ms 5_000

  @type hook_fn :: (map() ->
                      {:ok, map()}
                      | {:block, String.t()}
                      | {:deny, String.t()}
                      | {:rewrite_input, term()}
                      | {:rewrite_output, term()}
                      | {:inject_context, term()}
                      | :allow
                      | :continue
                      | :skip)

  # ── Table management ────────────────────────────────────────────────

  @doc "Create the engine's ETS tables if they do not already exist."
  @spec ensure_tables() :: :ok
  def ensure_tables do
    if :ets.whereis(@hooks_table) == :undefined do
      :ets.new(@hooks_table, [:named_table, :bag, :public, {:read_concurrency, true}])
    end

    if :ets.whereis(@metrics_table) == :undefined do
      :ets.new(@metrics_table, [:named_table, :public, :set, {:write_concurrency, true}])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  def hooks_table_name, do: @hooks_table
  @doc false
  def metrics_table_name, do: @metrics_table

  @doc """
  Insert (register) a hook definition into ETS. This is the single write path;
  every registration — builtins, SDK, shell/http hooks — funnels through here.
  """
  @spec insert(atom(), String.t(), (map() -> term()), integer(), keyword()) :: :ok
  def insert(event, name, handler, priority \\ 50, opts \\ []) do
    :ets.insert(@hooks_table, {event, name, priority, handler, opts})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Remove every registered hook for `event` with `name` (all priorities).
  Used to unregister dynamically-added hooks; primarily so tests that register
  a hook (especially a blocking one) don't leak it into the global table and
  contaminate later `run/2` calls.
  """
  @spec remove(atom(), String.t()) :: :ok
  def remove(event, name) do
    :ets.match_delete(@hooks_table, {event, name, :_, :_, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  # ── Execution ───────────────────────────────────────────────────────

  @doc """
  Run all hooks for an event synchronously in the caller's process.
  Returns `{:ok, final_payload}` or `{:blocked, reason}`.
  """
  @spec run(atom(), map()) :: {:ok, map()} | {:blocked, String.t()} | {:error, :hooks_unavailable}
  def run(event, payload) do
    # Fail CLOSED for pre_* events when the pipeline is unreachable. Hooks read
    # ETS inline (no GenServer on the hot path), and the tables are owned by the
    # Hooks GenServer — if it dies, ERTS deletes the tables and hooks_for_event
    # would rescue to [], silently skipping security_check/spend_guard and
    # letting the tool run (fail-open). For pre_* events that contradicts the
    # documented fail-closed contract, so we surface :hooks_unavailable instead.
    if pre_event?(event) and not pipeline_live?() do
      Logger.error(
        "[Hooks] pre-event #{event} requested while hook pipeline is unavailable — failing closed"
      )

      {:error, :hooks_unavailable}
    else
      hooks = hooks_for_event(event)
      started_at = System.monotonic_time(:microsecond)
      result = run_chain(hooks, payload, event)
      elapsed_us = System.monotonic_time(:microsecond) - started_at
      update_metrics(event, elapsed_us, result)
      result
    end
  end

  # A pre_* lifecycle event gates a side effect (tool execution), so it must
  # fail closed. post_* / other events are best-effort and stay fail-open.
  defp pre_event?(event) do
    event |> Atom.to_string() |> String.starts_with?("pre_")
  end

  # The pipeline is live when the Hooks GenServer that owns the ETS tables is
  # alive AND the hooks table actually exists.
  defp pipeline_live? do
    Process.whereis(OptimalSystemAgent.Agent.Hooks) != nil and
      :ets.whereis(@hooks_table) != :undefined
  end

  @doc """
  Run hooks asynchronously (fire-and-forget) for post-events whose result the
  caller does not need.
  """
  @spec run_async(atom(), map()) :: :ok
  def run_async(event, payload) do
    Task.start(fn ->
      hooks = hooks_for_event(event)
      started_at = System.monotonic_time(:microsecond)
      result = run_chain(hooks, payload, event)
      elapsed_us = System.monotonic_time(:microsecond) - started_at
      update_metrics(event, elapsed_us, result)
    end)

    :ok
  end

  @doc "Return hooks for an event, sorted by ascending priority."
  @spec hooks_for_event(atom()) :: [map()]
  def hooks_for_event(event) do
    @hooks_table
    |> :ets.lookup(event)
    |> Enum.sort_by(fn {_event, _name, priority, _handler, _opts} -> priority end)
    |> Enum.map(fn {_event, name, priority, handler, opts} ->
      %{name: name, priority: priority, handler: handler, opts: opts}
    end)
  rescue
    ArgumentError -> []
  end

  # ── Chain execution with return-value control ──────────────────────

  @doc false
  @spec run_chain([map()], map(), atom()) :: {:ok, map()} | {:blocked, String.t()}
  def run_chain([], payload, _event), do: {:ok, payload}

  def run_chain([hook | rest], payload, event) do
    case invoke(hook, payload, event) do
      # Allow / continue unchanged
      :allow ->
        run_chain(rest, payload, event)

      :continue ->
        run_chain(rest, payload, event)

      :skip ->
        run_chain(rest, payload, event)

      # Allow with (possibly modified) full payload
      {:ok, updated} when is_map(updated) ->
        run_chain(rest, updated, event)

      # Deny — stop the chain
      {:block, reason} ->
        deny(hook, event, payload, reason)

      {:deny, reason} ->
        deny(hook, event, payload, reason)

      # Rewrite the tool input (:arguments) or the user message (:message)
      {:rewrite_input, new_input} ->
        run_chain(rest, apply_rewrite_input(payload, new_input), event)

      # Rewrite the tool output (:result)
      {:rewrite_output, new_output} ->
        run_chain(rest, Map.put(payload, :result, new_output), event)

      # Inject additional context to be surfaced to the model
      {:inject_context, content} ->
        run_chain(rest, apply_inject_context(payload, content), event)

      # Unknown / legacy return — do not let it break the chain
      other ->
        Logger.warning("[Hooks] #{hook.name} returned unexpected: #{inspect(other)}")
        run_chain(rest, payload, event)
    end
  end

  # Invoke a single handler, honouring an optional per-hook timeout and
  # isolating crashes so a broken hook never brings down the chain.
  defp invoke(hook, payload, event) do
    timeout = Keyword.get(hook.opts, :timeout_ms)
    fail_closed = Keyword.get(hook.opts, :fail_closed, false)

    started = System.monotonic_time(:microsecond)

    raw =
      if is_integer(timeout) and timeout > 0 do
        invoke_with_timeout(hook, payload, event, timeout, fail_closed)
      else
        invoke_inline(hook, payload, event)
      end

    us = System.monotonic_time(:microsecond) - started
    {outcome, result} = classify(raw)
    emit_hook_run(hook, event, payload, outcome, us)
    result
  end

  # What the counter means, decided in ONE place.
  #
  # A hook that crashed and a hook that deliberately returned `:skip` both used
  # to leave `invoke_inline` as a bare `:skip`, which makes "failed" unknowable
  # from the outside. The failure paths now return a private tagged tuple that
  # never escapes this module: `classify/1` reads the tag, reports it, and hands
  # `run_chain` the same `:skip` it always saw, so the chain's behaviour is
  # unchanged and only the reporting is new.
  #
  # `:blocked` is counted apart from `:failed` on purpose. A hook that blocks did
  # its job — a policy hook that denies a dangerous command is the system working,
  # not an error — and folding the two together would make a correctly-configured
  # setup look broken.
  defp classify({:__hook_error__, kind}), do: {kind, :skip}
  defp classify({:block, _} = r), do: {:blocked, r}
  defp classify({:deny, _} = r), do: {:blocked, r}
  defp classify(r), do: {:ok, r}

  defp emit_hook_run(hook, event, payload, outcome, us) do
    Bus.emit(:system_event, %{
      event: :hook_run,
      hook_name: hook.name,
      hook_event: event,
      outcome: outcome,
      duration_ms: div(us, 1000),
      session_id: Map.get(payload, :session_id, "unknown")
    })
  end

  # Default path: run inline (zero overhead, preserves legacy behaviour).
  defp invoke_inline(hook, payload, event) do
    hook.handler.(payload)
  rescue
    e ->
      Logger.error("[Hooks] #{hook.name} crashed on #{event}: #{Exception.message(e)}")
      {:__hook_error__, :crashed}
  catch
    :exit, reason ->
      Logger.error("[Hooks] #{hook.name} exited on #{event}: #{inspect(reason)}")
      {:__hook_error__, :crashed}
  end

  # Opt-in path: run under a wall-clock timeout in a supervised task.
  defp invoke_with_timeout(hook, payload, event, timeout, fail_closed) do
    task = Task.async(fn -> invoke_inline(hook, payload, event) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      _ ->
        Logger.warning("[Hooks] #{hook.name} timed out after #{timeout}ms on #{event}")

        if fail_closed do
          {:block, "hook #{hook.name} timed out (fail-closed)"}
        else
          {:__hook_error__, :timed_out}
        end
    end
  end

  defp deny(hook, event, payload, reason) do
    Logger.warning("[Hooks] #{hook.name} blocked #{event}: #{reason}")

    Bus.emit(:system_event, %{
      event: :hook_blocked,
      hook_name: hook.name,
      hook_event: event,
      reason: reason,
      session_id: Map.get(payload, :session_id, "unknown")
    })

    {:blocked, reason}
  end

  # A map rewrite always targets tool :arguments. A string rewrite targets the
  # user :message when present (user_prompt_submit), else the tool :arguments.
  defp apply_rewrite_input(payload, new_input) when is_map(new_input) do
    Map.put(payload, :arguments, new_input)
  end

  defp apply_rewrite_input(payload, new_input) when is_binary(new_input) do
    if Map.has_key?(payload, :message) do
      Map.put(payload, :message, new_input)
    else
      Map.put(payload, :arguments, new_input)
    end
  end

  defp apply_rewrite_input(payload, _new_input), do: payload

  defp apply_inject_context(payload, content) do
    existing = Map.get(payload, :injected_context, [])
    Map.put(payload, :injected_context, existing ++ [content])
  end

  # ── Introspection ───────────────────────────────────────────────────

  @doc "List registered hooks grouped by event, sorted by priority."
  @spec list_hooks() :: %{atom() => [%{name: String.t(), priority: integer()}]}
  def list_hooks do
    @hooks_table
    |> :ets.tab2list()
    |> Enum.group_by(fn {event, _name, _priority, _handler, _opts} -> event end)
    |> Enum.map(fn {event, entries} ->
      hooks =
        entries
        |> Enum.sort_by(fn {_event, _name, priority, _handler, _opts} -> priority end)
        |> Enum.map(fn {_event, name, priority, _handler, _opts} ->
          %{name: name, priority: priority}
        end)

      {event, hooks}
    end)
    |> Map.new()
  rescue
    ArgumentError -> %{}
  end

  @doc "Get hook execution metrics per event."
  @spec metrics() :: map()
  def metrics do
    @metrics_table
    |> :ets.tab2list()
    |> Enum.filter(fn {key, _val} -> match?({_event, _metric}, key) end)
    |> Enum.group_by(fn {{event, _metric}, _val} -> event end)
    |> Enum.map(fn {event, entries} ->
      kv = Map.new(entries, fn {{_event, metric}, val} -> {metric, val} end)
      calls = Map.get(kv, :calls, 0)
      total_us = Map.get(kv, :total_us, 0)
      blocks = Map.get(kv, :blocks, 0)
      avg_us = if calls > 0, do: div(total_us, calls), else: 0

      {event, %{calls: calls, total_us: total_us, blocks: blocks, avg_us: avg_us}}
    end)
    |> Map.new()
  rescue
    ArgumentError -> %{}
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp update_metrics(event, elapsed_us, result) do
    :ets.update_counter(@metrics_table, {event, :calls}, {2, 1}, {{event, :calls}, 0})

    :ets.update_counter(
      @metrics_table,
      {event, :total_us},
      {2, elapsed_us},
      {{event, :total_us}, 0}
    )

    if match?({:blocked, _}, result) do
      :ets.update_counter(@metrics_table, {event, :blocks}, {2, 1}, {{event, :blocks}, 0})
    end
  rescue
    ArgumentError -> :ok
  end

  @doc "Default per-hook timeout in milliseconds (used when a hook opts in)."
  @spec default_timeout_ms() :: pos_integer()
  def default_timeout_ms, do: @default_timeout_ms
end
