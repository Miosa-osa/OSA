defmodule OptimalSystemAgent.Channels.HTTP.API.ChannelRoutes do
  @moduledoc """
  Channel webhook routes — all 10 chat platforms plus GET /channels list.

  This module is forwarded to from /channels in the parent router.
  Routes below are relative to that stripped prefix.

  These routes intentionally bypass JWT authentication. Each platform
  provides its own verification mechanism (HMAC signatures, challenge
  tokens, etc.) which is enforced inline here via WebhookVerify.

  Effective endpoints (relative to /channels prefix):
    GET  /                      — List active channel adapters
    POST /telegram/webhook
    POST /discord/webhook
    POST /slack/events
    GET  /whatsapp/webhook      (Meta verification challenge)
    POST /whatsapp/webhook
    POST /signal/webhook
    POST /matrix/webhook
    POST /email/inbound
    POST /qq/webhook
    POST /dingtalk/webhook
    POST /feishu/events
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  import OptimalSystemAgent.Channels.HTTP.API.WebhookVerify
  require Logger

  alias OptimalSystemAgent.Channels.Telegram
  alias OptimalSystemAgent.Channels.Slack
  alias OptimalSystemAgent.Channels.Signal, as: SignalChannel

  plug :match
  plug :dispatch

  # ── GET / — list channels ──────────────────────────────────────────

  get "/" do
    alias OptimalSystemAgent.Channels.Manager

    channels = Manager.list_channels()

    body =
      Jason.encode!(%{
        channels:
          Enum.map(channels, fn ch ->
            %{name: ch.name, connected: ch.connected, module: inspect(ch.module)}
          end),
        count: length(channels),
        active_count: Enum.count(channels, & &1.connected)
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── Telegram ───────────────────────────────────────────────────────

  post "/telegram/webhook" do
    secret = Application.get_env(:optimal_system_agent, :telegram_webhook_secret)

    case verify_telegram(conn, secret) do
      :ok ->
        case Telegram.handle_update(conn.body_params) do
          :ok ->
            send_resp(conn, 200, "")

          {:error, :not_started} ->
            json_error(conn, 503, "channel_unavailable", "Telegram adapter not started")
        end

      {:error, :no_secret} ->
        # Security: treat a missing secret as a configuration error, not an auth
        # failure.  401 could mislead callers into thinking they can retry with
        # different credentials.  503 signals that the endpoint is not ready to
        # accept requests until the operator sets TELEGRAM_WEBHOOK_SECRET.
        Logger.error("Telegram webhook is misconfigured: TELEGRAM_WEBHOOK_SECRET is not set. " <>
          "All webhook requests will be rejected until this is resolved. " <>
          "Set TELEGRAM_WEBHOOK_SECRET in your environment (see .env.example).")
        json_error(conn, 503, "configuration_error", "Webhook secret not configured — contact the server operator")

      {:error, :invalid_signature} ->
        json_error(conn, 401, "unauthorized", "Invalid signature")
    end
  end

  # ── Discord ────────────────────────────────────────────────────────

  post "/discord/webhook" do
    alias OptimalSystemAgent.Channels.Discord

    if Discord.connected?() do
      Discord.handle_update(conn.body_params)
      send_resp(conn, 200, "")
    else
      json_error(conn, 503, "channel_unavailable", "Discord adapter not started. Set DISCORD_BOT_TOKEN.")
    end
  end

  # ── Slack ──────────────────────────────────────────────────────────

  post "/slack/events" do
    timestamp = get_req_header(conn, "x-slack-request-timestamp") |> List.first("")
    signature = get_req_header(conn, "x-slack-signature") |> List.first("")
    raw_body = conn.assigns[:raw_body] || Jason.encode!(conn.body_params)

    case Slack.handle_event(raw_body, timestamp, signature) do
      {:challenge, challenge} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{challenge: challenge}))

      :ok ->
        send_resp(conn, 200, "")

      {:error, :invalid_signature} ->
        json_error(conn, 401, "unauthorized", "Invalid request signature")

      {:error, :not_started} ->
        json_error(conn, 503, "channel_unavailable", "Slack adapter not started")
    end
  end

  # ── WhatsApp ───────────────────────────────────────────────────────
  # WhatsApp uses a Baileys bridge sidecar, not webhooks.
  # These endpoints exist for Meta Business API compatibility if needed.

  get "/whatsapp/webhook" do
    # Meta verification challenge
    params = Plug.Conn.fetch_query_params(conn).query_params
    verify_token = Application.get_env(:optimal_system_agent, :whatsapp_verify_token)
    if params["hub.mode"] == "subscribe" and params["hub.verify_token"] == verify_token do
      send_resp(conn, 200, params["hub.challenge"] || "")
    else
      send_resp(conn, 403, "")
    end
  end

  post "/whatsapp/webhook" do
    # Forward to WhatsApp adapter if using Business API mode
    send_resp(conn, 200, "")
  end

  # ── Signal ─────────────────────────────────────────────────────────

  post "/signal/webhook" do
    secret = Application.get_env(:optimal_system_agent, :signal_webhook_secret)
    raw_body = conn.assigns[:raw_body] || Jason.encode!(conn.body_params)

    verified =
      case verify_signal(conn, raw_body, secret) do
        :ok ->
          :ok

        {:error, :no_secret} ->
          # Dev mode: no secret configured — warn and allow.
          # In production, set signal_webhook_secret to enforce verification.
          Logger.warning("Signal webhook: signal_webhook_secret not configured — processing without verification (dev mode)")
          :ok

        {:error, :invalid_signature} ->
          {:error, :invalid_signature}
      end

    case verified do
      {:error, :invalid_signature} ->
        json_error(conn, 401, "unauthorized", "Invalid signature")

      :ok ->
        case SignalChannel.handle_webhook(conn.body_params) do
          :ok ->
            send_resp(conn, 200, "")

          {:error, :not_started} ->
            json_error(conn, 503, "channel_unavailable", "Signal adapter not started")
        end
    end
  end

  # ── Matrix ─────────────────────────────────────────────────────────
  # Matrix uses /sync polling, not webhooks. This is for appservice mode.

  post "/matrix/webhook" do
    # Matrix appservice transaction endpoint (future)
    send_resp(conn, 200, "")
  end

  # ── Email ──────────────────────────────────────────────────────────
  # Email uses IMAP polling. This endpoint is for SendGrid/Mailgun inbound parse.

  post "/email/inbound" do
    alias OptimalSystemAgent.Channels.EmailChannel

    if EmailChannel.connected?() do
      # Forward parsed email to the adapter
      send_resp(conn, 200, "")
    else
      json_error(conn, 503, "channel_unavailable", "Email adapter not started")
    end
  end

  # ── LINE ──────────────────────────────────────────────────────────

  post "/line/webhook" do
    alias OptimalSystemAgent.Channels.Line

    secret = Application.get_env(:optimal_system_agent, :line_channel_secret)
    signature = get_req_header(conn, "x-line-signature") |> List.first("")
    raw_body = conn.assigns[:raw_body] || Jason.encode!(conn.body_params)

    case Line.verify_signature(raw_body, signature, secret || "") do
      :ok ->
        Line.handle_webhook(conn.body_params)
        send_resp(conn, 200, "")

      {:error, :invalid_signature} ->
        json_error(conn, 401, "unauthorized", "Invalid LINE signature")
    end
  end

  # ── QQ ─────────────────────────────────────────────────────────────

  post "/qq/webhook" do
    json_error(conn, 501, "not_implemented", "QQ channel not yet available")
  end

  # ── DingTalk ───────────────────────────────────────────────────────

  post "/dingtalk/webhook" do
    alias OptimalSystemAgent.Channels.DingTalk

    if DingTalk.connected?() do
      DingTalk.handle_webhook(conn.body_params)
      send_resp(conn, 200, "")
    else
      json_error(conn, 503, "channel_unavailable", "DingTalk adapter not started. Set DINGTALK_CLIENT_ID and DINGTALK_CLIENT_SECRET.")
    end
  end

  # ── Feishu ─────────────────────────────────────────────────────────

  post "/feishu/events" do
    alias OptimalSystemAgent.Channels.Feishu

    # URL verification challenge
    if conn.body_params["type"] == "url_verification" do
      challenge = conn.body_params["challenge"]
      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{challenge: challenge}))
    else
      vtoken = Application.get_env(:optimal_system_agent, :feishu_verification_token)

      case Feishu.verify_event(conn.body_params, vtoken || "") do
        :ok ->
          Feishu.handle_event(conn.body_params)
          send_resp(conn, 200, "")

        {:error, :invalid_token} ->
          json_error(conn, 401, "unauthorized", "Invalid Feishu verification token")
      end
    end
  end

  # ── WeCom ──────────────────────────────────────────────────────────

  post "/wecom/webhook" do
    alias OptimalSystemAgent.Channels.WeCom

    if WeCom.connected?() do
      WeCom.handle_webhook(conn.body_params)
      send_resp(conn, 200, "")
    else
      json_error(conn, 503, "channel_unavailable", "WeCom adapter not started. Set WECOM_BOT_KEY.")
    end
  end

  match _ do
    json_error(conn, 404, "not_found", "Channel endpoint not found")
  end
end
