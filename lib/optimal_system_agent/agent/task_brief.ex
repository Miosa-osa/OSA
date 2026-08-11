defmodule OptimalSystemAgent.Agent.TaskBrief do
  @moduledoc """
  Durable, immutable Task Brief — the original instruction / hard constraints of
  a run, captured ONCE at run start and re-injected into context on EVERY turn.

  ## Why this exists (audit gap M1)

  On a long-horizon (hours/days) single-instruction run, the original goal and
  its constraints live only as an ordinary `role: "user"` message. That message
  is fully eligible for `Agent.Compactor` folding — each compaction cycle
  re-compresses the previous summary, compounding loss — so over a days-long run
  the original constraint can be silently forgotten.

  The Task Brief fixes this by capturing `{goal, constraints, acceptance_criteria,
  created_at}` once, storing it on disk next to the session (atomic temp+rename,
  keyed by `session_id`), and having `Agent.Context.build/1` inject it as part of
  the `role: "system"` prompt on every turn. Because it is re-derived from disk
  every turn AND lands in a `role: "system"` block (which `Agent.Compactor`
  preserves verbatim — see `split_system/1`), it can never be compacted away.

  ## Immutability

  `capture/3` writes the brief only the FIRST time a real goal is set for a
  session. Re-issuing `/goal` (or any later `ProgressLedger.set_goal/2`) does not
  overwrite the original brief — the brief is the run's founding instruction, not
  a mutable status field (that role belongs to `ProgressLedger`'s `## Goal`).

  Normal short chats never set a goal, so no brief file exists and
  `context_block/1` injects nothing.
  """

  require Logger

  alias OptimalSystemAgent.ConfigFile
  alias OptimalSystemAgent.System.AtomicFile

  @cache :osa_task_brief_cache
  @placeholder "_Not set._"

  @type t :: %{
          goal: String.t(),
          constraints: String.t(),
          acceptance_criteria: String.t(),
          created_at: String.t()
        }

  # Runtime-resolved so a prebuilt release uses the END USER's home, not the CI
  # runner's baked-in path. Resolved on every call via ConfigFile.config_dir/0.
  defp sessions_dir, do: Path.join(ConfigFile.config_dir(), "sessions")

  @doc "Absolute path to a session's durable task-brief file."
  @spec path(String.t()) :: String.t()
  def path(session_id) when is_binary(session_id) do
    Path.join(sessions_dir(), "#{safe_id(session_id)}.brief.json")
  end

  @doc """
  Capture the task brief for a session ONCE (immutable).

  Writes the brief only when none exists yet and `goal` is a real, non-empty,
  non-placeholder instruction. `opts` may carry `:constraints` and
  `:acceptance_criteria`; when absent they fall back to the goal text so the
  brief is always self-describing even before structured constraints exist.

  Best-effort: never raises. Returns `{:ok, brief}` (new or pre-existing), or
  `{:error, reason}`.
  """
  @spec capture(String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def capture(session_id, goal, opts \\ [])

  def capture(session_id, goal, opts) when is_binary(session_id) and is_binary(goal) do
    trimmed = String.trim(goal)

    cond do
      trimmed == "" or trimmed == @placeholder ->
        {:error, :empty_goal}

      exists?(session_id) ->
        # Immutable: the first real goal is the founding brief; never clobber it.
        load(session_id)

      true ->
        brief = %{
          goal: trimmed,
          constraints: opt_text(opts, :constraints, trimmed),
          acceptance_criteria: opt_text(opts, :acceptance_criteria, trimmed),
          created_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        case save(session_id, brief) do
          :ok -> {:ok, brief}
          err -> err
        end
    end
  end

  def capture(_session_id, _goal, _opts), do: {:error, :invalid_args}

  @doc """
  Load the task brief for a session. Cached (ETS) for the per-turn hot path;
  the cache is invalidated whenever `save/2` writes a new brief.

  Returns `{:ok, brief}` or `{:error, :not_found}`.
  """
  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(session_id) when is_binary(session_id) do
    case cache_get(session_id) do
      {:hit, :none} ->
        {:error, :not_found}

      {:hit, brief} ->
        {:ok, brief}

      :miss ->
        result = read_from_disk(session_id)
        cache_put(session_id, elem_or_none(result))
        result
    end
  end

  def load(_), do: {:error, :not_found}

  @doc """
  Build the `role: "system"` task-brief block for injection into `Context.build`,
  or `nil` when no brief exists (normal short chats inject nothing).
  """
  @spec context_block(String.t()) :: String.t() | nil
  def context_block(session_id) when is_binary(session_id) do
    case load(session_id) do
      {:ok, brief} -> render(brief)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def context_block(_), do: nil

  @doc "True when a brief file already exists for the session."
  @spec exists?(String.t()) :: boolean()
  def exists?(session_id) when is_binary(session_id) do
    case cache_get(session_id) do
      {:hit, :none} -> false
      {:hit, _brief} -> true
      :miss -> File.exists?(path(session_id))
    end
  end

  def exists?(_), do: false

  @doc """
  Atomically persist a brief (temp-file + rename), mirroring
  `SessionPersistence`'s crash-safe write. Refreshes the cache. Best-effort.
  """
  @spec save(String.t(), t()) :: :ok | {:error, term()}
  def save(session_id, brief) when is_binary(session_id) and is_map(brief) do
    File.mkdir_p!(sessions_dir())
    file = path(session_id)

    case Jason.encode(stringify(brief)) do
      {:ok, json} ->
        AtomicFile.write!(file, json)
        cache_put(session_id, brief)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("[task_brief] save failed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp render(%{goal: goal} = brief) do
    constraints = Map.get(brief, :constraints, "")
    acceptance = Map.get(brief, :acceptance_criteria, "")

    lines =
      ["## TASK BRIEF (do not lose sight of this)", "", "Goal: #{goal}"]
      |> maybe_line("Constraints", constraints, goal)
      |> maybe_line("Acceptance criteria", acceptance, goal)

    (lines ++
       [
         "",
         "This is the ORIGINAL instruction for this run, preserved verbatim. Keep it " <>
           "in view across every step and do not drift from it, even after long work " <>
           "or context compaction."
       ])
    |> Enum.join("\n")
  end

  defp render(_), do: nil

  # Append a labeled line only when the value is meaningful and not a duplicate
  # of the goal (avoids "Constraints: <same as goal>" noise when unstructured).
  defp maybe_line(lines, label, value, goal) do
    v = String.trim(to_string(value))

    if v != "" and v != @placeholder and v != String.trim(goal) do
      lines ++ ["#{label}: #{v}"]
    else
      lines
    end
  end

  defp read_from_disk(session_id) do
    case File.read(path(session_id)) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, data} when is_map(data) ->
            {:ok,
             %{
               goal: data["goal"] || "",
               constraints: data["constraints"] || "",
               acceptance_criteria: data["acceptance_criteria"] || "",
               created_at: data["created_at"] || ""
             }}

          _ ->
            {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  defp opt_text(opts, key, fallback) do
    case Keyword.get(opts, key) do
      v when is_binary(v) and v != "" -> String.trim(v)
      _ -> fallback
    end
  end

  defp stringify(brief) do
    Map.new(brief, fn {k, v} -> {to_string(k), v} end)
  end

  defp elem_or_none({:ok, brief}), do: brief
  defp elem_or_none(_), do: :none

  # ── ETS cache ────────────────────────────────────────────────────────────

  defp cache_get(session_id) do
    ensure_cache()

    case :ets.lookup(@cache, session_id) do
      [{^session_id, value}] -> {:hit, value}
      [] -> :miss
    end
  rescue
    _ -> :miss
  end

  defp cache_put(session_id, value) do
    ensure_cache()
    :ets.insert(@cache, {session_id, value})
    :ok
  rescue
    _ -> :ok
  end

  defp ensure_cache do
    case :ets.whereis(@cache) do
      :undefined ->
        :ets.new(@cache, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @spec safe_id(String.t()) :: String.t()
  defp safe_id(session_id) do
    Regex.replace(~r/[^a-zA-Z0-9_\-]/, session_id, "_")
  end
end
