defmodule OptimalSystemAgent.Workspace.Workspace do
  @moduledoc """
  Workspace Manager GenServer.

  A workspace is the durable layer above ephemeral sessions. Teams, tasks, and
  all progress survive disconnects. Sessions are ephemeral overlays that connect
  and disconnect without affecting workspace state.

  ## Lifecycle

    1. `start_link/1` — start a named GenServer for a workspace_id
    2. On `init/1` — attempt to restore state from SQLite via `restore_state/1`
    3. State mutations trigger async `save_state/1` persists (debounced)
    4. Sessions `connect/2` to a workspace and receive state broadcasts
    5. Sessions `disconnect/1` — workspace continues running unaffected

  ## State

      %{
        workspace_id: String.t(),
        name:         String.t(),
        project_path: String.t(),
        teams:        %{team_id => team_state_map},
        tasks:        %{task_id => task_state_map},
        created_at:   DateTime.t(),
        last_active:  DateTime.t()
      }

  ## Process naming

  Workspaces are registered in `OptimalSystemAgent.Registry` under
  `{Workspace, workspace_id}` so they can be looked up without holding
  a direct PID.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.Workspace.Store
  alias OptimalSystemAgent.Workspace.TaskJournal

  @persist_debounce_ms 2_000

  defstruct workspace_id: nil,
            name: "",
            project_path: "",
            teams: %{},
            tasks: %{},
            created_at: nil,
            last_active: nil,
            # Internal — pid of pending debounce timer
            persist_timer: nil

  @type t :: %__MODULE__{}

  # ── Child Spec / Supervision ───────────────────────────────────────────────

  def child_spec(opts) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)

    %{
      id: {__MODULE__, workspace_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      shutdown: 5_000
    }
  end

  # ── Client API ─────────────────────────────────────────────────────────────

  @doc """
  Start a Workspace GenServer.

  ## Options
  - `:workspace_id`  — required, unique identifier
  - `:name`          — display name (default: workspace_id)
  - `:project_path`  — filesystem path for the project (default: "")
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    via = via_name(workspace_id)
    GenServer.start_link(__MODULE__, opts, name: via)
  end

  @doc "Get the full workspace state map."
  @spec get_state(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_state(workspace_id) do
    call(workspace_id, :get_state)
  end

  @doc "Update team state within the workspace."
  @spec put_team(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def put_team(workspace_id, team_id, team_state) do
    call(workspace_id, {:put_team, team_id, team_state})
  end

  @doc "Remove a team from the workspace."
  @spec remove_team(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_team(workspace_id, team_id) do
    call(workspace_id, {:remove_team, team_id})
  end

  @doc "Update task state within the workspace."
  @spec put_task(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def put_task(workspace_id, task_id, task_state) do
    call(workspace_id, {:put_task, task_id, task_state})
  end

  @doc "Remove a task from workspace tracking."
  @spec remove_task(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_task(workspace_id, task_id) do
    call(workspace_id, {:remove_task, task_id})
  end

  @doc """
  Persist full workspace state to SQLite immediately (bypasses debounce).
  Returns `:ok` or `{:error, reason}`.
  """
  @spec save_state(String.t()) :: :ok | {:error, term()}
  def save_state(workspace_id) do
    call(workspace_id, :save_now)
  end

  @doc """
  Restore workspace state from SQLite.

  Called automatically during `init/1`. Exposed for manual recovery or
  testing. Returns `{:ok, state}` or `{:error, reason}`.
  """
  @spec restore_state(String.t()) :: {:ok, map()} | {:error, term()}
  def restore_state(workspace_id) do
    Store.load_workspace(workspace_id)
  end

  @doc "Record a task journal entry for this workspace."
  @spec journal(String.t(), map()) :: :ok | {:error, term()}
  def journal(workspace_id, entry) do
    TaskJournal.append(workspace_id, entry)
  end

  @doc "Check whether a workspace GenServer is alive."
  @spec alive?(String.t()) :: boolean()
  def alive?(workspace_id) do
    case Registry.lookup(OptimalSystemAgent.Registry, {__MODULE__, workspace_id}) do
      [{_pid, _}] -> true
      [] -> false
    end
  end

  # ── Server Callbacks ───────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    now = DateTime.utc_now()

    base_state = %__MODULE__{
      workspace_id: workspace_id,
      name: Keyword.get(opts, :name, workspace_id),
      project_path: Keyword.get(opts, :project_path, ""),
      created_at: now,
      last_active: now
    }

    state =
      case Store.load_workspace(workspace_id) do
        {:ok, persisted} ->
          Logger.info("[Workspace] Restored #{workspace_id} from SQLite")
          overlay_persisted(base_state, persisted)

        {:error, :not_found} ->
          Logger.info("[Workspace] New workspace #{workspace_id}")
          base_state

        {:error, reason} ->
          Logger.warning("[Workspace] Could not restore #{workspace_id}: #{inspect(reason)} — starting fresh")
          base_state
      end

    # Persist new workspaces immediately so they exist in SQLite
    if state.workspace_id == base_state.workspace_id and state.teams == %{} and
         state.tasks == %{} do
      schedule_persist(state)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, to_public_map(state)}, touch(state)}
  end

  def handle_call({:put_team, team_id, team_state}, _from, state) do
    new_state =
      state
      |> Map.update!(:teams, &Map.put(&1, team_id, team_state))
      |> touch()
      |> schedule_persist()

    {:reply, :ok, new_state}
  end

  def handle_call({:remove_team, team_id}, _from, state) do
    new_state =
      state
      |> Map.update!(:teams, &Map.delete(&1, team_id))
      |> touch()
      |> schedule_persist()

    {:reply, :ok, new_state}
  end

  def handle_call({:put_task, task_id, task_state}, _from, state) do
    new_state =
      state
      |> Map.update!(:tasks, &Map.put(&1, task_id, task_state))
      |> touch()
      |> schedule_persist()

    {:reply, :ok, new_state}
  end

  def handle_call({:remove_task, task_id}, _from, state) do
    new_state =
      state
      |> Map.update!(:tasks, &Map.delete(&1, task_id))
      |> touch()
      |> schedule_persist()

    {:reply, :ok, new_state}
  end

  def handle_call(:save_now, _from, state) do
    # Cancel any pending debounce timer
    cancel_timer(state.persist_timer)
    result = do_persist(state)
    {:reply, result, %{state | persist_timer: nil}}
  end

  @impl true
  def handle_info(:persist_debounce, state) do
    do_persist(state)
    {:noreply, %{state | persist_timer: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Best-effort final persist on shutdown
    cancel_timer(state.persist_timer)
    do_persist(state)
    :ok
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp via_name(workspace_id) do
    {:via, Registry, {OptimalSystemAgent.Registry, {__MODULE__, workspace_id}}}
  end

  defp call(workspace_id, message) do
    via = via_name(workspace_id)

    try do
      GenServer.call(via, message, 10_000)
    catch
      :exit, {:noproc, _} -> {:error, :not_found}
      :exit, reason -> {:error, reason}
    end
  end

  defp touch(state), do: %{state | last_active: DateTime.utc_now()}

  defp schedule_persist(%{persist_timer: existing} = state) do
    cancel_timer(existing)
    timer = Process.send_after(self(), :persist_debounce, @persist_debounce_ms)
    %{state | persist_timer: timer}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp do_persist(state) do
    record = %{
      id: state.workspace_id,
      name: state.name,
      project_path: state.project_path,
      state: %{
        teams: state.teams,
        tasks: state.tasks,
        created_at: DateTime.to_iso8601(state.created_at),
        last_active: DateTime.to_iso8601(state.last_active)
      }
    }

    case Store.save_workspace(record) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Workspace] Persist failed for #{state.workspace_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp overlay_persisted(base, %{state: persisted_state} = persisted) do
    teams = Map.get(persisted_state, "teams", %{}) |> atomize_keys()
    tasks = Map.get(persisted_state, "tasks", %{}) |> atomize_keys()

    created_at =
      case Map.get(persisted_state, "created_at") do
        nil -> base.created_at
        iso -> parse_datetime(iso, base.created_at)
      end

    %{
      base
      | name: Map.get(persisted, :name, base.name),
        project_path: Map.get(persisted, :project_path, base.project_path),
        teams: teams,
        tasks: tasks,
        created_at: created_at
    }
  end

  defp to_public_map(state) do
    %{
      workspace_id: state.workspace_id,
      name: state.name,
      project_path: state.project_path,
      teams: state.teams,
      tasks: state.tasks,
      created_at: state.created_at,
      last_active: state.last_active
    }
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, v} end)
  end

  defp atomize_keys(other), do: other

  defp parse_datetime(iso, default) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> default
    end
  end
end
