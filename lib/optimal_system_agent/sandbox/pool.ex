defmodule OptimalSystemAgent.Sandbox.Pool do
  @moduledoc """
  Container pool for warm, low-latency sandbox execution.

  ## Strategy

  The pool pre-starts `@pool_size` containers in "sleeping" mode
  (`sleep infinity`). When a command needs to run, the pool picks an
  idle container, executes via `docker exec`, then marks that container
  available again.

  If all containers are busy the pool spawns a temporary overflow
  container via `Docker.execute/2` (slightly higher latency but never
  drops work).

  After `@recycle_after` uses a container is replaced so it starts fresh
  with no accumulated state.

  ## State shape

      %{
        containers: [
          %{id: "osa-pool-xxxx", status: :idle | :busy, uses: integer}
        ]
      }
  """

  use GenServer

  require Logger

  alias OptimalSystemAgent.Sandbox.Docker

  @pool_size 3
  @container_image "osa-sandbox:latest"
  # Replace a container after this many uses to prevent state accumulation
  @recycle_after 50
  # How often (ms) to run the health-check sweep
  @health_interval 60_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Execute `command` using a pooled container.

  Falls back to a fresh `Docker.execute/2` call if the pool is exhausted.
  `opts` are the same as `Docker.execute/2`.
  """
  @spec execute(String.t(), keyword()) ::
          {:ok, String.t(), non_neg_integer()} | {:error, String.t()}
  def execute(command, opts \\ []) do
    GenServer.call(__MODULE__, {:execute, command, opts}, 60_000)
  end

  @doc """
  Return current pool status (idle/busy counts).
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    # Defer pool warm-up so the supervisor doesn't time out
    send(self(), :warm_up)

    # Schedule periodic health checks
    Process.send_after(self(), :health_check, @health_interval)

    {:ok, %{containers: []}}
  end

  @impl true
  def handle_call({:execute, command, opts}, _from, state) do
    case checkout_container(state) do
      {:ok, container, new_state} ->
        result = exec_in_container(container, command, opts)
        final_state = checkin_container(new_state, container, result)
        {:reply, result, final_state}

      :overflow ->
        Logger.debug("[Sandbox.Pool] All #{@pool_size} containers busy — overflow to fresh container")
        result = Docker.execute(command, opts)
        {:reply, result, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    counts =
      Enum.reduce(state.containers, %{idle: 0, busy: 0}, fn c, acc ->
        Map.update!(acc, c.status, &(&1 + 1))
      end)

    {:reply, Map.put(counts, :total, length(state.containers)), state}
  end

  @impl true
  def handle_info(:warm_up, state) do
    Logger.info("[Sandbox.Pool] Warming up #{@pool_size} containers (image: #{@container_image})")

    containers =
      if Docker.available?() do
        Enum.map(1..@pool_size, fn _ -> start_pool_container() end)
        |> Enum.filter(&(not is_nil(&1)))
      else
        Logger.warning(
          "[Sandbox.Pool] Docker not available — pool will use overflow-only mode"
        )
        []
      end

    Logger.info("[Sandbox.Pool] Pool ready — #{length(containers)} containers started")
    {:noreply, %{state | containers: containers}}
  end

  @impl true
  def handle_info(:health_check, state) do
    healthy_containers =
      Enum.map(state.containers, fn container ->
        if container_alive?(container.id) do
          container
        else
          Logger.warning(
            "[Sandbox.Pool] Container #{container.id} is gone — replacing"
          )
          start_pool_container()
        end
      end)
      |> Enum.filter(&(not is_nil(&1)))

    # Top up to pool_size if any replacements failed
    missing = @pool_size - length(healthy_containers)

    topped_up =
      if missing > 0 and Docker.available?() do
        Logger.info("[Sandbox.Pool] Topping up pool — starting #{missing} replacement containers")
        replacements =
          Enum.map(1..missing, fn _ -> start_pool_container() end)
          |> Enum.filter(&(not is_nil(&1)))
        healthy_containers ++ replacements
      else
        healthy_containers
      end

    Process.send_after(self(), :health_check, @health_interval)
    {:noreply, %{state | containers: topped_up}}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec start_pool_container() :: map() | nil
  defp start_pool_container do
    id = "osa-pool-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"

    workspace = Path.expand("~/.osa/workspace")
    File.mkdir_p!(workspace)

    args = [
      "run", "-d",
      "--name", id,
      "--network", "none",
      "--memory", "256m",
      "--cpus", "0.5",
      "--read-only",
      "--tmpfs", "/tmp:rw,noexec,nosuid,size=64m",
      "--security-opt", "no-new-privileges:true",
      "--cap-drop", "ALL",
      "-v", "#{workspace}:/workspace:rw",
      "-w", "/workspace",
      "-u", "1000:1000",
      @container_image,
      "sleep", "infinity"
    ]

    try do
      case System.cmd("docker", args, stderr_to_stdout: true) do
        {_out, 0} ->
          Logger.debug("[Sandbox.Pool] Started pool container #{id}")
          %{id: id, status: :idle, uses: 0}

        {err, code} ->
          Logger.warning(
            "[Sandbox.Pool] Failed to start container #{id} exit=#{code}: #{String.trim(err)}"
          )
          nil
      end
    rescue
      e ->
        Logger.warning("[Sandbox.Pool] Exception starting container: #{Exception.message(e)}")
        nil
    end
  end

  @spec stop_pool_container(String.t()) :: :ok
  defp stop_pool_container(id) do
    try do
      System.cmd("docker", ["rm", "-f", id], stderr_to_stdout: true)
      Logger.debug("[Sandbox.Pool] Removed container #{id}")
    rescue
      _ -> :ok
    end

    :ok
  end

  @spec container_alive?(String.t()) :: boolean()
  defp container_alive?(id) do
    try do
      case System.cmd("docker", ["inspect", "--format", "{{.State.Running}}", id],
             stderr_to_stdout: true
           ) do
        {"true\n", 0} -> true
        _ -> false
      end
    rescue
      _ -> false
    end
  end

  @spec checkout_container(map()) :: {:ok, map(), map()} | :overflow
  defp checkout_container(state) do
    case Enum.find_index(state.containers, &(&1.status == :idle)) do
      nil ->
        :overflow

      index ->
        container = Enum.at(state.containers, index)
        updated = %{container | status: :busy}
        new_containers = List.replace_at(state.containers, index, updated)
        {:ok, updated, %{state | containers: new_containers}}
    end
  end

  @spec checkin_container(map(), map(), term()) :: map()
  defp checkin_container(state, container, _result) do
    index = Enum.find_index(state.containers, &(&1.id == container.id))

    if is_nil(index) do
      state
    else
      updated_uses = container.uses + 1

      if updated_uses >= @recycle_after do
        # Replace this container with a fresh one asynchronously
        Logger.debug(
          "[Sandbox.Pool] Container #{container.id} reached #{@recycle_after} uses — recycling"
        )

        Task.start(fn ->
          stop_pool_container(container.id)
        end)

        replacement = start_pool_container()

        new_containers =
          if replacement do
            List.replace_at(state.containers, index, replacement)
          else
            List.delete_at(state.containers, index)
          end

        %{state | containers: new_containers}
      else
        refreshed = %{container | status: :idle, uses: updated_uses}
        %{state | containers: List.replace_at(state.containers, index, refreshed)}
      end
    end
  end

  @spec exec_in_container(map(), String.t(), keyword()) ::
          {:ok, String.t(), non_neg_integer()} | {:error, String.t()}
  defp exec_in_container(container, command, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    docker_args = ["exec", container.id, "sh", "-c", command]

    Logger.debug("[Sandbox.Pool] Exec in #{container.id}: #{String.slice(command, 0, 80)}")

    task =
      Task.async(fn ->
        try do
          System.cmd("docker", docker_args, stderr_to_stdout: true)
        rescue
          e -> {Exception.message(e), 1}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {output, 0}} -> {:ok, output, 0}
      {:ok, {output, code}} -> {:ok, output, code}
      nil ->
        Logger.warning(
          "[Sandbox.Pool] Exec in #{container.id} timed out after #{timeout}ms"
        )
        {:error, "Command timed out after #{timeout}ms"}
    end
  end
end
