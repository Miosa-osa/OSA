defmodule OptimalSystemAgent.Agent.RunStore do
  @moduledoc """
  Lightweight subagent run index.

  The orchestrator uses this to keep structured status, completion metadata,
  and a sidechain transcript for each subagent. ETS gives live inspection even
  when a run is active; append-only markdown files under `~/.osa/agent-runs`
  keep completed runs inspectable after the process exits.
  """

  require Logger

  alias OptimalSystemAgent.Agent.RunResult

  @table __MODULE__
  @default_runs_dir Path.expand("~/.osa/agent-runs")

  @type run :: %{
          agent_id: String.t(),
          parent_session_id: String.t(),
          role: String.t(),
          task: String.t(),
          status: :running | :completed | :failed | :cancelled,
          started_at: DateTime.t(),
          completed_at: DateTime.t() | nil,
          last_heartbeat_at: DateTime.t(),
          phase: :queued | :spawning | :running | :waiting | :completed | :failed | :cancelled,
          current_action: String.t() | nil,
          duration_ms: non_neg_integer() | nil,
          tool_count: non_neg_integer(),
          tokens_used: non_neg_integer(),
          result: map() | nil,
          transcript_path: String.t()
        }

  @doc "Start or replace a run record."
  @spec start_run(map()) :: :ok
  def start_run(attrs) do
    ensure_table()

    agent_id = Map.fetch!(attrs, :agent_id)
    started_at = DateTime.utc_now()
    transcript_path = transcript_path(agent_id)

    run =
      %{
        agent_id: agent_id,
        parent_session_id: Map.fetch!(attrs, :parent_session_id),
        role: Map.get(attrs, :role, "agent"),
        task: Map.get(attrs, :task, ""),
        status: :running,
        started_at: started_at,
        completed_at: nil,
        last_heartbeat_at: started_at,
        phase: :spawning,
        current_action: "spawning",
        duration_ms: nil,
        tool_count: 0,
        tokens_used: 0,
        result: nil,
        transcript_path: transcript_path
      }

    :ets.insert(@table, {agent_id, run})
    append(agent_id, "START role=#{run.role} parent=#{run.parent_session_id}\n\n#{run.task}")
  end

  @doc "Record a progress line for a running agent."
  @spec progress(String.t(), String.t(), non_neg_integer()) :: :ok
  def progress(agent_id, action, tool_count \\ 0) do
    now = DateTime.utc_now()

    update(agent_id, fn run ->
      %{
        run
        | phase: :running,
          current_action: action,
          last_heartbeat_at: now,
          tool_count: max(run.tool_count, tool_count)
      }
    end)

    append(agent_id, "PROGRESS tools=#{tool_count}\n\n#{action}")
  end

  @doc "Record a heartbeat without appending noisy transcript output."
  @spec heartbeat(String.t(), String.t() | nil) :: :ok
  def heartbeat(agent_id, action \\ nil) do
    now = DateTime.utc_now()

    update(agent_id, fn run ->
      %{
        run
        | phase: :running,
          current_action: action || run.current_action,
          last_heartbeat_at: now
      }
    end)
  end

  @doc "Mark a run complete and attach the structured result."
  @spec complete(String.t(), map()) :: :ok
  def complete(agent_id, result) do
    now = DateTime.utc_now()
    result = RunResult.new(result)

    update(agent_id, fn run ->
      phase = terminal_phase(result.status)

      %{
        run
        | status: result.status,
          phase: phase,
          current_action: Atom.to_string(phase),
          completed_at: now,
          last_heartbeat_at: now,
          duration_ms: result.duration_ms,
          tool_count: result.tool_count,
          tokens_used: result.tokens_used,
          result: result
      }
    end)

    append(
      agent_id,
      "STOP status=#{result.status}\n\n#{format_result(result)}"
    )
  end

  @doc "Get a run by agent id."
  @spec get(String.t()) :: run() | nil
  def get(agent_id) do
    ensure_table()

    case :ets.lookup(@table, agent_id) do
      [{^agent_id, run}] -> run
      [] -> nil
    end
  end

  @doc "List known runs, newest first."
  @spec list(keyword()) :: [run()]
  def list(opts \\ []) do
    ensure_table()
    limit = Keyword.get(opts, :limit, 20)
    status = Keyword.get(opts, :status)

    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, run} -> run end)
    |> Enum.filter(fn run -> is_nil(status) or run.status == status end)
    |> Enum.sort_by(fn run -> DateTime.to_unix(run.started_at, :millisecond) end, :desc)
    |> Enum.take(limit)
  end

  @doc "Return a transcript as text if it exists."
  @spec transcript(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def transcript(agent_id) do
    path =
      case get(agent_id) do
        %{transcript_path: path} -> path
        nil -> transcript_path(agent_id)
      end

    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, "No transcript found for #{agent_id}"}
      {:error, reason} -> {:error, "Could not read transcript: #{inspect(reason)}"}
    end
  end

  @doc "Format a structured result for legacy string-return callers."
  @spec format_result(map()) :: String.t()
  def format_result(result) do
    result = RunResult.new(result)

    files =
      result
      |> Map.get(:files_changed, [])
      |> case do
        [] -> "none"
        list -> Enum.join(list, ", ")
      end

    commands =
      result
      |> Map.get(:commands_run, [])
      |> case do
        [] -> "none"
        list -> Enum.join(list, "\n")
      end

    inspected = format_list(result.files_inspected)
    findings = format_list(result.findings)
    tests = format_list(result.tests_run)
    blockers = format_list(result.blockers)
    next_actions = format_list(result.next_actions)
    errors = format_list(result.errors)

    """
    Agent #{result.agent_id} #{result.status}

    #{result.summary}

    Files changed: #{files}
    Files inspected: #{inspected}
    Findings: #{findings}
    Commands run: #{commands}
    Tests run: #{tests}
    Blockers: #{blockers}
    Next actions: #{next_actions}
    Errors: #{errors}
    Confidence: #{result.confidence}%
    Tools: #{result.tool_count}
    Tokens: #{result.tokens_used}
    Duration: #{result.duration_ms}ms
    Transcript: #{result.transcript_path}
    """
    |> String.trim()
  end

  defp format_list([]), do: "none"
  defp format_list(list), do: Enum.join(list, "\n")

  defp terminal_phase(:completed), do: :completed
  defp terminal_phase(:failed), do: :failed
  defp terminal_phase(:cancelled), do: :cancelled
  defp terminal_phase(_), do: :failed

  defp update(agent_id, fun) do
    ensure_table()

    case get(agent_id) do
      nil -> :ok
      run -> :ets.insert(@table, {agent_id, fun.(run)})
    end
  end

  defp append(agent_id, body) do
    path = transcript_path(agent_id)
    File.mkdir_p!(Path.dirname(path))

    entry = """

    ## #{DateTime.utc_now() |> DateTime.to_iso8601()}

    #{body}
    """

    File.write(path, entry, [:append])
    :ok
  rescue
    e ->
      Logger.debug("[RunStore] transcript append failed for #{agent_id}: #{Exception.message(e)}")
      :ok
  end

  defp transcript_path(agent_id) do
    safe_id = Regex.replace(~r/[^a-zA-Z0-9_\-]/, agent_id, "_")
    Path.join(runs_dir(), "#{safe_id}.md")
  end

  defp runs_dir do
    Application.get_env(:optimal_system_agent, :agent_runs_dir, @default_runs_dir)
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end
end
