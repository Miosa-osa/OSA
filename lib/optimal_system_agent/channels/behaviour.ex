defmodule OptimalSystemAgent.Channels.Behaviour do
  @moduledoc """
  Behaviour contract for all OSA channel adapters.

  Every adapter is a GenServer that:
  - Registers under its channel_name/0 atom via a named process or Registry
  - Starts only when its required configuration is present
  - Routes inbound messages through Agent.Loop.process_message/2
  - Sends outbound messages via the platform's API

  ## Implementing a Channel Adapter

      defmodule OptimalSystemAgent.Channels.MyChannel do
        use GenServer
        @behaviour OptimalSystemAgent.Channels.Behaviour
        require Logger

        @impl OptimalSystemAgent.Channels.Behaviour
        def channel_name, do: :my_channel

        @impl OptimalSystemAgent.Channels.Behaviour
        def start_link(opts) do
          GenServer.start_link(__MODULE__, opts, name: __MODULE__)
        end

        @impl OptimalSystemAgent.Channels.Behaviour
        def send_message(chat_id, message, opts \\ []) do
          GenServer.call(__MODULE__, {:send, chat_id, message, opts})
        end

        @impl OptimalSystemAgent.Channels.Behaviour
        def connected? do
          case Process.whereis(__MODULE__) do
            nil -> false
            pid -> Process.alive?(pid)
          end
        end
      end
  """

  @doc "Channel identifier atom (e.g. :telegram, :discord, :slack)"
  @callback channel_name() :: atom()

  @doc "Start the channel adapter. Returns a standard GenServer start result."
  @callback start_link(opts :: keyword()) :: GenServer.on_start()

  @doc """
  Send a message to a user/chat on this channel.
  `chat_id` is platform-specific (Telegram chat ID, Discord channel ID, Slack channel, etc.).
  Returns `:ok` on success or `{:error, term}` on failure.
  """
  @callback send_message(chat_id :: String.t(), message :: String.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  @doc "Whether this channel adapter is currently connected and able to send/receive."
  @callback connected?() :: boolean()
end
