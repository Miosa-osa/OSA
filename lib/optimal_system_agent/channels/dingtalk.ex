defmodule OptimalSystemAgent.Channels.DingTalk do
  @moduledoc """
  DingTalk channel adapter.

  Receives messages via webhook (DingTalk robot callback).
  Responds via the session webhook URL provided in each message.

  ## Configuration

      config :optimal_system_agent,
        dingtalk_client_id: System.get_env("DINGTALK_CLIENT_ID"),
        dingtalk_client_secret: System.get_env("DINGTALK_CLIENT_SECRET")
  """

  use GenServer
  @behaviour OptimalSystemAgent.Channels.Behaviour

  require Logger

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Channels.Chunker
  alias OptimalSystemAgent.Channels.Delivery
  alias OptimalSystemAgent.Events.Bus

  # DingTalk's robot-webhook limit is expressed in bytes (20,000 UTF-8 bytes of
  # message content), not characters. Counting graphemes (as this module used
  # to) let 20,000 Chinese characters — 60,000 bytes, 3x the cap — measure as
  # "one chunk that fits".
  @max_message_length 20_000
  @length_unit :bytes

  defstruct [:client_id, :client_secret, session_webhooks: %{}, connected: false]

  @impl OptimalSystemAgent.Channels.Behaviour
  def channel_name, do: :dingtalk

  @impl OptimalSystemAgent.Channels.Behaviour
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl OptimalSystemAgent.Channels.Behaviour
  def send_message(conversation_id, text, _opts \\ []) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      _pid -> GenServer.call(__MODULE__, {:send, conversation_id, text}, 15_000)
    end
  end

  @impl OptimalSystemAgent.Channels.Behaviour
  def connected? do
    case Process.whereis(__MODULE__) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  def handle_webhook(payload) when is_map(payload) do
    GenServer.cast(__MODULE__, {:webhook, payload})
  end

  @doc "Verify DingTalk webhook signature."
  def verify_signature(timestamp, sign, secret) do
    string_to_sign = "#{timestamp}\n#{secret}"
    computed = :crypto.mac(:hmac, :sha256, secret, string_to_sign) |> Base.encode64()
    if computed == sign, do: :ok, else: {:error, :invalid_signature}
  end

  @impl true
  def init(_opts) do
    client_id = Application.get_env(:optimal_system_agent, :dingtalk_client_id)
    client_secret = Application.get_env(:optimal_system_agent, :dingtalk_client_secret)

    if is_nil(client_id) or client_id == "" do
      Logger.info("[DingTalk] Not configured — adapter disabled")
      :ignore
    else
      Logger.info("[DingTalk] Adapter started (webhook mode)")
      Bus.emit(:channel_connected, %{channel: :dingtalk})
      {:ok, %__MODULE__{client_id: client_id, client_secret: client_secret, connected: true}}
    end
  end

  @impl true
  def handle_cast({:webhook, payload}, state) do
    Delivery.start_task(:dingtalk, fn -> process_webhook(payload, state) end)

    {:noreply, state}
  end

  @impl true
  def handle_call({:send, conv_id, text}, _from, state) do
    case Map.get(state.session_webhooks, conv_id) do
      nil -> {:reply, {:error, :no_webhook}, state}
      webhook_url -> {:reply, send_via_webhook(webhook_url, text), state}
    end
  end

  defp process_webhook(payload, _state) do
    sender_id = payload["senderStaffId"] || payload["senderId"] || "unknown"
    text = get_in(payload, ["text", "content"]) || ""
    text = String.trim(text)
    conversation_id = payload["conversationId"] || "dingtalk:#{sender_id}"
    session_webhook = payload["sessionWebhook"]

    if text == "" do
      :ok
    else
      session_id = "dingtalk:#{conversation_id}"
      ensure_session(session_id)

      # Store session webhook for replies
      if session_webhook do
        GenServer.cast(__MODULE__, {:store_webhook, conversation_id, session_webhook})
      end

      case Loop.process_message(session_id, text, channel: :dingtalk, user_id: sender_id) do
        {:ok, response} ->
          if session_webhook do
            send_via_webhook(session_webhook, response)
          end

        {:error, reason} ->
          Logger.warning("[DingTalk] Agent error: #{inspect(reason)}")
      end
    end
  rescue
    e -> Logger.error("[DingTalk] Processing error: #{Exception.message(e)}")
  end

  @impl true
  def handle_cast({:store_webhook, conv_id, url}, state) do
    {:noreply, %{state | session_webhooks: Map.put(state.session_webhooks, conv_id, url)}}
  end

  defp send_via_webhook(webhook_url, text) do
    text
    |> chunk_message()
    |> then(&Delivery.send_chunks(:dingtalk, &1, fn chunk -> post_chunk(webhook_url, chunk) end))
  rescue
    e ->
      Logger.error("[DingTalk] Send failed: #{Exception.message(e)}")
      {:error, :send_failed}
  end

  defp post_chunk(webhook_url, chunk) do
    body = %{msgtype: "markdown", markdown: %{title: "OSA", text: chunk}}

    case Req.post(webhook_url, json: body, receive_timeout: 10_000) do
      # DingTalk answers 200 with an in-body errcode; 0 means success.
      {:ok, %{status: 200, body: %{"errcode" => 0}}} -> :ok
      {:ok, %{status: 200, body: %{"errcode" => code} = body}} -> {:error, {code, body}}
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Split an outbound reply into DingTalk-sized chunks.

  Public so the chunking contract can be tested against DingTalk's real limit
  and unit rather than against a copy of them.
  """
  @spec chunk_message(String.t()) :: [String.t()]
  def chunk_message(text), do: Chunker.chunk(text, @max_message_length, @length_unit)

  @doc false
  @spec message_limit() :: {pos_integer(), Chunker.unit()}
  def message_limit, do: {@max_message_length, @length_unit}

  defp ensure_session(session_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{_, _}] ->
        :ok

      [] ->
        DynamicSupervisor.start_child(
          OptimalSystemAgent.SessionSupervisor,
          {Loop, session_id: session_id, channel: :dingtalk}
        )
    end

    :ok
  rescue
    _ -> :ok
  end
end
