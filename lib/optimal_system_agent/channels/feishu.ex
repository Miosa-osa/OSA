defmodule OptimalSystemAgent.Channels.Feishu do
  @moduledoc """
  Feishu/Lark channel adapter.

  Receives messages via webhook events (POST /channels/feishu/events).
  Responds via Feishu REST API.

  ## Configuration

      config :optimal_system_agent,
        feishu_app_id: System.get_env("FEISHU_APP_ID"),
        feishu_app_secret: System.get_env("FEISHU_APP_SECRET"),
        feishu_verification_token: System.get_env("FEISHU_VERIFICATION_TOKEN")
  """

  use GenServer
  @behaviour OptimalSystemAgent.Channels.Behaviour

  require Logger

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Channels.Chunker
  alias OptimalSystemAgent.Channels.Delivery
  alias OptimalSystemAgent.Events.Bus

  @api_base "https://open.feishu.cn/open-apis"

  # Feishu/Lark sizes message content in bytes (the `content` field is a
  # JSON-encoded string with a byte ceiling); 4,000 is this adapter's margin
  # under it. Counting graphemes (as this module used to) meant 4,000 Chinese
  # characters measured "under" the limit at 12,000 bytes — and Feishu's
  # `content` is JSON-escaped before sending, which only adds bytes.
  @max_message_length 4_000
  @length_unit :bytes

  defstruct [
    :app_id,
    :app_secret,
    :verification_token,
    :tenant_token,
    :token_expires_at,
    connected: false
  ]

  @impl OptimalSystemAgent.Channels.Behaviour
  def channel_name, do: :feishu

  @impl OptimalSystemAgent.Channels.Behaviour
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl OptimalSystemAgent.Channels.Behaviour
  def send_message(chat_id, text, _opts \\ []) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      _pid -> GenServer.call(__MODULE__, {:send, chat_id, text}, 15_000)
    end
  end

  @impl OptimalSystemAgent.Channels.Behaviour
  def connected? do
    case Process.whereis(__MODULE__) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  def handle_event(payload) when is_map(payload) do
    GenServer.cast(__MODULE__, {:event, payload})
  end

  @doc "Verify Feishu event signature."
  def verify_event(payload, verification_token) do
    token = payload["token"] || get_in(payload, ["header", "token"])
    if token == verification_token, do: :ok, else: {:error, :invalid_token}
  end

  @impl true
  def init(_opts) do
    app_id = Application.get_env(:optimal_system_agent, :feishu_app_id)
    app_secret = Application.get_env(:optimal_system_agent, :feishu_app_secret)
    vtoken = Application.get_env(:optimal_system_agent, :feishu_verification_token)

    if is_nil(app_id) or app_id == "" do
      Logger.info("[Feishu] Not configured — adapter disabled")
      :ignore
    else
      state = %__MODULE__{app_id: app_id, app_secret: app_secret, verification_token: vtoken}

      case refresh_tenant_token(state) do
        {:ok, state} ->
          Logger.info("[Feishu] Adapter started")
          Bus.emit(:channel_connected, %{channel: :feishu})
          {:ok, %{state | connected: true}}

        {:error, reason} ->
          Logger.error("[Feishu] Token fetch failed: #{reason}")
          :ignore
      end
    end
  end

  @impl true
  def handle_cast({:event, payload}, state) do
    # URL verification challenge
    case payload do
      %{"type" => "url_verification", "challenge" => _} ->
        :ok

      _ ->
        Delivery.start_task(:feishu, fn -> process_event(payload, state) end)
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:send, chat_id, text}, _from, state) do
    state = ensure_token(state)
    result = send_text(state, chat_id, text)
    {:reply, result, state}
  end

  # ── Event Processing ─────────────────────────────────────────────────

  defp process_event(payload, state) do
    event = payload["event"] || payload
    msg = event["message"] || %{}
    chat_id = msg["chat_id"]
    sender = get_in(event, ["sender", "sender_id", "open_id"]) || "unknown"
    msg_type = msg["message_type"]

    if msg_type == "text" and chat_id do
      content =
        case Jason.decode(msg["content"] || "{}") do
          {:ok, %{"text" => text}} -> String.trim(text) |> String.replace(~r/@_user_\d+\s*/, "")
          _ -> ""
        end

      if content != "" do
        session_id = "feishu:#{chat_id}"
        ensure_session(session_id)

        case Loop.process_message(session_id, content, channel: :feishu, user_id: sender) do
          {:ok, response} ->
            state = ensure_token(state)
            reply_to_message(state, msg["message_id"], response)

          {:error, reason} ->
            Logger.warning("[Feishu] Agent error: #{inspect(reason)}")
        end
      end
    end
  rescue
    e -> Logger.error("[Feishu] Processing error: #{Exception.message(e)}")
  end

  # ── Feishu API ───────────────────────────────────────────────────────

  defp send_text(state, chat_id, text) do
    text
    |> chunk_message()
    |> then(&Delivery.send_chunks(:feishu, &1, fn chunk -> post_chunk(state, chat_id, chunk) end))
  rescue
    e ->
      Logger.error("[Feishu] Send failed: #{Exception.message(e)}")
      {:error, :send_failed}
  end

  defp post_chunk(state, chat_id, chunk) do
    body = %{
      receive_id: chat_id,
      msg_type: "text",
      content: Jason.encode!(%{text: chunk})
    }

    case Req.post("#{@api_base}/im/v1/messages?receive_id_type=chat_id",
           json: body,
           headers: auth_headers(state),
           receive_timeout: 10_000
         ) do
      # Feishu answers 200 with an in-body code; 0 means success.
      {:ok, %{status: 200, body: %{"code" => 0}}} -> :ok
      {:ok, %{status: 200, body: %{"code" => code} = body}} -> {:error, {code, body}}
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reply_to_message(state, message_id, text) when is_binary(message_id) do
    body = %{
      msg_type: "text",
      content: Jason.encode!(%{text: text})
    }

    Req.post("#{@api_base}/im/v1/messages/#{message_id}/reply",
      json: body,
      headers: auth_headers(state),
      receive_timeout: 10_000
    )
  end

  defp reply_to_message(_, _, _), do: :ok

  defp refresh_tenant_token(state) do
    case Req.post("#{@api_base}/auth/v3/tenant_access_token/internal",
           json: %{app_id: state.app_id, app_secret: state.app_secret},
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: %{"tenant_access_token" => token, "expire" => expire}}} ->
        {:ok,
         %{
           state
           | tenant_token: token,
             token_expires_at: System.system_time(:second) + expire - 300
         }}

      {:ok, %{body: body}} ->
        {:error, "Unexpected response: #{inspect(body)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp ensure_token(state) do
    if state.token_expires_at && System.system_time(:second) >= state.token_expires_at do
      case refresh_tenant_token(state) do
        {:ok, new_state} -> new_state
        _ -> state
      end
    else
      state
    end
  end

  defp auth_headers(state), do: [{"authorization", "Bearer #{state.tenant_token}"}]

  @doc """
  Split an outbound reply into Feishu-sized chunks.

  Public so the chunking contract can be tested against Feishu's real limit and
  unit rather than against a copy of them.
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
          {Loop, session_id: session_id, channel: :feishu}
        )
    end

    :ok
  rescue
    _ -> :ok
  end
end
