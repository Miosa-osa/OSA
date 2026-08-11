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
  alias OptimalSystemAgent.Channels.Chunker
  alias OptimalSystemAgent.Channels.Delivery
  alias OptimalSystemAgent.Events.Bus

  @api_base "https://api.line.me/v2/bot"

  # LINE caps a text message at 5,000 characters, counted the way its JS/Java
  # SDKs count them: UTF-16 code units.
  @max_message_length 5_000
  @length_unit :utf16

  # LINE accepts at most 5 message objects per reply/push request. This is a
  # real provider limit — but it caps messages *per request*, not per reply, and
  # `push` may be called repeatedly. The old code applied `Enum.take(5)` to the
  # whole chunk list, so chunk 6 onward was discarded with no error and no
  # marker: a long answer just stopped mid-sentence.
  @max_messages_per_request 5

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
      Delivery.start_task(:line, fn -> process_event(event, state) end)
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
        case reply_message(state.token, reply_token, user_id, response) do
          :ok -> :ok
          {:error, reason} -> Logger.warning("[LINE] Reply delivery failed: #{inspect(reason)}")
        end

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

  # A reply token is single-use, so only the first 5 chunks can go out as a
  # reply. The rest are pushed to the same conversation, which delivers the
  # whole answer. If there is no push target (the webhook gave us no
  # user/group/room id) the overflow genuinely cannot be delivered — in that
  # case we say so in the last delivered message instead of dropping it in
  # silence.
  defp reply_message(token, reply_token, target, text) do
    case batches(text) do
      [] ->
        :ok

      [only] ->
        post_reply(token, reply_token, only)

      [first | rest] ->
        if pushable?(target) do
          with :ok <- post_reply(token, reply_token, first) do
            push_batches(token, target, rest)
          end
        else
          undeliverable = rest |> List.flatten() |> length()
          post_reply(token, reply_token, mark_truncated(first, undeliverable))
        end
    end
  end

  defp push_message(token, target, text) do
    text |> batches() |> then(&push_batches(token, target, &1))
  end

  defp push_batches(token, target, batches) do
    Delivery.send_chunks(:line, batches, fn batch ->
      post(token, "#{@api_base}/message/push", %{to: target, messages: to_messages(batch)})
    end)
  end

  defp post_reply(token, reply_token, batch) do
    post(token, "#{@api_base}/message/reply", %{
      replyToken: reply_token,
      messages: to_messages(batch)
    })
  end

  defp post(token, url, body) do
    case Req.post(url,
           json: body,
           headers: [{"authorization", "Bearer #{token}"}],
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: s, body: b}} -> {:error, {s, b}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp to_messages(batch), do: Enum.map(batch, &%{type: "text", text: &1})

  @doc """
  Chunks grouped into request-sized batches of at most 5 messages.

  Public so a test can assert that flattening the batches returns every chunk —
  the property `Enum.take(5)` used to break.
  """
  @spec batches(String.t()) :: [[String.t()]]
  def batches(text) do
    text |> chunk_message() |> Enum.chunk_every(@max_messages_per_request)
  end

  defp pushable?(target), do: is_binary(target) and target != "" and target != "unknown"

  @doc """
  Appends a visible notice to the final message of the batch, shrinking that
  message just enough to keep the result within LINE's per-message limit.

  Public so a test can assert the undeliverable-overflow case is announced
  rather than dropped.
  """
  @spec mark_truncated([String.t()], non_neg_integer()) :: [String.t()]
  def mark_truncated(batch, undeliverable) do
    notice =
      "\n\n[#{undeliverable} further message(s) could not be delivered: LINE accepts at most " <>
        "#{@max_messages_per_request} messages per reply and this conversation has no push target.]"

    {leading, [last]} = Enum.split(batch, -1)
    room = max(@max_message_length - Chunker.measure(notice, @length_unit), 1)
    kept = last |> Chunker.chunk(room, @length_unit) |> List.first() || ""

    leading ++ [kept <> notice]
  end

  @doc """
  Split an outbound reply into LINE-sized chunks.

  Public so the chunking contract can be tested against LINE's real limit and
  unit rather than against a copy of them.
  """
  @spec chunk_message(String.t()) :: [String.t()]
  def chunk_message(text), do: Chunker.chunk(text, @max_message_length, @length_unit)

  @doc false
  @spec message_limit() :: {pos_integer(), Chunker.unit()}
  def message_limit, do: {@max_message_length, @length_unit}

  @doc false
  @spec max_messages_per_request() :: pos_integer()
  def max_messages_per_request, do: @max_messages_per_request

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
