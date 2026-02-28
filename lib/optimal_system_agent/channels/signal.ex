defmodule OptimalSystemAgent.Channels.Signal do
  @moduledoc """
  Signal messenger channel adapter via signal-cli REST API.

  Receives messages via webhook from a running signal-cli-rest-api container:
    POST /api/v1/channels/signal/webhook

  Sends messages via the signal-cli REST API.

  ## Setup

  Run signal-cli-rest-api (Docker):

      docker run -d \\
        -p 8080:8080 \\
        -e MODE=native \\
        bbernhard/signal-cli-rest-api

  Then link/register your phone number via the signal-cli API before use.

  ## Configuration

      config :optimal_system_agent,
        signal_api_url: System.get_env("SIGNAL_API_URL"),      # e.g. "http://localhost:8080"
        signal_phone_number: System.get_env("SIGNAL_PHONE_NUMBER")  # e.g. "+15551234567"

  The adapter starts only when `:signal_api_url` is configured.
  """
  use GenServer
  @behaviour OptimalSystemAgent.Channels.Behaviour
  require Logger

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Channels.Session

  @send_timeout 15_000

  defstruct [:api_url, :phone_number, connected: false]

  # ── Behaviour Callbacks ──────────────────────────────────────────────

  @impl OptimalSystemAgent.Channels.Behaviour
  def channel_name, do: :signal

  @impl OptimalSystemAgent.Channels.Behaviour
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl OptimalSystemAgent.Channels.Behaviour
  def send_message(recipient, message, opts \\ []) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      _pid -> GenServer.call(__MODULE__, {:send, recipient, message, opts}, @send_timeout)
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

  @doc "Handle inbound webhook from signal-cli-rest-api (called by HTTP API)."
  def handle_webhook(body) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      _pid -> GenServer.cast(__MODULE__, {:webhook, body})
    end
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────

  @impl true
  def init(_opts) do
    api_url = Application.get_env(:optimal_system_agent, :signal_api_url)
    phone_number = Application.get_env(:optimal_system_agent, :signal_phone_number)

    case api_url do
      nil ->
        Logger.info("Signal: No API URL configured, adapter disabled")
        :ignore

      _ ->
        Logger.info("Signal: Adapter started (api_url=#{api_url}, number=#{phone_number})")
        {:ok, %__MODULE__{api_url: api_url, phone_number: phone_number, connected: true}}
    end
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, state.connected, state}
  end

  @impl true
  def handle_call({:send, recipient, message, opts}, _from, state) do
    result = do_send_message(state.api_url, state.phone_number, recipient, message, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_cast({:webhook, body}, state) do
    spawn(fn -> process_webhook(body, state) end)
    {:noreply, state}
  end

  # ── Webhook Processing ───────────────────────────────────────────────

  # signal-cli-rest-api v2 envelope format
  defp process_webhook(
         %{
           "envelope" => %{
             "dataMessage" => %{"message" => text},
             "source" => source
           }
         } = _body,
         state
       )
       when is_binary(text) do
    session_id = "signal_#{source}"
    Logger.debug("Signal: Message from #{source}: #{text}")

    Session.ensure_loop(session_id, source, :signal)

    case Loop.process_message(session_id, text) do
      {:ok, response} ->
        do_send_message(state.api_url, state.phone_number, source, response, [])

      {:filtered, signal} ->
        Logger.debug("Signal: Signal filtered (weight=#{signal.weight})")

      {:error, reason} ->
        Logger.warning("Signal: Agent error for #{source}: #{inspect(reason)}")

        do_send_message(
          state.api_url,
          state.phone_number,
          source,
          "Sorry, I encountered an error.",
          []
        )
    end
  end

  # Group messages
  defp process_webhook(
         %{
           "envelope" => %{
             "dataMessage" => %{"message" => text, "groupInfo" => %{"groupId" => group_id}},
             "source" => source
           }
         },
         state
       )
       when is_binary(text) do
    session_id = "signal_group_#{group_id}"
    Logger.debug("Signal: Group message from #{source} in #{group_id}: #{text}")

    Session.ensure_loop(session_id, source, :signal)

    case Loop.process_message(session_id, text) do
      {:ok, response} ->
        do_send_group_message(state.api_url, state.phone_number, group_id, response)

      {:filtered, signal} ->
        Logger.debug("Signal: Group signal filtered (weight=#{signal.weight})")

      {:error, reason} ->
        Logger.warning("Signal: Agent error for group #{group_id}: #{inspect(reason)}")
    end
  end

  defp process_webhook(body, _state) do
    Logger.debug("Signal: Unhandled webhook shape: #{inspect(Map.keys(body))}")
  end

  # ── HTTP Helpers ─────────────────────────────────────────────────────

  defp do_send_message(api_url, from_number, recipient, message, _opts) do
    # signal-cli REST API v2 send endpoint
    url = "#{api_url}/v2/send"

    body = %{
      message: message,
      number: from_number,
      recipients: [recipient]
    }

    case Req.post(url, json: body, receive_timeout: @send_timeout) do
      {:ok, %{status: status}} when status in [200, 201] ->
        :ok

      {:ok, %{body: body}} ->
        Logger.warning("Signal: Send failed: #{inspect(body)}")
        {:error, body}

      {:error, reason} ->
        Logger.warning("Signal: HTTP error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_send_group_message(api_url, from_number, group_id, message) do
    url = "#{api_url}/v2/send"

    body = %{
      message: message,
      number: from_number,
      recipients: [group_id]
    }

    case Req.post(url, json: body, receive_timeout: @send_timeout) do
      {:ok, %{status: status}} when status in [200, 201] ->
        :ok

      {:ok, %{body: body}} ->
        Logger.warning("Signal: Group send failed: #{inspect(body)}")
        {:error, body}

      {:error, reason} ->
        Logger.warning("Signal: HTTP error sending to group: #{inspect(reason)}")
        {:error, reason}
    end
  end

end
