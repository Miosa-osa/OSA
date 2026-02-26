defmodule OptimalSystemAgent.Agent.Scheduler do
  @moduledoc """
  Periodic task scheduler with HEARTBEAT.md support.

  Checks `~/.osa/HEARTBEAT.md` every 30 minutes. If the file contains
  tasks (markdown checklist items), the agent executes them through the
  standard Agent.Loop pipeline and marks them as completed.

  Tasks are written as markdown checklists:

      ## Periodic Tasks
      - [ ] Check weather forecast and send a summary
      - [ ] Scan inbox for urgent emails

  Completed tasks are marked:
      - [x] Check weather forecast and send a summary (completed 2026-02-24T10:30:00Z)

  The agent can also manage this file itself — ask it to
  "add a periodic task" and it will update HEARTBEAT.md.

  Circuit breaker: auto-disables a task after 3 consecutive failures.
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Events.Bus

  @heartbeat_interval Application.compile_env(
                        :optimal_system_agent,
                        :heartbeat_interval,
                        30 * 60 * 1000
                      )

  @config_dir Application.compile_env(:optimal_system_agent, :config_dir, "~/.osa")

  defstruct failures: %{}, last_run: nil

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  end

  @doc "Trigger a heartbeat check manually."
  def heartbeat do
    GenServer.cast(__MODULE__, :heartbeat)
  end

  @doc "Get the path to the HEARTBEAT.md file."
  def heartbeat_path do
    Path.expand(Path.join(@config_dir, "HEARTBEAT.md"))
  end

  @impl true
  def init(state) do
    ensure_heartbeat_file()
    schedule_heartbeat()
    Logger.info("Scheduler started — heartbeat every #{div(@heartbeat_interval, 60_000)} min")
    {:ok, state}
  end

  @impl true
  def handle_cast(:heartbeat, state) do
    state = run_heartbeat(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    state = run_heartbeat(state)
    schedule_heartbeat()
    {:noreply, state}
  end

  # ── Heartbeat Execution ─────────────────────────────────────────────

  defp run_heartbeat(state) do
    path = heartbeat_path()

    if File.exists?(path) do
      content = File.read!(path)
      tasks = parse_pending_tasks(content)

      if tasks == [] do
        Logger.debug("Heartbeat: no pending tasks")
        %{state | last_run: DateTime.utc_now()}
      else
        Logger.info("Heartbeat: #{length(tasks)} pending task(s)")

        Bus.emit(:system_event, %{
          event: :heartbeat_started,
          task_count: length(tasks)
        })

        {completed, state} =
          Enum.reduce(tasks, {[], state}, fn task, {done, acc} ->
            failures = Map.get(acc.failures, task, 0)

            if failures >= 3 do
              Logger.warning("Heartbeat: skipping '#{task}' — circuit breaker open (#{failures} failures)")
              {done, acc}
            else
              case execute_task(task) do
                {:ok, _result} ->
                  Logger.info("Heartbeat: completed '#{task}'")
                  {[task | done], %{acc | failures: Map.delete(acc.failures, task)}}

                {:error, reason} ->
                  Logger.warning("Heartbeat: failed '#{task}' — #{reason}")
                  {done, %{acc | failures: Map.put(acc.failures, task, failures + 1)}}
              end
            end
          end)

        # Update HEARTBEAT.md — mark completed tasks
        if completed != [] do
          updated = mark_completed(content, completed)
          File.write!(path, updated)
        end

        Bus.emit(:system_event, %{
          event: :heartbeat_completed,
          completed: length(completed),
          total: length(tasks)
        })

        %{state | last_run: DateTime.utc_now()}
      end
    else
      %{state | last_run: DateTime.utc_now()}
    end
  end

  defp execute_task(task_description) do
    session_id = "heartbeat_#{System.system_time(:second)}"

    # Start a temporary agent loop for this heartbeat task
    case DynamicSupervisor.start_child(
           OptimalSystemAgent.Channels.Supervisor,
           {Loop, session_id: session_id, channel: :heartbeat}
         ) do
      {:ok, _pid} ->
        result = Loop.process_message(session_id, task_description)

        # Clean up the temporary loop
        case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
          [{pid, _}] -> GenServer.stop(pid, :normal)
          _ -> :ok
        end

        case result do
          {:ok, response} -> {:ok, response}
          {:filtered, _signal} -> {:ok, "filtered"}
          {:error, reason} -> {:error, to_string(reason)}
        end

      {:error, reason} ->
        {:error, "Failed to start agent loop: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ── HEARTBEAT.md Parsing ────────────────────────────────────────────

  defp parse_pending_tasks(content) do
    # Strip HTML comments before parsing — example tasks shouldn't trigger
    stripped =
      content
      |> String.replace(~r/<!--[\s\S]*?-->/, "")

    stripped
    |> String.split("\n")
    |> Enum.filter(fn line ->
      String.match?(line, ~r/^\s*-\s*\[\s*\]\s*.+/)
    end)
    |> Enum.map(fn line ->
      line
      |> String.replace(~r/^\s*-\s*\[\s*\]\s*/, "")
      |> String.trim()
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp mark_completed(content, completed_tasks) do
    Enum.reduce(completed_tasks, content, fn task, acc ->
      timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
      pattern = ~r/(-\s*)\[\s*\](\s*#{Regex.escape(task)})/
      replacement = "\\1[x]\\2 (completed #{timestamp})"
      String.replace(acc, pattern, replacement, global: false)
    end)
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp ensure_heartbeat_file do
    path = heartbeat_path()
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    unless File.exists?(path) do
      File.write!(path, """
      # Heartbeat Tasks

      Add tasks here as a markdown checklist. OSA checks this file every #{div(@heartbeat_interval, 60_000)} minutes
      and executes any unchecked items through the agent loop.

      ## Periodic Tasks

      <!-- Example tasks (uncomment to activate):
      - [ ] Check for new emails and summarize urgent ones
      - [ ] Review today's calendar and prepare a briefing
      -->
      """)
    end
  end

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
  end
end
