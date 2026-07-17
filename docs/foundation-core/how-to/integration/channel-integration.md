# Channel Integration Guide

How to configure each chat channel: CLI, HTTP, Telegram, Discord, Slack, and the
other supported adapters. Covers bot token setup, webhook configuration, and
verification.

## Audience

Operators deploying OSA to a messaging platform.

---

## How Channels Work

Every channel adapter implements `Channels.Behaviour`:

```elixir
@callback channel_name() :: atom()
@callback start_link(opts :: keyword()) :: GenServer.on_start()
@callback send_message(chat_id :: String.t(), message :: String.t(), opts :: keyword()) ::
            :ok | {:error, term()}
@callback connected?() :: boolean()
```

Adapters start automatically at boot via `Channels.Starter` if their required
configuration is present. An adapter returns `:ignore` from `init/1` when its
configuration key is missing, so unconfigured channels do not cause startup failures.

All inbound messages are routed through `Agent.Loop.process_message/2`. Responses
are sent back through the channel's `send_message/3`. Sessions are identified by
a `"{channel}_{chat_id}"` string and tracked in the `SessionRegistry`.

---

## CLI Channel

The CLI channel is always available — no configuration required.

```bash
# Start the interactive REPL:
mix osa.chat

# With a specific provider:
OSA_DEFAULT_PROVIDER=anthropic mix osa.chat
```

The CLI supports:
- Readline-style editing with arrow keys and history (up to 100 entries).
- Streaming responses with a spinner showing elapsed time and token count.
- Markdown rendering in the terminal.
- Slash commands (`/help`, `/clear`, `/plan`, etc.).
- Proactive mode integration.

The CLI session ID format is `"cli_"` followed by 16 random hex characters.

---

## HTTP Channel

The HTTP API is always available on port 9089 (configurable via `OSA_HTTP_PORT`).

```bash
# Start OSA:
mix run --no-halt

# Or in Docker:
docker-compose up
```

**Key endpoints:**

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/v1/orchestrate` | Full ReAct agent loop |
| `GET` | `/api/v1/stream/:session_id` | SSE event stream |
| `GET` | `/api/v1/tools` | List executable tools |
| `POST` | `/api/v1/tools/:name/execute` | Execute a tool |
| `GET` | `/api/v1/skills` | List SKILL.md skills |
| `POST` | `/api/v1/memory` | Save to memory |
| `GET` | `/api/v1/memory/recall` | Recall memory |
| `GET` | `/health` | Health check (no auth) |

**Authentication:** HS256 JWT via `Authorization: Bearer <token>`.

**Example request:**

```bash
curl -X POST http://localhost:9089/api/v1/orchestrate \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $JWT_TOKEN" \
  -d '{"message": "List files in /tmp", "session_id": "my-session"}'
```

**Change port:**

```bash
export OSA_HTTP_PORT=9090
```

---

## Telegram

Telegram operates in webhook mode. Telegram POSTs updates to OSA.

### Bot Setup

1. Message `@BotFather` on Telegram.
2. Send `/newbot` and follow the prompts.
3. Copy the bot token (format: `123456:ABCdef...`).

### Configuration

```bash
export TELEGRAM_BOT_TOKEN=123456:ABCdefGHI...
```

### Webhook Registration

After OSA is running and publicly accessible via HTTPS, register the webhook:

```elixir
# In IEx:
OptimalSystemAgent.Channels.Telegram.set_webhook("https://your-domain.com")
```

Or via curl:

```bash
curl "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/setWebhook" \
  -d "url=https://your-domain.com/api/v1/channels/telegram/webhook"
```

### Verification

```elixir
# Check adapter status:
OptimalSystemAgent.Channels.Telegram.connected?()
# => true

