defmodule OptimalSystemAgent.Python.Sidecar do
  @moduledoc """
  GenServer managing the Python sidecar process via an Erlang Port.

  Communicates over newline-delimited JSON-RPC on stdio.
  Auto-restarts on crash, health checks every 60s.
  """
  use GenServer
  require Logger

  alias OptimalSystemAgent.Sidecar.Protocol

  @health_interval 60_000
  @request_timeout 30_000

  # -- Client API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Send a JSON-RPC request to the Python sidecar."
  @spec request(String.t(), map(), non_neg_integer()) :: {:ok, any()} | {:error, atom()}
  def request(method, params \\ %{}, timeout \\ @request_timeout) do
    GenServer.call(__MODULE__, {:request, method, params}, timeout + 500)
  catch
    :exit, _ -> {:error, :timeout}
  end

  @doc "Check if the sidecar is available."
  @spec available?() :: boolean()
  def available? do
    GenServer.call(__MODULE__, :available?)
  catch
    :exit, _ -> false
  end

  # -- GenServer callbacks --

  @impl true
  def init(_opts) do
    state = %{
      port: nil,
      mode: :starting,
      pending: %{},  # id => {from, timer_ref}
      python_path: Application.get_env(:optimal_system_agent, :python_path, "python3")
    }

    state = start_sidecar(state)
    schedule_health_check()

    {:ok, state}
  end

  @impl true
  def handle_call({:request, _method, _params}, _from, %{mode: :unavailable} = state) do
    {:reply, {:error, :sidecar_unavailable}, state}
  end

  def handle_call({:request, method, params}, from, %{mode: :ready, port: port} = state) do
    {id, encoded} = Protocol.encode_request(method, params)
    Port.command(port, encoded)

    timer_ref = Process.send_after(self(), {:request_timeout, id}, @request_timeout)
    pending = Map.put(state.pending, id, {from, timer_ref})

    {:noreply, %{state | pending: pending}}
  end

  def handle_call({:request, _method, _params}, _from, state) do
    {:reply, {:error, :sidecar_not_ready}, state}
  end

  @impl true
  def handle_call(:available?, _from, state) do
    {:reply, state.mode == :ready, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    case Protocol.decode_response(line) do
      {:ok, id, result} ->
        # Check if this is the ping response during startup
        state = if state.mode == :starting, do: %{state | mode: :ready}, else: state
        resolve_pending(state, id, {:ok, result})

      {:error, id, error} when is_binary(id) ->
        msg = Map.get(error, "message", "unknown error")
        resolve_pending(state, id, {:error, {:sidecar_error, msg}})

      {:error, :invalid, reason} ->
        Logger.warning("[Python.Sidecar] Invalid response: #{reason}")
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("[Python.Sidecar] Port exited with status #{status}")
    state = fail_all_pending(state, :port_crashed)

    # Attempt restart after delay
    Process.send_after(self(), :restart_sidecar, 5_000)

    {:noreply, %{state | port: nil, mode: :unavailable}}
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

  def handle_info(:health_check, %{mode: :ready} = state) do
    # Send a ping to verify the sidecar is responsive
    {_id, encoded} = Protocol.encode_request("ping")
    try do
      Port.command(state.port, encoded)
    catch
      _, _ -> :ok
    end

    # Don't track this ping as a pending request — just fire and forget
    # If the port is dead, we'll get an exit_status message
    schedule_health_check()
    {:noreply, state}
  end

  def handle_info(:health_check, state) do
    schedule_health_check()
    {:noreply, state}
  end

  def handle_info(:restart_sidecar, state) do
    state = start_sidecar(%{state | port: nil})
    if state.mode != :unavailable do
      Logger.info("[Python.Sidecar] Restarted successfully")
    end
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when not is_nil(port) do
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end
    :ok
  end
  def terminate(_reason, _state), do: :ok

  # -- Private --

  defp start_sidecar(state) do
    script_path = sidecar_script_path()

    if File.exists?(script_path) do
      try do
        port = Port.open(
          {:spawn_executable, state.python_path},
          [
            :binary, :use_stdio, :exit_status,
            {:line, 1_048_576},
            {:args, [script_path]}
          ]
        )

        # Send initial ping to verify the sidecar is alive
        {_id, encoded} = Protocol.encode_request("ping")
        Port.command(port, encoded)

        Logger.info("[Python.Sidecar] Started, waiting for ping response...")
        %{state | port: port, mode: :starting}
      rescue
        e ->
          Logger.warning("[Python.Sidecar] Failed to start: #{inspect(e)}")
          %{state | port: nil, mode: :unavailable}
      end
    else
      Logger.info("[Python.Sidecar] Script not found at #{script_path}, marking unavailable")
      %{state | port: nil, mode: :unavailable}
    end
  end

  defp sidecar_script_path do
    Path.join([:code.priv_dir(:optimal_system_agent) |> to_string(), "python", "sidecar.py"])
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_interval)
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
