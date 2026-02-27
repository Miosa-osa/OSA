defmodule OptimalSystemAgent.Channels.WhatsApp do
  @moduledoc """
  WhatsApp Business API channel adapter using the Meta Cloud API.

  Receives messages via webhook:
    POST /api/v1/channels/whatsapp/webhook  — inbound messages
    GET  /api/v1/channels/whatsapp/webhook  — Meta verification challenge

  Sends messages via the Graph API.

  ## Configuration

      config :optimal_system_agent,
        whatsapp_token: System.get_env("WHATSAPP_TOKEN"),
        whatsapp_phone_number_id: System.get_env("WHATSAPP_PHONE_NUMBER_ID"),
        whatsapp_verify_token: System.get_env("WHATSAPP_VERIFY_TOKEN")

  - `:whatsapp_token` — Meta Graph API access token (permanent or temporary)
  - `:whatsapp_phone_number_id` — Phone number ID from Meta Developer Console
  - `:whatsapp_verify_token` — Any secret string you set in the Meta webhook config

  The adapter starts only when `:whatsapp_token` is configured.
  """
  use GenServer
  @behaviour OptimalSystemAgent.Channels.Behaviour
  require Logger

  alias OptimalSystemAgent.Agent.Loop

  @api_version "v21.0"
  @graph_base "https://graph.facebook.com"
  @send_timeout 15_000

  defstruct [:token, :phone_number_id, :verify_token, connected: false]

  # ── Behaviour Callbacks ──────────────────────────────────────────────

  @impl OptimalSystemAgent.Channels.Behaviour
  def channel_name, do: :whatsapp

  @impl OptimalSystemAgent.Channels.Behaviour
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl OptimalSystemAgent.Channels.Behaviour
  def send_message(phone_number, message, opts \\ []) do
    mode = Application.get_env(:optimal_system_agent, :whatsapp_mode, "auto")

    case resolve_mode(mode) do
      :web ->
        OptimalSystemAgent.WhatsAppWeb.send_message(phone_number, message)

      :api ->
        case Process.whereis(__MODULE__) do
          nil -> {:error, :not_started}
          _pid -> GenServer.call(__MODULE__, {:send, phone_number, message, opts}, @send_timeout)
        end
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
  Handle inbound webhook POST from Meta (called by HTTP API).
  Parses the WhatsApp webhook payload and processes messages.
  """
  def handle_webhook(body) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      _pid -> GenServer.cast(__MODULE__, {:webhook, body})
    end
  end

  @doc """
  Verify the Meta webhook subscription challenge (GET request).
  Returns `{:ok, challenge}` if the verify token matches, `{:error, :forbidden}` otherwise.
  """
  def verify_challenge(params) do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :not_started}

      _pid ->
        GenServer.call(__MODULE__, {:verify, params})
    end
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────

  @impl true
  def init(_opts) do
    token = Application.get_env(:optimal_system_agent, :whatsapp_token)
    phone_number_id = Application.get_env(:optimal_system_agent, :whatsapp_phone_number_id)

    verify_token =
      Application.get_env(:optimal_system_agent, :whatsapp_verify_token, "osa_whatsapp_verify")

    case token do
      nil ->
        Logger.info("WhatsApp: No token configured, adapter disabled")
        :ignore

      _ ->
        Logger.info("WhatsApp: Adapter started (phone_number_id=#{phone_number_id})")

        {:ok,
         %__MODULE__{
           token: token,
           phone_number_id: phone_number_id,
           verify_token: verify_token,
           connected: true
         }}
    end
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, state.connected, state}
  end

  @impl true
  def handle_call({:send, phone_number, message, opts}, _from, state) do
    result = do_send_message(state.token, state.phone_number_id, phone_number, message, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:verify, params}, _from, state) do
    mode = params["hub.mode"]
    challenge = params["hub.challenge"]
    token = params["hub.verify_token"]

    if mode == "subscribe" and token == state.verify_token do
      Logger.info("WhatsApp: Webhook verification succeeded")
      {:reply, {:ok, challenge}, state}
    else
      Logger.warning("WhatsApp: Webhook verification failed (token mismatch)")
      {:reply, {:error, :forbidden}, state}
    end
  end

  @impl true
  def handle_cast({:webhook, body}, state) do
    spawn(fn -> process_webhook(body, state) end)
    {:noreply, state}
  end

  # ── Webhook Processing ───────────────────────────────────────────────

  defp process_webhook(%{"object" => "whatsapp_business_account", "entry" => entries}, state) do
    Enum.each(entries, fn entry ->
      Enum.each(entry["changes"] || [], fn change ->
        process_change(change["value"], state)
      end)
    end)
  end

  defp process_webhook(body, _state) do
    Logger.debug("WhatsApp: Unhandled webhook object: #{inspect(body["object"])}")
  end

  defp process_change(%{"messages" => messages, "contacts" => contacts} = _value, state)
       when is_list(messages) do
    contact_map =
      (contacts || [])
      |> Enum.reduce(%{}, fn c, acc ->
        Map.put(acc, c["wa_id"], c["profile"]["name"])
      end)

    Enum.each(messages, fn msg ->
      process_message(msg, contact_map, state)
    end)
  end

  defp process_change(_value, _state), do: :ok

  defp process_message(
         %{"from" => from, "type" => "text", "text" => %{"body" => text}},
         contacts,
         state
       ) do
    session_id = "whatsapp_#{from}"
    name = Map.get(contacts, from, from)
    Logger.debug("WhatsApp: Message from #{name} (#{from}): #{text}")

    # Mark message as read
    mark_read(state.token, state.phone_number_id, from)

    ensure_loop(session_id, from)

    case Loop.process_message(session_id, text) do
      {:ok, response} ->
        do_send_message(state.token, state.phone_number_id, from, response, [])

      {:filtered, signal} ->
        Logger.debug("WhatsApp: Signal filtered (weight=#{signal.weight})")

      {:error, reason} ->
        Logger.warning("WhatsApp: Agent error for #{from}: #{inspect(reason)}")

        do_send_message(
          state.token,
          state.phone_number_id,
          from,
          "Sorry, I encountered an error.",
          []
        )
    end
  end

  defp process_message(%{"type" => type}, _contacts, _state) do
    Logger.debug("WhatsApp: Unsupported message type: #{type}")
  end

  # ── HTTP Helpers ─────────────────────────────────────────────────────

  defp do_send_message(token, phone_number_id, to, message, _opts) do
    url = "#{@graph_base}/#{@api_version}/#{phone_number_id}/messages"

    body = %{
      messaging_product: "whatsapp",
      recipient_type: "individual",
      to: to,
      type: "text",
      text: %{preview_url: false, body: message}
    }

    case Req.post(url,
           json: body,
           headers: [{"authorization", "Bearer #{token}"}],
           receive_timeout: @send_timeout
         ) do
      {:ok, %{status: status}} when status in [200, 201] ->
        :ok

      {:ok, %{status: 429, headers: headers}} ->
        retry_after = get_retry_after(headers)
        Logger.warning("WhatsApp: Rate limited. Retry after #{retry_after}s")
        {:error, {:rate_limited, retry_after}}

      {:ok, %{body: body}} ->
        Logger.warning("WhatsApp: Send failed: #{inspect(body)}")
        {:error, body}

      {:error, reason} ->
        Logger.warning("WhatsApp: HTTP error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp mark_read(token, phone_number_id, message_id) do
    url = "#{@graph_base}/#{@api_version}/#{phone_number_id}/messages"

    Req.post(url,
      json: %{
        messaging_product: "whatsapp",
        status: "read",
        message_id: message_id
      },
      headers: [{"authorization", "Bearer #{token}"}],
      receive_timeout: 5_000
    )
  end

  defp ensure_loop(session_id, user_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{_pid, _}] ->
        :ok

      [] ->
        DynamicSupervisor.start_child(
          OptimalSystemAgent.Channels.Supervisor,
          {Loop, session_id: session_id, user_id: to_string(user_id), channel: :whatsapp}
        )
    end
  end

  defp resolve_mode("web"), do: :web
  defp resolve_mode("api"), do: :api

  defp resolve_mode(_auto) do
    if OptimalSystemAgent.WhatsAppWeb.available?(), do: :web, else: :api
  end

  defp get_retry_after(headers) do
    case List.keyfind(headers, "retry-after", 0) do
      {_, value} -> String.to_integer(value)
      nil -> 60
    end
  end
end
