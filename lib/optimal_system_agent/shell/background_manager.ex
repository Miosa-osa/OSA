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

  @doc "Kill a running background command by id. Returns its final snapshot."
  @spec kill(String.t()) :: {:ok, map()} | {:error, :not_found}
  def kill(id), do: with_worker(id, &BackgroundTask.kill/1)

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
