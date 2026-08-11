defmodule OptimalSystemAgent.Channels.WeCom do
  @moduledoc """
  WeCom (Enterprise WeChat) channel adapter.

  Receives messages via webhook. Responds via WeCom bot API.

  ## Configuration

      config :optimal_system_agent,
        wecom_bot_key: System.get_env("WECOM_BOT_KEY"),
        wecom_webhook_token: System.get_env("WECOM_WEBHOOK_TOKEN"),
        wecom_encoding_aes_key: System.get_env("WECOM_ENCODING_AES_KEY")
  """

  use GenServer
  @behaviour OptimalSystemAgent.Channels.Behaviour

  require Logger

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Channels.Chunker
  alias OptimalSystemAgent.Channels.Delivery
  alias OptimalSystemAgent.Events.Bus

  # WeCom states its bot-webhook limit in bytes, not characters: markdown
  # content must be "最长不超过4096个字节" (at most 4096 UTF-8 bytes). 4,000 is this
  # adapter's margin under that. Counting graphemes (as this module used to)
  # was catastrophic for exactly the language WeCom is used in — 4,000 Chinese
  # characters measured "under" the limit at 12,000 bytes, 3x the real cap, so
  # every long Chinese reply was rejected outright.
  @max_message_length 4_000
  @length_unit :bytes

  defstruct [:bot_key, :webhook_token, connected: false]

  @impl OptimalSystemAgent.Channels.Behaviour
  def channel_name, do: :wecom

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

  def handle_webhook(payload) when is_map(payload) do
    GenServer.cast(__MODULE__, {:webhook, payload})
  end

  @impl true
  def init(_opts) do
    bot_key = Application.get_env(:optimal_system_agent, :wecom_bot_key)

    if is_nil(bot_key) or bot_key == "" do
      Logger.info("[WeCom] Not configured — adapter disabled")
      :ignore
    else
      Logger.info("[WeCom] Adapter started")
      Bus.emit(:channel_connected, %{channel: :wecom})

      {:ok,
       %__MODULE__{
         bot_key: bot_key,
         webhook_token: Application.get_env(:optimal_system_agent, :wecom_webhook_token),
         connected: true
       }}
    end
  end

  @impl true
  def handle_cast({:webhook, payload}, state) do
    Delivery.start_task(:wecom, fn -> process_webhook(payload, state) end)

    {:noreply, state}
  end

  @impl true
  def handle_call({:send, _user_id, text}, _from, state) do
    result = send_bot_message(state.bot_key, text)
    {:reply, result, state}
  end

  defp process_webhook(payload, state) do
    # WeCom webhook payload: XML or JSON depending on setup
    content = payload["Content"] || payload["content"] || payload["text"] || ""
    from_user = payload["FromUserName"] || payload["from_user"] || "unknown"

    content = String.trim(content)
    if content == "", do: throw(:skip)

    session_id = "wecom:#{from_user}"
    ensure_session(session_id)

    case Loop.process_message(session_id, content, channel: :wecom, user_id: from_user) do
      {:ok, response} ->
        send_bot_message(state.bot_key, response)

      {:error, reason} ->
        Logger.warning("[WeCom] Agent error: #{inspect(reason)}")
    end
  rescue
    e -> Logger.error("[WeCom] Processing error: #{Exception.message(e)}")
  catch
    :skip -> :ok
  end

  defp send_bot_message(bot_key, text) do
    url = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=#{bot_key}"

    text
    |> chunk_message()
    |> then(&Delivery.send_chunks(:wecom, &1, fn chunk -> post_chunk(url, chunk) end))
  rescue
    e ->
      Logger.error("[WeCom] Send failed: #{Exception.message(e)}")
      {:error, :send_failed}
  end

  defp post_chunk(url, chunk) do
    case Req.post(url,
           json: %{msgtype: "markdown", markdown: %{content: chunk}},
           receive_timeout: 10_000
         ) do
      # WeCom answers 200 with an in-body errcode; 0 means success.
      {:ok, %{status: 200, body: %{"errcode" => 0}}} -> :ok
      {:ok, %{status: 200, body: %{"errcode" => code} = body}} -> {:error, {code, body}}
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Split an outbound reply into WeCom-sized chunks.

  Public so the chunking contract can be tested against WeCom's real limit and
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
          {Loop, session_id: session_id, channel: :wecom}
        )
    end

    :ok
  rescue
    _ -> :ok
  end
end
