defmodule OptimalSystemAgent.Verification.Loop do
  @moduledoc """
  Verification loop GenServer.

  Runs autonomous write → test → diagnose → fix → re-test cycles until the
  test suite passes or the maximum iteration count is reached.

  ## Lifecycle

    1. Spawned with a `test_command`, optional `team_id` / `task_id`, and
       iteration limits.
    2. Each cycle runs the `test_command` in a supervised `Task.async`.
    3. `process_test_result/2` evaluates the exit code and output, updates the
       confidence tracker, and decides whether to:
       - Succeed (pass) — broadcast `:verification_passed`, terminate normally.
       - Continue (fail, under limit) — call the LLM to diagnose the failure,
         apply the suggested fix, then schedule the next iteration.
       - Escalate (fail, at limit) — broadcast `:verification_escalated`,
         terminate with `:max_iterations_reached`.
    4. A 30-minute overall timeout triggers escalation if still running.

  ## External steering

  Call `steer/2` at any time to inject additional guidance into the next
  diagnostic context. Guidance is consumed once per cycle.

  ## Checkpointing

  State is persisted every 5 iterations via `Verification.Checkpoint`.

  ## Events (via `Events.Bus`)

  - `system_event` with `event: :verification_started`
  - `system_event` with `event: :verification_iteration`
  - `system_event` with `event: :verification_passed`
  - `system_event` with `event: :verification_failed`
  - `system_event` with `event: :verification_escalated`
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Verification.Confidence
  alias OptimalSystemAgent.Verification.Checkpoint
  alias OptimalSystemAgent.Providers.Registry, as: Providers

  @default_max_iterations 5
  @default_timeout_ms 30 * 60 * 1000
  @checkpoint_every 5
  @result_history_limit 5

  defstruct loop_id: nil,
            team_id: nil,
            task_id: nil,
            test_command: nil,
            max_iterations: @default_max_iterations,
            timeout_ms: @default_timeout_ms,
            iteration: 0,
            results_history: [],
            confidence: nil,
            status: :idle,
            steering_guidance: nil,
            started_at: nil,
            task_ref: nil

  # --- Client API ---

  @doc """
  Start a verification loop.

  ## Options

    - `:team_id` - owning team identifier (optional)
    - `:task_id` - associated task identifier (optional)
    - `:test_command` - shell command to run on each iteration (required)
    - `:max_iterations` - stop after N failures (default: #{@default_max_iterations})
    - `:timeout_ms` - overall timeout in ms (default: 30 minutes)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    loop_id = Keyword.get(opts, :loop_id, generate_loop_id())

    GenServer.start_link(__MODULE__, Keyword.put(opts, :loop_id, loop_id),
      name: via(loop_id)
    )
  end

  @doc "Get current state snapshot."
  @spec get_state(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_state(loop_id) do
    GenServer.call(via(loop_id), :get_state)
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc """
  Inject steering guidance for the next diagnostic context.

  The guidance string is appended to the LLM prompt on the next iteration
  and cleared after use.
  """
  @spec steer(String.t(), String.t()) :: :ok | {:error, :not_found}
  def steer(loop_id, guidance) when is_binary(guidance) do
    GenServer.call(via(loop_id), {:steer, guidance})
  catch
    :exit, _ -> {:error, :not_found}
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    test_command = Keyword.fetch!(opts, :test_command)
    loop_id = Keyword.fetch!(opts, :loop_id)

    state = %__MODULE__{
      loop_id: loop_id,
      team_id: Keyword.get(opts, :team_id),
      task_id: Keyword.get(opts, :task_id),
      test_command: test_command,
      max_iterations: Keyword.get(opts, :max_iterations, @default_max_iterations),
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
      confidence: Confidence.new(window: @result_history_limit),
      status: :running,
      started_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    # Overall timeout guard — escalate if still running after `timeout_ms`.
    Process.send_after(self(), :overall_timeout, state.timeout_ms)

    Bus.emit(:system_event, %{
      event: :verification_started,
      loop_id: loop_id,
      task_id: state.task_id,
      team_id: state.team_id,
      test_command: test_command
    })

    Logger.info("[Verification.Loop] #{loop_id} started — command: #{test_command}")

    # Kick off iteration 1 immediately.
    {:ok, state, {:continue, :run_iteration}}
  end

  @impl true
  def handle_continue(:run_iteration, state) do
    {:noreply, spawn_test_task(state)}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    snapshot = %{
      loop_id: state.loop_id,
      task_id: state.task_id,
      team_id: state.team_id,
      status: state.status,
      iteration: state.iteration,
      confidence: Confidence.to_map(state.confidence),
      started_at: state.started_at
    }

    {:reply, {:ok, snapshot}, state}
  end

  def handle_call({:steer, guidance}, _from, state) do
    Logger.info("[Verification.Loop] #{state.loop_id} received steering guidance")
    {:reply, :ok, %{state | steering_guidance: guidance}}
  end

  @impl true
  def handle_info({ref, {:test_result, exit_code, output}}, state)
      when is_reference(ref) and ref == state.task_ref do
    # Task completed — demonitor to clean up the :DOWN message.
    Process.demonitor(ref, [:flush])
    state = %{state | task_ref: nil}
    state = process_test_result(state, {exit_code, output})
    {:noreply, state}
  end

  # Task crashed unexpectedly — treat as a test failure.
  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when ref == state.task_ref do
    Logger.warning("[Verification.Loop] #{state.loop_id} test task crashed: #{inspect(reason)}")
    state = %{state | task_ref: nil}
    state = process_test_result(state, {1, "Test task crashed: #{inspect(reason)}"})
    {:noreply, state}
  end

  def handle_info(:overall_timeout, %{status: :running} = state) do
    Logger.warning("[Verification.Loop] #{state.loop_id} hit overall timeout (#{state.timeout_ms}ms)")
    state = escalate(state, :timeout)
    {:noreply, state}
  end

  def handle_info(:overall_timeout, state), do: {:noreply, state}

  def handle_info(:schedule_next_iteration, state) do
    {:noreply, spawn_test_task(state)}
  end

  # Stray task messages after normal completion — ignore.
  def handle_info({ref, _}, state) when is_reference(ref), do: {:noreply, state}
  def handle_info(_, state), do: {:noreply, state}

  # --- Core Logic ---

  defp spawn_test_task(state) do
    iteration = state.iteration + 1

    Logger.info("[Verification.Loop] #{state.loop_id} — iteration #{iteration}/#{state.max_iterations}")

    Bus.emit(:system_event, %{
      event: :verification_iteration,
      loop_id: state.loop_id,
      iteration: iteration,
      task_id: state.task_id
    })

    parent = self()
    cmd = state.test_command

    task =
      Task.async(fn ->
        {output, exit_code} =
          try do
            System.cmd("sh", ["-c", cmd], stderr_to_stdout: true)
          rescue
            e -> {"Command error: #{Exception.message(e)}", 1}
          end

        send(parent, {self(), {:test_result, exit_code, output}})
      end)

    %{state | iteration: iteration, task_ref: task.ref}
  end

  defp process_test_result(state, {exit_code, output}) do
    passed = exit_code == 0
    result = if passed, do: :pass, else: :fail
    confidence = Confidence.update(state.confidence, result)

    # Keep a bounded history of the last N results.
    entry = %{
      iteration: state.iteration,
      passed: passed,
      exit_code: exit_code,
      output_tail: String.slice(output, -2000, 2000),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    history =
      [entry | state.results_history]
      |> Enum.take(@result_history_limit)

    state = %{state | confidence: confidence, results_history: history}

    # Checkpoint every N iterations.
    if rem(state.iteration, @checkpoint_every) == 0 do
      Checkpoint.save(state.loop_id, build_checkpoint_map(state))
    end

    if passed do
      Logger.info("[Verification.Loop] #{state.loop_id} PASSED on iteration #{state.iteration}")
      succeed(state)
    else
      if state.iteration >= state.max_iterations do
        Logger.warning("[Verification.Loop] #{state.loop_id} max iterations reached — escalating")
        escalate(state, :max_iterations_reached)
      else
        diagnose_and_fix(state, output)
      end
    end
  end

  defp succeed(state) do
    Checkpoint.save(state.loop_id, build_checkpoint_map(%{state | status: :passed}))

    Bus.emit(:system_event, %{
      event: :verification_passed,
      loop_id: state.loop_id,
      task_id: state.task_id,
      team_id: state.team_id,
      iteration: state.iteration,
      confidence: Confidence.score(state.confidence)
    })

    Logger.info("[Verification.Loop] #{state.loop_id} terminated with :passed")
    %{state | status: :passed}
  end

  defp escalate(state, reason) do
    status = :escalated
    event = if reason == :timeout, do: :verification_escalated, else: :verification_escalated

    Checkpoint.save(state.loop_id, build_checkpoint_map(%{state | status: status}))

    Bus.emit(:system_event, %{
      event: event,
      loop_id: state.loop_id,
      task_id: state.task_id,
      team_id: state.team_id,
      reason: reason,
      iteration: state.iteration,
      confidence: Confidence.score(state.confidence),
      results_history: state.results_history
    })

    Bus.emit_algedonic(:high, "Verification loop #{state.loop_id} escalated: #{reason}",
      source: "verification_loop",
      metadata: %{loop_id: state.loop_id, task_id: state.task_id, reason: reason}
    )

    Logger.warning("[Verification.Loop] #{state.loop_id} escalated (#{reason}) after #{state.iteration} iterations")
    %{state | status: status}
  end

  defp diagnose_and_fix(state, failure_output) do
    case call_llm_for_fix(state, failure_output) do
      {:ok, fix_instructions} ->
        Logger.info("[Verification.Loop] #{state.loop_id} applying fix: #{String.slice(fix_instructions, 0, 200)}")
        apply_fix(fix_instructions)

        Bus.emit(:system_event, %{
          event: :verification_failed,
          loop_id: state.loop_id,
          task_id: state.task_id,
          iteration: state.iteration,
          fix_applied: true,
          confidence: Confidence.score(state.confidence)
        })

        # Clear consumed steering guidance, schedule next iteration.
        state = %{state | steering_guidance: nil}
        Process.send_after(self(), :schedule_next_iteration, 100)
        state

      {:error, reason} ->
        Logger.warning("[Verification.Loop] #{state.loop_id} LLM diagnosis failed: #{inspect(reason)} — retrying without fix")

        Bus.emit(:system_event, %{
          event: :verification_failed,
          loop_id: state.loop_id,
          task_id: state.task_id,
          iteration: state.iteration,
          fix_applied: false,
          confidence: Confidence.score(state.confidence)
        })

        state = %{state | steering_guidance: nil}
        Process.send_after(self(), :schedule_next_iteration, 100)
        state
    end
  end

  defp call_llm_for_fix(state, failure_output) do
    steering_block =
      if state.steering_guidance do
        "\n\nAdditional guidance from operator:\n#{state.steering_guidance}"
      else
        ""
      end

    history_summary =
      state.results_history
      |> Enum.map(fn r ->
        status = if r.passed, do: "PASS", else: "FAIL (exit #{r.exit_code})"
        "Iteration #{r.iteration}: #{status}"
      end)
      |> Enum.join("\n")

    prompt = """
    You are a debugging assistant. A test suite is failing and your job is to
    diagnose the root cause and produce a precise fix.

    ## Test command
    #{state.test_command}

    ## Failure output (latest iteration #{state.iteration})
    #{String.slice(failure_output, -3000, 3000)}

    ## Iteration history
    #{history_summary}

    ## Confidence score
    #{Float.round(Confidence.score(state.confidence), 1)}% (#{Confidence.trend(state.confidence)})
    #{steering_block}

    Respond with a brief diagnosis followed by the EXACT shell commands or code
    changes needed to fix the failure. Be precise — these instructions will be
    applied directly.

    Format:
    DIAGNOSIS: <one-paragraph root cause>
    FIX: <exact commands or diff to apply>
    """

    messages = [%{role: "user", content: prompt}]

    case Providers.chat(messages, temperature: 0.2, max_tokens: 2048) do
      {:ok, %{content: content}} when is_binary(content) and content != "" ->
        {:ok, content}

      {:ok, _} ->
        {:error, "LLM returned empty response"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Apply fix instructions by executing embedded shell commands.
  # Looks for lines prefixed with `$ ` and runs them. When no such lines
  # exist, logs the instructions for a human operator to act on manually.
  defp apply_fix(instructions) do
    commands =
      instructions
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "$ "))
      |> Enum.map(&String.slice(&1, 2, String.length(&1)))

    if commands == [] do
      Logger.info("[Verification.Loop] No shell commands found in fix — human operator must act:\n#{String.slice(instructions, 0, 500)}")
    else
      Enum.each(commands, fn cmd ->
        Logger.info("[Verification.Loop] Applying fix: #{cmd}")

        case System.cmd("sh", ["-c", cmd], stderr_to_stdout: true) do
          {output, 0} ->
            Logger.debug("[Verification.Loop] Fix command succeeded: #{String.slice(output, 0, 200)}")

          {output, code} ->
            Logger.warning("[Verification.Loop] Fix command exited #{code}: #{String.slice(output, 0, 400)}")
        end
      end)
    end
  end

  defp build_checkpoint_map(state) do
    %{
      loop_id: state.loop_id,
      team_id: state.team_id,
      task_id: state.task_id,
      test_command: state.test_command,
      max_iterations: state.max_iterations,
      iteration: state.iteration,
      status: state.status,
      confidence_score: Confidence.score(state.confidence),
      confidence_trend: Confidence.trend(state.confidence),
      results_history: state.results_history,
      started_at: state.started_at
    }
  end

  defp via(loop_id), do: {:via, Registry, {OptimalSystemAgent.SessionRegistry, "vloop:#{loop_id}"}}

  defp generate_loop_id, do: OptimalSystemAgent.Utils.ID.generate("vloop")
end
