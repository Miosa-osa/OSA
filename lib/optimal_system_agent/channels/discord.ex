defmodule OptimalSystemAgent.Channels.Discord do
  @moduledoc """
  Discord channel adapter for OSA.

  Operates in webhook mode for v1: receives parsed interaction/message payloads
  forwarded from the channel_routes.ex webhook endpoint via handle_update/1, and
  sends responses via the Discord REST API (POST /channels/{id}/messages).

  Start/stop is managed by Channels.Manager. The process returns :ignore when
  DISCORD_BOT_TOKEN is absent or empty so the supervisor silently skips it.

  Features:
  - Token validation via GET /users/@me on startup
  - Standard markdown formatting (Discord supports it natively)
  - Long message chunking (2000 char limit)
  - Exponential backoff on send errors
  - Per-channel session routing
  """

  use GenServer
  @behaviour OptimalSystemAgent.Channels.Behaviour

  require Logger

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Channels.Chunker
  alias OptimalSystemAgent.Channels.Delivery
  alias OptimalSystemAgent.Events.Bus

  @discord_api "https://discord.com/api/v10"

  # Initial exponential back-off delay (milliseconds).
  @backoff_initial_ms 1_000

  # Discord message length limit: 2000 "characters", validated server-side as
  # JavaScript `content.length` — i.e. UTF-16 code units. A CJK char costs 1,
  # an astral emoji costs 2, a ZWJ family sequence costs 7-11.
  #
  # The old code tested `byte_size(candidate) > 2000` but then cut with
  # `String.split_at(para, 1990)`, which counts graphemes. On an emoji-heavy
  # paragraph the test tripped at ~500 emoji (4 bytes each) while the cut handed
  # back 1990 emoji — 3980 UTF-16 units, almost 2x Discord's cap. Discord 400'd
  # that chunk, the adapter ignored the result, and the following chunks were
  # still delivered: a hole in the middle of the reply.
  @max_message_length 2_000
  @length_unit :utf16

  # ── Behaviour callbacks ───────────────────────────────────────────────

  @impl OptimalSystemAgent.Channels.Behaviour
  def channel_name, do: :discord

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
  Handle a single parsed Discord message or interaction forwarded via webhook.
  """
  def handle_update(update) when is_map(update) do
    GenServer.cast(__MODULE__, {:webhook_update, update})
  end

  # ── GenServer callbacks ───────────────────────────────────────────────

  @impl true
  def init(_opts) do
    token = Application.get_env(:optimal_system_agent, :discord_bot_token)

    cond do
      is_nil(token) or token == "" ->
        Logger.info("[Discord] No bot token configured — adapter disabled")
        :ignore

      true ->
        case validate_token(token) do
          {:ok, bot_info} ->
            username = bot_info["username"] || "unknown"

            Logger.info(
              "[Discord] Bot connected: #{username}##{bot_info["discriminator"] || "0"} (webhook mode)"
            )

            Bus.emit(:channel_connected, %{channel: :discord, username: username})

            state = %{
              token: token,
              backoff_ms: @backoff_initial_ms,
              username: username
            }

            {:ok, state}

          {:error, reason} ->
            Logger.error("[Discord] Invalid bot token: #{reason}")
            :ignore
        end
    end
  end

  @impl true
  def handle_cast({:webhook_update, update}, state) do
    dispatch_update(update, state.token)
    {:noreply, state}
  end

  @impl true
  def handle_call({:send, channel_id, text}, _from, state) do
    result = send_text(state.token, channel_id, text)
    {:reply, result, state}
  end

  # ── Token Validation ─────────────────────────────────────────────────

  defp validate_token(token) do
    case Req.get("#{@discord_api}/users/@me",
           headers: [{"Authorization", "Bot #{token}"}],
           receive_timeout: 10_000,
           retry: :transient,
           max_retries: 2
         ) do
      {:ok, %{status: 200, body: info}} ->
        {:ok, info}

      {:ok, %{status: 401}} ->
        {:error, "unauthorized — token is invalid or revoked"}

      {:ok, %{status: status, body: body}} ->
        {:error, "status #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ── Message Dispatch ─────────────────────────────────────────────────

  defp dispatch_update(update, token) do
    # Support both direct message events and interaction payloads.
    # Webhook message event shape: %{"channel_id" => ..., "content" => ..., "author" => ...}
    with %{"channel_id" => channel_id, "content" => text} when is_binary(text) and text != "" <-
           update do
      author = update["author"] || %{}
      user_id = author["id"] || channel_id
      # Skip messages from bots (including ourselves) to avoid loops.
      cond do
        author["bot"] == true ->
          :ok

        not channel_allowed?(:discord_allowed_users, [user_id, channel_id]) ->
          Logger.warning("[Discord] Ignoring message from unauthorized user #{inspect(user_id)}")
          :ok

        true ->
          session_id = "discord:#{channel_id}"
          actor_id = "discord:#{user_id}"

          ensure_session(session_id)

          Delivery.start_task(:discord, fn ->
            case Loop.process_message(session_id, text, channel: :discord, user_id: actor_id) do
              {:ok, response} ->
                send_text(token, channel_id, response)

              {:error, reason} ->
                Logger.warning(
                  "[Discord] Loop error for session #{session_id}: #{inspect(reason)}"
                )

                send_text(token, channel_id, "Something went wrong. Please try again.")
            end
          end)
      end
    else
      _ ->
        # Non-text update or unsupported shape — silently ignore.
        :ok
    end
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
               {Loop, session_id: session_id, channel: :discord}
             ) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> Logger.warning("[Discord] Session start failed: #{inspect(reason)}")
        end
    end
  rescue
    _ -> :ok
  end

  # ── Message Sending ───────────────────────────────────────────────────

  defp send_text(token, channel_id, text) do
    text
    |> chunk_message()
    |> then(
      &Delivery.send_chunks(:discord, &1, fn chunk -> post_message(token, channel_id, chunk) end)
    )
  end

  defp post_message(token, channel_id, text) do
    url = "#{@discord_api}/channels/#{channel_id}/messages"

    case Req.post(url,
           headers: [{"Authorization", "Bot #{token}"}],
           json: %{"content" => text},
           receive_timeout: 15_000
         ) do
      {:ok, %{status: status}} when status in [200, 201] ->
        :ok

      {:ok, %{status: 429, body: body}} ->
        retry_after = get_in(body, ["retry_after"]) || 1
        Logger.warning("[Discord] Rate limited — retry_after=#{retry_after}s")
        Process.sleep(trunc(retry_after * 1_000))
        post_message(token, channel_id, text)

      {:ok, %{status: status, body: body}} ->
        Logger.warning("[Discord] POST /messages failed (#{status}): #{inspect(body)}")
        {:error, {status, body}}

      {:error, reason} ->
        Logger.warning("[Discord] POST /messages error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ── Message Chunking ──────────────────────────────────────────────────

  @doc """
  Split an outbound reply into Discord-sized chunks.

  Public so the chunking contract can be tested against Discord's real limit
  and unit rather than against a copy of them.
  """
  @spec chunk_message(String.t()) :: [String.t()]
  def chunk_message(text), do: Chunker.chunk(text, @max_message_length, @length_unit)

  @doc false
  @spec message_limit() :: {pos_integer(), Chunker.unit()}
  def message_limit, do: {@max_message_length, @length_unit}
end
