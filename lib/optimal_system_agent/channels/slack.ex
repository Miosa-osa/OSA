defmodule OptimalSystemAgent.Channels.Slack do
  @moduledoc """
  Slack channel adapter for OSA.

  Receives events via webhook (forwarded from channel_routes.ex) and sends
  responses via Slack's Web API (chat.postMessage).

  The process returns :ignore when :slack_bot_token is absent or empty so the
  supervisor silently skips it.

  Features:
  - Webhook-only (app_mention and message events)
  - HMAC-SHA256 request signature verification
  - URL verification challenge support
  - Slack mrkdwn formatting (*bold*, _italic_, `code`, ```blocks```)
  - Long message chunking at 4000 chars
  """

  use GenServer
  @behaviour OptimalSystemAgent.Channels.Behaviour

  require Logger

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Channels.Chunker
  alias OptimalSystemAgent.Channels.Delivery
  alias OptimalSystemAgent.Events.Bus

  # Slack's own cap on chat.postMessage `text` is 40,000; 4,000 is this
  # adapter's self-imposed, far more conservative limit. Because it sits 10x
  # under the real cap, measuring in UTF-8 bytes is safe under every reading of
  # Slack's "characters" (bytes >= UTF-16 units >= codepoints for all input),
  # and unlike the previous code it is the same unit the split uses.
  @max_message_length 4_000
  @length_unit :bytes
  @slack_post_url "https://slack.com/api/chat.postMessage"

  # ── Behaviour callbacks ───────────────────────────────────────────────

  @impl OptimalSystemAgent.Channels.Behaviour
  def channel_name, do: :slack

  @impl OptimalSystemAgent.Channels.Behaviour
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl OptimalSystemAgent.Channels.Behaviour
  def send_message(channel_id, text, _opts \\ []) do
    GenServer.call(__MODULE__, {:send, channel_id, text}, 30_000)
  end

  @impl OptimalSystemAgent.Channels.Behaviour
  def connected? do
    case Process.whereis(__MODULE__) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  @doc """
  Handle a Slack events webhook POST.

  Verifies the Slack request signature (v0 HMAC-SHA256), then dispatches the
  event.  Returns:
    - `{:challenge, binary()}` — URL verification handshake
    - `:ok`                   — event accepted
    - `{:error, :invalid_signature}` — HMAC mismatch
    - `{:error, :not_started}` — adapter not running
  """
  def handle_event(raw_body, timestamp, signature) do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :not_started}

      _pid ->
        GenServer.call(__MODULE__, {:webhook, raw_body, timestamp, signature}, 10_000)
    end
  end

  # ── GenServer callbacks ───────────────────────────────────────────────

  @impl true
  def init(_opts) do
    token = Application.get_env(:optimal_system_agent, :slack_bot_token)

    cond do
      is_nil(token) or token == "" ->
        Logger.info("[Slack] No bot token configured — adapter disabled")
        :ignore

      true ->
        Logger.info("[Slack] Adapter started (webhook mode)")
        Bus.emit(:channel_connected, %{channel: :slack})
        signing_secret = Application.get_env(:optimal_system_agent, :slack_signing_secret)
        {:ok, %{token: token, signing_secret: signing_secret}}
    end
  end

  @impl true
  def handle_call({:webhook, raw_body, timestamp, signature}, _from, state) do
    with :ok <- check_timestamp(timestamp),
         :ok <- verify_signature(raw_body, timestamp, signature, state.signing_secret) do
      result =
        case Jason.decode(raw_body) do
          {:ok, %{"type" => "url_verification", "challenge" => challenge}} ->
            {:challenge, challenge}

          {:ok, %{"event" => event}} ->
            dispatch_event(event, state.token)
            :ok

          _ ->
            :ok
        end

      {:reply, result, state}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:send, channel_id, text}, _from, state) do
    result = send_text(state.token, channel_id, text)
    {:reply, result, state}
  end

  # ── Signature Verification ────────────────────────────────────────────

  defp verify_signature(_raw_body, _timestamp, _signature, nil) do
    # FAIL CLOSED: the adapter only starts when a bot token is configured, so a
    # missing signing secret is a misconfiguration, not dev mode. Accepting
    # unsigned requests would let anyone who knows the URL drive agent turns.
    Logger.warning(
      "[Slack] SLACK_SIGNING_SECRET not set — rejecting webhook. Set it to enable Slack."
    )

    {:error, :signing_secret_not_configured}
  end

  defp verify_signature(_raw_body, _timestamp, _signature, "") do
    {:error, :signing_secret_not_configured}
  end

  defp verify_signature(raw_body, timestamp, signature, signing_secret) do
    base = "v0:#{timestamp}:#{raw_body}"
    expected_mac = :crypto.mac(:hmac, :sha256, signing_secret, base)
    expected = "v0=" <> Base.encode16(expected_mac, case: :lower)

    if Plug.Crypto.secure_compare(signature, expected) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp check_timestamp(timestamp_str) do
    case Integer.parse(timestamp_str) do
      {ts, ""} ->
        if abs(System.system_time(:second) - ts) <= 300 do
          :ok
        else
          {:error, :expired}
        end

      _ ->
        {:error, :invalid_timestamp}
    end
  end

  # ── Event Dispatch ────────────────────────────────────────────────────

  defp dispatch_event(event, token) do
    # Ignore bot echo messages
    if Map.has_key?(event, "bot_id") do
      :ok
    else
      case event do
        %{"type" => type, "channel" => channel_id, "text" => text, "user" => user_id}
        when type in ["app_mention", "message"] ->
          if channel_allowed?(:slack_allowed_users, [user_id, channel_id]) do
            deliver_slack(channel_id, user_id, text, token)
          else
            Logger.warning("[Slack] Ignoring message from unauthorized user #{inspect(user_id)}")
            :ok
          end

        _ ->
          :ok
      end
    end
  end

  defp deliver_slack(channel_id, user_id, text, token) do
    session_id = "slack:#{channel_id}"
    ensure_session(session_id)

    Delivery.start_task(:slack, fn ->
      case Loop.process_message(session_id, text,
             channel: :slack,
             user_id: "slack:#{user_id}"
           ) do
        {:ok, response} ->
          send_text(token, channel_id, response)

        {:error, reason} ->
          Logger.warning("[Slack] Loop error for #{session_id}: #{inspect(reason)}")
          send_text(token, channel_id, "Something went wrong. Try again.")
      end
    end)
  end

  # Per-channel allowlist gate. Empty/unset preserves current open behavior;
  # when set, only listed ids drive agent turns.
  defp channel_allowed?(config_key, ids) do
    case Application.get_env(:optimal_system_agent, config_key) do
      value when value in [nil, ""] ->
        true

      str when is_binary(str) ->
        allowed =
          str
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> MapSet.new()

        MapSet.size(allowed) == 0 or
          Enum.any?(ids, fn id -> MapSet.member?(allowed, to_string(id)) end)
    end
  end

  defp ensure_session(session_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{_pid, _}] ->
        :ok

      [] ->
        case DynamicSupervisor.start_child(
               OptimalSystemAgent.SessionSupervisor,
               {Loop, session_id: session_id, channel: :slack}
             ) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> Logger.warning("[Slack] Session start failed: #{inspect(reason)}")
        end
    end
  rescue
    _ -> :ok
  end

  # ── Message Sending ───────────────────────────────────────────────────

  defp send_text(token, channel_id, text) do
    text
    |> markdown_to_mrkdwn()
    |> chunk_message()
    |> then(
      &Delivery.send_chunks(:slack, &1, fn chunk -> post_message(token, channel_id, chunk) end)
    )
  end

  defp post_message(token, channel_id, text) do
    case Req.post(@slack_post_url,
           headers: [{"authorization", "Bearer #{token}"}],
           json: %{"channel" => channel_id, "text" => text},
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: %{"ok" => true}}} ->
        :ok

      {:ok, %{status: 200, body: %{"ok" => false, "error" => err}}} ->
        Logger.warning("[Slack] chat.postMessage failed: #{err}")
        {:error, err}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("[Slack] chat.postMessage failed (#{status}): #{inspect(body)}")
        {:error, {status, body}}

      {:error, reason} ->
        Logger.warning("[Slack] chat.postMessage error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ── Markdown → mrkdwn ────────────────────────────────────────────────

  defp markdown_to_mrkdwn(text) do
    text
    # Fenced code blocks — backtick triple is identical in mrkdwn
    |> String.replace(~r/```(\w*)\n([\s\S]*?)```/, "```\\2```")
    # Bold: **text** or __text__ → *text*
    |> String.replace(~r/\*\*(.+?)\*\*/, "*\\1*")
    |> String.replace(~r/__(.+?)__/, "*\\1*")
    # Italic: *text* → _text_ (after bold so ** is already consumed)
    |> String.replace(~r/(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)/, "_\\1_")
    # Strikethrough: ~~text~~ → ~text~
    |> String.replace(~r/~~(.+?)~~/, "~\\1~")
    # Links: [label](url) → <url|label>
    |> String.replace(~r/\[([^\]]+)\]\(([^)]+)\)/, "<\\2|\\1>")
  end

  # ── Message Chunking ──────────────────────────────────────────────────

  @doc """
  Split an outbound reply into Slack-sized chunks.

  Public so the chunking contract can be tested against Slack's real limit and
  unit rather than against a copy of them.
  """
  @spec chunk_message(String.t()) :: [String.t()]
  def chunk_message(text), do: Chunker.chunk(text, @max_message_length, @length_unit)

  @doc false
  @spec message_limit() :: {pos_integer(), Chunker.unit()}
  def message_limit, do: {@max_message_length, @length_unit}
end
