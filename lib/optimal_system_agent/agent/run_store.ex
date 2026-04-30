defmodule OptimalSystemAgent.Agent.RunStore do
  @moduledoc """
  Lightweight subagent run index.

  The orchestrator uses this to keep structured status, completion metadata,
  and a sidechain transcript for each subagent. ETS gives live inspection even
  when a run is active; append-only markdown files under `~/.osa/agent-runs`
  keep completed runs inspectable after the process exits.
  """

  require Logger

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
    update(agent_id, fn run -> %{run | tool_count: max(run.tool_count, tool_count)} end)
    append(agent_id, "PROGRESS tools=#{tool_count}\n\n#{action}")
  end

  @doc "Mark a run complete and attach the structured result."
  @spec complete(String.t(), map()) :: :ok
  def complete(agent_id, result) do
    now = DateTime.utc_now()

    update(agent_id, fn run ->
      %{
        run
        | status: Map.get(result, :status, :completed),
          completed_at: now,
          duration_ms: Map.get(result, :duration_ms),
          tool_count: Map.get(result, :tool_count, run.tool_count),
          tokens_used: Map.get(result, :tokens_used, run.tokens_used),
          result: result
      }
    end)

    append(
      agent_id,
      "STOP status=#{Map.get(result, :status, :completed)}\n\n#{format_result(result)}"
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

    duration_ms = Map.get(result, :duration_ms) || 0

    """
    Agent #{Map.get(result, :agent_id, "unknown")} #{Map.get(result, :status, :completed)}

    #{Map.get(result, :summary, "")}

    Files changed: #{files}
    Commands run: #{commands}
    Tools: #{Map.get(result, :tool_count, 0)}
    Tokens: #{Map.get(result, :tokens_used, 0)}
    Duration: #{duration_ms}ms
    Transcript: #{Map.get(result, :transcript_path, "unavailable")}
    """
    |> String.trim()
  end

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
