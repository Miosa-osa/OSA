defmodule OptimalSystemAgent.Channels.Telegram do
  @moduledoc """
  Telegram channel adapter for OSA.

  Uses long-polling (getUpdates) to receive messages and Req for all HTTP calls.
  Each inbound message is routed through Agent.Loop via a per-session GenServer.

  Start/stop is managed by Channels.Manager.  The process returns :ignore when
  TELEGRAM_BOT_TOKEN is absent or invalid so the supervisor silently skips it.

  Features:
  - Token validation via getMe on startup
  - Typing indicator while agent thinks
  - Markdown → HTML conversion for rich formatting
  - Long message chunking (4096 char limit)
  - Exponential backoff on errors

  ## Webhook mode
  POST bodies forwarded from channel_routes.ex can be processed via handle_update/1.
  """

  use GenServer
  @behaviour OptimalSystemAgent.Channels.Behaviour

  require Logger

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Events.Bus

  # Long-poll timeout sent to the Telegram API (seconds).
  @poll_timeout_s 30
  @receive_timeout_ms (@poll_timeout_s + 5) * 1_000

  # Exponential back-off caps (milliseconds).
  @backoff_initial_ms 1_000
  @backoff_max_ms 60_000

  # Telegram message length limit.
  @max_message_length 4096

  # ── Behaviour callbacks ───────────────────────────────────────────────

  @impl OptimalSystemAgent.Channels.Behaviour
  def channel_name, do: :telegram

  @impl OptimalSystemAgent.Channels.Behaviour
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl OptimalSystemAgent.Channels.Behaviour
  def send_message(chat_id, text, _opts \\ []) do
    GenServer.call(__MODULE__, {:send, chat_id, text}, 30_000)
  end

  @impl OptimalSystemAgent.Channels.Behaviour
  def connected? do
    case Process.whereis(__MODULE__) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  @doc """
  Handle a single parsed Telegram update delivered via webhook.
  """
  def handle_update(update) when is_map(update) do
    GenServer.cast(__MODULE__, {:webhook_update, update})
  end

  # ── GenServer callbacks ───────────────────────────────────────────────

  @impl true
  def init(_opts) do
    token = Application.get_env(:optimal_system_agent, :telegram_bot_token)

    cond do
      is_nil(token) or token == "" ->
        Logger.info("[Telegram] No bot token configured — adapter disabled")
        :ignore

      true ->
        case validate_token(token) do
          {:ok, bot_info} ->
            username = bot_info["username"] || "unknown"
            Logger.info("[Telegram] Bot connected: @#{username} (long-polling)")
            Bus.emit(:channel_connected, %{channel: :telegram, username: username})

            state = %{
              token: token,
              offset: 0,
              backoff_ms: @backoff_initial_ms,
              username: username
            }

            send(self(), :poll)
            {:ok, state}

          {:error, reason} ->
            Logger.error("[Telegram] Invalid bot token: #{reason}")
            :ignore
        end
    end
  end

  @impl true
  def handle_info(:poll, state) do
    case fetch_updates(state.token, state.offset) do
      {:ok, updates} ->
        new_offset = process_updates(updates, state.offset, state.token)
        schedule_poll(0)
        {:noreply, %{state | offset: new_offset, backoff_ms: @backoff_initial_ms}}

      {:error, reason} ->
        Logger.warning(
          "[Telegram] Poll error: #{inspect(reason)} — retrying in #{state.backoff_ms}ms"
        )

        schedule_poll(state.backoff_ms)
        next_backoff = min(state.backoff_ms * 2, @backoff_max_ms)
        {:noreply, %{state | backoff_ms: next_backoff}}
    end
  end

  @impl true
  def handle_cast({:webhook_update, update}, state) do
    dispatch_update(update, state.token)
    {:noreply, state}
  end

  @impl true
  def handle_call({:send, chat_id, text}, _from, state) do
    result = send_text(state.token, chat_id, text)
    {:reply, result, state}
  end

  # ── Token Validation ────────────────────────────────────────────────

  defp validate_token(token) do
    case Req.get("https://api.telegram.org/bot#{token}/getMe",
           receive_timeout: 10_000,
           retry: :transient,
           max_retries: 2
         ) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => info}}} ->
        {:ok, info}

      {:ok, %{status: 401}} ->
        {:error, "unauthorized — token is invalid or revoked"}

      {:ok, %{body: %{"description" => desc}}} ->
        {:error, desc}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ── Polling ─────────────────────────────────────────────────────────

  defp schedule_poll(delay_ms) do
    Process.send_after(self(), :poll, delay_ms)
  end

  defp fetch_updates(token, offset) do
    url = "https://api.telegram.org/bot#{token}/getUpdates"

    case Req.get(url,
           params: [offset: offset, timeout: @poll_timeout_s],
           receive_timeout: @receive_timeout_ms
         ) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => updates}}} ->
        {:ok, updates}

      {:ok, %{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_updates(updates, current_offset, token) do
    Enum.reduce(updates, current_offset, fn update, acc ->
      dispatch_update(update, token)
      max(acc, update["update_id"] + 1)
    end)
  end

  # ── Message Dispatch ────────────────────────────────────────────────

  defp dispatch_update(update, token) do
    with %{"message" => %{"chat" => %{"id" => chat_id}, "text" => text} = msg} <- update do
      from_id = get_in(msg, ["from", "id"]) || chat_id
      session_id = "telegram:#{chat_id}"
      user_id = "telegram:#{from_id}"

      # Send typing indicator immediately
      send_typing(token, chat_id)

      ensure_session(session_id)

      Task.Supervisor.start_child(OptimalSystemAgent.Events.TaskSupervisor, fn ->
        case Loop.process_message(session_id, text, channel: :telegram, user_id: user_id) do
          {:ok, response} ->
            send_text(token, chat_id, response)

          {:error, reason} ->
            Logger.warning("[Telegram] Loop error for session #{session_id}: #{inspect(reason)}")
            send_text(token, chat_id, "Something went wrong. Try again.")
        end
      end)
    else
      _ ->
        # Non-text update (photo, sticker, etc.) — silently ignore.
        :ok
    end
  end

  defp ensure_session(session_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{_pid, _}] ->
        :ok

      [] ->
        case DynamicSupervisor.start_child(
               OptimalSystemAgent.SessionSupervisor,
               {Loop, session_id: session_id, channel: :telegram}
             ) do
          {:ok, _pid} ->
            :ok

          {:error, {:already_started, _pid}} ->
            :ok

          {:error, reason} ->
            Logger.warning("[Telegram] Session start failed: #{inspect(reason)}")
        end
    end
  rescue
    _ -> :ok
  end

  # ── Typing Indicator ────────────────────────────────────────────────

  defp send_typing(token, chat_id) do
    Req.post("https://api.telegram.org/bot#{token}/sendChatAction",
      json: %{"chat_id" => chat_id, "action" => "typing"},
      receive_timeout: 5_000
    )
  rescue
    _ -> :ok
  end

  # ── Message Sending ─────────────────────────────────────────────────

  defp send_text(token, chat_id, text) do
    html = markdown_to_html(text)

    html
    |> chunk_message()
    |> Enum.each(fn chunk ->
      post_message(token, chat_id, chunk)
    end)

    :ok
  end

  defp post_message(token, chat_id, text) do
    url = "https://api.telegram.org/bot#{token}/sendMessage"

    case Req.post(url,
           json: %{
             "chat_id" => chat_id,
             "text" => text,
             "parse_mode" => "HTML"
           },
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: 400, body: %{"description" => desc}}} when is_binary(desc) ->
        # If HTML parsing fails, retry as plain text
        if String.contains?(desc, "parse") do
          Logger.debug("[Telegram] HTML parse error, retrying as plain text")
          Req.post(url, json: %{"chat_id" => chat_id, "text" => strip_html(text)})
          :ok
        else
          Logger.warning("[Telegram] sendMessage failed: #{desc}")
          {:error, desc}
        end

      {:ok, %{status: status, body: body}} ->
        Logger.warning("[Telegram] sendMessage failed (#{status}): #{inspect(body)}")
        {:error, {status, body}}

      {:error, reason} ->
        Logger.warning("[Telegram] sendMessage error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ── Markdown → HTML ─────────────────────────────────────────────────

  defp markdown_to_html(text) do
    text
    # Code blocks first (before inline replacements)
    |> String.replace(~r/```(\w*)\n([\s\S]*?)```/, fn _, lang, code ->
      lang_attr = if lang != "", do: " class=\"language-#{lang}\"", else: ""
      "<pre><code#{lang_attr}>#{escape_html(code)}</code></pre>"
    end)
    # Inline code
    |> String.replace(~r/`([^`]+)`/, fn _, code ->
      "<code>#{escape_html(code)}</code>"
    end)
    # Bold (** or __)
    |> String.replace(~r/\*\*(.+?)\*\*/, "<b>\\1</b>")
    |> String.replace(~r/__(.+?)__/, "<b>\\1</b>")
    # Italic (* or _) — careful not to match ** or __
    |> String.replace(~r/(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)/, "<i>\\1</i>")
    # Links
    |> String.replace(~r/\[([^\]]+)\]\(([^)]+)\)/, "<a href=\"\\2\">\\1</a>")
    # Strikethrough
    |> String.replace(~r/~~(.+?)~~/, "<s>\\1</s>")
  end

  defp escape_html(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp strip_html(text) do
    text
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
  end

  # ── Message Chunking ────────────────────────────────────────────────

  defp chunk_message(text) when byte_size(text) <= @max_message_length, do: [text]

  defp chunk_message(text) do
    # Try to split on paragraph boundaries first
    paragraphs = String.split(text, "\n\n")
    build_chunks(paragraphs, [], "")
  end

  defp build_chunks([], acc, current) do
    if current == "" do
      Enum.reverse(acc)
    else
      Enum.reverse([String.trim(current) | acc])
    end
  end

  defp build_chunks([para | rest], acc, current) do
    candidate =
      if current == "" do
        para
      else
        current <> "\n\n" <> para
      end

    if byte_size(candidate) > @max_message_length do
      if current == "" do
        # Single paragraph too long — force split by characters
        {head, tail} = String.split_at(para, @max_message_length - 10)
        build_chunks([tail | rest], [head <> "..." | acc], "")
      else
        # Current chunk is full, start new one with this paragraph
        build_chunks([para | rest], [String.trim(current) | acc], "")
      end
    else
      build_chunks(rest, acc, candidate)
    end
  end
end
