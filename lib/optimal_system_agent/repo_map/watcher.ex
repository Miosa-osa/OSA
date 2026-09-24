defmodule OptimalSystemAgent.RepoMap.Watcher do
  @moduledoc """
  Keeps `RepoMap` current for edits made OUTSIDE OSA — another terminal, an
  editor, a build step — without rescanning anything on the model's behalf.

  Polls on its OWN timer, independent of turn cadence (mirrors
  `Settings.Watcher`'s established idiom in this codebase: a singleton
  GenServer, a poll interval, and an explicit `register_root/1` /
  `unregister_root/1` pair for callers that run OSA under a directory other
  than the process-global cwd — `Agent.Fleet`'s `:working_dir`, the
  orchestrator's `repo_dir`, a `Workspace.FastWorktree` worktree).

  Each tick is a single `git status --porcelain` diff per registered root
  (`RepoMap.sync_from_git/1`) — NOT a directory rewalk — and only for roots
  `RepoMap.cached?/1` says have actually been consulted at least once. A
  root nobody has asked about yet costs this watcher nothing.

  Disabled when `:repo_map_watcher_enabled` is `false` (the test suite,
  which changes cwd per test and would otherwise fire spurious git calls
  against directories mid-teardown).
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.RepoMap

  @poll_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Add `root` to the watch set. Idempotent, and safe to call when the watcher
  is disabled or not running.
  """
  @spec register_root(String.t()) :: :ok
  def register_root(root) when is_binary(root) and root != "" do
    GenServer.cast(__MODULE__, {:register_root, Path.expand(root)})
  catch
    _, _ -> :ok
  end

  def register_root(_), do: :ok

  @doc "Remove a root previously added with `register_root/1`."
  @spec unregister_root(String.t()) :: :ok
  def unregister_root(root) when is_binary(root) and root != "" do
    GenServer.cast(__MODULE__, {:unregister_root, Path.expand(root)})
  catch
    _, _ -> :ok
  end

  def unregister_root(_), do: :ok

  @doc "The roots currently being polled. `[]` when the watcher is not running."
  @spec watching() :: [String.t()]
  def watching do
    GenServer.call(__MODULE__, :watching, 1_000)
  catch
    _, _ -> []
  end

  @doc "Force an immediate poll tick, synchronously. Test/diagnostic seam."
  @spec poll_now() :: :ok
  def poll_now do
    GenServer.call(__MODULE__, :poll_now, 5_000)
  catch
    _, _ -> :ok
  end

  @impl true
  def init(opts) do
    if Application.get_env(:optimal_system_agent, :repo_map_watcher_enabled, true) do
      poll_ms = Keyword.get(opts, :poll_ms, @poll_ms)
      roots = opts |> Keyword.get(:roots, []) |> Enum.map(&Path.expand/1) |> MapSet.new()

      Process.send_after(self(), :poll, poll_ms)
      {:ok, %{poll_ms: poll_ms, roots: roots}}
    else
      :ignore
    end
  end

  @impl true
  def handle_cast({:register_root, root}, state) do
    {:noreply, %{state | roots: MapSet.put(state.roots, root)}}
  end

  def handle_cast({:unregister_root, root}, state) do
    {:noreply, %{state | roots: MapSet.delete(state.roots, root)}}
  end

  @impl true
  def handle_call(:watching, _from, state), do: {:reply, MapSet.to_list(state.roots), state}

  def handle_call(:poll_now, _from, state) do
    poll(state.roots)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    poll(state.roots)
    Process.send_after(self(), :poll, state.poll_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp poll(roots) do
    Enum.each(roots, &poll_root/1)
  end

  defp poll_root(root) do
    if RepoMap.cached?(root), do: RepoMap.sync_from_git(root)
  rescue
    e -> Logger.debug("[repo_map_watcher] poll failed for #{root}: #{Exception.message(e)}")
  catch
    _, _ -> :ok
  end
end
