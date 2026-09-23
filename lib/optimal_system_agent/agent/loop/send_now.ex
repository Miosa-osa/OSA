defmodule OptimalSystemAgent.Agent.Loop.SendNow do
  @moduledoc """
  Send-now: the user's queued messages interrupt the running turn instead of
  waiting for its current step to finish (Claude Code 2.1.268/2.1.275 parity).

  A plain mid-turn steer (`Loop.steer/2`) is folded in at the next ReAct step
  boundary, and a step boundary is only reached once every tool in the current
  batch has returned. A foreground subagent or a long shell command can hold
  that boundary for many minutes, so a steer typed "now" was read "later".

  Send-now closes that gap without destroying work:

    * `request/2` queues every message as a steer (FIFO, in one call, so a
      multi-message send cannot interleave) and THEN raises a per-session
      yield flag. The order matters: `yield?/1` requires a queued steer as
      well as the flag, so a flag that outlives its steer can never yield a
      later, unrelated tool batch.
    * The tool collectors (`ToolOrchestrator.collect_tasks/5`, the streaming
      executor) poll `yield?/1`. On a yield they hand every still-running tool
      to `background_pending/2` instead of waiting for it, and the turn moves
      straight on to its next step, where the steer is drained.
    * `background_pending/2` reuses the existing background machinery where
      it exists — a foreground shell command is promoted to a supervised
      `BackgroundManager` task (the Ctrl+B path), and a foreground subagent's
      run is re-marked `background: true` so an ordinary interrupt no longer
      reaches it. Every other tool keeps running in its task. Whichever way,
      the model receives a "moved to background" result now and the real
      result later as a `<task-notification>`.
    * The LLM stream's cancel watcher polls `yield?/1` too, so a send-now that
      lands mid-generation cuts the stream (keeping the partial text) rather
      than letting the model finish a plan the user just redirected.

  ## Exactly-once hand-off

  A tool can finish at the very instant the loop decides to background it. Two
  claims arbitrate that race on one ETS key per tool call, both with
  `:ets.insert_new/2`:

    * the tool's own task, on finishing, claims `:finished` (`task_finished/3`);
    * the loop, on backgrounding, claims `:adopted` (`adopt/3`).

  Whoever loses knows what happened: a task that finds `:adopted` delivers its
  own result as a notification; a loop that finds `:finished` waits for the
  reply the task is about to send. Neither path can drop or double a result.
  """

  require Logger

  alias OptimalSystemAgent.Agent.Loop.Steer
  alias OptimalSystemAgent.Agent.TaskNotifications

  @table :osa_send_now

  # How long the loop waits for tools to settle after a shell detach before it
  # adopts whatever is still running. A detach answers within a few ms; this is
  # a bound, not a delay, because `Task.yield_many/2` returns as soon as every
  # task has replied.
  @settle_ms 300

  # A tool that won the `:finished` claim has already returned its value; its
  # reply is in flight to the loop. Bounded so a wedged mailbox cannot hang the
  # turn — the fallback result names what happened.
  @finished_reply_ms 5_000

  # Cap on the tool output carried inside a notification. The model reads it
  # verbatim; a runaway result must not blow the context in one message.
  @max_notification_chars 12_000

  @doc """
  Queue `texts` as mid-turn steers for `session_id`, in order, then raise the
  yield flag so the running turn stops waiting on its current tools.

  Each text goes through `Loop.steer/2`, so stop-intent routing and
  fan-out to running descendants behave exactly as a typed `/steer` does.
  Returns `:ok`; the steers are durable before the flag is visible.
  """
  @spec request(String.t(), [String.t()], (String.t(), String.t() -> any())) :: :ok
  def request(session_id, texts, steer_fun \\ &OptimalSystemAgent.Agent.Loop.steer/2)
      when is_binary(session_id) and is_list(texts) do
    texts = texts |> Enum.filter(&is_binary/1) |> Enum.reject(&(String.trim(&1) == ""))

    Enum.each(texts, fn text -> steer_fun.(session_id, text) end)

    if texts != [] do
      insert({{:flag, session_id}, System.monotonic_time(:millisecond)})
    end

    :ok
  end

  @doc """
  True when the running turn should stop waiting on its tools/stream: the
  user asked to send now AND a steer is actually waiting to be folded in.

  A raised flag with nothing queued is stale — the steer was already drained
  at a boundary the loop reached before the flag landed — and is cleared here
  rather than allowed to yield work the user never asked to interrupt.
  """
  @spec yield?(String.t() | nil) :: boolean()
  def yield?(session_id) when is_binary(session_id) do
    if flagged?(session_id) do
      if Steer.live_count(session_id) > 0 do
        true
      else
        clear(session_id)
        false
      end
    else
      false
    end
  end

  def yield?(_), do: false

  @doc "Whether the send-now flag is raised (regardless of queued steers)."
  @spec flagged?(String.t()) :: boolean()
  def flagged?(session_id) when is_binary(session_id) do
    match?([_], :ets.lookup(@table, {:flag, session_id}))
  rescue
    ArgumentError -> false
  end

  @doc "Lower the yield flag. Called once the steers have been folded in."
  @spec clear(String.t() | nil) :: :ok
  def clear(session_id) when is_binary(session_id) do
    :ets.delete(@table, {:flag, session_id})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def clear(_), do: :ok

  # ── Task side ───────────────────────────────────────────────────────────

  @doc """
  Run by a tool's own task once `result` is ready. Claims `:finished`; if the
  loop already adopted the call (it was backgrounded), the result is delivered
  as a `<task-notification>` instead, since nobody is waiting for the reply.
  Returns `result` unchanged.
  """
  @spec task_finished(String.t() | nil, map(), term()) :: term()
  def task_finished(session_id, tc, result) when is_binary(session_id) and is_map(tc) do
    key = tool_key(session_id, tc)

    if insert_new({key, :finished}) do
      result
    else
      delete(key)
      deliver(session_id, tc, result)
      result
    end
  end

  def task_finished(_session_id, _tc, result), do: result

  @doc """
  Forget the `:finished` markers of calls the loop collected normally. Called
  once per dispatched batch; a stale marker would make a later call that
  reuses the same id look already-finished.
  """
  @spec forget(String.t() | nil, [map()]) :: :ok
  def forget(session_id, tool_calls) when is_binary(session_id) and is_list(tool_calls) do
    Enum.each(tool_calls, fn tc ->
      :ets.delete_object(@table, {tool_key(session_id, tc), :finished})
    end)

    :ok
  rescue
    ArgumentError -> :ok
  end

  def forget(_, _), do: :ok

  # ── Loop side ───────────────────────────────────────────────────────────

  @doc """
  Move every still-running `{tool_call, task}` pair to the background and
  return one `{tool_call, result}` per pair.

  Order of operations:

    1. a foreground shell command is detached into `BackgroundManager` (the
       Ctrl+B path) — its task then returns a "moved to background" result of
       its own, with a `background_id` the model can poll or kill;
    2. foreground subagents of this session are re-marked as background runs,
       so a later Esc no longer cancels work the user chose to keep;
    3. tasks get a short settle window to return on their own;
    4. anything still running is adopted: it keeps running, and its result
       arrives later as a notification.

  `opts` exists for tests: `:detach_shell` (fn sid -> term) and `:settle_ms`.
  """
  @spec background_pending([{map(), Task.t()}], String.t(), keyword()) :: [{map(), term()}]
  def background_pending(pending, session_id, opts \\ [])

  def background_pending([], _session_id, _opts), do: []

  def background_pending(pending, session_id, opts) do
    if Enum.any?(pending, fn {tc, _} -> shell_call?(tc) end) do
      detach = Keyword.get(opts, :detach_shell, &detach_foreground_shell/1)
      _ = detach.(session_id)
    end

    mark_subagents_background(session_id)

    settle_ms = Keyword.get(opts, :settle_ms, @settle_ms)
    settled = Task.yield_many(Enum.map(pending, &elem(&1, 1)), settle_ms)
    by_ref = Map.new(settled, fn {task, res} -> {task.ref, res} end)

    results =
      Enum.map(pending, fn {tc, task} ->
        case Map.get(by_ref, task.ref) do
          {:ok, result} ->
            {tc, result}

          {:exit, reason} ->
            {tc, error_result(tc, "tool exited: #{inspect(reason)}")}

          nil ->
            {tc, adopt(session_id, tc, task)}
        end
      end)

    count = Enum.count(results, fn {_tc, r} -> backgrounded_result?(r) end)

    if count > 0 do
      Logger.info(
        "[send_now] #{count} running tool(s) moved to the background for #{session_id} " <>
          "so the user's message is read now"
      )
    end

    results
  end

  @doc """
  Adopt one running tool task: it keeps running, its reply is no longer
  awaited, and its result will arrive as a notification. Returns the tool
  result the model reads now.
  """
  @spec adopt(String.t(), map(), Task.t()) :: term()
  def adopt(session_id, tc, %Task{} = task) do
    key = tool_key(session_id, tc)

    if insert_new({key, :adopted}) do
      # Nobody will read this task's reply or its DOWN now. The reply message
      # itself is dropped by the Loop's catch-all `handle_info/2`.
      Process.demonitor(task.ref, [:flush])
      backgrounded_result(tc)
    else
      # The task won the race: it already finished and its reply is on the
      # way. Take it as an ordinary result.
      delete(key)

      case Task.yield(task, @finished_reply_ms) do
        {:ok, result} -> result
        {:exit, reason} -> error_result(tc, "tool exited: #{inspect(reason)}")
        nil -> error_result(tc, "tool finished but its result did not arrive")
      end
    end
  end

  @backgrounded_marker "Moved to background: the user sent a new message"

  @doc false
  def backgrounded_marker, do: @backgrounded_marker

  defp backgrounded_result(tc) do
    content =
      "#{@backgrounded_marker}, so this call keeps running detached from the turn " <>
        "instead of being cancelled. Its result will arrive later as a " <>
        "<task-notification> with task-id \"#{notification_task_id(tc)}\". " <>
        "Do not run it again; read the user's message and act on it now."

    {%{role: "tool", tool_call_id: tc.id, name: Map.get(tc, :name), content: content}, content}
  end

  defp backgrounded_result?({_msg, str}) when is_binary(str),
    do: String.starts_with?(str, @backgrounded_marker)

  defp backgrounded_result?(_), do: false

  defp error_result(tc, msg) do
    {%{role: "tool", tool_call_id: tc.id, name: Map.get(tc, :name), content: "Error: #{msg}"},
     "Error: #{msg}"}
  end

  # ── Delivery ────────────────────────────────────────────────────────────

  defp deliver(session_id, tc, result) do
    {status, text} = result_text(result)

    notification = %{
      task_id: notification_task_id(tc),
      tool_use_id: tc.id,
      status: status,
      summary:
        "Backgrounded #{Map.get(tc, :name) || "tool"} call #{status}.\n\n" <>
          clamp(text)
    }

    case TaskNotifications.queue_once(session_id, notification) do
      :ok -> TaskNotifications.poke_after_batch(session_id)
      _ -> :ok
    end
  rescue
    e ->
      Logger.warning("[send_now] could not deliver backgrounded result: #{Exception.message(e)}")
      :ok
  end

  defp result_text({_msg, str}) when is_binary(str), do: {status_of(str), str}
  defp result_text({_msg, str, _fatal}) when is_binary(str), do: {"failed", str}
  defp result_text(other), do: {"completed", inspect(other)}

  defp status_of("Error:" <> _), do: "failed"
  defp status_of(_), do: "completed"

  defp clamp(text) do
    if String.length(text) > @max_notification_chars do
      String.slice(text, 0, @max_notification_chars) <>
        "\n\n[... output truncated at #{@max_notification_chars} characters]"
    else
      text
    end
  end

  defp notification_task_id(tc), do: "tool:#{tc.id}"

  # ── Background machinery reuse ──────────────────────────────────────────

  defp shell_call?(tc) do
    Map.get(tc, :name) == OptimalSystemAgent.Tools.Builtins.ShellExecute.Constants.tool_name()
  end

  defp detach_foreground_shell(session_id) do
    OptimalSystemAgent.Tools.Builtins.ShellExecute.Handler.detach_foreground(session_id)
  rescue
    _ -> {:error, :detach_failed}
  catch
    :exit, _ -> {:error, :detach_failed}
  end

  # A foreground subagent is a RunStore row with `background: false` whose
  # parent is this session. Re-marking it keeps it out of an ordinary
  # interrupt's reach (`Loop.cancel/2` skips background runs) — it now runs
  # exactly like a `delegate(background: true)` launch would have.
  defp mark_subagents_background(session_id) do
    alias OptimalSystemAgent.Agent.RunStore

    session_id
    |> RunStore.children_of()
    |> Enum.each(fn child ->
      case RunStore.get(child) do
        %{status: :running, background: false} -> RunStore.mark_background(child)
        _ -> :ok
      end
    end)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # ── ETS ─────────────────────────────────────────────────────────────────

  defp tool_key(session_id, tc), do: {:tool, session_id, Map.get(tc, :id)}

  defp insert(row) do
    :ets.insert(@table, row)
  rescue
    ArgumentError -> false
  end

  defp insert_new(row) do
    :ets.insert_new(@table, row)
  rescue
    # No table (a bare unit test without the application): behave as if the
    # claim was won, which degrades to the pre-send-now behaviour.
    ArgumentError -> true
  end

  defp delete(key) do
    :ets.delete(@table, key)
  rescue
    ArgumentError -> true
  end
end
