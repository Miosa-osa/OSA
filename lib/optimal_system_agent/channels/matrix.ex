defmodule OptimalSystemAgent.Channels.Matrix do
  @moduledoc """
  Matrix channel adapter for OSA.

  Connects to any Matrix homeserver via the Client-Server REST API.
  Uses /sync long-polling to receive messages.

  ## Configuration

      config :optimal_system_agent,
        matrix_homeserver: "https://matrix.example.org",
        matrix_access_token: System.get_env("MATRIX_ACCESS_TOKEN"),
        matrix_allowed_users: "@user:server,@other:server"
  """

  use GenServer
  @behaviour OptimalSystemAgent.Channels.Behaviour

  require Logger

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Channels.Chunker
  alias OptimalSystemAgent.Channels.Delivery
  alias OptimalSystemAgent.Events.Bus

  @sync_timeout_ms 30_000

  # Matrix has no per-message character limit; what it enforces is a 65,536
  # *byte* ceiling on the whole event PDU. 4,000 is this adapter's conservative
  # self-imposed budget, and bytes is the unit that ceiling is expressed in.
  # Counting graphemes (as this module used to) meant 4,000 CJK characters
  # measured "under" the limit while weighing 12,000 bytes on the wire.
  @max_message_length 4_000
  @length_unit :bytes

  defstruct [:homeserver, :token, :since, :user_id, allowed_users: MapSet.new(), connected: false]

  @impl OptimalSystemAgent.Channels.Behaviour
  def channel_name, do: :matrix

  @impl OptimalSystemAgent.Channels.Behaviour
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl OptimalSystemAgent.Channels.Behaviour
  def send_message(room_id, text, _opts \\ []) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      _pid -> GenServer.call(__MODULE__, {:send, room_id, text}, 15_000)
    end
  end

  @impl OptimalSystemAgent.Channels.Behaviour
  def connected? do
    case Process.whereis(__MODULE__) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  @impl true
  def init(_opts) do
    homeserver = Application.get_env(:optimal_system_agent, :matrix_homeserver)
    token = Application.get_env(:optimal_system_agent, :matrix_access_token)

    if is_nil(homeserver) or is_nil(token) or homeserver == "" or token == "" do
      Logger.info("[Matrix] Not configured — adapter disabled")
      :ignore
    else
      allowed =
        parse_allowed(Application.get_env(:optimal_system_agent, :matrix_allowed_users, ""))

      state = %__MODULE__{
        homeserver: String.trim_trailing(homeserver, "/"),
        token: token,
        allowed_users: allowed
      }

      # Discover our own user ID
      case whoami(state) do
        {:ok, user_id} ->
          Logger.info("[Matrix] Connected as #{user_id}")
          Bus.emit(:channel_connected, %{channel: :matrix, user_id: user_id})
          send(self(), :sync)
          {:ok, %{state | user_id: user_id, connected: true}}

        {:error, reason} ->
          Logger.error("[Matrix] Auth failed: #{reason}")
          :ignore
      end
    end
  end

  @impl true
  def handle_call({:send, room_id, text}, _from, state) do
    result = send_text(state, room_id, text)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:sync, state) do
    state = do_sync(state)
    send(self(), :sync)
    {:noreply, state}
  end

  # ── Sync Loop ────────────────────────────────────────────────────────

  defp do_sync(state) do
    params = %{timeout: 30_000}
    params = if state.since, do: Map.put(params, :since, state.since), else: params

    url = "#{state.homeserver}/_matrix/client/v3/sync"

    case Req.get(url,
           params: params,
           headers: auth_headers(state),
           receive_timeout: @sync_timeout_ms + 5_000
         ) do
      {:ok, %{status: 200, body: body}} ->
        process_sync(body, state)
        %{state | since: body["next_batch"]}

      {:ok, %{status: status}} ->
        Logger.warning("[Matrix] Sync returned #{status}")
        Process.sleep(5_000)
        state

      {:error, reason} ->
        Logger.warning("[Matrix] Sync failed: #{inspect(reason)}")
        Process.sleep(5_000)
        state
    end
  rescue
    e ->
      Logger.error("[Matrix] Sync error: #{Exception.message(e)}")
      Process.sleep(5_000)
      state
  end

  defp process_sync(%{"rooms" => %{"join" => rooms}}, state) when is_map(rooms) do
    for {room_id, room_data} <- rooms,
        event <- get_in(room_data, ["timeline", "events"]) || [] do
      if event["type"] == "m.room.message" do
        sender = event["sender"]
        # Skip our own messages
        if sender != state.user_id and allowed?(sender, state.allowed_users) do
          text = get_in(event, ["content", "body"]) || ""

          if text != "" do
            Delivery.start_task(:matrix, fn ->
              process_message(room_id, sender, text, state)
            end)
          end
        end
      end
    end
  end

  defp process_sync(_, _state), do: :ok

  defp process_message(room_id, sender, text, state) do
    session_id = "matrix:#{room_id}"
    ensure_session(session_id)

    case Loop.process_message(session_id, text, channel: :matrix, user_id: sender) do
      {:ok, response} -> send_text(state, room_id, response)
      {:error, reason} -> Logger.warning("[Matrix] Agent error: #{inspect(reason)}")
    end
  rescue
    e -> Logger.error("[Matrix] Processing error: #{Exception.message(e)}")
  end

  # ── Sending ──────────────────────────────────────────────────────────

  defp send_text(state, room_id, text) do
    text
    |> chunk_message()
    |> then(&Delivery.send_chunks(:matrix, &1, fn chunk -> put_event(state, room_id, chunk) end))
  rescue
    e ->
      Logger.error("[Matrix] Send failed: #{Exception.message(e)}")
      {:error, :send_failed}
  end

  defp put_event(state, room_id, chunk) do
    txn_id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    url =
      "#{state.homeserver}/_matrix/client/v3/rooms/#{URI.encode(room_id)}/send/m.room.message/#{txn_id}"

    case Req.put(url,
           json: %{msgtype: "m.text", body: chunk},
           headers: auth_headers(state),
           receive_timeout: 10_000
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp whoami(state) do
    case Req.get("#{state.homeserver}/_matrix/client/v3/account/whoami",
           headers: auth_headers(state)
         ) do
      {:ok, %{status: 200, body: %{"user_id" => id}}} -> {:ok, id}
      {:ok, %{status: s}} -> {:error, "HTTP #{s}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp auth_headers(state), do: [{"authorization", "Bearer #{state.token}"}]

  defp parse_allowed(nil), do: MapSet.new()
  defp parse_allowed(""), do: MapSet.new()

  defp parse_allowed(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp allowed?(_sender, allowed) when allowed == %MapSet{}, do: true
  defp allowed?(sender, allowed), do: MapSet.member?(allowed, sender)

  @doc """
  Split an outbound reply into Matrix-sized chunks.

  Public so the chunking contract can be tested against Matrix's real limit and
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
          {Loop, session_id: session_id, channel: :matrix}
        )

        :ok
    end
  rescue
    _ -> :ok
  end
end
