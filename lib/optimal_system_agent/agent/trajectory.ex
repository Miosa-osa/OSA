defmodule OptimalSystemAgent.Agent.Trajectory do
  @moduledoc """
  Per-turn trajectory recording for debugging, replay, and training.

  Each LLM round-trip is captured as a JSONL entry appended to
  `~/.osa/trajectories/{session_id}.jsonl`. Entries include:

    * timestamp
    * session_id
    * model
    * input_tokens / output_tokens / cache stats
    * cost_usd (this round-trip)
    * tool_calls (names + arguments, truncated)
    * tool_results (truncated)
    * assistant_response (truncated)
    * context_utilization (at time of call)
    * compaction_events (if any fired this round-trip)

  ## Configuration

      # config/config.exs
      config :optimal_system_agent, :trajectory_recording, true

      # ~/.osa/config.toml
      [trajectory]
      enabled = true
      max_field_chars = 2000

  Disabled by default. Enable via config to start recording.

  ## Usage

  The recording hook is called from `Loop.Accounting.record/2` — operators
  don't call it directly. To read trajectories:

      Trajectory.read(session_id)       # → [entry, ...]
      Trajectory.list_sessions()        # → [session_id, ...]
      Trajectory.session_path(session_id)  # → path string
  """

  require Logger

  alias OptimalSystemAgent.ConfigFile

  @trajectory_dir "trajectories"
  @default_max_field_chars 2_000

  @type entry :: %{
          timestamp: String.t(),
          session_id: String.t(),
          model: String.t(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_creation_tokens: non_neg_integer(),
          cache_read_tokens: non_neg_integer(),
          cost_usd: float(),
          tool_calls: [map()],
          tool_results: [String.t()],
          assistant_response: String.t(),
          context_utilization: float(),
          compaction_events: [map()]
        }

  @doc "Is trajectory recording enabled?"
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:optimal_system_agent, :trajectory_recording, false) or
      toml_enabled?()
  end

  defp toml_enabled? do
    try do
      case ConfigFile.get(["trajectory", "enabled"]) do
        v when is_boolean(v) -> v
        _ -> false
      end
    rescue
      _ -> false
    end
  end

  @doc "Max chars to store per field (tool args, results, responses)."
  @spec max_field_chars() :: pos_integer()
  def max_field_chars do
    Application.get_env(:optimal_system_agent, :trajectory_max_field_chars) ||
      toml_max_chars() ||
      @default_max_field_chars
  end

  defp toml_max_chars do
    try do
      case ConfigFile.get(["trajectory", "max_field_chars"]) do
        n when is_integer(n) and n > 0 -> n
        _ -> nil
      end
    rescue
      _ -> nil
    end
  end

  @doc "Directory where trajectory files are stored."
  @spec dir() :: String.t()
  def dir do
    Path.join(ConfigFile.config_dir(), @trajectory_dir)
  end

  @doc "Full path for a session's trajectory file."
  @spec session_path(String.t()) :: String.t()
  def session_path(session_id) do
    safe_id = sanitize_session_id(session_id)
    Path.join(dir(), "#{safe_id}.jsonl")
  end

  @doc """
  Record a single LLM round-trip as a JSONL entry.

  Called from `Loop.Accounting.record/2` after each provider response.
  Best-effort — a write failure is logged and swallowed, never propagated.
  """
  @spec record(map()) :: :ok | {:error, term()}
  def record(%{session_id: session_id} = entry) when is_binary(session_id) do
    # `unless enabled?(), do: :ok` does NOT return early — Elixir has no early
    # return, so the expression was evaluated, discarded, and the write ran
    # unconditionally. Trajectory recording is documented as opt-in and writes
    # raw conversation content to disk, so the guard has to actually branch.
    if enabled?() do
      do_record(session_id, entry)
    else
      :ok
    end
  end

  def record(_), do: :ok

  defp do_record(session_id, entry) do
    path = session_path(session_id)

    try do
      File.mkdir_p(Path.dirname(path))

      line = encode_entry(entry)
      :ok = File.write(path, line <> "\n", [:append, :utf8])
      :ok
    rescue
      e ->
        Logger.warning("Trajectory.record failed: #{Exception.message(e)}")
        {:error, Exception.message(e)}
    catch
      kind, reason ->
        Logger.warning("Trajectory.record caught #{kind}: #{inspect(reason)}")
        {:error, {kind, reason}}
    end
  end

  @doc "Read all trajectory entries for a session."
  @spec read(String.t()) :: [map()]
  def read(session_id) do
    path = session_path(session_id)

    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode/1)
        |> Enum.filter(fn
          {:ok, _} -> true
          _ -> false
        end)
        |> Enum.map(&elem(&1, 1))

      {:error, _} ->
        []
    end
  end

  @doc "List all session IDs that have trajectory files."
  @spec list_sessions() :: [String.t()]
  def list_sessions do
    case File.ls(dir()) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(&String.replace_trailing(&1, ".jsonl", ""))

      {:error, _} ->
        []
    end
  end

  @doc "Delete trajectory files older than `max_age_days`."
  @spec prune(pos_integer()) :: non_neg_integer()
  def prune(max_age_days) do
    cutoff = DateTime.utc_now() |> DateTime.add(-max_age_days, :day)

    case File.ls(dir()) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.count(fn file ->
          path = Path.join(dir(), file)

          case File.stat(path) do
            {:ok, %{mtime: mtime}} ->
              mtime_dt = DateTime.from_naive!(NaiveDateTime.from_erl!(mtime), "Etc/UTC")

              if DateTime.compare(mtime_dt, cutoff) == :lt do
                File.rm(path)
                true
              else
                false
              end

            _ ->
              false
          end
        end)

      {:error, _} ->
        0
    end
  end

  # --- Private ---

  defp encode_entry(entry) do
    %{
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "session_id" => Map.get(entry, :session_id, ""),
      "model" => Map.get(entry, :model, ""),
      "input_tokens" => Map.get(entry, :input_tokens, 0),
      "output_tokens" => Map.get(entry, :output_tokens, 0),
      "cache_creation_tokens" => Map.get(entry, :cache_creation_tokens, 0),
      "cache_read_tokens" => Map.get(entry, :cache_read_tokens, 0),
      "cost_usd" => Map.get(entry, :cost_usd, 0.0),
      "tool_calls" => truncate_tool_calls(Map.get(entry, :tool_calls, [])),
      "tool_results" => truncate_list(Map.get(entry, :tool_results, [])),
      "assistant_response" => truncate(Map.get(entry, :assistant_response, "")),
      "context_utilization" => Map.get(entry, :context_utilization, 0.0),
      "compaction_events" => Map.get(entry, :compaction_events, [])
    }
    |> Jason.encode!()
  end

  defp truncate(nil), do: ""

  defp truncate(s) when is_binary(s) do
    max = max_field_chars()

    if byte_size(s) > max do
      binary_part(s, 0, max) <> "…[truncated]"
    else
      s
    end
  end

  defp truncate(v), do: truncate(to_string(v))

  defp truncate_list(list) when is_list(list) do
    Enum.map(list, &truncate/1)
  end

  defp truncate_list(_), do: []

  defp truncate_tool_calls(calls) when is_list(calls) do
    Enum.map(calls, fn call ->
      %{
        "name" => Map.get(call, :name, Map.get(call, "name", "")),
        "arguments" => truncate(Map.get(call, :arguments, Map.get(call, "arguments", "")))
      }
    end)
  end

  defp truncate_tool_calls(_), do: []

  defp sanitize_session_id(id) when is_binary(id) do
    id
    |> String.replace(~r/[^a-zA-Z0-9_\-]/, "_")
    |> String.slice(0, 100)
  end

  defp sanitize_session_id(_), do: "unknown"
end
