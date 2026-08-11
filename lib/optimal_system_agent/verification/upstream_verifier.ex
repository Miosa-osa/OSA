defmodule OptimalSystemAgent.Verification.UpstreamVerifier do
  @moduledoc """
  Upstream verification — validates task output before dependents proceed.

  Auto-spawns on task completion to run a set of verification checks against
  the task's output. Dependent tasks are held until verification passes.

  ## Verification checks

  A `verification_criteria` map can specify one or more of:

    - `:test_command` — shell command that must exit 0
    - `:output_spec` — string or regex that the task output must match
    - `:no_regressions` — shell command whose output must be identical to a
      previously captured baseline (not yet implemented; reserved)

  ## Blocking dependents

  The verifier stores its `:pending` / `:passed` / `:failed` status in an ETS
  table (`:osa_upstream_verifications`). Dependent task launchers call
  `block_until_passed/2` which polls the table until the status resolves or
  a timeout expires.

  ## Failure

  On failure, `send_back/3` is called with the task_id and a failure context
  map so the upstream task can be retried or escalated.
  """

  require Logger

  alias OptimalSystemAgent.Events.Bus

  @table :osa_upstream_verifications
  @poll_interval_ms 500
  @default_timeout_ms 5 * 60 * 1000

  # --- Public API ---

  @doc """
  Run verification checks for `task_id` against `verification_criteria`.

  Stores result in ETS and emits `system_event` on completion.
  Should be called asynchronously (e.g., via `Task.start/1`) so it does not
  block the calling process.

  ## verification_criteria keys

    - `"test_command"` — shell command to run
    - `"output_spec"` — expected substring or `~r/regex/` string in task output
    - `"task_output"` — the string output produced by the task (for spec matching)

  Returns `:passed` or `{:failed, context_map}`.
  """
  @spec verify(String.t(), map()) :: :passed | {:failed, map()}
  def verify(task_id, verification_criteria)
      when is_binary(task_id) and is_map(verification_criteria) do
    ensure_table()

    # Every attempt gets its own token. The table is keyed on `task_id` alone,
    # so a slow first attempt used to land its stale `{:failed, …}` on top of a
    # retry's `:passed` — the retry's own dependents then stayed blocked on a
    # verdict that no longer applied. Writes are now conditional on still being
    # the current run (`put_status/3`); a superseded run's writes are dropped.
    run_ref = make_ref()
    :ets.insert(@table, {task_id, :pending, run_ref})

    # A verifier is documented to run inside a `Task`, and a killed Task left
    # the row at `:pending` forever — every `block_until_passed/2` then burned
    # its full timeout (5 minutes by default) before giving up. Watch this
    # process and resolve the row if it dies without recording a verdict.
    watchdog = start_watchdog(task_id, run_ref)

    Logger.info("[UpstreamVerifier] Starting verification for task #{task_id}")

    checks = build_checks(verification_criteria)

    failures =
      checks
      |> Enum.map(&run_check/1)
      |> Enum.filter(fn
        {:ok, _} -> false
        {:fail, _} -> true
      end)

    result =
      if failures == [] do
        put_status(task_id, run_ref, :passed)
        Logger.info("[UpstreamVerifier] task #{task_id} PASSED all checks")

        Bus.emit(:system_event, %{
          event: :upstream_verification_passed,
          task_id: task_id
        })

        :passed
      else
        failure_contexts = Enum.map(failures, fn {:fail, ctx} -> ctx end)
        put_status(task_id, run_ref, {:failed, failure_contexts})
        Logger.warning("[UpstreamVerifier] task #{task_id} FAILED: #{inspect(failure_contexts)}")

        Bus.emit(:system_event, %{
          event: :upstream_verification_failed,
          task_id: task_id,
          failures: failure_contexts
        })

        {:failed, %{task_id: task_id, failures: failure_contexts}}
      end

    stop_watchdog(watchdog)

    # Send task back on failure so it can be retried / escalated.
    case result do
      {:failed, ctx} -> send_back(task_id, ctx, verification_criteria)
      :passed -> :ok
    end

    result
  end

  @doc """
  Block the calling process until the upstream verification for `task_id` resolves.

  Polls ETS every #{@poll_interval_ms}ms up to `timeout_ms`.
  Returns `:passed`, `{:failed, context}`, or `{:error, :timeout}`.
  """
  @spec block_until_passed(String.t(), non_neg_integer()) ::
          :passed | {:failed, map()} | {:error, :timeout}
  def block_until_passed(task_id, timeout_ms \\ @default_timeout_ms) do
    ensure_table()
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_for_result(task_id, deadline)
  end

  @doc "Return current verification status for `task_id` without blocking."
  @spec status(String.t()) :: :pending | :passed | {:failed, list()} | :unknown
  def status(task_id) do
    ensure_table()

    case :ets.lookup(@table, task_id) do
      [{^task_id, st, _run_ref}] -> st
      [] -> :unknown
    end
  end

  @doc """
  Create the verification table from a long-lived process.

  Called from `Application.start/2`. A named ETS table belongs to whichever
  process created it and dies with that process; left to `ensure_table/0`, the
  first `verify/2` in the VM became the owner — and `verify/2` is documented to
  run inside a short-lived `Task`. When that Task finished, the table vanished,
  taking every recorded verdict with it and turning `block_until_passed/2`'s
  lookups into `[]`. Same reasoning as `Infra.BoundedTable.init_tables/0`.
  """
  @spec init_table() :: :ok
  def init_table, do: ensure_table()

  @doc "Clear the verification record for `task_id`."
  @spec clear(String.t()) :: :ok
  def clear(task_id) do
    ensure_table()
    :ets.delete(@table, task_id)
    :ok
  end

  # --- Private ---

  # Build the check list.
  #
  # Two things used to go wrong here. `Map.get(criteria, "test_command")` only
  # matched STRING keys, so a criteria map written with atom keys (the natural
  # shape for internal Elixir callers) produced no checks at all. And an empty
  # check list fell straight through `failures == []` to `:passed` — a task
  # whose criteria were mistyped, or written with the wrong key style, verified
  # *vacuously* and released every blocked dependent. Keys are now read in both
  # styles, and criteria that specify something we do not recognise are
  # reported (`:unrecognized`) rather than silently passing. A genuinely empty
  # criteria map still passes: that is an explicit "nothing to verify", and
  # failing it would deadlock dependents instead.
  defp build_checks(criteria) do
    checks = []

    checks =
      case fetch_criterion(criteria, "test_command") do
        nil -> checks
        cmd -> [{:test_command, cmd} | checks]
      end

    checks =
      case fetch_criterion(criteria, "output_spec") do
        nil ->
          checks

        spec ->
          task_output = fetch_criterion(criteria, "task_output") || ""
          [{:output_spec, spec, task_output} | checks]
      end

    case {checks, Map.keys(criteria)} do
      {[], []} -> []
      {[], keys} -> [{:unrecognized, keys}]
      {checks, _} -> checks
    end
  end

  @known_keys ["test_command", "output_spec", "task_output", "no_regressions"]

  # Listed so the atoms exist in the VM before `fetch_criterion/2` reaches for
  # them — `String.to_existing_atom/1` is deliberately used there (never
  # `to_atom/1`: criteria maps come from task metadata and must not be able to
  # mint atoms), and it would otherwise raise on the very keys we support.
  @known_atoms [:test_command, :output_spec, :task_output, :no_regressions]
  @doc false
  def known_atoms, do: @known_atoms

  defp fetch_criterion(criteria, key) do
    case Map.get(criteria, key) do
      nil -> Map.get(criteria, String.to_existing_atom(key))
      value -> value
    end
  rescue
    ArgumentError -> nil
  end

  defp run_check({:unrecognized, keys}) do
    {:fail,
     %{
       check: :criteria,
       reason: "verification_criteria specified no runnable check",
       keys: Enum.map(keys, &to_string/1),
       known_keys: @known_keys
     }}
  end

  defp run_check({:test_command, cmd}) do
    case OptimalSystemAgent.OS.Shell.cmd(cmd, stderr_to_stdout: true) do
      {_output, 0} ->
        {:ok, :test_command_passed}

      {output, code} ->
        {:fail,
         %{
           check: :test_command,
           command: cmd,
           exit_code: code,
           output: String.slice(output, 0, 1000)
         }}
    end
  rescue
    e ->
      {:fail, %{check: :test_command, command: cmd, error: Exception.message(e)}}
  end

  defp run_check({:output_spec, spec, task_output}) do
    matches =
      cond do
        is_binary(spec) ->
          String.contains?(task_output, spec)

        true ->
          case Regex.compile(spec) do
            {:ok, regex} -> Regex.match?(regex, task_output)
            {:error, _} -> String.contains?(task_output, spec)
          end
      end

    if matches do
      {:ok, :output_spec_matched}
    else
      {:fail, %{check: :output_spec, spec: spec, reason: "output did not match spec"}}
    end
  end

  defp send_back(task_id, failure_context, _criteria) do
    Bus.emit(:system_event, %{
      event: :task_returned_for_retry,
      task_id: task_id,
      failure_context: failure_context,
      source: "upstream_verifier"
    })

    Logger.info("[UpstreamVerifier] Sent task #{task_id} back for retry")
  end

  defp poll_for_result(task_id, deadline) do
    case :ets.lookup(@table, task_id) do
      [{^task_id, :pending, _run_ref}] ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(@poll_interval_ms)
          poll_for_result(task_id, deadline)
        end

      [{^task_id, :passed, _run_ref}] ->
        :passed

      [{^task_id, {:failed, ctx}, _run_ref}] ->
        {:failed, ctx}

      [] ->
        {:error, :timeout}
    end
  end

  # Record `status` for `task_id` only if `run_ref` is still the current run.
  defp put_status(task_id, run_ref, status) do
    case :ets.lookup(@table, task_id) do
      [{^task_id, _st, ^run_ref}] ->
        :ets.insert(@table, {task_id, status, run_ref})
        :ok

      [] ->
        # Row was cleared underneath us; do not resurrect a stale verdict.
        :ok

      _superseded ->
        Logger.debug(
          "[UpstreamVerifier] dropping superseded #{inspect(status)} for task #{task_id}"
        )

        :ok
    end
  rescue
    _ -> :ok
  end

  # Resolve a still-`:pending` row if the verifying process dies without a
  # verdict, so dependents fail fast instead of polling to the deadline.
  defp start_watchdog(task_id, run_ref) do
    verifier = self()

    spawn(fn ->
      ref = Process.monitor(verifier)

      receive do
        {:DOWN, ^ref, :process, ^verifier, :normal} ->
          :ok

        {:DOWN, ^ref, :process, ^verifier, reason} ->
          put_status(task_id, run_ref, {:failed, [%{check: :verifier, reason: inspect(reason)}]})

        :verifier_done ->
          Process.demonitor(ref, [:flush])
          :ok
      end
    end)
  end

  defp stop_watchdog(pid) when is_pid(pid) do
    send(pid, :verifier_done)
    :ok
  end

  defp stop_watchdog(_), do: :ok

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end
end
