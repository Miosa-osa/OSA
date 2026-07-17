defmodule OptimalSystemAgent.Monitor.WatchManager do
  @moduledoc """
  Facade over the background-watcher mechanism for the `monitor` tool.

  MECHANISM layer — the `monitor` tool handler (interface) calls into this
  module; this module owns the DynamicSupervisor + Registry lifecycle plumbing
  and hands out opaque watch ids. Mirrors `OptimalSystemAgent.Shell.BackgroundManager`.

    * `start/2` — register a supervised watcher, returns `{:ok, watch_id}`
    * `stop/1`  — stop a running watcher by id
    * `list/0`  — snapshot of all live watchers

  The supervising `DynamicSupervisor`
  (`OptimalSystemAgent.Monitor.WatchSupervisor`) and lookup `Registry`
  (`OptimalSystemAgent.Monitor.WatchRegistry`) are started in
  `OptimalSystemAgent.Supervisors.Infrastructure`.
  """

  alias OptimalSystemAgent.Monitor.WatchTask

  @registry OptimalSystemAgent.Monitor.WatchRegistry
  @supervisor OptimalSystemAgent.Monitor.WatchSupervisor

  @doc """
  Register `input` (the validated `monitor` tool args) as a supervised watcher
  bound to `session_id`. Returns `{:ok, watch_id}` immediately (does not block on
  the watch) or `{:error, reason}` if the watcher could not be started.
  """
  @spec start(map(), String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def start(input, session_id) do
    id = generate_id()
    child_opts = [id: id, input: input, session_id: session_id]
    spec = %{id: id, start: {WatchTask, :start_link, [child_opts]}, restart: :temporary}

    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, _pid} -> {:ok, id}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @doc "Stop a running watcher by id. Returns its final snapshot."
  @spec stop(String.t()) :: {:ok, map()} | {:error, :not_found}
  def stop(id), do: with_worker(id, &WatchTask.stop/1)

  @doc "Return snapshots of all currently tracked watchers."
  @spec list() :: [map()]
  def list do
    Registry.select(@registry, [{{:"$1", :"$2", :_}, [], [:"$2"]}])
    |> Enum.map(fn pid ->
      try do
        WatchTask.snapshot(pid)
      catch
        _, _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc "Number of watchers currently in the `:running` state."
  @spec running_count() :: non_neg_integer()
  def running_count, do: list() |> Enum.count(&(&1.status == :running))

  # ── Private ──────────────────────────────────────────────────────────

  defp with_worker(id, fun) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> {:ok, fun.(pid)}
      [] -> {:error, :not_found}
    end
  end

  defp generate_id do
    "watch_" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false))
  end
end
