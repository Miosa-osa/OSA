defmodule OptimalSystemAgent.Channels.Telegram do
  @moduledoc """
  Telegram Bot API channel adapter.

  Operates in webhook mode. Telegram POSTs updates to:
    POST /api/v1/channels/telegram/webhook

  To register the webhook with Telegram, call `set_webhook/1` with your public HTTPS URL.

  ## Configuration

      config :optimal_system_agent,
        telegram_bot_token: System.get_env("TELEGRAM_BOT_TOKEN")

  ## Supported features
  - Text messages (inbound + outbound)
  - Markdown formatting (parse_mode: "MarkdownV2")
  - Inline keyboards (pass {:keyboard, buttons} in opts)

  The adapter starts only when `:telegram_bot_token` is configured.
  """
  use GenServer
  @behaviour OptimalSystemAgent.Channels.Behaviour
  require Logger

  alias OptimalSystemAgent.Agent.Loop

  @base_url "https://api.telegram.org"
  @send_timeout 10_000

  defstruct [:token, connected: false]

  # ── Behaviour Callbacks ──────────────────────────────────────────────

  @impl OptimalSystemAgent.Channels.Behaviour
  def channel_name, do: :telegram

  @impl OptimalSystemAgent.Channels.Behaviour
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl OptimalSystemAgent.Channels.Behaviour
  def send_message(chat_id, message, opts \\ []) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      _pid -> GenServer.call(__MODULE__, {:send, chat_id, message, opts}, @send_timeout)
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
  Register the webhook URL with the Telegram Bot API.
  Call this once after deployment:

      OptimalSystemAgent.Channels.Telegram.set_webhook("https://yourdomain.com")
  """
  def set_webhook(base_url) do
    GenServer.call(__MODULE__, {:set_webhook, base_url}, 15_000)
  end

  @doc "Handle an inbound webhook update from Telegram (called by HTTP API)."
  def handle_update(update) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      _pid -> GenServer.cast(__MODULE__, {:update, update})
    end
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────

  @impl true
  def init(_opts) do
    case Application.get_env(:optimal_system_agent, :telegram_bot_token) do
      nil ->
        Logger.info("Telegram: No token configured, adapter disabled")
        :ignore

      token ->
        Logger.info("Telegram: Adapter started")
        {:ok, %__MODULE__{token: token, connected: true}}
    end
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, state.connected, state}
  end

  @impl true
  def handle_call({:send, chat_id, message, opts}, _from, state) do
    result = do_send_message(state.token, chat_id, message, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:set_webhook, base_url}, _from, state) do
    webhook_url = "#{base_url}/api/v1/channels/telegram/webhook"

    result =
      Req.post("#{@base_url}/bot#{state.token}/setWebhook",
        json: %{url: webhook_url},
        receive_timeout: 10_000
      )

    case result do
      {:ok, %{status: 200, body: %{"ok" => true}}} ->
        Logger.info("Telegram: Webhook registered at #{webhook_url}")
        {:reply, :ok, state}

      {:ok, %{body: body}} ->
        Logger.warning("Telegram: Failed to set webhook: #{inspect(body)}")
        {:reply, {:error, body}, state}

      {:error, reason} ->
        Logger.warning("Telegram: HTTP error setting webhook: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:update, update}, state) do
    spawn(fn -> process_update(update) end)
    {:noreply, state}
  end

  # ── Internal Helpers ─────────────────────────────────────────────────

  defp process_update(%{"message" => %{"text" => text, "chat" => %{"id" => chat_id}} = msg}) do
    session_id = "telegram_#{chat_id}"
    from = get_in(msg, ["from", "username"]) || get_in(msg, ["from", "first_name"]) || "unknown"
    Logger.debug("Telegram: Message from #{from} in chat #{chat_id}: #{text}")

    ensure_loop(session_id, chat_id)

    case Loop.process_message(session_id, text) do
      {:ok, response} ->
        send_message(to_string(chat_id), response)

      {:filtered, signal} ->
        Logger.debug("Telegram: Signal filtered (weight=#{signal.weight}) from #{from}")

      {:error, reason} ->
        Logger.warning("Telegram: Agent error for chat #{chat_id}: #{inspect(reason)}")
        send_message(to_string(chat_id), "Sorry, I encountered an error. Please try again.")
    end
  end

  defp process_update(%{"callback_query" => %{"data" => data, "from" => %{"id" => user_id}} = cq}) do
    chat_id = get_in(cq, ["message", "chat", "id"]) || user_id
    process_update(%{"message" => %{"text" => data, "chat" => %{"id" => chat_id}, "from" => cq["from"]}})
  end

  defp process_update(update) do
    Logger.debug("Telegram: Unhandled update type: #{inspect(Map.keys(update))}")
  end

  defp do_send_message(token, chat_id, message, opts) do
    parse_mode = Keyword.get(opts, :parse_mode, "MarkdownV2")
    body = %{chat_id: chat_id, text: message, parse_mode: parse_mode}

    body =
      case Keyword.get(opts, :keyboard) do
        nil ->
          body

        buttons when is_list(buttons) ->
          inline_keyboard = Enum.map(buttons, fn btn ->
            [%{text: btn.text, callback_data: btn.data}]
          end)
          Map.put(body, :reply_markup, %{inline_keyboard: inline_keyboard})
      end

    case Req.post("#{@base_url}/bot#{token}/sendMessage",
           json: body,
           receive_timeout: @send_timeout
         ) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: 429, headers: headers}} ->
        retry_after = get_retry_after(headers)
        Logger.warning("Telegram: Rate limited. Retry after #{retry_after}s")
        {:error, {:rate_limited, retry_after}}

      {:ok, %{body: body}} ->
        Logger.warning("Telegram: Send failed: #{inspect(body)}")
        {:error, body}

      {:error, reason} ->
        Logger.warning("Telegram: HTTP error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp ensure_loop(session_id, chat_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{_pid, _}] ->
        :ok

      [] ->
        DynamicSupervisor.start_child(
          OptimalSystemAgent.Channels.Supervisor,
          {Loop, session_id: session_id, user_id: to_string(chat_id), channel: :telegram}
        )
    end
  end

  defp get_retry_after(headers) do
    case List.keyfind(headers, "retry-after", 0) do
      {_, value} -> String.to_integer(value)
      nil -> 5
    end
  end
end
