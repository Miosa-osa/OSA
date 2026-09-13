defmodule OptimalSystemAgent.Shell.BackgroundManager do
  @moduledoc """
  Facade over the background-shell mechanism.

  MECHANISM layer — the tool handlers (interface) call into this module; this
  module owns the DynamicSupervisor + Registry lifecycle plumbing and hands out
  opaque background ids.

    * `start/3`  — spawn a supervised background command, returns `{:ok, id}`
    * `output/1` — poll accumulated stdout/stderr + status by id
    * `kill/1`   — terminate a running background command by id
    * `list/0`   — snapshot of all live/completed background commands

  The supervising `DynamicSupervisor`
  (`OptimalSystemAgent.Shell.BackgroundSupervisor`) and lookup `Registry`
  (`OptimalSystemAgent.Shell.BackgroundRegistry`) are started in
  `OptimalSystemAgent.Supervisors.Infrastructure`.
  """

  alias OptimalSystemAgent.Shell.BackgroundTask

  @registry OptimalSystemAgent.Shell.BackgroundRegistry
  @supervisor OptimalSystemAgent.Shell.BackgroundSupervisor

  @doc """
  Spawn `command` as a supervised background process running in `cwd`.

  Returns `{:ok, background_id}` immediately (does not wait for completion) or
  `{:error, reason}` if the process could not be started.

  Options are forwarded to `BackgroundTask` (`:max_bytes`, `:retain_ms`).
  """
  @spec start(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def start(command, cwd, opts \\ []) do
    id = generate_id()

    child_opts = [id: id, command: command, cwd: cwd] ++ opts
    spec = %{id: id, start: {BackgroundTask, :start_link, [child_opts]}, restart: :temporary}

    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, _pid} -> {:ok, id}
      {:error, {:spawn_failed, msg}} -> {:error, msg}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @doc """
  Adopt an ALREADY-RUNNING OS process (its live `Port` + os_pid) into a fresh
  supervised `BackgroundTask`, seeding it with the output collected so far.

  Used to promote an in-flight FOREGROUND `shell_execute` to the background
  (TUI Ctrl+B). The caller must own the port and, right after this returns
  `{:ok, id, pid}`, transfer ownership with `Port.connect(port, pid)` so the
  worker receives the remaining data/exit-status messages.

  Required opts: `:command`, `:cwd`, `:port`, `:os_pid`. Optional: `:session_id`,
  `:initial` (output already collected), plus the usual `:max_bytes`/`:retain_ms`.
  """
  @spec adopt(keyword()) :: {:ok, String.t(), pid()} | {:error, String.t()}
  def adopt(opts) do
    id = generate_id()
    child_opts = [id: id, adopt: true] ++ opts
    spec = %{id: id, start: {BackgroundTask, :start_link, [child_opts]}, restart: :temporary}

    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, pid} -> {:ok, id, pid}
      {:error, {:spawn_failed, msg}} -> {:error, msg}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @doc "Poll a background command's accumulated output + status by id."
  @spec output(String.t()) :: {:ok, map()} | {:error, :not_found}
  def output(id), do: with_worker(id, &BackgroundTask.snapshot/1)

  @doc """
  Terminal output tail for a background command, read FRESH from the worker at
  call time. Used by `BackgroundNotifier` when it builds a completion summary so
  the notice carries the command's FINAL frame - not a mid-flight progress line
  (e.g. a download's "61% 10GB/16GB") that happened to sit at the front of the
  retained tail window.

  The worker lingers for `retain_ms` after finishing, so this reads the true
  terminal snapshot. Returns `""` when the id is unknown or the worker has
  already retired, so the caller can fall back to whatever tail the completion
  event carried.
  """
  @spec final_tail(String.t(), non_neg_integer()) :: String.t()
  def final_tail(id, max_chars \\ 400) do
    case output(id) do
      {:ok, %{output: output}} -> terminal_tail(output, max_chars)
      _ -> ""
    end
  end

  @doc """
  Collapse carriage-return progress frames in `output` to their final rendered
  form, then return the last `max_chars` characters (the TERMINAL snapshot).

  Progress bars overwrite a single line with `\\r` (`" 61%\\r 62%\\r100%"`); only
  the segment after the last `\\r` on each line is what the terminal actually
  shows. Collapsing first, then taking the END, yields the completed frame -
  never an intermediate one, and never the FRONT of the tail window (the old
  bug that surfaced a stale in-flight frame after completion).
  """
  @spec terminal_tail(binary() | term(), non_neg_integer()) :: String.t()
  def terminal_tail(output, max_chars \\ 400) do
    collapsed =
      output
      |> to_string()
      |> String.split("\n")
      |> Enum.map(&last_cr_frame/1)
      |> Enum.join("\n")
      |> String.trim()

    len = String.length(collapsed)
    if len > max_chars, do: String.slice(collapsed, len - max_chars, max_chars), else: collapsed
  end

  @doc "Kill a running background command by id. Returns its final snapshot."
  @spec kill(String.t()) :: {:ok, map()} | {:error, :not_found}
  def kill(id), do: with_worker(id, &BackgroundTask.kill/1)

  @doc """
  Kill every RUNNING background command belonging to `session_id` — orphan
  reaping when the owning session ends (WS6). Returns the number killed.
  """
  @spec kill_for_session(String.t()) :: non_neg_integer()
  def kill_for_session(session_id) when is_binary(session_id) do
    list()
    |> Enum.filter(&(&1.status == :running and &1[:session_id] == session_id))
    |> Enum.reduce(0, fn snap, acc ->
      case kill(snap.id) do
        {:ok, _} -> acc + 1
        _ -> acc
      end
    end)
  end

  @doc """
  Kill every RUNNING background command belonging to ANY of `session_ids` —
  transitive/cascading cancel (Loop.cancel/1 subtree fan-out). Same shape as
  `kill_for_session/1` but batched across a whole cancelled-session subtree
  (parent + every BFS-discovered descendant) in one pass. Returns the number
  killed.
  """
  @spec cancel_for_sessions([String.t()]) :: non_neg_integer()
  def cancel_for_sessions(session_ids) when is_list(session_ids) do
    wanted = MapSet.new(session_ids)

    list()
    |> Enum.filter(&(&1.status == :running and MapSet.member?(wanted, &1[:session_id])))
    |> Enum.reduce(0, fn snap, acc ->
      case kill(snap.id) do
        {:ok, _} -> acc + 1
        _ -> acc
      end
    end)
  end

  @doc "Number of background commands currently in the `:running` state."
  @spec running_count() :: non_neg_integer()
  def running_count do
    list() |> Enum.count(&(&1.status == :running))
  end

  @doc "Return snapshots of all currently tracked background commands."
  @spec list() :: [map()]
  def list do
    Registry.select(@registry, [{{:"$1", :"$2", :_}, [], [:"$2"]}])
    |> Enum.map(fn pid ->
      try do
        BackgroundTask.snapshot(pid)
      catch
        _, _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # ── Private ──────────────────────────────────────────────────────────

  # Keep only the final overwrite frame of a single line: the text after its
  # last carriage return. A lone trailing `\r` (a CRLF split on "\n") is
  # stripped first so a normal line is left intact.
  defp last_cr_frame(line) do
    line = String.trim_trailing(line, "\r")

    case :binary.matches(line, "\r") do
      [] ->
        line

      matches ->
        {pos, len} = List.last(matches)
        binary_part(line, pos + len, byte_size(line) - pos - len)
    end
  end

  defp with_worker(id, fun) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> {:ok, fun.(pid)}
      [] -> {:error, :not_found}
    end
  end

  defp generate_id do
    "bg_" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false))
  end
end
