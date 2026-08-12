defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Compose do
  @moduledoc """
  Docker Compose executor for the OpenComputers direct-mode protocol.

  One GenServer per OSA session. Manages the full lifecycle of compose stacks:
  up, down, ps, and log streaming.

  ## Compose v2 only

  Uses `docker compose` (plugin, v2). Detects availability at startup via
  `docker compose version`. If unavailable, emits `compose_not_available` on
  any request.

  ## Wire protocol handled

    Inbound (MIOSA → OSA):
      {:compose_up_request, %{project_id, name, yaml, env, pull, build}}
      {:compose_down_request, %{project_id, remove_volumes}}
      {:compose_ps_request, %{project_id}}
      {:compose_logs_subscribe, %{project_id, service_name}}

    Outbound (OSA → MIOSA):
      {:compose_progress, %{project_id, phase, message}}
      {:compose_up, %{project_id, services: [{name, container_id, state}]}}
      {:compose_down, %{project_id}}
      {:compose_ps, %{project_id, services: [...]}}
      {:compose_log_line, %{project_id, service, stream, line, ts}}
      {:compose_error, %{project_id, reason, phase}}

  ## Temp directory

  Each project gets `/tmp/miosa-compose/<project_id>/`. Cleaned up on
  `compose_down` or when the project is removed.

  ## Log streaming

  `compose_logs_subscribe` starts a Port-based streaming tail for the whole
  compose project (or a single service if `service_name` is provided). Lines
  are parsed and emitted as `compose_log_line` frames.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.OpenComputers.FrameRouter

  # Computed at runtime so the platform temp dir is used (e.g. %TEMP% on
  # Windows). On Unix `System.tmp_dir!()` yields "/tmp", preserving prior paths.
  defp base_tmp, do: Path.join(System.tmp_dir!(), "miosa-compose")

  # ── Public API ────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.merge([name: __MODULE__], opts))
  end

  @doc "Handle an inbound compose frame dispatched by FrameRouter."
  @spec handle_frame(term()) :: :ok
  def handle_frame(frame) do
    GenServer.cast(__MODULE__, {:inbound, frame})
  end

  # ── GenServer ─────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    state = %{
      # nil | "docker" | :unavailable
      runtime: nil,
      # %{project_id => %{name: name, log_port: port | nil}}
      projects: %{}
    }

    {:ok, state}
  end

  # ── Inbound: compose_up_request ───────────────────────────────────────────────

  @impl true
  def handle_cast({:inbound, {:compose_up_request, payload}}, state) do
    %{project_id: project_id, name: name, yaml: yaml, env: env} = payload
    pull = Map.get(payload, :pull, false)
    build = Map.get(payload, :build, false)

    {runtime, state} = ensure_runtime(state)

    case runtime do
      :unavailable ->
        send_error(project_id, :compose_not_available, :pre_flight)
        {:noreply, state}

      bin ->
        self_pid = self()

        Task.start(fn ->
          do_up(self_pid, bin, project_id, name, yaml, env, pull, build)
        end)

        state = put_in(state.projects[project_id], %{name: name, log_port: nil})
        {:noreply, state}
    end
  end

  # ── Inbound: compose_down_request ─────────────────────────────────────────────

  def handle_cast({:inbound, {:compose_down_request, payload}}, state) do
    %{project_id: project_id} = payload
    remove_volumes = Map.get(payload, :remove_volumes, false)

    {runtime, state} = ensure_runtime(state)

    case runtime do
      :unavailable ->
        send_error(project_id, :compose_not_available, :down)
        {:noreply, state}

      bin ->
        project_name = get_project_name(state, project_id)

        # Stop log stream if running
        state = stop_log_stream(state, project_id)

        Task.start(fn ->
          do_down(bin, project_id, project_name, remove_volumes)
        end)

        {:noreply, state}
    end
  end

  # ── Inbound: compose_ps_request ───────────────────────────────────────────────

  def handle_cast({:inbound, {:compose_ps_request, payload}}, state) do
    %{project_id: project_id} = payload
    {runtime, state} = ensure_runtime(state)

    case runtime do
      :unavailable ->
        send_error(project_id, :compose_not_available, :ps)
        {:noreply, state}

      bin ->
        project_name = get_project_name(state, project_id)

        Task.start(fn ->
          do_ps(bin, project_id, project_name)
        end)

        {:noreply, state}
    end
  end

  # ── Inbound: compose_logs_subscribe ──────────────────────────────────────────

  def handle_cast({:inbound, {:compose_logs_subscribe, payload}}, state) do
    %{project_id: project_id} = payload
    service_name = Map.get(payload, :service_name)

    {runtime, state} = ensure_runtime(state)

    case runtime do
      :unavailable ->
        send_error(project_id, :compose_not_available, :logs)
        {:noreply, state}

      bin ->
        project_name = get_project_name(state, project_id)

        # Stop existing stream if any
        state = stop_log_stream(state, project_id)

        log_port = start_log_stream(bin, project_id, project_name, service_name)

        state =
          update_in(state.projects[project_id], fn p ->
            if p, do: %{p | log_port: log_port}, else: %{name: project_name, log_port: log_port}
          end)

        {:noreply, state}
    end
  end

  def handle_cast({:inbound, _frame}, state), do: {:noreply, state}

  # ── Messages from Tasks and Ports ─────────────────────────────────────────────

  # compose_up finished — send compose_up frame
  def handle_cast({:compose_up_done, project_id, services}, state) do
    FrameRouter.send_frame({:compose_up, %{project_id: project_id, services: services}})
    {:noreply, state}
  end

  # compose_down finished
  def handle_cast({:compose_down_done, project_id}, state) do
    state = cleanup_tmp(state, project_id)
    FrameRouter.send_frame({:compose_down, %{project_id: project_id}})
    {:noreply, state}
  end

  # compose_ps finished
  def handle_cast({:compose_ps_done, project_id, services}, state) do
    FrameRouter.send_frame({:compose_ps, %{project_id: project_id, services: services}})
    {:noreply, state}
  end

  # compose task error
  def handle_cast({:compose_task_error, project_id, reason, phase}, state) do
    send_error(project_id, reason, phase)
    {:noreply, state}
  end

  # progress emission from Task
  def handle_cast({:compose_progress, project_id, phase, message}, state) do
    FrameRouter.send_frame(
      {:compose_progress, %{project_id: project_id, phase: phase, message: message}}
    )

    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, state) do
    # Log line from a compose logs Port
    {project_id, _p} =
      Enum.find(state.projects, {nil, nil}, fn {_id, p} ->
        is_map(p) and p[:log_port] == port
      end)

    if project_id do
      data
      |> String.split("\n", trim: true)
      |> Enum.each(fn line ->
        {service, rest} = extract_service_prefix(line)
        {ts, stripped} = extract_timestamp(rest)

        FrameRouter.send_frame(
          {:compose_log_line,
           %{
             project_id: project_id,
             service: service,
             stream: "stdout",
             line: stripped,
             ts: ts
           }}
        )
      end)
    end

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, _code}}, state) do
    Logger.debug("[Compose] log port exited: #{inspect(port)}")

    state =
      Enum.reduce(state.projects, state, fn {id, p}, acc ->
        if is_map(p) and p[:log_port] == port do
          put_in(acc.projects[id], %{p | log_port: nil})
        else
          acc
        end
      end)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Runtime detection ─────────────────────────────────────────────────────────

  defp ensure_runtime(%{runtime: nil} = state) do
    runtime =
      if compose_v2_available?() do
        "docker"
      else
        :unavailable
      end

    {runtime, %{state | runtime: runtime}}
  end

  defp ensure_runtime(%{runtime: r} = state), do: {r, state}

  defp compose_v2_available? do
    case System.cmd("docker", ["compose", "version"], stderr_to_stdout: true) do
      {_out, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  # ── compose up (in Task) ──────────────────────────────────────────────────────

  defp do_up(server, runtime, project_id, name, yaml, env, pull, build) do
    tmp_dir = project_tmp_dir(project_id)

    emit_progress(server, project_id, :validating, "Validating compose file")

    with :ok <- write_compose_files(tmp_dir, yaml, env),
         :ok <- maybe_pull(server, runtime, project_id, name, tmp_dir, pull),
         :ok <- maybe_build(server, runtime, project_id, name, tmp_dir, build),
         :ok <- do_compose_up(server, runtime, project_id, name, tmp_dir),
         {:ok, services} <- do_ps_query(runtime, project_id, name) do
      GenServer.cast(server, {:compose_up_done, project_id, services})
    else
      {:error, reason, phase} ->
        GenServer.cast(server, {:compose_task_error, project_id, reason, phase})
    end
  end

  defp write_compose_files(tmp_dir, yaml, env) do
    File.mkdir_p!(tmp_dir)
    compose_path = Path.join(tmp_dir, "docker-compose.yml")

    case File.write(compose_path, yaml) do
      :ok ->
        if map_size(env) > 0 do
          env_content = Enum.map_join(env, "\n", fn {k, v} -> "#{k}=#{v}" end)
          env_path = Path.join(tmp_dir, ".env")

          case File.write(env_path, env_content) do
            :ok -> :ok
            {:error, reason} -> {:error, "env_write_failed: #{reason}", :validating}
          end
        else
          :ok
        end

      {:error, reason} ->
        {:error, "yaml_write_failed: #{reason}", :validating}
    end
  rescue
    e -> {:error, "write_failed: #{Exception.message(e)}", :validating}
  end

  defp maybe_pull(_server, _runtime, _project_id, _name, _tmp_dir, false), do: :ok

  defp maybe_pull(server, runtime, project_id, name, tmp_dir, true) do
    emit_progress(server, project_id, :pulling, "Pulling images")

    case run_compose_cmd(runtime, name, tmp_dir, ["pull"]) do
      :ok -> :ok
      {:error, reason} -> {:error, reason, :pulling}
    end
  end

  defp maybe_build(_server, _runtime, _project_id, _name, _tmp_dir, false), do: :ok

  defp maybe_build(server, runtime, project_id, name, tmp_dir, true) do
    emit_progress(server, project_id, :building, "Building images")

    case run_compose_cmd(runtime, name, tmp_dir, ["build"]) do
      :ok -> :ok
      {:error, reason} -> {:error, reason, :building}
    end
  end

  defp do_compose_up(server, runtime, project_id, name, tmp_dir) do
    emit_progress(server, project_id, :starting, "Starting services")

    case run_compose_cmd(runtime, name, tmp_dir, ["up", "-d"]) do
      :ok -> :ok
      {:error, reason} -> {:error, reason, :starting}
    end
  end

  # ── compose down (in Task) ────────────────────────────────────────────────────

  defp do_down(runtime, project_id, name, remove_volumes) do
    args = if remove_volumes, do: ["down", "--volumes"], else: ["down"]
    tmp_dir = project_tmp_dir(project_id)

    case run_compose_cmd(runtime, name, tmp_dir, args) do
      :ok ->
        GenServer.cast(__MODULE__, {:compose_down_done, project_id})

      {:error, reason} ->
        Logger.warning("[Compose] down failed project=#{project_id}: #{inspect(reason)}")
        # Still emit down — the project is being removed from the MIOSA side
        GenServer.cast(__MODULE__, {:compose_down_done, project_id})
    end
  end

  # ── compose ps (in Task) ──────────────────────────────────────────────────────

  defp do_ps(runtime, project_id, name) do
    case do_ps_query(runtime, project_id, name) do
      {:ok, services} ->
        GenServer.cast(__MODULE__, {:compose_ps_done, project_id, services})

      {:error, reason} ->
        Logger.warning("[Compose] ps failed project=#{project_id}: #{inspect(reason)}")
        GenServer.cast(__MODULE__, {:compose_ps_done, project_id, []})
    end
  end

  defp do_ps_query(runtime, _project_id, name) do
    tmp_dir = project_tmp_dir_by_name(name)

    args =
      ["compose", "--project-name", name] ++
        if(File.exists?(tmp_dir),
          do: ["--file", Path.join(tmp_dir, "docker-compose.yml")],
          else: []
        ) ++
        ["ps", "--format", "json"]

    case System.cmd(runtime, args,
           stderr_to_stdout: true,
           env: OptimalSystemAgent.OS.Env.cmd_env()
         ) do
      {output, 0} ->
        services = parse_ps_json(output)
        {:ok, services}

      {err, _} ->
        {:error, "ps_failed: #{String.trim(err)}"}
    end
  rescue
    e -> {:error, "ps_error: #{Exception.message(e)}"}
  end

  # ── compose logs streaming ────────────────────────────────────────────────────

  defp start_log_stream(runtime, project_id, name, service_name) do
    tmp_dir = project_tmp_dir(project_id)

    args =
      ["compose", "--project-name", name] ++
        if(File.exists?(tmp_dir),
          do: ["--file", Path.join(tmp_dir, "docker-compose.yml")],
          else: []
        ) ++
        ["logs", "-f", "--timestamps"] ++
        if service_name, do: [service_name], else: []

    executable = System.find_executable(runtime)

    Port.open(
      {:spawn_executable, executable},
      [
        :binary,
        :exit_status,
        {:args, args},
        {:env, OptimalSystemAgent.OS.Env.port_env()},
        :stderr_to_stdout
      ]
    )
  rescue
    e ->
      Logger.warning("[Compose] failed to open log port: #{Exception.message(e)}")
      nil
  end

  defp stop_log_stream(state, project_id) do
    case get_in(state.projects, [project_id]) do
      %{log_port: port} when not is_nil(port) ->
        Port.close(port)
        put_in(state.projects[project_id].log_port, nil)

      _ ->
        state
    end
  rescue
    _ -> state
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  defp run_compose_cmd(runtime, name, tmp_dir, subargs) do
    args =
      ["compose", "--project-name", name] ++
        if(File.exists?(tmp_dir),
          do: ["--file", Path.join(tmp_dir, "docker-compose.yml")],
          else: []
        ) ++
        subargs

    Logger.info("[Compose] #{runtime} #{Enum.join(args, " ")}")

    # compose interpolates `${VAR}` from the CLIENT environment into the
    # compose file, so a workspace-supplied compose file can read any variable
    # this process holds. Scrub before handing it the file.
    case System.cmd(runtime, args,
           cd: tmp_dir,
           stderr_to_stdout: true,
           env: OptimalSystemAgent.OS.Env.cmd_env()
         ) do
      {_out, 0} -> :ok
      {err, _} -> {:error, String.trim(err)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp parse_ps_json(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, obj} when is_map(obj) ->
          [
            %{
              "name" => obj["Service"] || obj["Name"] || "",
              "container_id" => obj["ID"] || obj["ContainerID"] || "",
              "state" => obj["State"] || obj["Status"] || "unknown"
            }
          ]

        {:ok, arr} when is_list(arr) ->
          Enum.map(arr, fn obj ->
            %{
              "name" => obj["Service"] || obj["Name"] || "",
              "container_id" => obj["ID"] || obj["ContainerID"] || "",
              "state" => obj["State"] || obj["Status"] || "unknown"
            }
          end)

        _ ->
          []
      end
    end)
  end

  # Parse compose log lines: "service_name  | log content"
  defp extract_service_prefix(line) do
    case Regex.run(~r/^([a-zA-Z0-9_\-]+)-\d+\s+\|\s+(.*)$/, line) do
      [_, service, rest] ->
        {service, rest}

      _ ->
        case Regex.run(~r/^([a-zA-Z0-9_\-]+)\s+\|\s+(.*)$/, line) do
          [_, service, rest] -> {service, rest}
          _ -> {"default", line}
        end
    end
  end

  defp extract_timestamp(line) do
    case Regex.run(~r/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z)\s+(.*)$/, line) do
      [_, ts, rest] -> {ts, rest}
      _ -> {DateTime.utc_now() |> DateTime.to_iso8601(), line}
    end
  end

  defp emit_progress(server, project_id, phase, message) do
    GenServer.cast(server, {:compose_progress, project_id, phase, message})
  end

  defp project_tmp_dir(project_id) do
    Path.join(base_tmp(), project_id)
  end

  defp project_tmp_dir_by_name(name) do
    # When we have only the project name (not ID), we can't determine the exact dir.
    # This is a fallback used by ps when tmp_dir may not exist.
    Path.join(base_tmp(), name)
  end

  defp cleanup_tmp(state, project_id) do
    tmp_dir = project_tmp_dir(project_id)
    File.rm_rf(tmp_dir)
    %{state | projects: Map.delete(state.projects, project_id)}
  rescue
    _ -> %{state | projects: Map.delete(state.projects, project_id)}
  end

  defp get_project_name(state, project_id) do
    case get_in(state.projects, [project_id]) do
      %{name: name} -> name
      _ -> project_id
    end
  end

  defp send_error(project_id, reason, phase) do
    FrameRouter.send_frame(
      {:compose_error, %{project_id: project_id, reason: reason, phase: phase}}
    )
  end
end
