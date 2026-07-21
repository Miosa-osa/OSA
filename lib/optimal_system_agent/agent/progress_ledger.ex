defmodule OptimalSystemAgent.Agent.ProgressLedger do
  @moduledoc """
  Per-session progress ledger — a durable, human-readable markdown file that the
  agent updates every step and that survives every context reset.

  Motivation (Anthropic context-engineering research): for long / multi-day
  runs the model's context window is repeatedly summarised, compacted, and
  recovered (see `Agent.Loop.ContextCollapse`). Anything held only in-context is
  eventually lost. An **external file the agent appends to every step** becomes
  the coherence anchor: on any reset the agent can re-read the ledger head and
  recover its goal, its decisions, and its open todos.

  This module is the storage primitive. It intentionally mirrors
  `Agent.SessionPersistence` (same `~/.osa/sessions/` directory, same safe-id
  scheme) so a session's full-state JSON and its progress ledger live
  side-by-side:

      ~/.osa/sessions/<safe_id>.json         # full message state (resume)
      ~/.osa/sessions/<safe_id>.progress.md  # progress ledger (this module)

  ## File layout

      # Progress Ledger

      - **Session:** <session_id>
      - **Created:** <iso8601>

      ## Goal

      <goal text, or "_Not set._">

      ## Log

      - [<iso8601>] first entry
      - [<iso8601>] second entry
      ...

  The `## Goal` section is always first and the `## Log` section is always last,
  so `append_entry/2` is a cheap file-append and `set_goal/2` is a bounded
  section replacement.

  All writes emit a `:system_event` on the event bus (event `:progress_ledger`)
  for the TUI / learning engine, mirroring `Agent.Scratchpad`.
  """

  require Logger

  alias OptimalSystemAgent.ConfigFile
  alias OptimalSystemAgent.Events.Bus

  # Runtime-resolved so a prebuilt release uses the END USER's home, not the CI
  # runner's baked-in path. Resolved on every call via ConfigFile.config_dir/0.
  defp sessions_dir, do: Path.join(ConfigFile.config_dir(), "sessions")

  # Number of most-recent log entries surfaced by `summarize/1`. Keeps the
  # injected context bounded regardless of ledger length.
  @summary_entries 10

  @goal_placeholder "_Not set._"

  # Matches the body of the "## Goal" section: everything between the "## Goal"
  # heading and the following "## Log" heading. Dotall so the body may span
  # multiple lines.
  @goal_section ~r/(## Goal\n\n)(.*?)(\n\n## Log)/s

  @type result :: {:ok, String.t()} | {:error, term()}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Absolute path to a session's progress ledger.

  Uses the same safe-id scheme as `Agent.SessionPersistence` so the ledger sits
  next to the session's `<safe_id>.json`.
  """
  @spec path(String.t()) :: String.t()
  def path(session_id) when is_binary(session_id) do
    Path.join(sessions_dir(), "#{safe_id(session_id)}.progress.md")
  end

  @doc """
  Read the full ledger for a session.

  Returns `{:ok, contents}`, or `{:error, :not_found}` if no ledger exists yet.
  """
  @spec read(String.t()) :: result()
  def read(session_id) when is_binary(session_id) do
    case File.read(path(session_id)) do
      {:ok, contents} -> {:ok, contents}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Append a timestamped bullet to the `## Log` section.

  The ledger is created (with scaffold) if it does not exist yet. Multi-line
  entries are indented so they remain part of the same markdown bullet.

  Returns `{:ok, entry_line}` on success.
  """
  @spec append_entry(String.t(), String.t()) :: result()
  def append_entry(session_id, entry)
      when is_binary(session_id) and is_binary(entry) do
    trimmed = String.trim(entry)

    if trimmed == "" do
      {:error, :empty_entry}
    else
      with :ok <- ensure_file(session_id) do
        line = format_bullet(trimmed)

        case File.write(path(session_id), line, [:append]) do
          :ok ->
            emit(session_id, :entry_appended, %{entry: trimmed})
            Logger.debug("[progress_ledger] appended entry for #{session_id}")
            {:ok, line}

          {:error, reason} ->
            Logger.warning("[progress_ledger] append failed: #{inspect(reason)}")
            {:error, reason}
        end
      end
    end
  rescue
    e ->
      Logger.warning("[progress_ledger] append raised: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @doc """
  Set (or replace) the ledger's `## Goal` section.

  The ledger is created if it does not exist yet. Passing an empty string resets
  the goal to the placeholder.

  Returns `{:ok, goal}` on success.
  """
  @spec set_goal(String.t(), String.t()) :: result()
  def set_goal(session_id, goal)
      when is_binary(session_id) and is_binary(goal) do
    with :ok <- ensure_file(session_id),
         {:ok, contents} <- read(session_id) do
      body = normalize_goal(goal)

      updated =
        Regex.replace(@goal_section, contents, fn _full, head, _old, tail ->
          "#{head}#{body}#{tail}"
        end)

      case atomic_write(path(session_id), updated) do
        :ok ->
          # Capture the durable, immutable Task Brief once, at the moment the run's
          # first real goal is set (audit gap M1). Every goal-set path funnels
          # through here (progress_note tool, GoalTracker.start/2, memory
          # coordinator, /goal), so this single chokepoint covers them all.
          # `capture/3` is a no-op once a brief exists and ignores the placeholder,
          # so re-issuing /goal never clobbers the founding brief. Best-effort.
          maybe_capture_brief(session_id, body)
          emit(session_id, :goal_set, %{goal: body})
          Logger.debug("[progress_ledger] goal set for #{session_id}")
          {:ok, body}

        {:error, reason} ->
          Logger.warning("[progress_ledger] set_goal failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  rescue
    e ->
      Logger.warning("[progress_ledger] set_goal raised: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @doc """
  Produce a compact summary ("ledger head") suitable for injecting into context
  at turn start: the current goal plus the most recent #{@summary_entries} log
  entries.

  Returns `{:ok, summary}`, or `{:error, :not_found}` if no ledger exists.
  """
  @spec summarize(String.t()) :: result()
  def summarize(session_id) when is_binary(session_id) do
    with {:ok, contents} <- read(session_id) do
      {:ok, build_summary(contents)}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # Create the ledger scaffold if it does not already exist. Idempotent.
  @spec ensure_file(String.t()) :: :ok | {:error, term()}
  defp ensure_file(session_id) do
    file = path(session_id)

    if File.exists?(file) do
      :ok
    else
      File.mkdir_p!(sessions_dir())

      case File.write(file, scaffold(session_id)) do
        :ok ->
          emit(session_id, :created, %{})
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec scaffold(String.t()) :: String.t()
  defp scaffold(session_id) do
    """
    # Progress Ledger

    - **Session:** #{session_id}
    - **Created:** #{now()}

    ## Goal

    #{@goal_placeholder}

    ## Log
    """
  end

  # A single log bullet. Continuation lines are indented under the bullet so
  # multi-line entries stay part of the same markdown list item.
  @spec format_bullet(String.t()) :: String.t()
  defp format_bullet(entry) do
    body =
      entry
      |> String.split("\n")
      |> Enum.map_join("\n", fn
        line -> "  " <> line
      end)
      |> String.trim_leading()

    "- [#{now()}] #{body}\n"
  end

  @spec normalize_goal(String.t()) :: String.t()
  defp normalize_goal(goal) do
    case String.trim(goal) do
      "" -> @goal_placeholder
      g -> g
    end
  end

  @spec build_summary(String.t()) :: String.t()
  defp build_summary(contents) do
    goal = extract_goal(contents)
    entries = extract_recent_entries(contents, @summary_entries)

    log_block =
      case entries do
        [] -> "_No entries yet._"
        list -> Enum.join(list, "\n")
      end

    """
    Progress ledger (recovered from disk):

    Goal: #{goal}

    Recent log:
    #{log_block}
    """
    |> String.trim()
  end

  @spec extract_goal(String.t()) :: String.t()
  defp extract_goal(contents) do
    case Regex.run(@goal_section, contents) do
      [_full, _head, body, _tail] -> String.trim(body)
      _ -> @goal_placeholder
    end
  end

  # Return the last `n` "- [...]" log bullets, preserving order.
  @spec extract_recent_entries(String.t(), pos_integer()) :: [String.t()]
  defp extract_recent_entries(contents, n) do
    contents
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "- ["))
    |> Enum.take(-n)
  end

  @spec safe_id(String.t()) :: String.t()
  defp safe_id(session_id) do
    Regex.replace(~r/[^a-zA-Z0-9_\-]/, session_id, "_")
  end

  # Atomic full-file rewrite (temp + rename), mirroring SessionPersistence's
  # crash-safe pattern (audit gap D4). Used for the `## Goal` section rewrite so a
  # crash mid-write can never leave a torn goal file — the exact file a long run
  # relies on to recover its intent. Pure appends (append_entry/2) stay O_APPEND:
  # a torn final line is tolerable for an append-only log and preserves replay.
  @spec atomic_write(String.t(), iodata()) :: :ok | {:error, term()}
  defp atomic_write(path, contents) do
    tmp = path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.write(tmp, contents),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  # Immutable Task Brief capture (audit gap M1). Never raises into set_goal.
  defp maybe_capture_brief(session_id, goal) do
    OptimalSystemAgent.Agent.TaskBrief.capture(session_id, goal)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @spec now() :: String.t()
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  @spec emit(String.t(), atom(), map()) :: :ok
  defp emit(session_id, event, extra) do
    Bus.emit(
      :system_event,
      Map.merge(extra, %{event: :progress_ledger, action: event, session_id: session_id})
    )

    :ok
  rescue
    # Ledger writes must never fail because the bus is unavailable (e.g. in
    # tests or before the supervision tree is up).
    _ -> :ok
  catch
    # Bus.emit dispatches through a GenServer; an unstarted supervision tree
    # surfaces as an exit, not an exception. Swallow it for the same reason.
    :exit, _ -> :ok
  end
end
