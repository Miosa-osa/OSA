defmodule OptimalSystemAgent.Channels.Line do
  @moduledoc """
  LINE Messaging API channel adapter.

  Webhook-based: LINE sends POST to /channels/line/webhook.
  Responses sent via LINE REST API.

  ## Configuration

      config :optimal_system_agent,
        line_channel_token: System.get_env("LINE_CHANNEL_TOKEN"),
        line_channel_secret: System.get_env("LINE_CHANNEL_SECRET")
  """

  use GenServer
  @behaviour OptimalSystemAgent.Channels.Behaviour

  require Logger

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Events.Bus

  @api_base "https://api.line.me/v2/bot"
  @max_message_length 5_000

  defstruct [:token, :secret, connected: false]

  @impl OptimalSystemAgent.Channels.Behaviour
  def channel_name, do: :line

  @impl OptimalSystemAgent.Channels.Behaviour
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl OptimalSystemAgent.Channels.Behaviour
  def send_message(user_id, text, _opts \\ []) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      _pid -> GenServer.call(__MODULE__, {:send, user_id, text}, 15_000)
    end
  end

  @impl OptimalSystemAgent.Channels.Behaviour
  def connected? do
    case Process.whereis(__MODULE__) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  @doc "Handle LINE webhook payload."
  def handle_webhook(body) when is_map(body) do
    GenServer.cast(__MODULE__, {:webhook, body})
  end

  @doc "Verify LINE webhook signature."
  def verify_signature(body_raw, signature, secret) do
    computed = :crypto.mac(:hmac, :sha256, secret, body_raw) |> Base.encode64()
    if computed == signature, do: :ok, else: {:error, :invalid_signature}
  end

  @impl true
  def init(_opts) do
    token = Application.get_env(:optimal_system_agent, :line_channel_token)
    secret = Application.get_env(:optimal_system_agent, :line_channel_secret)

    if is_nil(token) or token == "" do
      Logger.info("[LINE] No channel token — adapter disabled")
      :ignore
    else
      Logger.info("[LINE] Adapter started")
      Bus.emit(:channel_connected, %{channel: :line})
      {:ok, %__MODULE__{token: token, secret: secret, connected: true}}
    end
  end

  @impl true
  def handle_cast({:webhook, %{"events" => events}}, state) when is_list(events) do
    for event <- events do
      Task.Supervisor.start_child(OptimalSystemAgent.Events.TaskSupervisor, fn ->
        process_event(event, state)
      end)
    end

    {:noreply, state}
  end

  def handle_cast({:webhook, _}, state), do: {:noreply, state}

  @impl true
  def handle_call({:send, user_id, text}, _from, state) do
    result = push_message(state.token, user_id, text)
    {:reply, result, state}
  end

  # ── Event Processing ─────────────────────────────────────────────────

  defp process_event(
         %{
           "type" => "message",
           "source" => source,
           "replyToken" => reply_token,
           "message" => msg
         },
         state
       ) do
    user_id = source["userId"] || source["groupId"] || "unknown"
    text = msg["text"] || ""
    if text == "", do: throw(:skip)

    session_id = "line:#{user_id}"
    ensure_session(session_id)

    case Loop.process_message(session_id, text, channel: :line, user_id: user_id) do
      {:ok, response} ->
        reply_message(state.token, reply_token, response)

      {:error, reason} ->
        Logger.warning("[LINE] Agent error: #{inspect(reason)}")
    end
  rescue
    e -> Logger.error("[LINE] Processing error: #{Exception.message(e)}")
  catch
    :skip -> :ok
  end

  defp process_event(_, _), do: :ok

  # ── LINE API ─────────────────────────────────────────────────────────

  defp reply_message(token, reply_token, text) do
    messages = chunk_message(text) |> Enum.map(&%{type: "text", text: &1}) |> Enum.take(5)

    Req.post("#{@api_base}/message/reply",
      json: %{replyToken: reply_token, messages: messages},
      headers: [{"authorization", "Bearer #{token}"}],
      receive_timeout: 10_000
    )
  end

  defp push_message(token, user_id, text) do
    messages = chunk_message(text) |> Enum.map(&%{type: "text", text: &1}) |> Enum.take(5)

    case Req.post("#{@api_base}/message/push",
           json: %{to: user_id, messages: messages},
           headers: [{"authorization", "Bearer #{token}"}],
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: s}} -> {:error, "HTTP #{s}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp chunk_message(text) do
    if String.length(text) <= @max_message_length,
      do: [text],
      else:
        text
        |> String.graphemes()
        |> Enum.chunk_every(@max_message_length)
        |> Enum.map(&Enum.join/1)
  end

  defp ensure_session(session_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{_, _}] ->
        :ok

      [] ->
        DynamicSupervisor.start_child(
          OptimalSystemAgent.SessionSupervisor,
          {Loop, session_id: session_id, channel: :line}
        )
    end

    :ok
  rescue
    _ -> :ok
  end
end
