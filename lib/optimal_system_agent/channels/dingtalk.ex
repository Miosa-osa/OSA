defmodule OptimalSystemAgent.Channels.DingTalk do
  @moduledoc """
  DingTalk (Alibaba) channel adapter.

  Receives events via webhook:
    POST /api/v1/channels/dingtalk/webhook

  Outbound messages are sent to a DingTalk outgoing webhook with optional
  HMAC-SHA256 signing (required when a `:dingtalk_secret` is configured).

  ## Configuration

      config :optimal_system_agent,
        dingtalk_access_token: System.get_env("DINGTALK_ACCESS_TOKEN"),
        dingtalk_secret: System.get_env("DINGTALK_SECRET")   # optional but recommended

  - `:dingtalk_access_token` — The `access_token` from the DingTalk custom robot URL
  - `:dingtalk_secret` — If set, appends timestamp + sign parameters to outbound URLs

  The adapter starts only when `:dingtalk_access_token` is configured.

  ## Outbound message format
  Uses the "markdown" type by default, falling back to "text" for plain messages.

  ## Signature (outbound)
  When `:dingtalk_secret` is set:
    timestamp = current Unix ms as string
    sign = Base64(HMAC-SHA256(secret, "\\n".join([timestamp, secret])))
  These are appended as `?timestamp=...&sign=...` query params.
  """
  use GenServer
  @behaviour OptimalSystemAgent.Channels.Behaviour
  require Logger

  alias OptimalSystemAgent.Agent.Loop

  @webhook_base "https://oapi.dingtalk.com/robot/send"
  @send_timeout 10_000

  defstruct [:access_token, :secret, connected: false]

  # ── Behaviour Callbacks ──────────────────────────────────────────────

  @impl OptimalSystemAgent.Channels.Behaviour
  def channel_name, do: :dingtalk

  @impl OptimalSystemAgent.Channels.Behaviour
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl OptimalSystemAgent.Channels.Behaviour
  def send_message(_chat_id, message, opts \\ []) do
    # DingTalk robot webhooks don't target individual chats — they post to the group
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      _pid -> GenServer.call(__MODULE__, {:send, message, opts}, @send_timeout)
    end
  end

  @impl OptimalSystemAgent.Channels.Behaviour
  def connected? do
    case Process.whereis(__MODULE__) do
      nil -> false
      pid -> GenServer.call(pid, :connected?)
    end
  end

  # ── Public API ───────────────────────────────────────────────────────

  @doc """
  Handle inbound webhook event from DingTalk (called by HTTP API).
  DingTalk sends a JSON payload with the message and sender info.
  """
  def handle_event(body) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      _pid -> GenServer.cast(__MODULE__, {:event, body})
    end
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────

  @impl true
  def init(_opts) do
    access_token = Application.get_env(:optimal_system_agent, :dingtalk_access_token)
    secret = Application.get_env(:optimal_system_agent, :dingtalk_secret)

    case access_token do
      nil ->
        Logger.info("DingTalk: No access token configured, adapter disabled")
        :ignore

      _ ->
        Logger.info("DingTalk: Adapter started")
        {:ok, %__MODULE__{access_token: access_token, secret: secret, connected: true}}
    end
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, state.connected, state}
  end

  @impl true
  def handle_call({:send, message, opts}, _from, state) do
    result = do_send_message(state, message, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_cast({:event, body}, state) do
    spawn(fn -> process_event(body, state) end)
    {:noreply, state}
  end

  # ── Event Processing ─────────────────────────────────────────────────

  defp process_event(
         %{
           "text" => %{"content" => content},
           "senderStaffId" => sender_id,
           "conversationId" => conversation_id
         } = _body,
         state
       ) do
    text = String.trim(content)

    if text != "" do
      Logger.debug("DingTalk: Message from #{sender_id}: #{text}")
      session_id = "dingtalk_#{conversation_id}_#{sender_id}"
      ensure_loop(session_id, sender_id)

      case Loop.process_message(session_id, text) do
        {:ok, response} ->
          do_send_message(state, response, [])

        {:filtered, signal} ->
          Logger.debug("DingTalk: Signal filtered (weight=#{signal.weight})")

        {:error, reason} ->
          Logger.warning("DingTalk: Agent error: #{inspect(reason)}")
      end
    end
  end

  defp process_event(%{"msgtype" => "text", "text" => %{"content" => content}} = body, state) do
    sender_id = get_in(body, ["senderNick"]) || get_in(body, ["senderId"]) || "unknown"
    conversation_id = body["conversationId"] || body["sessionWebhookExpiredTime"] || "default"

    process_event(
      %{
        "text" => %{"content" => content},
        "senderStaffId" => sender_id,
        "conversationId" => conversation_id
      },
      state
    )
  end

  defp process_event(body, _state) do
    Logger.debug("DingTalk: Unhandled event shape: #{inspect(Map.keys(body))}")
  end

  # ── HTTP Helpers ─────────────────────────────────────────────────────

  defp do_send_message(state, message, opts) do
    url = build_webhook_url(state)
    msg_type = Keyword.get(opts, :type, :auto)

    body = build_message_body(message, msg_type)

    case Req.post(url,
           json: body,
           receive_timeout: @send_timeout
         ) do
      {:ok, %{status: 200, body: %{"errcode" => 0}}} ->
        :ok

      {:ok, %{status: 200, body: %{"errcode" => 130101}}} ->
        Logger.warning("DingTalk: Rate limited")
        {:error, :rate_limited}

      {:ok, %{body: body}} ->
        Logger.warning("DingTalk: Send failed: #{inspect(body)}")
        {:error, body}

      {:error, reason} ->
        Logger.warning("DingTalk: HTTP error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_webhook_url(%{access_token: token, secret: nil}) do
    "#{@webhook_base}?access_token=#{token}"
  end

  defp build_webhook_url(%{access_token: token, secret: secret}) do
    timestamp = System.system_time(:millisecond) |> to_string()
    sign_string = "#{timestamp}\n#{secret}"
    mac = :crypto.mac(:hmac, :sha256, secret, sign_string)
    sign = Base.encode64(mac)
    sign_encoded = URI.encode_www_form(sign)
    "#{@webhook_base}?access_token=#{token}&timestamp=#{timestamp}&sign=#{sign_encoded}"
  end

  defp build_message_body(message, :text) do
    %{msgtype: "text", text: %{content: message}}
  end

  defp build_message_body(message, :markdown) do
    %{
      msgtype: "markdown",
      markdown: %{
        title: "OSA Agent",
        text: message
      }
    }
  end

  defp build_message_body(message, :auto) do
    # Use markdown if the message contains markdown-like syntax
    if String.contains?(message, ["**", "##", "- ", "```", "`"]) do
      build_message_body(message, :markdown)
    else
      build_message_body(message, :text)
    end
  end

  defp ensure_loop(session_id, user_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{_pid, _}] ->
        :ok

      [] ->
        DynamicSupervisor.start_child(
          OptimalSystemAgent.Channels.Supervisor,
          {Loop, session_id: session_id, user_id: to_string(user_id), channel: :dingtalk}
        )
    end
  end
end
