defmodule OptimalSystemAgent.Channels.WhatsApp do
  @moduledoc """
  WhatsApp channel adapter for OSA.

  Communicates with a Node.js Baileys bridge sidecar that handles
  the WhatsApp Web protocol. The bridge exposes an HTTP API:

    GET  /messages    — poll for new incoming messages
    POST /send        — send a text message
    POST /send-media  — send media (image, video, document)
    POST /typing      — send typing indicator
    GET  /health      — connection status

  ## Setup

  1. Install the bridge: `cd scripts/whatsapp-bridge && npm install`
  2. Pair: `node bridge.js --pair-only` (scan QR with phone)
  3. Run: `node bridge.js --port 3001`

  ## Configuration

      config :optimal_system_agent,
        whatsapp_bridge_url: "http://127.0.0.1:3001",
        whatsapp_enabled: true
  """

  use GenServer
  @behaviour OptimalSystemAgent.Channels.Behaviour

  require Logger

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Events.Bus

  @poll_interval_ms 1_500
  @max_message_length 4_096
  @send_timeout 15_000

  defstruct [:bridge_url, :poll_timer, connected: false]

  # ── Behaviour Callbacks ──────────────────────────────────────────────

  @impl OptimalSystemAgent.Channels.Behaviour
  def channel_name, do: :whatsapp

  @impl OptimalSystemAgent.Channels.Behaviour
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl OptimalSystemAgent.Channels.Behaviour
  def send_message(chat_id, text, _opts \\ []) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      _pid -> GenServer.call(__MODULE__, {:send, chat_id, text}, @send_timeout)
    end
  end

  @impl OptimalSystemAgent.Channels.Behaviour
  def connected? do
    case Process.whereis(__MODULE__) do
      nil -> false
      pid -> Process.alive?(pid) && GenServer.call(pid, :connected?)
    end
  rescue
    _ -> false
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────

  @impl true
  def init(_opts) do
    bridge_url = Application.get_env(:optimal_system_agent, :whatsapp_bridge_url)
    enabled = Application.get_env(:optimal_system_agent, :whatsapp_enabled, false)

    cond do
      !enabled ->
        Logger.info("[WhatsApp] Adapter disabled — set whatsapp_enabled: true")
        :ignore

      is_nil(bridge_url) or bridge_url == "" ->
        Logger.info("[WhatsApp] No bridge URL configured — adapter disabled")
        :ignore

      true ->
        state = %__MODULE__{bridge_url: bridge_url}

        case check_bridge_health(bridge_url) do
          {:ok, status} ->
            Logger.info("[WhatsApp] Bridge connected (status: #{status})")
            Bus.emit(:channel_connected, %{channel: :whatsapp})
            timer = Process.send_after(self(), :poll, @poll_interval_ms)
            {:ok, %{state | connected: true, poll_timer: timer}}

          {:error, reason} ->
            Logger.warning("[WhatsApp] Bridge not reachable: #{reason} — will retry")
            timer = Process.send_after(self(), :poll, 5_000)
            {:ok, %{state | poll_timer: timer}}
        end
    end
  end

  @impl true
  def handle_call({:send, chat_id, text}, _from, state) do
    result = send_text(state.bridge_url, chat_id, text)
    {:reply, result, state}
  end

  def handle_call(:connected?, _from, state) do
    {:reply, state.connected, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = poll_messages(state)
    timer = Process.send_after(self(), :poll, @poll_interval_ms)
    {:noreply, %{state | poll_timer: timer}}
  end

  # ── Polling ──────────────────────────────────────────────────────────

  defp poll_messages(state) do
    case Req.get("#{state.bridge_url}/messages", receive_timeout: 5_000) do
      {:ok, %{status: 200, body: messages}} when is_list(messages) ->
        state = if !state.connected, do: %{state | connected: true}, else: state

        for msg <- messages do
          Task.Supervisor.start_child(OptimalSystemAgent.Events.TaskSupervisor, fn ->
            process_incoming(msg, state.bridge_url)
          end)
        end

        state

      {:ok, _} ->
        state

      {:error, reason} ->
        if state.connected do
          Logger.warning("[WhatsApp] Bridge poll failed: #{inspect(reason)}")
        end

        %{state | connected: false}
    end
  rescue
    e ->
      Logger.warning("[WhatsApp] Poll error: #{Exception.message(e)}")
      %{state | connected: false}
  end

  defp process_incoming(msg, bridge_url) do
    chat_id = msg["chatId"]
    text = msg["body"] || ""
    sender_name = msg["senderName"] || "unknown"
    session_id = "whatsapp:#{chat_id}"

    ensure_session(session_id)

    # Typing indicator
    Req.post("#{bridge_url}/typing", json: %{chatId: chat_id})

    case Loop.process_message(session_id, text, channel: :whatsapp, user_id: msg["senderId"]) do
      {:ok, response} ->
        send_text(bridge_url, chat_id, response)

      {:error, reason} ->
        Logger.warning("[WhatsApp] Agent error for #{session_id}: #{inspect(reason)}")
        send_text(bridge_url, chat_id, "Something went wrong. Please try again.")
    end
  rescue
    e ->
      Logger.error("[WhatsApp] Message processing error: #{Exception.message(e)}")
  end

  # ── Sending ──────────────────────────────────────────────────────────

  defp send_text(bridge_url, chat_id, text) do
    text
    |> chunk_message()
    |> Enum.each(fn chunk ->
      Req.post("#{bridge_url}/send",
        json: %{chatId: chat_id, message: chunk},
        receive_timeout: @send_timeout
      )
    end)

    :ok
  rescue
    e ->
      Logger.error("[WhatsApp] Send failed: #{Exception.message(e)}")
      {:error, :send_failed}
  end

  defp chunk_message(text) do
    if String.length(text) <= @max_message_length do
      [text]
    else
      text
      |> String.graphemes()
      |> Enum.chunk_every(@max_message_length)
      |> Enum.map(&Enum.join/1)
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp ensure_session(session_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{_pid, _}] ->
        :ok

      [] ->
        case DynamicSupervisor.start_child(
               OptimalSystemAgent.SessionSupervisor,
               {Loop, session_id: session_id, channel: :whatsapp}
             ) do
          {:ok, _} ->
            :ok

          {:error, {:already_started, _}} ->
            :ok

          {:error, reason} ->
            Logger.warning("[WhatsApp] Session start failed: #{inspect(reason)}")
        end
    end
  rescue
    _ -> :ok
  end

  defp check_bridge_health(bridge_url) do
    case Req.get("#{bridge_url}/health", receive_timeout: 3_000) do
      {:ok, %{status: 200, body: %{"status" => status}}} -> {:ok, status}
      {:ok, %{status: code}} -> {:error, "HTTP #{code}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
