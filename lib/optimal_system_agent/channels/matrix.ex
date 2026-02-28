defmodule OptimalSystemAgent.Channels.Matrix do
  @moduledoc """
  Matrix protocol channel adapter using the Client-Server API.

  Uses long-polling via the /sync endpoint (no external library needed).
  Sends messages via the PUT rooms/{room_id}/send endpoint.

  ## Configuration

      config :optimal_system_agent,
        matrix_homeserver: System.get_env("MATRIX_HOMESERVER"),   # e.g. "https://matrix.org"
        matrix_access_token: System.get_env("MATRIX_ACCESS_TOKEN"),
        matrix_user_id: System.get_env("MATRIX_USER_ID")           # e.g. "@bot:matrix.org"

  The adapter starts only when `:matrix_access_token` is configured.

  ## How it works

  On start, the adapter begins a polling loop:
    1. GET /_matrix/client/v3/sync?timeout=30000&since={next_batch}
    2. Process timeline events from all joined rooms
    3. Respond to messages, accept room invites
    4. Repeat with the returned `next_batch` token

  The `next_batch` token is persisted in process state only (not to disk).
  On restart, the adapter will re-process recent events.
  """
  use GenServer
  @behaviour OptimalSystemAgent.Channels.Behaviour
  require Logger

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Channels.Session

  @sync_timeout 30_000
  @request_timeout 35_000
  @send_timeout 10_000
  # Avoid re-processing events older than this on first boot
  @initial_since_fallback nil

  defstruct [
    :homeserver,
    :access_token,
    :user_id,
    :next_batch,
    :sync_timer,
    txn_id: 0,
    connected: false
  ]

  # ── Behaviour Callbacks ──────────────────────────────────────────────

  @impl OptimalSystemAgent.Channels.Behaviour
  def channel_name, do: :matrix

  @impl OptimalSystemAgent.Channels.Behaviour
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl OptimalSystemAgent.Channels.Behaviour
  def send_message(room_id, message, opts \\ []) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      _pid -> GenServer.call(__MODULE__, {:send, room_id, message, opts}, @send_timeout)
    end
  end

  @impl OptimalSystemAgent.Channels.Behaviour
  def connected? do
    case Process.whereis(__MODULE__) do
      nil -> false
      pid -> GenServer.call(pid, :connected?)
    end
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────

  @impl true
  def init(_opts) do
    homeserver = Application.get_env(:optimal_system_agent, :matrix_homeserver)
    access_token = Application.get_env(:optimal_system_agent, :matrix_access_token)
    user_id = Application.get_env(:optimal_system_agent, :matrix_user_id)

    case access_token do
      nil ->
        Logger.info("Matrix: No access token configured, adapter disabled")
        :ignore

      _ ->
        Logger.info("Matrix: Adapter started (homeserver=#{homeserver}, user=#{user_id})")
        # Start sync loop after init completes
        send(self(), :start_sync)

        {:ok,
         %__MODULE__{
           homeserver: homeserver,
           access_token: access_token,
           user_id: user_id,
           next_batch: @initial_since_fallback,
           connected: true
         }}
    end
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, state.connected, state}
  end

  @impl true
  def handle_call({:send, room_id, message, opts}, _from, state) do
    {result, new_state} = do_send_message(state, room_id, message, opts)
    {:reply, result, new_state}
  end

  @impl true
  def handle_info(:start_sync, state) do
    send(self(), :sync)
    {:noreply, state}
  end

  @impl true
  def handle_info(:sync, state) do
    case do_sync(state) do
      {:ok, new_state} ->
        # Immediately schedule next sync (it will block for up to sync_timeout ms)
        send(self(), :sync)
        {:noreply, new_state}

      {:error, reason} ->
        Logger.warning("Matrix: Sync error: #{inspect(reason)}, retrying in 5s")
        Process.send_after(self(), :sync, 5_000)
        {:noreply, %{state | connected: false}}
    end
  end

  # ── Sync Loop ────────────────────────────────────────────────────────

  defp do_sync(state) do
    params =
      %{timeout: @sync_timeout}
      |> maybe_put(:since, state.next_batch)

    url = "#{state.homeserver}/_matrix/client/v3/sync"

    case Req.get(url,
           params: params,
           headers: [{"authorization", "Bearer #{state.access_token}"}],
           receive_timeout: @request_timeout
         ) do
      {:ok, %{status: 200, body: body}} ->
        next_batch = body["next_batch"]
        new_state = %{state | next_batch: next_batch, connected: true}
        process_sync_response(body, new_state)
        {:ok, new_state}

      {:ok, %{status: 401}} ->
        Logger.warning("Matrix: Access token invalid or expired")
        {:error, :unauthorized}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Matrix: Sync returned #{status}: #{inspect(body)}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.warning("Matrix: Sync HTTP error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp process_sync_response(%{"rooms" => rooms}, state) do
    joined = get_in(rooms, ["join"]) || %{}
    invited = get_in(rooms, ["invite"]) || %{}

    # Accept all room invites
    Enum.each(invited, fn {room_id, _invite_state} ->
      Logger.info("Matrix: Accepting invite to room #{room_id}")
      join_room(state, room_id)
    end)

    # Process timeline events from joined rooms
    Enum.each(joined, fn {room_id, room_data} ->
      events = get_in(room_data, ["timeline", "events"]) || []
      Enum.each(events, fn event -> process_event(event, room_id, state) end)
    end)
  end

  defp process_sync_response(_body, _state), do: :ok

  defp process_event(
         %{
           "type" => "m.room.message",
           "sender" => sender,
           "content" => %{"msgtype" => "m.text", "body" => text}
         } = event,
         room_id,
         state
       ) do
    # Ignore our own messages
    if sender != state.user_id do
      age = get_in(event, ["unsigned", "age"]) || 0

      # Skip events older than 60 seconds to avoid replaying history on startup
      if age < 60_000 do
        Logger.debug("Matrix: Message from #{sender} in #{room_id}: #{text}")
        session_id = "matrix_#{room_id}_#{sender}"
        Session.ensure_loop(session_id, sender, :matrix)

        case Loop.process_message(session_id, text) do
          {:ok, response} ->
            GenServer.call(__MODULE__, {:send, room_id, response, []})

          {:filtered, signal} ->
            Logger.debug("Matrix: Signal filtered (weight=#{signal.weight})")

          {:error, reason} ->
            Logger.warning("Matrix: Agent error for room #{room_id}: #{inspect(reason)}")
        end
      end
    end
  end

  defp process_event(_event, _room_id, _state), do: :ok

  # ── HTTP Helpers ─────────────────────────────────────────────────────

  defp do_send_message(state, room_id, message, _opts) do
    txn_id = state.txn_id + 1

    url =
      "#{state.homeserver}/_matrix/client/v3/rooms/#{URI.encode(room_id)}/send/m.room.message/#{txn_id}"

    body = %{msgtype: "m.text", body: message}

    result =
      case Req.put(url,
             json: body,
             headers: [{"authorization", "Bearer #{state.access_token}"}],
             receive_timeout: @send_timeout
           ) do
        {:ok, %{status: status}} when status in [200, 201] ->
          :ok

        {:ok, %{status: 429, headers: headers}} ->
          retry_after = get_retry_after(headers)
          Logger.warning("Matrix: Rate limited. Retry after #{retry_after}s")
          {:error, {:rate_limited, retry_after}}

        {:ok, %{body: body}} ->
          Logger.warning("Matrix: Send failed: #{inspect(body)}")
          {:error, body}

        {:error, reason} ->
          Logger.warning("Matrix: HTTP error: #{inspect(reason)}")
          {:error, reason}
      end

    {result, %{state | txn_id: txn_id}}
  end

  defp join_room(state, room_id) do
    url = "#{state.homeserver}/_matrix/client/v3/join/#{URI.encode(room_id)}"

    case Req.post(url,
           json: %{},
           headers: [{"authorization", "Bearer #{state.access_token}"}],
           receive_timeout: @send_timeout
         ) do
      {:ok, %{status: status}} when status in [200, 201] ->
        Logger.info("Matrix: Joined room #{room_id}")

      {:ok, %{body: body}} ->
        Logger.warning("Matrix: Failed to join room #{room_id}: #{inspect(body)}")

      {:error, reason} ->
        Logger.warning("Matrix: HTTP error joining room: #{inspect(reason)}")
    end
  end

  # ── Misc Helpers ─────────────────────────────────────────────────────

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp get_retry_after(headers) do
    case List.keyfind(headers, "retry-after", 0) do
      {_, value} -> String.to_integer(value)
      nil -> 5
    end
  end
end
