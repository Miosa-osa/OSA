defmodule OptimalSystemAgent.Channels.Email do
  @moduledoc """
  Email channel adapter.

  Inbound: Webhook from email service (SendGrid/Mailgun inbound parse) at:
    POST /api/v1/channels/email/inbound

  Outbound: SMTP via Erlang's built-in `:gen_tcp` or via an HTTP API.
  Uses the SendGrid or Mailgun HTTP API when `:email_api_key` is configured,
  falls back to SMTP (`:email_smtp_*`) otherwise.

  ## Configuration

      config :optimal_system_agent,
        email_from: System.get_env("EMAIL_FROM"),              # "bot@yourdomain.com"
        email_from_name: System.get_env("EMAIL_FROM_NAME"),    # "OSA Agent"

        # Option A: HTTP API (SendGrid)
        email_api_key: System.get_env("SENDGRID_API_KEY"),
        email_api_provider: :sendgrid,   # or :mailgun

        # Option B: SMTP
        email_smtp_host: System.get_env("EMAIL_SMTP_HOST"),    # "smtp.gmail.com"
        email_smtp_port: 587,
        email_smtp_user: System.get_env("EMAIL_SMTP_USER"),
        email_smtp_password: System.get_env("EMAIL_SMTP_PASSWORD"),
        email_smtp_tls: :always  # or :never

  The adapter starts only when `:email_from` is configured.

  ## Thread tracking
  Reply subjects are prefixed with `Re: ` and the conversation is tracked
  per sender email address.
  """
  use GenServer
  @behaviour OptimalSystemAgent.Channels.Behaviour
  require Logger

  alias OptimalSystemAgent.Agent.Loop

  @send_timeout 15_000

  @sendgrid_api "https://api.sendgrid.com/v3/mail/send"
  @mailgun_api_base "https://api.mailgun.net/v3"

  defstruct [
    :from_email,
    :from_name,
    :api_key,
    :api_provider,
    :smtp_config,
    connected: false
  ]

  # ── Behaviour Callbacks ──────────────────────────────────────────────

  @impl OptimalSystemAgent.Channels.Behaviour
  def channel_name, do: :email

  @impl OptimalSystemAgent.Channels.Behaviour
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl OptimalSystemAgent.Channels.Behaviour
  def send_message(to_email, message, opts \\ []) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      _pid -> GenServer.call(__MODULE__, {:send, to_email, message, opts}, @send_timeout)
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

  @doc "Handle inbound email webhook from SendGrid/Mailgun (called by HTTP API)."
  def handle_inbound(params) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      _pid -> GenServer.cast(__MODULE__, {:inbound, params})
    end
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────

  @impl true
  def init(_opts) do
    from_email = Application.get_env(:optimal_system_agent, :email_from)
    from_name = Application.get_env(:optimal_system_agent, :email_from_name, "OSA Agent")
    api_key = Application.get_env(:optimal_system_agent, :email_api_key)
    api_provider = Application.get_env(:optimal_system_agent, :email_api_provider, :sendgrid)
    smtp_config = build_smtp_config()

    case from_email do
      nil ->
        Logger.info("Email: No from address configured, adapter disabled")
        :ignore

      _ ->
        Logger.info("Email: Adapter started (from=#{from_email}, provider=#{api_provider})")

        {:ok,
         %__MODULE__{
           from_email: from_email,
           from_name: from_name,
           api_key: api_key,
           api_provider: api_provider,
           smtp_config: smtp_config,
           connected: true
         }}
    end
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, state.connected, state}
  end

  @impl true
  def handle_call({:send, to_email, message, opts}, _from, state) do
    result = do_send_email(state, to_email, message, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_cast({:inbound, params}, state) do
    spawn(fn -> process_inbound(params, state) end)
    {:noreply, state}
  end

  # ── Inbound Processing ───────────────────────────────────────────────

  # SendGrid inbound parse format
  defp process_inbound(%{"from" => from_raw, "text" => text} = params, state) do
    from_email = extract_email(from_raw)
    subject = params["subject"] || "(no subject)"

    Logger.debug("Email: Inbound from #{from_email}: #{subject}")

    session_id = "email_#{sanitize_email(from_email)}"
    ensure_loop(session_id, from_email)

    case Loop.process_message(session_id, text) do
      {:ok, response} ->
        reply_subject = if String.starts_with?(subject, "Re: "), do: subject, else: "Re: #{subject}"
        do_send_email(state, from_email, response, subject: reply_subject)

      {:filtered, signal} ->
        Logger.debug("Email: Signal filtered (weight=#{signal.weight})")

      {:error, reason} ->
        Logger.warning("Email: Agent error for #{from_email}: #{inspect(reason)}")
    end
  end

  # Mailgun inbound format
  defp process_inbound(%{"sender" => sender, "body-plain" => text} = params, state) do
    subject = params["subject"] || "(no subject)"
    Logger.debug("Email: Mailgun inbound from #{sender}: #{subject}")

    process_inbound(%{"from" => sender, "text" => text, "subject" => subject}, state)
  end

  defp process_inbound(params, _state) do
    Logger.debug("Email: Unhandled inbound format: #{inspect(Map.keys(params))}")
  end

  # ── Send Helpers ─────────────────────────────────────────────────────

  defp do_send_email(state, to_email, message, opts) do
    cond do
      not is_nil(state.api_key) ->
        case state.api_provider do
          :sendgrid -> send_via_sendgrid(state, to_email, message, opts)
          :mailgun -> send_via_mailgun(state, to_email, message, opts)
          _ -> send_via_sendgrid(state, to_email, message, opts)
        end

      not is_nil(state.smtp_config) ->
        send_via_smtp(state, to_email, message, opts)

      true ->
        Logger.warning("Email: No send method configured (need api_key or smtp config)")
        {:error, :no_send_method}
    end
  end

  defp send_via_sendgrid(state, to_email, message, opts) do
    subject = Keyword.get(opts, :subject, "Message from OSA Agent")

    body = %{
      personalizations: [%{to: [%{email: to_email}]}],
      from: %{email: state.from_email, name: state.from_name},
      subject: subject,
      content: [%{type: "text/plain", value: message}]
    }

    case Req.post(@sendgrid_api,
           json: body,
           headers: [{"authorization", "Bearer #{state.api_key}"}],
           receive_timeout: @send_timeout
         ) do
      {:ok, %{status: status}} when status in [200, 201, 202] ->
        :ok

      {:ok, %{status: 429, headers: headers}} ->
        retry_after = get_retry_after(headers)
        Logger.warning("Email (SendGrid): Rate limited. Retry after #{retry_after}s")
        {:error, {:rate_limited, retry_after}}

      {:ok, %{body: body}} ->
        Logger.warning("Email (SendGrid): Send failed: #{inspect(body)}")
        {:error, body}

      {:error, reason} ->
        Logger.warning("Email (SendGrid): HTTP error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp send_via_mailgun(state, to_email, message, opts) do
    subject = Keyword.get(opts, :subject, "Message from OSA Agent")
    domain = Keyword.get(opts, :domain) || extract_domain(state.from_email)
    url = "#{@mailgun_api_base}/#{domain}/messages"

    form_data = %{
      from: "#{state.from_name} <#{state.from_email}>",
      to: to_email,
      subject: subject,
      text: message
    }

    # Mailgun uses HTTP Basic auth: api:<api_key>
    encoded_key = Base.encode64("api:#{state.api_key}")

    case Req.post(url,
           form: form_data,
           headers: [{"authorization", "Basic #{encoded_key}"}],
           receive_timeout: @send_timeout
         ) do
      {:ok, %{status: status}} when status in [200, 201] ->
        :ok

      {:ok, %{status: 429, headers: headers}} ->
        retry_after = get_retry_after(headers)
        Logger.warning("Email (Mailgun): Rate limited. Retry after #{retry_after}s")
        {:error, {:rate_limited, retry_after}}

      {:ok, %{body: body}} ->
        Logger.warning("Email (Mailgun): Send failed: #{inspect(body)}")
        {:error, body}

      {:error, reason} ->
        Logger.warning("Email (Mailgun): HTTP error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp send_via_smtp(state, to_email, message, opts) do
    subject = Keyword.get(opts, :subject, "Message from OSA Agent")
    smtp = state.smtp_config

    # Build a minimal RFC 2822 message
    raw_email =
      """
      From: #{state.from_name} <#{state.from_email}>
      To: #{to_email}
      Subject: #{subject}
      MIME-Version: 1.0
      Content-Type: text/plain; charset=utf-8
      Content-Transfer-Encoding: quoted-printable

      #{message}
      """

    smtp_mod = :gen_smtp_client

    try do
      smtp_opts = [
        relay: to_charlist(smtp.host),
        port: smtp.port,
        username: to_charlist(smtp.user),
        password: to_charlist(smtp.password),
        tls: smtp.tls,
        auth: :always
      ]

      apply(smtp_mod, :send_blocking, [{state.from_email, [to_email], raw_email}, smtp_opts])
      :ok
    rescue
      e ->
        Logger.warning("Email (SMTP): Send error: #{inspect(e)}")
        {:error, e}
    catch
      kind, reason ->
        Logger.warning("Email (SMTP): #{kind}: #{inspect(reason)}")
        {:error, {kind, reason}}
    end
  end

  # ── Config Helpers ───────────────────────────────────────────────────

  defp build_smtp_config do
    host = Application.get_env(:optimal_system_agent, :email_smtp_host)

    case host do
      nil ->
        nil

      _ ->
        %{
          host: host,
          port: Application.get_env(:optimal_system_agent, :email_smtp_port, 587),
          user: Application.get_env(:optimal_system_agent, :email_smtp_user),
          password: Application.get_env(:optimal_system_agent, :email_smtp_password),
          tls: Application.get_env(:optimal_system_agent, :email_smtp_tls, :always)
        }
    end
  end

  defp ensure_loop(session_id, user_id) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{_pid, _}] ->
        :ok

      [] ->
        DynamicSupervisor.start_child(
          OptimalSystemAgent.Channels.Supervisor,
          {Loop, session_id: session_id, user_id: to_string(user_id), channel: :email}
        )
    end
  end

  defp extract_email(raw) when is_binary(raw) do
    # Parse "Name <email@example.com>" or plain "email@example.com"
    case Regex.run(~r/<([^>]+)>/, raw) do
      [_, email] -> String.trim(email)
      nil -> String.trim(raw)
    end
  end

  defp sanitize_email(email) do
    String.replace(email, ~r/[^a-zA-Z0-9@._-]/, "_")
  end

  defp extract_domain(email) do
    case String.split(email, "@") do
      [_, domain] -> domain
      _ -> "example.com"
    end
  end

  defp get_retry_after(headers) do
    case List.keyfind(headers, "retry-after", 0) do
      {_, value} -> String.to_integer(value)
      nil -> 60
    end
  end
end
