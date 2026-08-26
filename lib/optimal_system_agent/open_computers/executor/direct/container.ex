defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Container do
  @moduledoc """
  Docker/Podman container executor for the OpenComputers direct-mode protocol.

  One GenServer per session. Tracks all active containers and manages their
  full lifecycle: run, log streaming, stats polling, stop, and remove.

  ## Runtime selection

  On first use, the executor probes for Docker and Podman. Docker is preferred
  when both are available. If neither is found, `:runtime_not_available` is
  emitted. The detected runtime is cached for the session lifetime.

  ## Wire protocol handled

    Inbound (MIOSA → OSA):
      {:container_run_request, %{container_id, image, name, ports, env, volumes,
                                  command, restart_policy, runtime}}
      {:container_logs_subscribe, %{container_id}}
      {:container_logs_unsubscribe, %{container_id}}
      {:container_stop_request, %{container_id, timeout_s}}
      {:container_remove_request, %{container_id, force}}

    Outbound (OSA → MIOSA):
      {:container_started, %{container_id, container_runtime_id, started_at,
                              ip, ports_resolved}}
      {:container_log_line, %{container_id, stream, line, ts}}
      {:container_stats, %{container_id, cpu_percent, mem_mb, net_rx, net_tx,
                            disk_read, disk_write}}
      {:container_stopped, %{container_id, exit_code, stopped_at}}
      {:container_removed, %{container_id}}
      {:container_error, %{container_id, reason, phase}}

  ## Session disconnect behaviour

  Containers are NOT stopped when the OSA session disconnects — they run
  independently. Only explicit `container_stop_request` or
  `container_remove_request` frames stop/remove containers.

  ## Stats polling

  Every 10 seconds (configurable via `@stats_interval_ms`), the executor runs
  `docker stats --no-stream` on all running containers and emits
  `container_stats` frames. Stopped containers are silently skipped.

  ## Port conflict detection

  Before launching a container, `docker ps --format '{{.Ports}}'` is parsed to
  find currently bound host ports. A conflict emits `:port_conflict`.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.OpenComputers.FrameRouter

  @stats_interval_ms 10_000

  # ── Container record ──────────────────────────────────────────────────────────

  defstruct [
    # MIOSA-assigned UUID
    :container_id,
    # Docker/Podman runtime ID (64-char hex)
    :runtime_id,
    :name,
    :image,
    # Task pid streaming logs (nil if not subscribed)
    :log_task,
    # :running | :stopped
    state: :running
  ]

  # ── Public API ────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.merge([name: __MODULE__], opts))
  end

  @doc "Handle an inbound container frame dispatched by FrameRouter."
  @spec handle_frame(term()) :: :ok
  def handle_frame(frame) do
    GenServer.cast(__MODULE__, {:inbound, frame})
  end

  # ── GenServer ─────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    state = %{
      # Detected runtime binary: "docker" | "podman" | nil (not yet detected)
      runtime: nil,
      # %{container_id => %Container{}}
      containers: %{},
      # Timer ref for stats polling
      stats_timer: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:inbound, {:container_run_request, payload}}, state) do
    container_id = payload.container_id

    {runtime, state} = ensure_runtime(state, Map.get(payload, :runtime, "auto"))

    case runtime do
      nil ->
        send_error(container_id, :runtime_not_available, :pre_flight)
        {:noreply, state}

      runtime_bin ->
        self_pid = self()

        Task.start(fn ->
          do_run(self_pid, runtime_bin, container_id, payload)
        end)

        {:noreply, state}
    end
  end

  def handle_cast({:inbound, {:container_logs_subscribe, %{container_id: cid}}}, state) do
    state =
      case Map.get(state.containers, cid) do
        nil ->
          Logger.debug("[Container] logs_subscribe for unknown container #{cid} — ignored")
          state

        %__MODULE__{log_task: nil} = c ->
          runtime = state.runtime || detect_runtime()
          task = start_log_stream(runtime, c.runtime_id, cid)
          put_in(state.containers[cid], %{c | log_task: task})

        _already_streaming ->
          state
      end

    {:noreply, state}
  end

  def handle_cast({:inbound, {:container_logs_unsubscribe, %{container_id: cid}}}, state) do
    state =
      case Map.get(state.containers, cid) do
        nil ->
          state

        %__MODULE__{log_task: task} = c when not is_nil(task) ->
          Process.exit(task, :kill)
          put_in(state.containers[cid], %{c | log_task: nil})

        _no_stream ->
          state
      end

    {:noreply, state}
  end

  def handle_cast({:inbound, {:container_stop_request, %{container_id: cid} = payload}}, state) do
    timeout_s = Map.get(payload, :timeout_s, 10)

    case Map.get(state.containers, cid) do
      nil ->
        send_error(cid, :not_found, :stop)

      %__MODULE__{runtime_id: rid} ->
        runtime = state.runtime || detect_runtime()

        Task.start(fn ->
          do_stop(runtime, rid, cid, timeout_s)
        end)
    end

    {:noreply, state}
  end

  def handle_cast(
        {:inbound, {:container_remove_request, %{container_id: cid} = payload}},
        state
      ) do
    force = Map.get(payload, :force, false)

    case Map.get(state.containers, cid) do
      nil ->
        send_error(cid, :not_found, :remove)

      %__MODULE__{runtime_id: rid} ->
        runtime = state.runtime || detect_runtime()

        Task.start(fn ->
          do_remove(runtime, rid, cid, force)
        end)
    end

    {:noreply, state}
  end

  def handle_cast({:inbound, _frame}, state), do: {:noreply, state}

  # ── Internal messages from Tasks ──────────────────────────────────────────────

  # Container successfully started
  def handle_cast({:container_started, container_id, runtime_id, ports_resolved}, state) do
    c = %__MODULE__{
      container_id: container_id,
      runtime_id: runtime_id,
      name: runtime_id,
      image: "",
      log_task: nil,
      state: :running
    }

    state = put_in(state.containers[container_id], c)
    state = ensure_stats_timer(state)

    FrameRouter.send_frame(
      {:container_started,
       %{
         container_id: container_id,
         container_runtime_id: runtime_id,
         started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
         ip: nil,
         ports_resolved: ports_resolved
       }}
    )

    {:noreply, state}
  end

  # Container stopped (from stop Task)
  def handle_cast({:container_stopped, container_id, exit_code}, state) do
    state =
      case Map.get(state.containers, container_id) do
        nil -> state
        c -> put_in(state.containers[container_id], %{c | state: :stopped})
      end

    FrameRouter.send_frame(
      {:container_stopped,
       %{
         container_id: container_id,
         exit_code: exit_code,
         stopped_at: DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    )

    {:noreply, state}
  end

  # Container removed
  def handle_cast({:container_removed, container_id}, state) do
    state = %{state | containers: Map.delete(state.containers, container_id)}
    FrameRouter.send_frame({:container_removed, %{container_id: container_id}})
    {:noreply, state}
  end

  # Run error
  def handle_cast({:container_run_error, container_id, reason}, state) do
    send_error(container_id, reason, :start)
    {:noreply, state}
  end

  # Port conflict detected before run
  def handle_cast({:container_port_conflict, container_id}, state) do
    send_error(container_id, :port_conflict, :pre_flight)
    {:noreply, state}
  end

  # Stats emission keyed by runtime_id → look up container_id in state
  def handle_cast(
        {:emit_stats_for_runtime_id, runtime_id, cpu, mem_mb, net_rx, net_tx, disk_read,
         disk_write},
        state
      ) do
    case Enum.find(state.containers, fn {_id, c} -> c.runtime_id == runtime_id end) do
      nil ->
        {:noreply, state}

      {container_id, _c} ->
        FrameRouter.send_frame(
          {:container_stats,
           %{
             container_id: container_id,
             cpu_percent: cpu,
             mem_mb: mem_mb,
             net_rx: net_rx,
             net_tx: net_tx,
             disk_read: disk_read,
             disk_write: disk_write
           }}
        )

        {:noreply, state}
    end
  end

  # Stats tick: emit stats for all running containers
  @impl true
  def handle_info(:stats_tick, state) do
    running =
      state.containers
      |> Enum.filter(fn {_id, c} -> c.state == :running end)
      |> Enum.map(fn {_id, c} -> c.runtime_id end)

    if running != [] do
      runtime = state.runtime || detect_runtime()
      Task.start(fn -> emit_stats(runtime, running) end)
    end

    # Reschedule
    ref = Process.send_after(self(), :stats_tick, @stats_interval_ms)
    {:noreply, %{state | stats_timer: ref}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Runtime detection ─────────────────────────────────────────────────────────

  defp ensure_runtime(%{runtime: nil} = state, requested) do
    runtime = detect_runtime_for_request(requested)
    {runtime, %{state | runtime: runtime}}
  end

  defp ensure_runtime(%{runtime: r} = state, _requested) when not is_nil(r) do
    {r, state}
  end

  defp detect_runtime_for_request("docker") do
    if runtime_available?("docker"), do: "docker", else: nil
  end

  defp detect_runtime_for_request("podman") do
    if runtime_available?("podman"), do: "podman", else: nil
  end

  defp detect_runtime_for_request(_auto) do
    # Prefer docker, fall back to podman
    cond do
      runtime_available?("docker") -> "docker"
      runtime_available?("podman") -> "podman"
      true -> nil
    end
  end

  defp detect_runtime do
    cond do
      runtime_available?("docker") -> "docker"
      runtime_available?("podman") -> "podman"
      true -> nil
    end
  end

  defp runtime_available?(binary) do
    case System.cmd(binary, ["version", "--format", "{{.Client.Version}}"],
           stderr_to_stdout: true
         ) do
      {_out, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  # ── Container run (in Task) ───────────────────────────────────────────────────

  defp do_run(server_pid, runtime, container_id, payload) do
    %{
      image: image,
      name: name,
      ports: ports,
      env: env,
      volumes: volumes,
      restart_policy: restart_policy
    } = payload

    command = Map.get(payload, :command, [])

    # Pre-flight: check port conflicts
    case check_port_conflicts(runtime, ports) do
      {:conflict, port} ->
        Logger.warning("[Container] port conflict on port #{port} for container #{container_id}")
        GenServer.cast(server_pid, {:container_port_conflict, container_id})

      :ok ->
        args = build_run_args(name, restart_policy, ports, env, volumes, image, command)

        Logger.info("[Container] running: #{runtime} #{Enum.join(args, " ")}")

        # `docker run -e FOO` with no value FORWARDS the daemon client's own
        # FOO into the container, so an unscrubbed env here is a direct path
        # from the operator's credentials into an arbitrary image.
        case System.cmd(runtime, args,
               stderr_to_stdout: false,
               env: OptimalSystemAgent.OS.Env.cmd_env()
             ) do
          {runtime_id, 0} ->
            runtime_id = String.trim(runtime_id)
            ports_resolved = resolve_ports(runtime, runtime_id)

            GenServer.cast(
              server_pid,
              {:container_started, container_id, runtime_id, ports_resolved}
            )

          {stderr, exit_code} ->
            Logger.warning(
              "[Container] run failed exit=#{exit_code} stderr=#{String.trim(stderr)}"
            )

            reason =
              cond do
                String.contains?(stderr, "pull") -> :image_pull_failed
                String.contains?(stderr, "Conflict") -> :port_conflict
                true -> :start_failed
              end

            GenServer.cast(server_pid, {:container_run_error, container_id, reason})
        end
    end
  end

  defp build_run_args(name, restart_policy, ports, env, volumes, image, command) do
    base = ["run", "-d", "--name", name, "--restart", restart_policy]

    port_args =
      Enum.flat_map(ports, fn port ->
        hp = to_string(port["host_port"] || port[:host_port])
        cp = to_string(port["container_port"] || port[:container_port])
        proto = port["protocol"] || port[:protocol] || "tcp"
        ["-p", "#{hp}:#{cp}/#{proto}"]
      end)

    env_args =
      Enum.flat_map(env, fn {k, v} ->
        ["-e", "#{k}=#{v}"]
      end)

    volume_args =
      Enum.flat_map(volumes, fn vol ->
        src = vol["source"] || vol[:source]
        tgt = vol["target"] || vol[:target]
        ro = vol["readonly"] || vol[:readonly] || false
        suffix = if ro, do: ":ro", else: ""
        ["-v", "#{src}:#{tgt}#{suffix}"]
      end)

    image_and_cmd = [image | List.wrap(command)]

    base ++ port_args ++ env_args ++ volume_args ++ image_and_cmd
  end

  defp check_port_conflicts(_runtime, []), do: :ok

  defp check_port_conflicts(runtime, ports) do
    # Get all currently bound host ports
    case System.cmd(runtime, ["ps", "--format", "{{.Ports}}"], stderr_to_stdout: true) do
      {output, 0} ->
        bound_ports =
          output
          |> String.split("\n")
          |> Enum.flat_map(&extract_host_ports/1)
          |> MapSet.new()

        requested =
          Enum.map(ports, fn p ->
            parse_port_int(p["host_port"] || p[:host_port])
          end)

        case Enum.find(requested, fn p -> MapSet.member?(bound_ports, p) end) do
          nil -> :ok
          conflict_port -> {:conflict, conflict_port}
        end

      _ ->
        # Cannot check — allow the run to proceed; Docker will fail with a clear error
        :ok
    end
  end

  # Parses "0.0.0.0:5432->5432/tcp, :::5432->5432/tcp" → [5432]
  defp extract_host_ports(""), do: []

  defp extract_host_ports(ports_str) do
    ports_str
    |> String.split(",")
    |> Enum.flat_map(fn binding ->
      case Regex.run(~r/:(\d+)->/, String.trim(binding)) do
        [_, port_str] ->
          case Integer.parse(port_str) do
            {p, ""} -> [p]
            _ -> []
          end

        _ ->
          []
      end
    end)
  end

  defp resolve_ports(runtime, runtime_id) do
    case System.cmd(
           runtime,
           ["inspect", "--format", "{{json .NetworkSettings.Ports}}", runtime_id],
           stderr_to_stdout: true
         ) do
      {json, 0} ->
        case Jason.decode(String.trim(json)) do
          {:ok, ports_map} ->
            Enum.flat_map(ports_map, fn {key, bindings} ->
              [container_port_str, proto] = String.split(key, "/")

              Enum.map(List.wrap(bindings), fn b ->
                %{
                  "host_port" => parse_port_int(b["HostPort"]),
                  "container_port" => parse_port_int(container_port_str),
                  "protocol" => proto,
                  "host_ip" => b["HostIp"]
                }
              end)
            end)

          _ ->
            []
        end

      _ ->
        []
    end
  end

  defp parse_port_int(v) when is_integer(v), do: v

  defp parse_port_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      _ -> 0
    end
  end

  defp parse_port_int(_), do: 0

  # ── Container stop (in Task) ──────────────────────────────────────────────────

  defp do_stop(runtime, runtime_id, container_id, timeout_s) do
    args = ["stop", "-t", to_string(timeout_s), runtime_id]

    case System.cmd(runtime, args, stderr_to_stdout: true) do
      {_out, 0} ->
        # Get exit code from inspect
        exit_code = get_exit_code(runtime, runtime_id)
        GenServer.cast(__MODULE__, {:container_stopped, container_id, exit_code})

      {stderr, exit_code} ->
        Logger.warning("[Container] stop failed runtime_id=#{runtime_id}: #{String.trim(stderr)}")

        if exit_code == 1 and String.contains?(stderr, "No such container") do
          # Already gone — treat as stopped
          GenServer.cast(__MODULE__, {:container_stopped, container_id, -1})
        else
          send_error(container_id, :start_failed, :stop)
        end
    end
  end

  defp get_exit_code(runtime, runtime_id) do
    case System.cmd(runtime, ["inspect", "--format", "{{.State.ExitCode}}", runtime_id],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case Integer.parse(String.trim(out)) do
          {code, _} -> code
          _ -> 0
        end

      _ ->
        0
    end
  end

  # ── Container remove (in Task) ────────────────────────────────────────────────

  defp do_remove(runtime, runtime_id, container_id, force) do
    args = if force, do: ["rm", "-f", runtime_id], else: ["rm", runtime_id]

    case System.cmd(runtime, args, stderr_to_stdout: true) do
      {_out, 0} ->
        GenServer.cast(__MODULE__, {:container_removed, container_id})

      {stderr, _} ->
        if String.contains?(stderr, "No such container") do
          # Already gone — emit removed anyway
          GenServer.cast(__MODULE__, {:container_removed, container_id})
        else
          Logger.warning(
            "[Container] remove failed runtime_id=#{runtime_id}: #{String.trim(stderr)}"
          )

          send_error(container_id, :not_found, :remove)
        end
    end
  end

  # ── Log streaming (in Task) ───────────────────────────────────────────────────

  defp start_log_stream(nil, _runtime_id, container_id) do
    Logger.warning("[Container] cannot stream logs — runtime not detected")
    send_error(container_id, :runtime_not_available, :logs)
    nil
  end

  defp start_log_stream(runtime, runtime_id, container_id) do
    _parent = self()

    spawn_link(fn ->
      stream_logs(runtime, runtime_id, container_id)
    end)
  end

  defp stream_logs(runtime, runtime_id, container_id) do
    port =
      Port.open(
        {:spawn_executable, System.find_executable(runtime)},
        [
          :binary,
          :exit_status,
          {:args, ["logs", "-f", "--timestamps", runtime_id]},
          # `{:env, []}` is an EMPTY OVERLAY — it inherits everything. Scrub.
          {:env, OptimalSystemAgent.OS.Env.port_env()},
          :stderr_to_stdout
        ]
      )

    receive_log_lines(port, container_id, "stdout")
  end

  defp receive_log_lines(port, container_id, default_stream) do
    receive do
      {^port, {:data, data}} ->
        data
        |> String.split("\n", trim: true)
        |> Enum.each(fn line ->
          # docker logs --timestamps format: "2026-01-01T00:00:00.000Z line..."
          {ts, stripped} = extract_timestamp(line)

          FrameRouter.send_frame(
            {:container_log_line,
             %{
               container_id: container_id,
               stream: default_stream,
               line: stripped,
               ts: ts
             }}
          )
        end)

        receive_log_lines(port, container_id, default_stream)

      {^port, {:exit_status, _code}} ->
        Logger.debug("[Container] log stream ended container=#{container_id}")

      _other ->
        receive_log_lines(port, container_id, default_stream)
    end
  end

  defp extract_timestamp(line) do
    case Regex.run(~r/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z)\s+(.*)$/, line) do
      [_, ts, rest] -> {ts, rest}
      _ -> {DateTime.utc_now() |> DateTime.to_iso8601(), line}
    end
  end

  # ── Stats polling (in Task) ───────────────────────────────────────────────────

  defp emit_stats(nil, _runtime_ids), do: :ok

  defp emit_stats(runtime, runtime_ids) do
    # docker stats --no-stream --format "{{.ID}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}"
    args =
      [
        "stats",
        "--no-stream",
        "--format",
        "{{.ID}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}"
      ] ++
        runtime_ids

    case System.cmd(runtime, args, stderr_to_stdout: true) do
      {output, 0} ->
        # Match runtime_id → container_id via GenServer state isn't available in Task
        # So we emit stats keyed by runtime_id and let HostServer match them
        output
        |> String.split("\n", trim: true)
        |> Enum.each(fn line ->
          parse_and_emit_stats_line(line)
        end)

      {err, _} ->
        Logger.debug("[Container] stats poll error: #{String.trim(err)}")
    end
  end

  defp parse_and_emit_stats_line(line) do
    parts = String.split(line, "\t")

    case parts do
      [runtime_id, cpu_str, mem_str, net_str, block_str | _] ->
        cpu = parse_percent(cpu_str)
        mem_mb = parse_mem_mb(mem_str)
        {net_rx, net_tx} = parse_io_pair(net_str)
        {disk_read, disk_write} = parse_io_pair(block_str)

        # We need the MIOSA container_id. We send it via the GenServer.
        GenServer.cast(
          __MODULE__,
          {:emit_stats_for_runtime_id, runtime_id, cpu, mem_mb, net_rx, net_tx, disk_read,
           disk_write}
        )

      _ ->
        :ok
    end
  end

  # ── Stats parsing helpers ──────────────────────────────────────────────────────

  defp parse_percent(s) do
    case Float.parse(String.trim_trailing(s, "%")) do
      {f, _} -> f
      _ -> 0.0
    end
  end

  defp parse_mem_mb(s) do
    # "256MiB / 8GiB"  — take the left side
    [used | _] = String.split(s, "/")
    parse_bytes_to_mb(String.trim(used))
  end

  defp parse_bytes_to_mb(s) do
    cond do
      String.ends_with?(s, "GiB") ->
        case Float.parse(String.trim_trailing(s, "GiB")) do
          {n, _} -> round(n * 1024)
          _ -> 0
        end

      String.ends_with?(s, "MiB") ->
        case Float.parse(String.trim_trailing(s, "MiB")) do
          {n, _} -> round(n)
          _ -> 0
        end

      String.ends_with?(s, "kB") ->
        case Float.parse(String.trim_trailing(s, "kB")) do
          {n, _} -> round(n / 1024)
          _ -> 0
        end

      true ->
        0
    end
  end

  defp parse_io_pair(s) do
    # "1.5kB / 2.0kB" → {rx_bytes, tx_bytes}
    case String.split(s, "/") do
      [rx, tx] -> {parse_bytes(String.trim(rx)), parse_bytes(String.trim(tx))}
      _ -> {0, 0}
    end
  end

  defp parse_bytes(s) do
    cond do
      String.ends_with?(s, "GB") ->
        case Float.parse(String.trim_trailing(s, "GB")) do
          {n, _} -> round(n * 1_000_000_000)
          _ -> 0
        end

      String.ends_with?(s, "MB") ->
        case Float.parse(String.trim_trailing(s, "MB")) do
          {n, _} -> round(n * 1_000_000)
          _ -> 0
        end

      String.ends_with?(s, "kB") ->
        case Float.parse(String.trim_trailing(s, "kB")) do
          {n, _} -> round(n * 1_000)
          _ -> 0
        end

      String.ends_with?(s, "B") ->
        case Float.parse(String.trim_trailing(s, "B")) do
          {n, _} -> round(n)
          _ -> 0
        end

      true ->
        0
    end
  end

  # ── Stats timer management ────────────────────────────────────────────────────

  defp ensure_stats_timer(%{stats_timer: nil} = state) do
    ref = Process.send_after(self(), :stats_tick, @stats_interval_ms)
    %{state | stats_timer: ref}
  end

  defp ensure_stats_timer(state), do: state

  # ── Error helper ──────────────────────────────────────────────────────────────

  defp send_error(container_id, reason, phase) do
    FrameRouter.send_frame(
      {:container_error, %{container_id: container_id, reason: reason, phase: phase}}
    )
  end
end
