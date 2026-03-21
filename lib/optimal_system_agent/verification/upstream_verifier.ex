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
  def verify(task_id, verification_criteria) when is_binary(task_id) and is_map(verification_criteria) do
    ensure_table()
    :ets.insert(@table, {task_id, :pending})

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
        :ets.insert(@table, {task_id, :passed})
        Logger.info("[UpstreamVerifier] task #{task_id} PASSED all checks")

        Bus.emit(:system_event, %{
          event: :upstream_verification_passed,
          task_id: task_id
        })

        :passed
      else
        failure_contexts = Enum.map(failures, fn {:fail, ctx} -> ctx end)
        :ets.insert(@table, {task_id, {:failed, failure_contexts}})
        Logger.warning("[UpstreamVerifier] task #{task_id} FAILED: #{inspect(failure_contexts)}")

        Bus.emit(:system_event, %{
          event: :upstream_verification_failed,
          task_id: task_id,
          failures: failure_contexts
        })

        {:failed, %{task_id: task_id, failures: failure_contexts}}
      end

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
      [{^task_id, st}] -> st
      [] -> :unknown
    end
  end

  @doc "Clear the verification record for `task_id`."
  @spec clear(String.t()) :: :ok
  def clear(task_id) do
    ensure_table()
    :ets.delete(@table, task_id)
    :ok
  end

  # --- Private ---

  defp build_checks(criteria) do
    checks = []

    checks =
      case Map.get(criteria, "test_command") do
        nil -> checks
        cmd -> [{:test_command, cmd} | checks]
      end

    checks =
      case Map.get(criteria, "output_spec") do
        nil ->
          checks

        spec ->
          task_output = Map.get(criteria, "task_output", "")
          [{:output_spec, spec, task_output} | checks]
      end

    checks
  end

  defp run_check({:test_command, cmd}) do
    case System.cmd("sh", ["-c", cmd], stderr_to_stdout: true) do
      {_output, 0} ->
        {:ok, :test_command_passed}

      {output, code} ->
        {:fail, %{check: :test_command, command: cmd, exit_code: code, output: String.slice(output, 0, 1000)}}
    end
  rescue
    e ->
      {:fail, %{check: :test_command, command: cmd, error: Exception.message(e)}}
  end

  defp run_check({:output_spec, spec, task_output}) do
    matches =
      cond do
        is_binary(spec) -> String.contains?(task_output, spec)
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
      [{^task_id, :pending}] ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(@poll_interval_ms)
          poll_for_result(task_id, deadline)
        end

      [{^task_id, :passed}] ->
        :passed

      [{^task_id, {:failed, ctx}}] ->
        {:failed, ctx}

      [] ->
        {:error, :timeout}
    end
  end

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
