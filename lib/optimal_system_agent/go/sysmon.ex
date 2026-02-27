defmodule OptimalSystemAgent.Go.Sysmon do
  @moduledoc """
  GenServer wrapping the Go osa-sysmon sidecar for system metrics collection.

  Exposes cpu_percent, memory_info, disk_usage, and process_list via the
  shared JSON-RPC stdio protocol. Returns `{:error, :sidecar_unavailable}`
  when the binary is missing — system metrics have no meaningful in-process
  fallback.

  Binary search order:
    1. priv/go/sysmon/osa-sysmon  (in-tree, dev)
    2. ~/.osa/bin/osa-sysmon      (installed)
  """
  use GenServer
  require Logger

  @behaviour OptimalSystemAgent.Sidecar.Behaviour

  alias OptimalSystemAgent.Sidecar.{Protocol, Registry}

  @request_timeout 3_000

  # -- Client API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # -- Sidecar.Behaviour callbacks --

  @impl OptimalSystemAgent.Sidecar.Behaviour
  def call(method, params, timeout \\ @request_timeout) do
    GenServer.call(__MODULE__, {:request, method, params}, timeout + 500)
  catch
    :exit, _ -> {:error, :timeout}
  end

  @impl OptimalSystemAgent.Sidecar.Behaviour
  def health_check do
    if Process.whereis(__MODULE__) == nil do
      :unavailable
    else
      case GenServer.call(__MODULE__, :health, 2_000) do
        :ready -> :ready
        :fallback -> :degraded
        _ -> :unavailable
      end
    end
  catch
    :exit, _ -> :unavailable
  end

  @impl OptimalSystemAgent.Sidecar.Behaviour
  def capabilities, do: [:system_cpu, :system_memory, :system_disk, :system_processes]

  @doc """
  Return per-core CPU utilisation.

      {:ok, %{"percent" => [45.2, 30.1, ...], "count" => 8}}
  """
  @spec cpu_percent() :: {:ok, map()} | {:error, atom()}
  def cpu_percent do
    call("cpu_percent", %{})
  end

  @doc """
  Return virtual memory statistics.

      {:ok, %{"total" => N, "available" => N, "used" => N, "percent" => 50.0}}
  """
  @spec memory_info() :: {:ok, map()} | {:error, atom()}
  def memory_info do
    call("memory_info", %{})
  end

  @doc """
  Return disk usage for `path` (defaults to "/").

      {:ok, %{"total" => N, "free" => N, "used" => N, "percent" => 50.0}}
  """
  @spec disk_usage(String.t()) :: {:ok, map()} | {:error, atom()}
  def disk_usage(path \\ "/") do
    call("disk_usage", %{"path" => path})
  end

  @doc """
  Return a snapshot of running processes.

      {:ok, %{"processes" => [%{"pid" => 1, "name" => "init", ...}], "count" => 200}}
  """
  @spec process_list() :: {:ok, map()} | {:error, atom()}
  def process_list do
    call("process_list", %{})
  end

  # -- GenServer callbacks --

  @impl true
  def init(_opts) do
    binary_path = find_binary()

    state = %{
      port: nil,
      mode: :fallback,
      binary_path: binary_path,
      # id => {from, timer_ref}
      pending: %{}
    }

    state = maybe_start_port(state)

    Registry.register(__MODULE__, capabilities())
    Registry.update_health(__MODULE__, if(state.mode == :ready, do: :ready, else: :degraded))

    if state.mode == :ready do
      Logger.info("[Go.Sysmon] Started with binary at #{binary_path}")
    else
      Logger.info("[Go.Sysmon] Binary not found — system metrics unavailable")
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:health, _from, state) do
    {:reply, state.mode, state}
  end

  def handle_call(:available?, _from, state) do
    {:reply, state.mode == :ready, state}
  end

  # Generic request dispatch (satisfies Sidecar.Behaviour call/3).
  def handle_call({:request, _method, _params}, _from, %{mode: :fallback} = state) do
    {:reply, {:error, :sidecar_unavailable}, state}
  end

  def handle_call({:request, method, params}, from, %{mode: :ready, port: port} = state) do
    {id, encoded} = Protocol.encode_request(method, params)
    Port.command(port, encoded)

    timer_ref = Process.send_after(self(), {:request_timeout, id}, @request_timeout)
    pending = Map.put(state.pending, id, {from, timer_ref})

    {:noreply, %{state | pending: pending}}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    case Protocol.decode_response(line) do
      {:ok, id, result} ->
        resolve_pending(state, id, {:ok, result})

      {:error, id, _error} when is_binary(id) ->
        resolve_pending(state, id, {:error, :sidecar_error})

      {:error, :invalid, reason} ->
        Logger.warning("[Go.Sysmon] Invalid response: #{reason}")
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("[Go.Sysmon] Port exited with status #{status}, will retry in 5s")

    state = fail_all_pending(state, :port_crashed)
    Process.send_after(self(), :restart_port, 5_000)

    {:noreply, %{state | port: nil, mode: :fallback}}
  end

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {{from, _timer_ref}, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  def handle_info(:restart_port, state) do
    state = maybe_start_port(%{state | port: nil})

    if state.mode == :ready do
      Logger.info("[Go.Sysmon] Port restarted successfully")
      Registry.update_health(__MODULE__, :ready)
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port} = _state) when not is_nil(port) do
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  # -- Private --

  defp maybe_start_port(%{binary_path: nil} = state), do: state

  defp maybe_start_port(%{binary_path: path} = state) do
    if File.exists?(path) do
      try do
        port =
          Port.open(
            {:spawn_executable, path},
            [:binary, :use_stdio, :exit_status, {:line, 1_048_576}]
          )

        %{state | port: port, mode: :ready}
      rescue
        e ->
          Logger.warning("[Go.Sysmon] Failed to start port: #{inspect(e)}")
          state
      end
    else
      state
    end
  end

  defp find_binary do
    priv_path =
      :code.priv_dir(:optimal_system_agent)
      |> to_string()
      |> Path.join(["go", "sysmon", "osa-sysmon"])

    installed_path = Path.expand("~/.osa/bin/osa-sysmon")

    cond do
      File.exists?(priv_path) -> priv_path
      File.exists?(installed_path) -> installed_path
      true -> nil
    end
  end

  defp resolve_pending(state, id, result) do
    case Map.pop(state.pending, id) do
      {{from, timer_ref}, pending} ->
        Process.cancel_timer(timer_ref)
        GenServer.reply(from, result)
        {:noreply, %{state | pending: pending}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  defp fail_all_pending(state, reason) do
    Enum.each(state.pending, fn {_id, {from, timer_ref}} ->
      Process.cancel_timer(timer_ref)
      GenServer.reply(from, {:error, reason})
    end)

    %{state | pending: %{}}
  end
end
