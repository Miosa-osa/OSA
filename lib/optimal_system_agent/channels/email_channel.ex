defmodule OptimalSystemAgent.Channels.EmailChannel do
  @moduledoc """
  Email channel adapter for OSA.

  Uses IMAP to receive and SMTP to send messages.

  ## Configuration

      config :optimal_system_agent,
        email_imap_host: "imap.gmail.com",
        email_imap_port: 993,
        email_smtp_host: "smtp.gmail.com",
        email_smtp_port: 587,
        email_address: "agent@example.com",
        email_password: System.get_env("EMAIL_PASSWORD"),
        email_poll_interval: 15,
        email_allowed_senders: "user@example.com"
  """

  use GenServer
  @behaviour OptimalSystemAgent.Channels.Behaviour

  require Logger

  alias OptimalSystemAgent.Agent.Loop

  @default_poll_interval 15_000

  defstruct [
    :imap_host, :imap_port, :smtp_host, :smtp_port,
    :address, :password, :poll_timer,
    allowed_senders: MapSet.new(), connected: false
  ]

  @impl OptimalSystemAgent.Channels.Behaviour
  def channel_name, do: :email

  @impl OptimalSystemAgent.Channels.Behaviour
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl OptimalSystemAgent.Channels.Behaviour
  def send_message(to_address, text, opts \\ []) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      _pid -> GenServer.call(__MODULE__, {:send, to_address, text, opts}, 30_000)
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
    address = Application.get_env(:optimal_system_agent, :email_address)
    password = Application.get_env(:optimal_system_agent, :email_password)
    imap_host = Application.get_env(:optimal_system_agent, :email_imap_host)

    if is_nil(address) or is_nil(password) or is_nil(imap_host) do
      Logger.info("[Email] Not configured — adapter disabled")
      :ignore
    else
      poll_ms = (Application.get_env(:optimal_system_agent, :email_poll_interval, 15) || 15) * 1_000
      allowed = parse_allowed(Application.get_env(:optimal_system_agent, :email_allowed_senders, ""))

      state = %__MODULE__{
        imap_host: imap_host,
        imap_port: Application.get_env(:optimal_system_agent, :email_imap_port, 993),
        smtp_host: Application.get_env(:optimal_system_agent, :email_smtp_host, "smtp.gmail.com"),
        smtp_port: Application.get_env(:optimal_system_agent, :email_smtp_port, 587),
        address: address,
        password: password,
        allowed_senders: allowed,
        connected: true
      }

      Logger.info("[Email] Adapter started — #{address}")
      timer = Process.send_after(self(), :poll_inbox, poll_ms)
      {:ok, %{state | poll_timer: timer}}
    end
  end

  @impl true
  def handle_call({:send, to, text, opts}, _from, state) do
    subject = Keyword.get(opts, :subject, "OSA Agent Response")
    result = send_email(state, to, subject, text)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:poll_inbox, state) do
    poll_imap(state)
    poll_ms = Application.get_env(:optimal_system_agent, :email_poll_interval, 15) * 1_000
    timer = Process.send_after(self(), :poll_inbox, poll_ms)
    {:noreply, %{state | poll_timer: timer}}
  end

  # ── IMAP Polling ─────────────────────────────────────────────────────

  defp poll_imap(state) do
    case connect_imap(state) do
      {:ok, imap_pid} ->
        fetch_unseen(imap_pid, state)
        :ssl.close(imap_pid)

      {:error, reason} ->
        Logger.warning("[Email] IMAP connection failed: #{inspect(reason)}")
    end
  rescue
    e -> Logger.error("[Email] IMAP poll error: #{Exception.message(e)}")
  end

  defp connect_imap(state) do
    host = to_charlist(state.imap_host)
    port = state.imap_port

    ssl_opts = [verify: :verify_none]

    case :ssl.connect(host, port, ssl_opts, 10_000) do
      {:ok, socket} ->
        # Read greeting
        :ssl.recv(socket, 0, 5_000)

        # Login
        send_imap(socket, "A001 LOGIN #{state.address} #{state.password}")
        case recv_imap(socket) do
          {:ok, response} ->
            if String.contains?(response, "OK") do
              {:ok, socket}
            else
              :ssl.close(socket)
              {:error, "Login failed"}
            end

          error ->
            :ssl.close(socket)
            error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_unseen(socket, state) do
    send_imap(socket, "A002 SELECT INBOX")
    recv_imap(socket)

    send_imap(socket, "A003 SEARCH UNSEEN")
    case recv_imap(socket) do
      {:ok, response} ->
        ids = parse_search_response(response)

        for id <- Enum.take(ids, 10) do
          send_imap(socket, "A004 FETCH #{id} (BODY[HEADER.FIELDS (FROM SUBJECT)] BODY[TEXT])")
          case recv_imap(socket) do
            {:ok, raw} ->
              {from, subject, body} = parse_email(raw)

              if allowed_sender?(from, state.allowed_senders) and not automated_email?(from) do
                # Mark as seen
                send_imap(socket, "A005 STORE #{id} +FLAGS (\\Seen)")
                recv_imap(socket)

                Task.Supervisor.start_child(OptimalSystemAgent.Events.TaskSupervisor, fn ->
                  process_email(from, subject, body, state)
                end)
              end

            _ -> :ok
          end
        end

      _ -> :ok
    end
  end

  defp process_email(from, subject, body, state) do
    session_id = "email:#{from}"

    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{_, _}] -> :ok
      [] -> DynamicSupervisor.start_child(OptimalSystemAgent.SessionSupervisor, {Loop, session_id: session_id, channel: :email})
    end

    text = "Subject: #{subject}\n\n#{body}"

    case Loop.process_message(session_id, text, channel: :email, user_id: from) do
      {:ok, response} ->
        reply_subject = if String.starts_with?(subject, "Re: "), do: subject, else: "Re: #{subject}"
        send_email(state, from, reply_subject, response)

      {:error, reason} ->
        Logger.warning("[Email] Agent error: #{inspect(reason)}")
    end
  rescue
    e -> Logger.error("[Email] Processing error: #{Exception.message(e)}")
  end

  # ── SMTP Sending ─────────────────────────────────────────────────────

  defp send_email(state, to, subject, body) do
    message = build_email_message(state.address, to, subject, body)

    case :gen_smtp_client.send_blocking(
           {state.address, [to], message},
           [
             relay: to_charlist(state.smtp_host),
             port: state.smtp_port,
             username: to_charlist(state.address),
             password: to_charlist(state.password),
             tls: :always,
             auth: :always,
             ssl_options: [verify: :verify_none]
           ]
         ) do
      binary when is_binary(binary) -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e ->
      Logger.error("[Email] SMTP send failed: #{Exception.message(e)}")
      {:error, :send_failed}
  end

  defp build_email_message(from, to, subject, body) do
    "From: #{from}\r\nTo: #{to}\r\nSubject: #{subject}\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n#{body}"
  end

  # ── IMAP Helpers ─────────────────────────────────────────────────────

  defp send_imap(socket, command), do: :ssl.send(socket, "#{command}\r\n")

  defp recv_imap(socket) do
    case :ssl.recv(socket, 0, 10_000) do
      {:ok, data} -> {:ok, to_string(data)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_search_response(response) do
    case Regex.run(~r/\* SEARCH (.+)/, response) do
      [_, ids_str] -> String.split(ids_str) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
      _ -> []
    end
  end

  defp parse_email(raw) do
    from = case Regex.run(~r/From:\s*(.+)/i, raw) do
      [_, f] -> String.trim(f) |> extract_email_address()
      _ -> "unknown"
    end

    subject = case Regex.run(~r/Subject:\s*(.+)/i, raw) do
      [_, s] -> String.trim(s)
      _ -> "(no subject)"
    end

    body = case String.split(raw, "\r\n\r\n", parts: 2) do
      [_, b] -> String.trim(b) |> String.replace(~r/\)$/, "")
      _ -> ""
    end

    {from, subject, body}
  end

  defp extract_email_address(str) do
    case Regex.run(~r/<([^>]+)>/, str) do
      [_, addr] -> addr
      _ -> str
    end
  end

  defp automated_email?(from) do
    lower = String.downcase(from)
    Enum.any?(~w(noreply no-reply donotreply mailer-daemon postmaster bounce), &String.contains?(lower, &1))
  end

  defp parse_allowed(nil), do: MapSet.new()
  defp parse_allowed(""), do: MapSet.new()
  defp parse_allowed(str), do: str |> String.split(",") |> Enum.map(&String.trim/1) |> MapSet.new()

  defp allowed_sender?(_from, allowed) when allowed == %MapSet{}, do: true
  defp allowed_sender?(from, allowed), do: MapSet.member?(allowed, String.downcase(from))
end
