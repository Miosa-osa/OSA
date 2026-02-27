defmodule OptimalSystemAgent.Channels.QQ do
  @moduledoc """
  QQ Bot channel adapter (Tencent Open Platform).

  Receives events via webhook:
    POST /api/v1/channels/qq/webhook

  Handles the QQ Bot signature verification using Ed25519 and the
  URL verification challenge (op_code 13).

  Sends messages to QQ channels (guilds) or direct messages.

  ## Configuration

      config :optimal_system_agent,
        qq_app_id: System.get_env("QQ_APP_ID"),
        qq_app_secret: System.get_env("QQ_APP_SECRET"),
        qq_token: System.get_env("QQ_TOKEN")

  The adapter starts only when `:qq_app_id` is configured.

  ## API base
  - Guild/channel messages: https://api.sgroup.qq.com
  - Sandbox: https://sandbox.api.sgroup.qq.com
  """
  use GenServer
  @behaviour OptimalSystemAgent.Channels.Behaviour
  require Logger

  alias OptimalSystemAgent.Agent.Loop

  @api_base "https://api.sgroup.qq.com"
  @send_timeout 15_000

  defstruct [
    :app_id,
    :app_secret,
    :token,
    :access_token,
    :access_token_expires_at,
    connected: false
  ]

  # ── Behaviour Callbacks ──────────────────────────────────────────────

  @impl OptimalSystemAgent.Channels.Behaviour
  def channel_name, do: :qq

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

  @doc "Handle inbound webhook event from QQ (called by HTTP API)."
  def handle_event(body, signature, timestamp, nonce) do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :not_started}

      _pid ->
        GenServer.call(__MODULE__, {:event, body, signature, timestamp, nonce}, @send_timeout)
    end
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────

  @impl true
  def init(_opts) do
    app_id = Application.get_env(:optimal_system_agent, :qq_app_id)
    app_secret = Application.get_env(:optimal_system_agent, :qq_app_secret)
    token = Application.get_env(:optimal_system_agent, :qq_token)

    case app_id do
      nil ->
        Logger.info("QQ: No app_id configured, adapter disabled")
        :ignore

      _ ->
        Logger.info("QQ: Adapter started (app_id=#{app_id})")
        # Schedule token refresh
        send(self(), :refresh_token)

        {:ok,
         %__MODULE__{
           app_id: app_id,
           app_secret: app_secret,
           token: token,
           connected: true
         }}
    end
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, state.connected, state}
  end

  @impl true
  def handle_call({:send, channel_id, message, opts}, _from, state) do
    state = maybe_refresh_token(state)
    result = do_send_message(state, channel_id, message, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:event, body, signature, timestamp, nonce}, _from, state) do
    if verify_signature(body, signature, timestamp, nonce, state.token) do
      payload = Jason.decode!(body)
      result = route_event(payload, state)
      {:reply, result, state}
    else
      Logger.warning("QQ: Invalid webhook signature")
      {:reply, {:error, :invalid_signature}, state}
    end
  end

  @impl true
  def handle_info(:refresh_token, state) do
    new_state = do_refresh_access_token(state)
    # Refresh again 5 minutes before expiry (tokens are valid for ~7200s)
    Process.send_after(self(), :refresh_token, (7200 - 300) * 1_000)
    {:noreply, new_state}
  end

  # ── Event Routing ────────────────────────────────────────────────────

  # URL verification challenge (op_code 13)
  defp route_event(%{"op" => 13, "d" => %{"plain_token" => plain_token}}, state) do
    signature = sign_challenge(plain_token, state.token)
    {:challenge, %{plain_token: plain_token, signature: signature}}
  end

  # Dispatch message
  defp route_event(%{"t" => "AT_MESSAGE_CREATE", "d" => data}, state) do
    spawn(fn -> handle_message(data, state) end)
    :ok
  end

  defp route_event(%{"t" => "MESSAGE_CREATE", "d" => data}, state) do
    spawn(fn -> handle_message(data, state) end)
    :ok
  end

  defp route_event(%{"t" => event_type}, _state) do
    Logger.debug("QQ: Unhandled event type: #{event_type}")
    :ok
  end

  defp route_event(_event, _state), do: :ok

  defp handle_message(
         %{"content" => content, "channel_id" => channel_id, "author" => %{"id" => user_id}} = msg,
         state
       ) do
    # Strip @bot mention from content
    text = Regex.replace(~r/<@\d+>/, content, "") |> String.trim()

    if text != "" do
      session_id = "qq_#{user_id}_#{channel_id}"
      Logger.debug("QQ: Message from #{user_id} in #{channel_id}: #{text}")

      ensure_loop(session_id, user_id)

      case Loop.process_message(session_id, text) do
        {:ok, response} ->
          # Reply in the same channel, quoting the original message
          do_send_message(state, channel_id, response, msg_id: msg["id"])

        {:filtered, signal} ->
          Logger.debug("QQ: Signal filtered (weight=#{signal.weight})")

        {:error, reason} ->
          Logger.warning("QQ: Agent error for channel #{channel_id}: #{inspect(reason)}")
      end
    end
  end

  defp handle_message(data, _state) do
    Logger.debug("QQ: Unhandled message data keys: #{inspect(Map.keys(data))}")
  end

  # ── HTTP Helpers ─────────────────────────────────────────────────────

  defp do_send_message(state, channel_id, message, opts) do
    url = "#{@api_base}/channels/#{channel_id}/messages"
    token = state.access_token || state.token

    body = %{content: message}

    body =
      case Keyword.get(opts, :msg_id) do
        nil -> body
        id -> Map.put(body, :msg_id, id)
      end

    case Req.post(url,
           json: body,
           headers: auth_header(state.app_id, token),
           receive_timeout: @send_timeout
         ) do
      {:ok, %{status: status}} when status in [200, 201] ->
        :ok

      {:ok, %{status: 429, headers: headers}} ->
        retry_after = get_retry_after(headers)
        Logger.warning("QQ: Rate limited. Retry after #{retry_after}s")
        {:error, {:rate_limited, retry_after}}

      {:ok, %{body: body}} ->
        Logger.warning("QQ: Send failed: #{inspect(body)}")
        {:error, body}

      {:error, reason} ->
        Logger.warning("QQ: HTTP error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_refresh_access_token(%{app_id: nil} = state), do: state
  defp do_refresh_access_token(%{app_secret: nil} = state), do: state

  defp do_refresh_access_token(state) do
    url = "https://bots.qq.com/app/getAppAccessToken"

    case Req.post(url,
           json: %{appId: state.app_id, clientSecret: state.app_secret},
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} ->
        Logger.debug("QQ: Access token refreshed")
        %{state | access_token: token}

      {:ok, %{body: body}} ->
        Logger.warning("QQ: Failed to refresh access token: #{inspect(body)}")
        state

      {:error, reason} ->
        Logger.warning("QQ: Token refresh HTTP error: #{inspect(reason)}")
        state
    end
  end

  defp maybe_refresh_token(state) do
    expires_at = state.access_token_expires_at || 0
    now = System.system_time(:second)

    if now >= expires_at - 60 do
      do_refresh_access_token(state)
    else
      state
    end
  end

  # ── Signature Verification ───────────────────────────────────────────

  defp verify_signature(_body, _signature, _timestamp, _nonce, nil) do
    Logger.warning("QQ: No token configured — skipping signature verification")
    true
  end

  defp verify_signature(body, signature, timestamp, nonce, token) do
    try do
      # QQ uses Ed25519: message = timestamp + nonce + body
      message = timestamp <> nonce <> body
      sig_bytes = Base.decode16!(signature, case: :lower)
      key_bytes = Base.decode16!(token, case: :lower)
      :crypto.verify(:eddsa, :none, message, sig_bytes, [key_bytes, :ed25519])
    rescue
      _ ->
        Logger.warning("QQ: Signature verification error")
        false
    end
  end

  defp sign_challenge(plain_token, token) when is_binary(token) do
    try do
      key_bytes = Base.decode16!(token, case: :lower)
      sig = :crypto.sign(:eddsa, :none, plain_token, [key_bytes, :ed25519])
      Base.encode16(sig, case: :lower)
    rescue
      _ -> ""
    end
  end

  defp sign_challenge(_plain_token, _token), do: ""

  # ── Misc Helpers ─────────────────────────────────────────────────────

  defp auth_header(app_id, token) do
    [{"authorization", "QQBot #{app_id}.#{token}"}]
  end

  defp ensure_loop(session_id, user_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{_pid, _}] ->
        :ok

      [] ->
        DynamicSupervisor.start_child(
          OptimalSystemAgent.Channels.Supervisor,
          {Loop, session_id: session_id, user_id: to_string(user_id), channel: :qq}
        )
    end
  end

  defp get_retry_after(headers) do
    case List.keyfind(headers, "retry-after", 0) ||
           List.keyfind(headers, "x-ratelimit-reset-after", 0) do
      {_, value} ->
        case Integer.parse(value) do
          {n, _} -> n
          :error -> 5
        end

      nil ->
        5
    end
  end
end