# Check bot info:
OptimalSystemAgent.Channels.Telegram.get_me()
```

### Features

- Text messages (inbound and outbound).
- Markdown formatting via `parse_mode: "MarkdownV2"`.
- Inline keyboards via `{:keyboard, buttons}` in send opts.
- Session ID format: `"telegram_{chat_id}"`.

### Local Development with Telegram

Use [ngrok](https://ngrok.com) to expose a local port:

```bash
ngrok http 9089
# Copy the HTTPS URL: https://abc123.ngrok.io
```

Then register the webhook with the ngrok URL.

---

## Discord

Discord operates in interactions (webhook) mode. Discord POSTs signed interaction
payloads to OSA.

### Bot Setup

1. Go to [discord.com/developers/applications](https://discord.com/developers/applications).
2. Create a new application.
3. Under **Bot**, create a bot and copy the token.
4. Under **General Information**, copy the Application ID and Public Key.
5. Under **OAuth2 > URL Generator**, select `bot` scope with `Send Messages` permission.
6. Invite the bot to your server using the generated URL.

### Configuration

```bash
export DISCORD_BOT_TOKEN=your-bot-token
export DISCORD_APPLICATION_ID=your-application-id
export DISCORD_PUBLIC_KEY=your-public-key
```

The `DISCORD_PUBLIC_KEY` is used to verify Ed25519 signatures on incoming interactions.
Discord will reject the webhook registration if signature verification fails.

### Interactions Endpoint

Set the Interactions Endpoint URL in your Discord application settings:

```
https://your-domain.com/api/v1/channels/discord/webhook
```

Discord sends a verification challenge when you first set this URL. OSA responds
automatically.

### Verification

```elixir
OptimalSystemAgent.Channels.Discord.connected?()
```

**Outbound message format:** Discord uses `Authorization: Bot {token}` headers. Outbound
calls target `https://discord.com/api/v10/channels/{channel_id}/messages`.

### Session ID Format

`"discord_{channel_id}"` — one session per Discord channel.

---

## Slack

Slack uses the Events API. Slack POSTs events to OSA after HMAC-SHA256 signature
verification.

### App Setup

1. Go to [api.slack.com/apps](https://api.slack.com/apps) and create a new app.
2. Under **OAuth & Permissions**, add the `chat:write` bot scope.
3. Install the app to your workspace.
4. Copy the Bot User OAuth Token (`xoxb-...`).
5. Under **Basic Information**, copy the Signing Secret.

### Configuration

```bash
export SLACK_BOT_TOKEN=xoxb-...
export SLACK_SIGNING_SECRET=your-signing-secret
```

### Event Subscription

Under **Event Subscriptions**, enable events and set the request URL:

```
https://your-domain.com/api/v1/channels/slack/events
```

Slack sends a URL verification challenge. OSA responds to `url_verification` events
automatically. Subscribe to the `message.im` bot event to receive direct messages.

### Signature Verification

OSA verifies Slack's HMAC-SHA256 signatures using the signing secret. Requests older
than 5 minutes (`@signature_max_age 300`) are rejected.

### Session ID Format

`"slack_{channel_id}"` — one session per Slack channel or DM.

---

## DingTalk (钉钉)

```bash
export DINGTALK_WEBHOOK_URL=https://oapi.dingtalk.com/robot/send?access_token=...
export DINGTALK_SECRET=SEC...   # optional signing secret
```

DingTalk uses outbound webhooks. Configure the robot token and optional signing secret
in the DingTalk admin panel.

---

## Feishu / Lark (飞书)

```bash
export FEISHU_APP_ID=cli_...
export FEISHU_APP_SECRET=...
```

---

## Matrix

```bash
export MATRIX_HOMESERVER=https://matrix.org
export MATRIX_ACCESS_TOKEN=syt_...
export MATRIX_USER_ID=@osa:matrix.org
```

---

## Email

```bash
export EMAIL_SMTP_HOST=smtp.example.com
export EMAIL_SMTP_PORT=587
export EMAIL_SMTP_USERNAME=osa@example.com
export EMAIL_SMTP_PASSWORD=...
export EMAIL_FROM=osa@example.com
```

---

## WhatsApp

```bash
export WHATSAPP_API_URL=https://graph.facebook.com/v17.0
export WHATSAPP_PHONE_NUMBER_ID=...
export WHATSAPP_ACCESS_TOKEN=EAAp...
```

WhatsApp uses the Meta Cloud API. Webhook verification is required via the Meta
developer portal.

---

## QQ

```bash
export QQ_BOT_APPID=...
export QQ_BOT_TOKEN=...
```

---

## Signal

```bash
export SIGNAL_PHONE_NUMBER=+15555555555
```

Signal integration requires `signal-cli` running as a daemon on the same host.

---

## Checking Channel Status

```elixir
# List all adapter modules:
[
  OptimalSystemAgent.Channels.Telegram,
  OptimalSystemAgent.Channels.Discord,
  OptimalSystemAgent.Channels.Slack,
]
|> Enum.map(fn mod ->
  {mod.channel_name(), mod.connected?()}
end)
# => [{:telegram, true}, {:discord, false}, {:slack, true}]

# Check if the CLI channel is active:
Process.whereis(OptimalSystemAgent.Channels.CLI) != nil
```
