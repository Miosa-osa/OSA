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

  alias OptimalSystemAgent.Agent.Loop.ToolExecutor
  alias OptimalSystemAgent.Tools.{LegacyAdapter, Registry, UseContext}

  require Logger

  @default_max_concurrency 10
  @default_timeout_ms 60_000
  @long_running_timeout_ms 10 * 60_000

  @type tool_call :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          optional(:arguments) => map() | String.t(),
          optional(any()) => any()
        }

  @type result :: {tool_message :: map(), result_str :: String.t()}

  @doc """
  Dispatch a list of tool calls.

  Executes consecutive concurrency-safe calls in parallel batches via
  `Task.Supervisor.async_stream_nolink/4`. Any unsafe call is treated as a
  barrier and executed serially in original order before later calls begin.
  Returns results in the **original order** of `tool_calls`.

  Options:

    * `:max_concurrency` (pos_integer)  — passed to `async_stream_nolink`
      (default: 10)
    * `:timeout_ms` (pos_integer)       — per-tool timeout (default: 60_000)
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

  defp run_parallel(tool_calls, state, opts) do
    supervisor = Keyword.get(opts, :supervisor, OptimalSystemAgent.TaskSupervisor)
    executor = Keyword.get(opts, :executor, ToolExecutor)
    max_conc = Keyword.get(opts, :max_concurrency, @default_max_concurrency)
    default_timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    supervisor
    |> Task.Supervisor.async_stream_nolink(
      tool_calls,
      fn tc -> executor.execute_tool_call(tc, state) end,
      max_concurrency: max_conc,
      timeout: batch_timeout(tool_calls, default_timeout),
      on_timeout: :kill_task
    )
    |> Enum.zip(tool_calls)
    |> Enum.map(&parallel_result/1)
  end

  defp run_serial(tool_calls, state, opts) do
    executor = Keyword.get(opts, :executor, ToolExecutor)

    Enum.map(tool_calls, fn tc ->
      {tc, executor.execute_tool_call(tc, state)}
    end)
  end

  defp parallel_result({{:ok, result}, tc}), do: {tc, result}

  defp parallel_result({{:exit, _reason}, tc}),
    do: {tc, error_result(tc, "Tool execution timed out")}

  defp parallel_result({_, tc}),
    do: {tc, error_result(tc, "Tool execution failed")}

  defp batch_timeout(tool_calls, default_timeout) do
    if Enum.any?(tool_calls, &long_running_tool?/1) do
      max(default_timeout, @long_running_timeout_ms)
    else
      default_timeout
    end
  end

  defp long_running_tool?(%{name: name}) when name in ["delegate", "task_wait", "peer_review"],
    do: true

  defp long_running_tool?(_), do: false

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
