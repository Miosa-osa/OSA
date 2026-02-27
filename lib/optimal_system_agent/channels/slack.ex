defmodule OptimalSystemAgent.Channels.Slack do
  @moduledoc """
  Slack Bot channel adapter using the Events API.

  Slack POSTs events to:
    POST /api/v1/channels/slack/events

  Inbound request signatures are verified using HMAC-SHA256 with the signing secret.
  Handles Slack's URL verification challenge automatically.

  ## Configuration

      config :optimal_system_agent,
        slack_bot_token: System.get_env("SLACK_BOT_TOKEN"),
        slack_signing_secret: System.get_env("SLACK_SIGNING_SECRET")

  - `:slack_bot_token` — `xoxb-...` Bot token for sending messages
  - `:slack_signing_secret` — Used to verify inbound webhook signatures

  The adapter starts only when `:slack_bot_token` is configured.
  """
  use GenServer
  @behaviour OptimalSystemAgent.Channels.Behaviour
  require Logger

  alias OptimalSystemAgent.Agent.Loop

  @api_base "https://slack.com/api"
  @send_timeout 10_000
  # Reject requests older than 5 minutes
  @signature_max_age 300

  defstruct [:token, :signing_secret, connected: false]

  # ── Behaviour Callbacks ──────────────────────────────────────────────

  @impl OptimalSystemAgent.Channels.Behaviour
  def channel_name, do: :slack

  @impl OptimalSystemAgent.Channels.Behaviour
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl OptimalSystemAgent.Channels.Behaviour
  def send_message(channel_id, message, opts \\ []) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      _pid -> GenServer.call(__MODULE__, {:send, channel_id, message, opts}, @send_timeout)
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
  Handle an inbound Slack event payload (called by HTTP API).

  `raw_body` is the raw request body string (needed for signature verification).
  `timestamp` and `signature` come from the `x-slack-request-timestamp` and
  `x-slack-signature` request headers.

  Returns `{:challenge, value}` for URL verification, `:ok` for normal events.
  """
  def handle_event(raw_body, timestamp, signature) do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :not_started}

      _pid ->
        GenServer.call(__MODULE__, {:event, raw_body, timestamp, signature}, @send_timeout)
    end
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────

  @impl true
  def init(_opts) do
    token = Application.get_env(:optimal_system_agent, :slack_bot_token)
    signing_secret = Application.get_env(:optimal_system_agent, :slack_signing_secret)

    case token do
      nil ->
        Logger.info("Slack: No bot token configured, adapter disabled")
        :ignore

      _ ->
        Logger.info("Slack: Adapter started")
        {:ok, %__MODULE__{token: token, signing_secret: signing_secret, connected: true}}
    end
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, state.connected, state}
  end

  @impl true
  def handle_call({:send, channel_id, message, opts}, _from, state) do
    result = do_send_message(state.token, channel_id, message, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:event, raw_body, timestamp, signature}, _from, state) do
    if verify_signature(raw_body, timestamp, signature, state.signing_secret) do
      payload = Jason.decode!(raw_body)
      result = route_event(payload, state)
      {:reply, result, state}
    else
      Logger.warning("Slack: Invalid request signature")
      {:reply, {:error, :invalid_signature}, state}
    end
  end

  # ── Event Routing ────────────────────────────────────────────────────

  # URL verification challenge — must respond synchronously
  defp route_event(%{"type" => "url_verification", "challenge" => challenge}, _state) do
    Logger.info("Slack: URL verification challenge received")
    {:challenge, challenge}
  end

  # Regular event callback wrapper
  defp route_event(%{"event" => event}, state) do
    spawn(fn -> dispatch_event(event, state) end)
    :ok
  end

  defp route_event(payload, _state) do
    Logger.debug("Slack: Unhandled payload type: #{inspect(payload["type"])}")
    :ok
  end

  defp dispatch_event(%{"type" => "message", "bot_id" => _}, _state) do
    # Ignore messages from bots (including ourselves) to avoid loops
    :ok
  end

  defp dispatch_event(%{"type" => "message", "text" => text, "channel" => channel, "user" => user_id}, state) do
    session_id = "slack_#{user_id}_#{channel}"
    Logger.debug("Slack: Message from #{user_id} in #{channel}: #{text}")

    ensure_loop(session_id, user_id)

    case Loop.process_message(session_id, text) do
      {:ok, response} ->
        do_send_message(state.token, channel, response, [thread_ts: nil])

      {:filtered, signal} ->
        Logger.debug("Slack: Signal filtered (weight=#{signal.weight})")

      {:error, reason} ->
        Logger.warning("Slack: Agent error for channel #{channel}: #{inspect(reason)}")
        do_send_message(state.token, channel, "Sorry, I encountered an error.", [])
    end
  end

  defp dispatch_event(event, _state) do
    Logger.debug("Slack: Unhandled event type: #{inspect(event["type"])}")
  end

  # ── HTTP Helpers ─────────────────────────────────────────────────────

  defp do_send_message(token, channel_id, message, opts) do
    body = %{channel: channel_id, text: message, mrkdwn: true}

    body =
      case Keyword.get(opts, :thread_ts) do
        nil -> body
        ts when is_binary(ts) -> Map.put(body, :thread_ts, ts)
        _ -> body
      end

    case Req.post("#{@api_base}/chat.postMessage",
           json: body,
           headers: [{"authorization", "Bearer #{token}"}],
           receive_timeout: @send_timeout
         ) do
      {:ok, %{status: 200, body: %{"ok" => true}}} ->
        :ok

      {:ok, %{status: 429, headers: headers}} ->
        retry_after = get_retry_after(headers)
        Logger.warning("Slack: Rate limited. Retry after #{retry_after}s")
        {:error, {:rate_limited, retry_after}}

      {:ok, %{body: %{"ok" => false, "error" => err}}} ->
        Logger.warning("Slack: API error: #{err}")
        {:error, err}

      {:ok, %{body: body}} ->
        Logger.warning("Slack: Send failed: #{inspect(body)}")
        {:error, body}

      {:error, reason} ->
        Logger.warning("Slack: HTTP error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ── Signature Verification ───────────────────────────────────────────

  defp verify_signature(_raw_body, _timestamp, _signature, nil) do
    Logger.warning("Slack: No signing secret configured — skipping signature verification")
    true
  end

  defp verify_signature(raw_body, timestamp, signature, signing_secret) do
    try do
      # Reject stale requests
      now = System.system_time(:second)
      ts = String.to_integer(timestamp)

      if abs(now - ts) > @signature_max_age do
        Logger.warning("Slack: Request timestamp too old (#{abs(now - ts)}s)")
        false
      else
        base_string = "v0:#{timestamp}:#{raw_body}"
        expected_mac = :crypto.mac(:hmac, :sha256, signing_secret, base_string)
        expected = "v0=" <> Base.encode16(expected_mac, case: :lower)
        Plug.Crypto.secure_compare(expected, signature)
      end
    rescue
      e ->
        Logger.warning("Slack: Signature verification error: #{inspect(e)}")
        false
    end
  end

  # ── Misc Helpers ─────────────────────────────────────────────────────

  defp ensure_loop(session_id, user_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{_pid, _}] ->
        :ok

      [] ->
        DynamicSupervisor.start_child(
          OptimalSystemAgent.Channels.Supervisor,
          {Loop, session_id: session_id, user_id: to_string(user_id), channel: :slack}
        )
    end
  end

  defp get_retry_after(headers) do
    case List.keyfind(headers, "retry-after", 0) do
      {_, value} -> String.to_integer(value)
      nil -> 30
    end
  end
end
