defmodule OptimalSystemAgent.Intelligence.ProactiveMonitor do
  @moduledoc """
  Scans for actionable patterns every N minutes and emits alerts.
  This is what makes OSA proactive instead of reactive.

  Scan categories:
  - Stale sessions: sessions inactive for > 24 hours
  - Unanswered questions: messages ending with ? that received no follow-up
  - Failed tasks: cron/heartbeat tasks that tripped the circuit breaker
  - System health: memory file size, disk space
  - Follow-up reminders: "remind me", "follow up", "later" patterns

  Alerts are stored in the process state (capped at 50) and emitted on the
  event bus so other subsystems can react.

  Signal Theory — autonomous pattern detection and intervention.
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Agent.Memory

  @interval Application.compile_env(:optimal_system_agent, :proactive_interval, 30 * 60 * 1000)

  # Max alerts held in memory at one time
  @max_alerts 50

  # Session considered stale after this many seconds without activity
  @stale_session_seconds 24 * 60 * 60

  # Memory file size threshold (bytes) before we emit a health alert
  @memory_size_threshold 10 * 1024 * 1024

  defstruct [
    alerts: [],
    last_scan: nil,
    scan_count: 0
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)

  @doc "Get current alerts."
  def alerts do
    GenServer.call(__MODULE__, :alerts)
  end

  @doc "Force an immediate scan."
  def scan_now do
    GenServer.cast(__MODULE__, :scan_now)
  end

  @doc "Dismiss an alert by index (0-based)."
  def dismiss(index) when is_integer(index) do
    GenServer.call(__MODULE__, {:dismiss, index})
  end

  @doc "Get scan statistics."
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    schedule_scan()
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_info(:scan, state) do
    alerts = run_scan()

    if alerts != [] do
      Logger.info("[ProactiveMonitor] #{length(alerts)} alert(s) detected")
      Bus.emit(:system_event, %{event: :proactive_alerts, count: length(alerts), alerts: alerts})
    end

    schedule_scan()

    new_alerts =
      (alerts ++ state.alerts)
      |> Enum.take(@max_alerts)

    {:noreply, %{state |
      alerts:     new_alerts,
      last_scan:  DateTime.utc_now(),
      scan_count: state.scan_count + 1
    }}
  end

  @impl true
  def handle_call(:alerts, _from, state) do
    {:reply, state.alerts, state}
  end

  @impl true
  def handle_call({:dismiss, index}, _from, state) do
    new_alerts =
      state.alerts
      |> Enum.with_index()
      |> Enum.reject(fn {_alert, i} -> i == index end)
      |> Enum.map(fn {alert, _i} -> alert end)

    {:reply, :ok, %{state | alerts: new_alerts}}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    result = %{
      scan_count:  state.scan_count,
      alert_count: length(state.alerts),
      last_scan:   state.last_scan
    }

    {:reply, result, state}
  end

  @impl true
  def handle_cast(:scan_now, state) do
    alerts = run_scan()

    if alerts != [] do
      Logger.info("[ProactiveMonitor] Manual scan: #{length(alerts)} alert(s) detected")
      Bus.emit(:system_event, %{event: :proactive_alerts, count: length(alerts), alerts: alerts})
    end

    new_alerts =
      (alerts ++ state.alerts)
      |> Enum.take(@max_alerts)

    {:noreply, %{state |
      alerts:     new_alerts,
      last_scan:  DateTime.utc_now(),
      scan_count: state.scan_count + 1
    }}
  end

  # ---------------------------------------------------------------------------
  # Scan orchestrator
  # ---------------------------------------------------------------------------

  defp run_scan do
    scanners = [
      &scan_stale_sessions/0,
      &scan_unanswered_questions/0,
      &scan_failed_tasks/0,
      &scan_system_health/0,
      &scan_follow_up_reminders/0
    ]

    scanners
    |> Enum.flat_map(fn scanner ->
      try do
        scanner.()
      rescue
        e ->
          Logger.debug("[ProactiveMonitor] scanner error: #{Exception.message(e)}")
          []
      end
    end)
    |> Enum.take(@max_alerts)
  end

  # ---------------------------------------------------------------------------
  # Scanner: Stale Sessions
  # ---------------------------------------------------------------------------

  defp scan_stale_sessions do
    sessions_dir = Path.expand(
      Application.get_env(:optimal_system_agent, :sessions_dir, "~/.osa/sessions")
    )

    if File.exists?(sessions_dir) do
      now = DateTime.utc_now()

      sessions_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
      |> Enum.flat_map(fn filename ->
        path = Path.join(sessions_dir, filename)
        session_id = String.trim_trailing(filename, ".jsonl")

        try do
          stat = File.stat!(path, time: :posix)
          last_modified = DateTime.from_unix!(stat.mtime)
          seconds_inactive = DateTime.diff(now, last_modified, :second)
          hours_inactive = div(seconds_inactive, 3600)

          if seconds_inactive > @stale_session_seconds do
            topic = extract_last_topic(path)

            [%{
              type:        :stale_session,
              severity:    :info,
              message:     "Session #{session_id} has been inactive for #{hours_inactive} hours. Last topic: #{topic}",
              detected_at: now,
              metadata:    %{session_id: session_id, hours_inactive: hours_inactive, topic: topic}
            }]
          else
            []
          end
        rescue
          _ -> []
        end
      end)
    else
      []
    end
  end

  # Read the last line of a JSONL session file and extract a topic hint
  defp extract_last_topic(path) do
    path
    |> File.stream!()
    |> Enum.reduce(nil, fn line, _acc -> line end)
    |> then(fn last_line ->
      if last_line do
        case Jason.decode(last_line) do
          {:ok, %{"content" => content}} when is_binary(content) ->
            content |> String.slice(0, 80) |> String.trim()
          _ ->
            "unknown"
        end
      else
        "unknown"
      end
    end)
  rescue
    _ -> "unknown"
  end

  # ---------------------------------------------------------------------------
  # Scanner: Unanswered Questions
  # ---------------------------------------------------------------------------

  defp scan_unanswered_questions do
    memory_content = safe_recall()
    now = DateTime.utc_now()

    memory_content
    |> String.split("\n")
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [line_a, line_b] ->
      # A question is a line ending with "?" that is NOT immediately followed
      # by a non-empty response line. This is a heuristic for MEMORY.md content.
      trimmed_a = String.trim(line_a)
      trimmed_b = String.trim(line_b)

      if String.ends_with?(trimmed_a, "?") and
         trimmed_b == "" and
         String.length(trimmed_a) > 10 do

        preview = String.slice(trimmed_a, 0, 100)

        [%{
          type:        :unanswered_question,
          severity:    :warning,
          message:     "Question may be unanswered: #{preview}",
          detected_at: now,
          metadata:    %{question_preview: preview}
        }]
      else
        []
      end
    end)
    |> Enum.take(5)
  end

  # ---------------------------------------------------------------------------
  # Scanner: Failed Tasks
  # ---------------------------------------------------------------------------

  defp scan_failed_tasks do
    now = DateTime.utc_now()

    # Use try/catch so we never block the scan if Scheduler is unavailable
    jobs =
      try do
        OptimalSystemAgent.Agent.Scheduler.list_jobs()
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    Enum.flat_map(jobs, fn job ->
      failures     = job["failure_count"] || 0
      circuit_open = job["circuit_open"] || false

      if failures > 0 do
        severity   = if circuit_open, do: :critical, else: :warning
        status_str = if circuit_open, do: "OPEN (task disabled)", else: "closed"

        [%{
          type:        :failed_task,
          severity:    severity,
          message:     "Task '#{job["name"] || job["id"]}' has failed #{failures} time(s). Circuit breaker #{status_str}",
          detected_at: now,
          metadata:    %{
            job_id:        job["id"],
            job_name:      job["name"],
            failure_count: failures,
            circuit_open:  circuit_open
          }
        }]
      else
        []
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Scanner: System Health
  # ---------------------------------------------------------------------------

  defp scan_system_health do
    check_memory_file_size(DateTime.utc_now()) ++ check_disk_space(DateTime.utc_now())
  end

  defp check_memory_file_size(now) do
    memory_file = Path.expand("~/.osa/MEMORY.md")

    if File.exists?(memory_file) do
      case File.stat(memory_file) do
        {:ok, %{size: size}} when size > @memory_size_threshold ->
          size_mb = Float.round(size / (1024 * 1024), 1)

          [%{
            type:        :system_health,
            severity:    :warning,
            message:     "Memory file exceeds 10MB (#{size_mb}MB) — consider archiving old sessions",
            detected_at: now,
            metadata:    %{file: memory_file, size_bytes: size, size_mb: size_mb}
          }]

        _ ->
          []
      end
    else
      []
    end
  end

  defp check_disk_space(now) do
    osa_dir = Path.expand("~/.osa")

    try do
      {output, 0} = System.cmd("df", ["-k", osa_dir], stderr_to_stdout: true)

      # Parse the `df` output — we want the "Use%" column (5th field on macOS/Linux)
      output
      |> String.split("\n")
      |> Enum.drop(1)
      |> Enum.flat_map(fn line ->
        parts = String.split(line, ~r/\s+/, trim: true)

        case parts do
          [_filesystem, _blocks, _used, _available, use_pct | _] ->
            pct_str = String.trim_trailing(use_pct, "%")

            case Integer.parse(pct_str) do
              {pct, ""} when pct >= 90 ->
                [%{
                  type:        :system_health,
                  severity:    :critical,
                  message:     "Disk is #{pct}% full — OSA storage may fail soon",
                  detected_at: now,
                  metadata:    %{use_percent: pct}
                }]

              {pct, ""} when pct >= 80 ->
                [%{
                  type:        :system_health,
                  severity:    :warning,
                  message:     "Disk is #{pct}% full — consider freeing space",
                  detected_at: now,
                  metadata:    %{use_percent: pct}
                }]

              _ ->
                []
            end

          _ ->
            []
        end
      end)
    rescue
      _ -> []
    catch
      _ -> []
    end
  end

  # ---------------------------------------------------------------------------
  # Scanner: Follow-up Reminders
  # ---------------------------------------------------------------------------

  @reminder_patterns [
    ~r/\bremind\s+me\b/i,
    ~r/\bfollow[- ]?up\b/i,
    ~r/\blater\b/i,
    ~r/\btomorrow\b/i,
    ~r/\bnext\s+week\b/i,
    ~r/\bdon'?t\s+forget\b/i,
    ~r/\bcheck\s+back\b/i
  ]

  defp scan_follow_up_reminders do
    memory_content = safe_recall()
    now = DateTime.utc_now()

    memory_content
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      trimmed = String.trim(line)

      if String.length(trimmed) > 5 and
         Enum.any?(@reminder_patterns, &Regex.match?(&1, trimmed)) do

        preview = String.slice(trimmed, 0, 100)

        [%{
          type:        :follow_up,
          severity:    :info,
          message:     "Potential follow-up needed: #{preview}",
          detected_at: now,
          metadata:    %{preview: preview}
        }]
      else
        []
      end
    end)
    |> Enum.take(5)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Wraps Memory.recall/0 with a graceful fallback so a missing or crashed
  # Memory process never takes down the scanner.
  defp safe_recall do
    try do
      Memory.recall()
    rescue
      _ -> ""
    catch
      :exit, _ -> ""
    end
  end

  defp schedule_scan, do: Process.send_after(self(), :scan, @interval)
end
