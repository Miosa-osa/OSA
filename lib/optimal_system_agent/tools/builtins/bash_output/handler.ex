defmodule OptimalSystemAgent.Tools.Builtins.BashOutput.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `bash_output`.

  INTERFACE layer — thin wrapper over the background-shell MECHANISM
  (`OptimalSystemAgent.Shell.BackgroundManager`). Split mirrors
  `TaskOutput.Handler`:
    * `validate/2`          — type-checks input shape (cheap, no I/O)
    * `check_permissions/2` — always allow (polling is session-local)
    * `execute/2`           — polls (or kills) the background command by id
  """

  alias OptimalSystemAgent.Agent.Cancellation
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Shell.BackgroundManager
  alias OptimalSystemAgent.Tools.UseContext

  # How often the blocking wait re-reads the task snapshot. 250 ms is well below
  # any human-visible latency and costs a `GenServer.call` per tick, so a 30-min
  # wait is ~7200 cheap local calls — nothing next to the LLM round-trip it
  # replaces.
  @poll_interval_ms 250

  # Ceiling on `wait_ms`. A single blocking wait must not be able to freeze the
  # turn for long stretches (a 30-min ceiling here caused an observed 415 s
  # freeze), so it is capped at 2 min. A caller that needs longer simply waits
  # again, and the wait is now cancel-aware so a user interrupt breaks it early.
  @max_wait_ms 120_000

  # ── Stage 1: Input validation ──────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"background_id" => id} = input, _ctx) when is_binary(id) do
    if String.trim(id) == "" do
      {:error, "background_id must not be empty", -32_602}
    else
      {:ok, input}
    end
  end

  def validate(%{"background_id" => _}, _ctx),
    do: {:error, "background_id must be a string", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: background_id", -32_602}

  # ── Stage 2: Permission check ──────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()} | {:ask, String.t()}
  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ───────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"background_id" => id} = input, ctx) do
    {result, waited} =
      if truthy?(input["kill"]) do
        {BackgroundManager.kill(id), nil}
      else
        await_terminal(id, wait_ms(input), ctx)
      end

    case result do
      {:ok, snapshot} ->
        # WS6: the model has now SEEN a terminal status — claim the per-task
        # notified flag so the completion broadcast doesn't ALSO queue a
        # <task-notification> (poll + completion race → exactly one).
        if snapshot.status != :running do
          OptimalSystemAgent.Agent.TaskNotifications.mark_notified(snapshot.id)
        end

        {:ok, format_snapshot(snapshot, waited)}

      {:error, :not_found} ->
        {:ok, not_found_message(id)}
    end
  rescue
    e -> {:error, "Failed to get background output: #{Exception.message(e)}"}
  end

  def execute(_input, _ctx),
    do: {:error, "Missing required parameter: background_id"}

  # ── Private ────────────────────────────────────────────────────────────

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  # ── Blocking wait ──────────────────────────────────────────────────────
  #
  # WHY THIS EXISTS. Before it, this tool had no way to wait and its own prompt
  # said so in capitals ("DO NOT USE THIS TOOL TO WAIT"), while `shell_execute`
  # forbade `sleep` and re-checking. The only sanctioned way to learn a
  # background command's result was the completion notification — which only
  # arrives if something drives another turn. In a one-shot/headless run
  # nothing does, so "I'll report when it completes" was the last thing 10
  # Terminal-Bench episodes ever produced
  # (`docs/research/failure-taxonomy.md` §1).
  #
  # The verification gate can refuse such a completion claim, but a refusal is
  # only useful if the turn has somewhere to go. Telling a model to "poll until
  # it finishes" when every poll returns instantly is not somewhere to go: it
  # burns the gate's re-prompt budget in seconds and ends in the same place.
  # This is the affordance that makes the refusal actionable — one tool call
  # that blocks until there is a real answer.
  defp wait_ms(input) do
    case Map.get(input, "wait_ms") do
      n when is_integer(n) and n > 0 -> min(n, @max_wait_ms)
      s when is_binary(s) -> s |> Integer.parse() |> parsed_wait()
      _ -> 0
    end
  end

  defp parsed_wait({n, _}) when n > 0, do: min(n, @max_wait_ms)
  defp parsed_wait(_), do: 0

  # Returns `{manager_result, waited_ms | nil}`. `nil` means no wait was asked
  # for, so the formatter stays byte-identical to the non-waiting path.
  defp await_terminal(id, 0, _ctx), do: {BackgroundManager.output(id), nil}

  defp await_terminal(id, ms, ctx) do
    started = System.monotonic_time(:millisecond)
    session_id = ctx && Map.get(ctx, :session_id)

    # Observable: a tool call that blocks changes the shape of the turn, so it
    # is announced on the same bus the verification gate uses.
    emit_wait(session_id, id, ms)

    result = poll_until(id, started + ms, session_id)
    {result, System.monotonic_time(:millisecond) - started}
  end

  defp poll_until(id, deadline, session_id) do
    case BackgroundManager.output(id) do
      {:ok, %{status: :running} = snap} = still_running ->
        cond do
          System.monotonic_time(:millisecond) >= deadline ->
            still_running

          # Cancel-aware: a user interrupt breaks the blocking wait instead of
          # holding the turn until the deadline. Tag the running snapshot so the
          # formatter can say the wait was interrupted (not that it timed out).
          cancelled?(session_id) ->
            {:ok, Map.put(snap, :cancelled_wait, true)}

          true ->
            Process.sleep(@poll_interval_ms)
            poll_until(id, deadline, session_id)
        end

      other ->
        other
    end
  end

  # Guard for a nil session_id (no session context) — skip the check.
  defp cancelled?(nil), do: false
  defp cancelled?(session_id), do: Cancellation.cancelled?(session_id)

  defp emit_wait(session_id, id, ms) do
    Bus.emit(:system_event, %{
      event: :background_wait_started,
      session_id: session_id,
      background_id: id,
      wait_ms: ms
    })

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp not_found_message(id) do
    "No background command with id \"#{id}\". It may have finished and been " <>
      "retired, been killed, or the id may be incorrect."
  end

  defp format_snapshot(snap, waited) do
    header =
      [
        "Background command #{snap.id} is #{snap.status}.",
        wait_line(snap, waited),
        "- Command: #{snap.command}",
        "- Status: #{snap.status}",
        exit_line(snap),
        output_file_line(snap),
        "- Output bytes: #{snap.bytes}#{if snap.truncated, do: " (truncated)", else: ""}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    body =
      case String.trim(snap.output) do
        "" -> "(no output yet)"
        out -> out
      end

    header <> "\n\n--- output ---\n" <> body
  end

  defp wait_line(_snap, nil), do: nil

  defp wait_line(%{status: :running, cancelled_wait: true}, waited),
    do:
      "- Waited #{waited} ms; the wait was INTERRUPTED by a cancel and it is STILL " <>
        "RUNNING. This is not a result. Resume the wait with a new wait_ms, or kill it " <>
        "and do the work in the foreground."

  defp wait_line(%{status: :running}, waited),
    do:
      "- Waited #{waited} ms and it is STILL RUNNING. This is not a result. " <>
        "Wait again with a longer wait_ms, or kill it and do the work in the foreground."

  defp wait_line(_snap, waited), do: "- Waited #{waited} ms for it to finish."

  defp exit_line(%{exit_code: nil}), do: nil
  defp exit_line(%{exit_code: code}), do: "- Exit code: #{code}"

  defp output_file_line(%{output_file: file}) when is_binary(file),
    do: "- Full output file: #{file} (read with the read tool)"

  defp output_file_line(_), do: nil
end
