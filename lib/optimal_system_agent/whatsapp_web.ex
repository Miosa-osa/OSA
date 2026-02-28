defmodule OptimalSystemAgent.WhatsAppWeb do
  @moduledoc """
  GenServer wrapping a Node.js Baileys process for WhatsApp Web connectivity.

  Uses the same JSON-RPC over stdio protocol as Go sidecars.
  Manages QR code display, message relay, and session persistence.

  The Node.js sidecar is expected at:
    priv/sidecar/baileys/index.js  (with node_modules installed)
  """
  use GenServer
  require Logger

  @behaviour OptimalSystemAgent.Sidecar.Behaviour

  alias OptimalSystemAgent.Channels.Session
  alias OptimalSystemAgent.Sidecar.{Protocol, Registry}
  alias OptimalSystemAgent.Agent.Loop

  @request_timeout 30_000

  # -- Client API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

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
      case GenServer.call(__MODULE__, :health, 5_000) do
        :connected -> :ready
        :qr -> :degraded
        _ -> :unavailable
      end
    end
  catch
    :exit, _ -> :unavailable
  end

  @impl OptimalSystemAgent.Sidecar.Behaviour
  def capabilities, do: [:whatsapp_web]

  @doc "Start WhatsApp Web connection. Returns QR data or connection status."
  def connect do
    call("connect", %{})
  end

  @doc "Send a text message."
  def send_message(to, text) do
    call("send_message", %{"to" => to, "text" => text})
  end

  @doc "Get current connection status."
  def connection_status do
    call("status", %{})
  end

  @doc "Disconnect and clear session."
  def logout do
    call("logout", %{})
  end

  @doc "Check if the sidecar process is running."
  def available? do
    Process.whereis(__MODULE__) != nil
  end

  # -- GenServer callbacks --

  @impl true
  def init(_opts) do
    sidecar_path = find_sidecar()

    state = %{
      port: nil,
      sidecar_path: sidecar_path,
      pending: %{},
      connection_state: :disconnected,
      jid: nil
    }

    state = maybe_start_port(state)

    Registry.register(__MODULE__, capabilities())
    Registry.update_health(__MODULE__, if(state.port, do: :degraded, else: :unavailable))

    if state.port do
      Logger.info("[WhatsAppWeb] Sidecar started")
    else
      Logger.info("[WhatsAppWeb] Sidecar not available (Node.js or Baileys not installed)")
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:request, _method, _params}, _from, %{port: nil} = state) do
    {:reply, {:error, :not_started}, state}
  end

  def handle_call({:request, method, params}, from, %{port: port} = state) do
    {id, encoded} = Protocol.encode_request(method, params)
    Port.command(port, encoded)

    timer_ref = Process.send_after(self(), {:request_timeout, id}, @request_timeout)
    pending = Map.put(state.pending, id, {from, timer_ref})

    {:noreply, %{state | pending: pending}}
  end

  def handle_call(:health, _from, state) do
    {:reply, state.connection_state, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    case Jason.decode(String.trim(line)) do
      {:ok, %{"id" => id} = msg} when is_binary(id) ->
        state = handle_response(state, id, msg)
        {:noreply, state}

      {:ok, %{"method" => "message", "params" => params}} ->
        handle_inbound_message(params)
        {:noreply, state}

      {:ok, %{"method" => "connection_lost", "params" => params}} ->
        Logger.warning("[WhatsAppWeb] Connection lost: #{inspect(params)}")
        {:noreply, %{state | connection_state: :disconnected}}

      {:ok, _other} ->
        {:noreply, state}

      {:error, _reason} ->
        Logger.warning("[WhatsAppWeb] Invalid JSON from sidecar: #{line}")
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("[WhatsAppWeb] Port exited with status #{status}")
    state = fail_all_pending(state, :port_crashed)
    Process.send_after(self(), :restart_port, 10_000)
    {:noreply, %{state | port: nil, connection_state: :disconnected}}
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

    if state.port do
      Logger.info("[WhatsAppWeb] Port restarted successfully")
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

  defp handle_response(state, id, %{"result" => result}) do
    state =
      case result do
        %{"status" => "connected", "jid" => jid} ->
          Logger.info("[WhatsAppWeb] Connected as #{jid}")
          %{state | connection_state: :connected, jid: jid}

        %{"status" => "qr"} ->
          %{state | connection_state: :qr}

        %{"status" => "logged_out"} ->
          %{state | connection_state: :disconnected, jid: nil}

        _ ->
          state
      end

    resolve_pending(state, id, {:ok, result})
  end

  defp handle_response(state, id, %{"error" => error}) do
    resolve_pending(state, id, {:error, error})
  end

  defp handle_response(state, _id, _msg), do: state

  defp handle_inbound_message(%{"from" => from, "text" => text} = params) do
    session_id = "whatsapp_web_#{String.replace(from, "@s.whatsapp.net", "")}"

    Logger.debug(
      "[WhatsAppWeb] Message from #{params["push_name"] || from}: #{String.slice(text, 0, 80)}"
    )

    Task.start(fn ->
      Session.ensure_loop(session_id, from, :whatsapp_web)

      case Loop.process_message(session_id, text) do
        {:ok, response} ->
          send_message(String.replace(from, "@s.whatsapp.net", ""), response)

        {:filtered, _signal} ->
          :ok

        {:error, reason} ->
          Logger.warning("[WhatsAppWeb] Agent error for #{from}: #{inspect(reason)}")
      end
    end)
  end

  defp handle_inbound_message(_), do: :ok

  defp maybe_start_port(%{sidecar_path: nil} = state), do: state

  defp maybe_start_port(%{sidecar_path: sidecar_path} = state) do
    index_js = Path.join(sidecar_path, "index.js")
    node_modules = Path.join(sidecar_path, "node_modules")

    if File.exists?(index_js) and File.dir?(node_modules) do
      case System.find_executable("node") do
        nil ->
          Logger.warning("[WhatsAppWeb] Node.js not found in PATH")
          state

        node_path ->
          try do
            port =
              Port.open(
                {:spawn_executable, node_path},
                [
                  :binary,
                  :use_stdio,
                  :exit_status,
                  {:line, 1_048_576},
                  {:args, [index_js]},
                  {:cd, sidecar_path}
                ]
              )

            %{state | port: port}
          rescue
            e ->
              Logger.warning("[WhatsAppWeb] Failed to start port: #{inspect(e)}")
              state
          end
      end
    else
      Logger.info("[WhatsAppWeb] Sidecar not installed at #{sidecar_path}")
      state
    end
  end

  defp find_sidecar do
    priv_path =
      Path.join([
        :code.priv_dir(:optimal_system_agent) |> to_string(),
        "sidecar",
        "baileys"
      ])

    if File.exists?(priv_path), do: priv_path, else: nil
  end

  defp resolve_pending(state, id, result) do
    case Map.pop(state.pending, id) do
      {{from, timer_ref}, pending} ->
        Process.cancel_timer(timer_ref)
        GenServer.reply(from, result)
        %{state | pending: pending}

      {nil, _} ->
        state
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
