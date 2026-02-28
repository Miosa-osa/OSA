defmodule OptimalSystemAgent.Channels.Discord do
  @moduledoc """
  Discord Bot channel adapter.

  Operates in webhook/interactions mode. Discord POSTs interactions to:
    POST /api/v1/channels/discord/webhook

  Outbound messages are sent to Discord channels via the Bot API.

  ## Configuration

      config :optimal_system_agent,
        discord_bot_token: System.get_env("DISCORD_BOT_TOKEN"),
        discord_application_id: System.get_env("DISCORD_APPLICATION_ID"),
        discord_public_key: System.get_env("DISCORD_PUBLIC_KEY")

  The `:discord_public_key` is used to verify the Ed25519 signature on interactions.
  The adapter starts only when `:discord_bot_token` is configured.

  ## Auth
  Outbound requests use `Authorization: Bot {token}` header.
  """
  use GenServer
  @behaviour OptimalSystemAgent.Channels.Behaviour
  require Logger

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Channels.Session

  @api_base "https://discord.com/api/v10"
  @send_timeout 10_000

  defstruct [:token, :application_id, :public_key, connected: false]

  # ── Behaviour Callbacks ──────────────────────────────────────────────

  @impl OptimalSystemAgent.Channels.Behaviour
  def channel_name, do: :discord

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
  Handle an inbound interaction or message from Discord (called by HTTP API).
  Returns `{:pong}` for ping interactions (required by Discord).
  """
  def handle_interaction(body, signature, timestamp) do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :not_started}

      _pid ->
        GenServer.call(__MODULE__, {:interaction, body, signature, timestamp}, @send_timeout)
    end
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────

  @impl true
  def init(_opts) do
    token = Application.get_env(:optimal_system_agent, :discord_bot_token)
    app_id = Application.get_env(:optimal_system_agent, :discord_application_id)
    public_key = Application.get_env(:optimal_system_agent, :discord_public_key)

    case token do
      nil ->
        Logger.info("Discord: No token configured, adapter disabled")
        :ignore

      _ ->
        Logger.info("Discord: Adapter started (application_id=#{app_id})")

        {:ok,
         %__MODULE__{
           token: token,
           application_id: app_id,
           public_key: public_key,
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
    result = do_send_message(state.token, channel_id, message, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:interaction, body, signature, timestamp}, _from, state) do
    if verify_signature(body, signature, timestamp, state.public_key) do
      parsed = Jason.decode!(body)
      result = route_interaction(parsed, state)
      {:reply, result, state}
    else
      Logger.warning("Discord: Invalid interaction signature")
      {:reply, {:error, :invalid_signature}, state}
    end
  end

  # ── Interaction Routing ──────────────────────────────────────────────

  # Discord PING — must respond with PONG (type 1)
  defp route_interaction(%{"type" => 1}, _state) do
    {:pong, %{type: 1}}
  end

  # Application command (slash command)
  defp route_interaction(
         %{"type" => 2, "data" => data, "channel_id" => channel_id} = interaction,
         state
       ) do
    user = get_in(interaction, ["member", "user"]) || interaction["user"] || %{}
    user_id = user["id"] || "unknown"
    username = user["username"] || "unknown"
    input = build_slash_input(data)

    Logger.debug("Discord: Slash command from #{username} in #{channel_id}: #{input}")
    spawn(fn -> handle_command(channel_id, user_id, input, state) end)

    # Deferred response while we process
    {:ok, %{type: 5}}
  end

  # Message component interaction (button click, select menu)
  defp route_interaction(
         %{"type" => 3, "data" => data, "channel_id" => channel_id} = interaction,
         state
       ) do
    user = get_in(interaction, ["member", "user"]) || interaction["user"] || %{}
    user_id = user["id"] || "unknown"
    custom_id = data["custom_id"] || ""

    Logger.debug("Discord: Component interaction custom_id=#{custom_id}")
    spawn(fn -> handle_command(channel_id, user_id, custom_id, state) end)
    {:ok, %{type: 6}}
  end

  defp route_interaction(event, _state) do
    Logger.debug("Discord: Unhandled interaction type: #{inspect(event["type"])}")
    {:ok, %{type: 1}}
  end

  defp handle_command(channel_id, user_id, input, state) do
    session_id = "discord_#{user_id}"
    Session.ensure_loop(session_id, user_id, :discord)

    case Loop.process_message(session_id, input) do
      {:ok, response} ->
        do_send_message(state.token, channel_id, response, [])

      {:filtered, signal} ->
        Logger.debug("Discord: Signal filtered (weight=#{signal.weight})")

      {:error, reason} ->
        Logger.warning("Discord: Agent error for channel #{channel_id}: #{inspect(reason)}")
        do_send_message(state.token, channel_id, "Sorry, I encountered an error.", [])
    end
  end

  # ── HTTP Helpers ─────────────────────────────────────────────────────

  defp do_send_message(token, channel_id, message, _opts) do
    # Discord has a 2000-char limit per message
    chunks = chunk_message(message, 2000)

    Enum.reduce_while(chunks, :ok, fn chunk, _acc ->
      case Req.post("#{@api_base}/channels/#{channel_id}/messages",
             json: %{content: chunk},
             headers: [{"authorization", "Bot #{token}"}],
             receive_timeout: @send_timeout
           ) do
        {:ok, %{status: status}} when status in [200, 201] ->
          {:cont, :ok}

        {:ok, %{status: 429, headers: headers}} ->
          retry_after = get_retry_after(headers)
          Logger.warning("Discord: Rate limited. Retry after #{retry_after}s")
          {:halt, {:error, {:rate_limited, retry_after}}}

        {:ok, %{body: body}} ->
          Logger.warning("Discord: Send failed: #{inspect(body)}")
          {:halt, {:error, body}}

        {:error, reason} ->
          Logger.warning("Discord: HTTP error: #{inspect(reason)}")
          {:halt, {:error, reason}}
      end
    end)
  end

  # ── Signature Verification (Ed25519) ────────────────────────────────

  defp verify_signature(_body, _signature, _timestamp, nil) do
    Logger.warning("Discord: No public key configured — skipping signature verification")
    true
  end

  defp verify_signature(body, signature, timestamp, public_key) do
    try do
      key = Base.decode16!(public_key, case: :lower)
      sig = Base.decode16!(signature, case: :lower)
      message = timestamp <> body
      :crypto.verify(:eddsa, :none, message, sig, [key, :ed25519])
    rescue
      _ ->
        Logger.warning("Discord: Signature verification error")
        false
    end
  end

  # ── Misc Helpers ─────────────────────────────────────────────────────

  defp build_slash_input(%{"name" => name, "options" => options}) when is_list(options) do
    args = Enum.map_join(options, " ", & &1["value"])
    "/#{name} #{args}"
  end

  defp build_slash_input(%{"name" => name}), do: "/#{name}"
  defp build_slash_input(_), do: ""

  defp chunk_message(message, max_len) when byte_size(message) <= max_len, do: [message]

  defp chunk_message(message, max_len) do
    message
    |> String.codepoints()
    |> Enum.chunk_every(max_len)
    |> Enum.map(&Enum.join/1)
  end

  defp get_retry_after(headers) do
    case List.keyfind(headers, "retry-after", 0) ||
           List.keyfind(headers, "x-ratelimit-reset-after", 0) do
      {_, value} ->
        case Float.parse(value) do
          {f, _} -> ceil(f)
          :error -> 5
        end

      nil ->
        5
    end
  end
end
