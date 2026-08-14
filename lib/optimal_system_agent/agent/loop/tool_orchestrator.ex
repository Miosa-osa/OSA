defmodule OptimalSystemAgent.Agent.Loop.ToolOrchestrator do
  @moduledoc """
  Per-input concurrency-aware tool dispatch.

  Replaces the inline parallel/sequential split in `ReactLoop.execute_tools/3`
  (currently around `react_loop.ex:320-353`). The orchestrator groups
  consecutive tool calls where `LegacyAdapter.concurrency_safe?/3` returns
  true into parallel batches, while any unsafe call is a serial barrier that
  runs in its original position.

  Key differences from the inline implementation:

    1. **Per-input** concurrency check (not module-level). A tool can be
       concurrency-safe for some inputs and not others (e.g., `shell_execute`
       with `cd` mutates the working dir).

    2. **Uniform LegacyAdapter routing** — the orchestrator never branches
       on flat-vs-structured itself; the adapter handles that.

    3. **`UseContext` flows through every call** — once `ReactLoop` wires
       the context construction (Phase 4), structured tools get it; flat
       tools warn-once via the adapter.

    4. **Result-budget enforcement** — large tool results are persisted via
       `ToolResultStorage` based on the tool's `max_result_size_chars/0`.

  ## Integration

  Wired into `ReactLoop.execute_tools/3` (around `react_loop.ex:319-326`)
  as the single dispatch point for ordered parallel/serial execution. The
  inline `Task.Supervisor.async_stream_nolink/4` previously inlined in
  the loop is now encapsulated here.
  """

  alias OptimalSystemAgent.Agent.Loop.ToolError
  alias OptimalSystemAgent.Agent.Loop.ToolExecutor
  alias OptimalSystemAgent.Tools.{LegacyAdapter, Registry, UseContext}

  require Logger

  @default_max_concurrency 10
  @default_timeout_ms 60_000
  # WS5 — shared cancel-flag table (same as ReactLoop) + await poll cadence.
  @cancel_table :osa_cancel_flags
  @poll_interval_ms 200

  @type tool_call :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          optional(:arguments) => map() | String.t(),
          optional(any()) => any()
        }

  # A fatal result carries a third element (`{:fatal, message}`) — see
  # `ToolError`. `ReactLoop` strips it via `ToolError.normalize_results/1`.
  @type result ::
          {tool_message :: map(), result_str :: String.t()}
          | {tool_message :: map(), result_str :: String.t(), {:fatal, String.t()}}

  @doc """
  Dispatch a list of tool calls.

  Executes consecutive concurrency-safe calls in parallel batches via
  `Task.Supervisor.async_stream_nolink/4`. Any unsafe call is treated as a
  barrier and executed serially in original order before later calls begin.
  Returns results in the **original order** of `tool_calls`.

  Options:

    * `:max_concurrency` (pos_integer)  — passed to `async_stream_nolink`
      (default: 10)
    * `:timeout_ms` (pos_integer | :infinity) — per-tool timeout (default: 60_000)
    * `:supervisor` (module)            — defaults to
      `OptimalSystemAgent.TaskSupervisor`
    * `:executor`   (module)            — defaults to
      `OptimalSystemAgent.Agent.Loop.ToolExecutor`. Tests can inject a
      stub.
  """
  @spec dispatch([tool_call()], map(), keyword()) :: [{tool_call(), result()}]
  def dispatch(tool_calls, state, opts \\ []) when is_list(tool_calls) do
    ctx = build_use_context(state)

    fresh =
      tool_calls
      |> execution_batches(ctx)
      |> Enum.flat_map(fn
        {:parallel, batch} -> run_parallel(batch, state, opts)
        {:serial, tc} -> run_serial([tc], state, opts)
      end)

    # Restore original input order — model expects results in submission order
    by_id = Map.new(fresh, fn {tc, r} -> {tc.id, {tc, r}} end)

    Enum.map(tool_calls, fn tc ->
      Map.get(by_id, tc.id, {tc, error_result(tc, "Tool not executed")})
    end)
  end

  @doc """
  Rewrite DUPLICATE tool-call ids so every call in a batch carries a distinct one.

  A provider (or streaming re-assembly) can emit two `tool_use` blocks under the
  same id. Every downstream stage keys results BY id — `dispatch/3`'s own
  order-restoring map and `ReactLoop`'s streaming/fresh merge map — so a
  collision makes one result overwrite the other and a result is lost. Worse,
  the assistant message then carries two `tool_use` blocks against a single
  `tool_result`, and a strict provider (Anthropic) rejects the *following*
  request outright: the turn after the one that actually went wrong is the one
  that breaks.

  This is the single, canonical place that repair happens. It must be applied
  ONCE and UPSTREAM of every id-keyed map — patching either map alone leaves the
  other broken, and two divergent repairs is how the bug survives.

  Rules:

    * The FIRST occurrence of an id keeps it verbatim, so streaming
      reconciliation (which started tools under the provider's original ids)
      still matches.
    * Each later duplicate gets a `#N` suffix, re-checked against everything
      already emitted so the rewrite cannot collide either.
    * A missing/non-scalar id is minted rather than left `nil` — two `nil` ids
      collapse in a map exactly like two equal strings do.
    * Strict no-op (same terms, same order) when the ids are already unique.
  """
  @spec uniquify_ids([tool_call()]) :: [tool_call()]
  def uniquify_ids(tool_calls) when is_list(tool_calls) do
    tool_calls
    |> Enum.map_reduce(MapSet.new(), fn tc, seen ->
      id = Map.get(tc, :id)

      cond do
        not scalar_id?(id) ->
          new_id = fresh_id(seen, "osa_toolcall")
          {Map.put(tc, :id, new_id), MapSet.put(seen, new_id)}

        MapSet.member?(seen, id) ->
          new_id = fresh_id(seen, to_string(id))
          {Map.put(tc, :id, new_id), MapSet.put(seen, new_id)}

        true ->
          {tc, MapSet.put(seen, id)}
      end
    end)
    |> elem(0)
  end

  def uniquify_ids(other), do: other

  # `nil` is an atom, so it must be excluded explicitly — a missing id is
  # "mint one", not "a valid scalar that happens to be nil".
  defp scalar_id?(nil), do: false
  defp scalar_id?(""), do: false
  defp scalar_id?(id), do: is_binary(id) or is_integer(id) or is_atom(id)

  defp fresh_id(seen, base), do: fresh_id(seen, base, 1)

  defp fresh_id(seen, base, n) do
    candidate = "#{base}##{n}"

    if MapSet.member?(seen, candidate),
      do: fresh_id(seen, base, n + 1),
      else: candidate
  end

  @doc """
  Partition tool calls into `{concurrency_safe, must_be_serial}`.

  Per-input — looks up the tool's module and asks
  `LegacyAdapter.concurrency_safe?(mod, input, ctx)`. Unknown tools
  fall back to **serial** (fail-closed).
  """
  @spec partition([tool_call()], UseContext.t()) :: {[tool_call()], [tool_call()]}
  def partition(tool_calls, %UseContext{} = ctx) do
    Enum.split_with(tool_calls, &concurrency_safe?(&1, ctx))
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp execution_batches(tool_calls, %UseContext{} = ctx) do
    {batches, safe_acc} =
      Enum.reduce(tool_calls, {[], []}, fn tc, {batches, safe_acc} ->
        if concurrency_safe?(tc, ctx) do
          {batches, [tc | safe_acc]}
        else
          batches = flush_safe_batch(batches, safe_acc)
          {[{:serial, tc} | batches], []}
        end
      end)

    batches
    |> flush_safe_batch(safe_acc)
    |> Enum.reverse()
  end

  defp flush_safe_batch(batches, []), do: batches
  defp flush_safe_batch(batches, safe_acc), do: [{:parallel, Enum.reverse(safe_acc)} | batches]

  defp concurrency_safe?(tc, %UseContext{} = ctx) do
    mod = lookup_module(tc.name)
    input = decode_arguments(tc)

    cond do
      is_nil(mod) -> false
      true -> LegacyAdapter.concurrency_safe?(mod, input, ctx)
    end
  end

  defp run_parallel([], _state, _opts), do: []

  # WS5 — explicit per-tool tasks (instead of async_stream_nolink) so a user
  # interrupt can brutal-kill every in-flight tool the moment the cancel flag
  # is set, rather than waiting for the batch to finish. Chunked by
  # max_concurrency to preserve the previous parallelism bound.
  defp run_parallel(tool_calls, state, opts) do
    supervisor = Keyword.get(opts, :supervisor, OptimalSystemAgent.TaskSupervisor)
    executor = Keyword.get(opts, :executor, ToolExecutor)
    max_conc = Keyword.get(opts, :max_concurrency, @default_max_concurrency)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    sid = Map.get(state, :session_id)

    tool_calls
    |> Enum.chunk_every(max_conc)
    |> Enum.flat_map(fn chunk ->
      if cancelled?(sid) do
        Enum.map(chunk, fn tc -> {tc, interrupted_result(tc)} end)
      else
        # Carry the session's cwd ACROSS the process boundary.
        #
        # `Workspace.Cwd.get/0` reads the process dictionary, and a process
        # dictionary does not propagate to a spawned Task. Every tool runs in
        # one of these Tasks, so `shell_execute` — which defaults to
        # `Cwd.get/0` — fell through to `original_cwd()`, the directory the
        # BACKEND booted in, rather than the session's working_dir.
        #
        # Observed in a SWE-bench Pro run: `pwd` returned the backend's boot
        # directory, so `git log` read OSA's own history instead of the task
        # repo's. It only showed in 4 of 12 instances because a command that
        # passes an explicit `cwd`, or that starts with its own `cd`, never
        # consults the default and is unaffected.
        #
        # Read on the CALLER (which has the override) and re-publish inside the
        # Task. Captured per batch rather than per call because it cannot change
        # mid-batch — `apply_overrides/2` publishes it once at turn start.
        caller_cwd = OptimalSystemAgent.Workspace.Cwd.get()

        # Carry the SESSION IDENTITY across the same boundary, for the same
        # reason. `Settings.current_session/0` reads `:osa_session_id` from the
        # process dictionary; without this every tool Task resolved `:global`,
        # so the session settings layer — which is where `/add-dir`'s
        # `permissions.additionalDirectories` are stored — was invisible to the
        # permission check that runs inside the Task. `/add-dir` therefore could
        # not widen scope for the tool it was granted for.
        tasks =
          Enum.map(chunk, fn tc ->
            {tc,
             Task.Supervisor.async_nolink(supervisor, fn ->
               OptimalSystemAgent.Workspace.Cwd.put_process_override(caller_cwd)
               if is_binary(sid) and sid != "", do: Process.put(:osa_session_id, sid)
               executor.execute_tool_call(tc, state)
             end)}
          end)

        deadline =
          case timeout do
            # No ceiling. A generic wrapper cannot know whether it is timing a
            # 200 ms file read or a three-agent dispatch that legitimately runs
            # for hours, so any single number it picks is wrong for one of them.
            :infinity -> :infinity
            ms -> System.monotonic_time(:millisecond) + ms
          end

        collect_tasks(tasks, [], sid, deadline)
      end
    end)
  end

  # Serial barriers now also run inside a supervised task (one at a time) so an
  # interrupt can kill a long-running barrier tool too. execute_tool_call has
  # always been task-safe: the parallel path and StreamingToolExecutor already
  # ran it under Task.Supervisor.
  defp run_serial(tool_calls, state, opts) do
    run_parallel(tool_calls, state, Keyword.put(opts, :max_concurrency, 1))
  end

  # Poll-await a batch: finishes normally, hard-kills every still-running task
  # the moment the session's cancel flag appears (WS5 interrupt), or kills on
  # deadline (parity with the old async_stream on_timeout: :kill_task).
  defp collect_tasks([], done, _sid, _deadline), do: Enum.reverse(done)

  defp collect_tasks(pending, done, sid, deadline) do
    cond do
      cancelled?(sid) ->
        killed =
          Enum.map(pending, fn {tc, task} ->
            case Task.shutdown(task, :brutal_kill) do
              {:ok, result} -> {tc, result}
              _ -> {tc, interrupted_result(tc)}
            end
          end)

        Enum.reverse(done) ++ killed

      deadline != :infinity and System.monotonic_time(:millisecond) > deadline ->
        timed_out =
          Enum.map(pending, fn {tc, task} ->
            case Task.shutdown(task, :brutal_kill) do
              {:ok, result} -> {tc, result}
              _ -> {tc, error_result(tc, "Tool execution timed out")}
            end
          end)

        Enum.reverse(done) ++ timed_out

      true ->
        yielded = Task.yield_many(Enum.map(pending, &elem(&1, 1)), @poll_interval_ms)
        results = Map.new(yielded, fn {task, res} -> {task.ref, res} end)

        {still_pending, newly_done} =
          Enum.reduce(pending, {[], done}, fn {tc, task}, {p, d} ->
            case Map.get(results, task.ref) do
              nil ->
                {[{tc, task} | p], d}

              {:ok, result} ->
                {p, [{tc, result} | d]}

              # RESPOND-TO-MODEL: the tool task died. `execute_tool_call/2`
              # already recovers everything it can see, so reaching here means
              # the process itself went down — surface the REASON to the model
              # (it used to be a contentless "Tool execution failed") and keep
              # the turn alive.
              {:exit, reason} ->
                {p, [{tc, error_result(tc, ToolError.exit_text(reason))} | d]}
            end
          end)

        collect_tasks(Enum.reverse(still_pending), newly_done, sid, deadline)
    end
  end

  defp cancelled?(sid) when is_binary(sid) do
    match?([{^sid, true}], :ets.lookup(@cancel_table, sid))
  rescue
    ArgumentError -> false
  end

  defp cancelled?(_), do: false

  defp interrupted_result(tc) do
    {%{role: "tool", tool_call_id: tc.id, name: tc.name, content: "Error: Interrupted by user"},
     "Error: Interrupted by user"}
  end

  defp error_result(tc, msg) do
    {%{role: "tool", tool_call_id: tc.id, name: tc.name, content: "Error: #{msg}"},
     "Error: #{msg}"}
  end

  defp lookup_module(name) do
    builtin = :persistent_term.get({Registry, :builtin_tools}, %{})
    Map.get(builtin, name)
  end

  defp decode_arguments(%{arguments: args}) when is_map(args), do: args

  defp decode_arguments(%{arguments: args}) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, m} when is_map(m) -> m
      _ -> %{}
    end
  end

  defp decode_arguments(_), do: %{}

  defp build_use_context(state) when is_map(state) do
    # Thread an `emit` closure through the context so structured tools can
    # publish progress / intermediate events directly to the Bus without
    # importing the Events module.
    emit_fn = fn topic, payload ->
      try do
        OptimalSystemAgent.Events.Bus.emit(topic, payload)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    UseContext.new(state, tool_use_id: nil, emit: emit_fn)
  end

  defp build_use_context(_), do: UseContext.empty()
end
