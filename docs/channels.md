# Channel Setup Guide

> How to connect OSA to messaging platforms

## Overview

OSA supports 12+ messaging channels. Each channel is a GenServer implementing `OptimalSystemAgent.Channels.Behaviour` with four callbacks: `channel_name/0`, `start_link/1`, `send_message/3`, and `connected?/0`.

Channels auto-start when their credentials are configured. The Channel Manager starts all configured channels after the supervision tree boots.

## Quick Start

```bash
# Add credentials to ~/.osa/.env
echo 'TELEGRAM_BOT_TOKEN=123456:ABC...' >> ~/.osa/.env

# Restart OSA — Telegram auto-starts
osagent
# → "Channel connected: telegram"
```

## Channel Status

```
/channels              # List all channels and their status
/channels status       # Detailed connection info
/channels connect telegram    # Manually connect a channel
/channels disconnect slack    # Disconnect a channel
/channels test discord        # Send test message
```

---

## CLI (Built-in)

Always available. Interactive terminal with:
- Readline-like history and editing
- Markdown-to-ANSI rendering
- Progress spinners and task display
- Plan formatting and review
- Auto-completion for `/commands`
- Session persistence

**Entry points:**
```bash
osagent              # Interactive chat (default)
osagent serve        # Headless HTTP API mode (no CLI)
osagent setup        # Configuration wizard
osagent version      # Print version
```

---

## HTTP API (Built-in)

Always available on port 8089 (configurable via `OSA_HTTP_PORT`).

```bash
# Enable authentication
OSA_REQUIRE_AUTH=true
OSA_SHARED_SECRET="your-secret-key"
```

See [http-api.md](http-api.md) for full endpoint documentation.

---

## Telegram

### Setup

1. Create a bot via [@BotFather](https://t.me/BotFather)
2. Copy the bot token
3. Configure:

```bash
TELEGRAM_BOT_TOKEN="123456789:ABCdefGHIjklMNOpqrsTUVwxyz"
```

### How It Works

- Uses Telegram Bot API long polling
- Receives messages, sends responses
- Supports markdown formatting in responses
- Group chat support (mention @yourbot or reply)

---

## Discord

### Setup

1. Go to [Discord Developer Portal](https://discord.com/developers/applications)
2. Create an application → Add a Bot
3. Enable MESSAGE CONTENT intent under Bot settings
4. Copy bot token, application ID, and public key

```bash
DISCORD_BOT_TOKEN="MTIzNDU2Nzg5MDEy..."
DISCORD_APPLICATION_ID="1234567890123"
DISCORD_PUBLIC_KEY="abc123def456..."
```

5. Invite bot to your server with `applications.commands` and `bot` scopes

### How It Works

- Uses Discord Gateway WebSocket connection
- Responds to mentions and DMs
- Supports markdown formatting
- Slash command registration (future)

---

## Slack

### Setup

1. Go to [Slack API](https://api.slack.com/apps) → Create New App
2. Add Bot Token Scopes: `chat:write`, `app_mentions:read`, `channels:history`, `im:history`
3. Install to workspace
4. Enable Socket Mode → generate App-Level Token

```bash
SLACK_BOT_TOKEN="xoxb-1234-5678-abcdef"
SLACK_APP_TOKEN="xapp-1-A0123-..."
SLACK_SIGNING_SECRET="abc123..."
```

### How It Works

- Uses Slack Socket Mode (no public URL needed)
- Responds to @mentions and DMs
- Thread support
- Block formatting in responses

---

## WhatsApp (Business API)

### Setup

1. Go to [Meta Developer Portal](https://developers.facebook.com)
2. Create a WhatsApp Business app
3. Set up a phone number
4. Get permanent token (System User token for production)

```bash
WHATSAPP_TOKEN="EAABx..."
WHATSAPP_PHONE_NUMBER_ID="15551234567"
WHATSAPP_VERIFY_TOKEN="my-verify-token"
```

5. Set webhook URL to `https://your-domain.com/webhook/whatsapp`
6. Subscribe to `messages` webhook field

### WhatsApp Web Sidecar (Experimental)

For personal WhatsApp (not Business API):
```bash
OSA_WHATSAPP_WEB_ENABLED=true
```

Uses a Puppeteer-like sidecar for WhatsApp Web automation.

---

## Signal

### Setup

1. Install [signal-cli](https://github.com/AsamK/signal-cli) or [signal-cli-rest-api](https://github.com/bbernhard/signal-cli-rest-api)
2. Register a phone number with Signal
3. Start the REST API

```bash
SIGNAL_API_URL="http://localhost:8080"
SIGNAL_PHONE_NUMBER="+15551234567"
```

---

## Matrix

### Setup

1. Create a Matrix account for your bot on any homeserver
2. Get an access token (via login API or Element)

```bash
MATRIX_HOMESERVER="https://matrix.org"
MATRIX_ACCESS_TOKEN="syt_xxx..."
MATRIX_USER_ID="@osa-bot:matrix.org"
```

### How It Works

- Long polling via Matrix Client-Server API
- Joins invited rooms automatically
- End-to-end encryption support (if configured)

---

## Email

### Via SendGrid

```bash
EMAIL_FROM="osa@yourdomain.com"
EMAIL_FROM_NAME="OSA Agent"
SENDGRID_API_KEY="SG.xxx..."
```

### Via SMTP

```bash
EMAIL_FROM="osa@yourdomain.com"
EMAIL_SMTP_HOST="smtp.gmail.com"
EMAIL_SMTP_USER="osa@gmail.com"
EMAIL_SMTP_PASSWORD="app-password-here"
```

### How It Works

- Polls for inbound email (IMAP or webhook)
- Sends responses via configured provider
- Subject line used as conversation context
- Attachment support (future)

---

## DingTalk (企钉)

### Setup

1. Create a custom robot in DingTalk group settings
2. Enable Security Settings → Custom Keywords or IP Whitelist

```bash
DINGTALK_ACCESS_TOKEN="xxx..."
DINGTALK_SECRET="SECxxx..."    # If using sign verification
```

---

## Feishu (飞书)

### Setup

1. Go to [Feishu Open Platform](https://open.feishu.cn)
2. Create an application → Add Bot capability
3. Configure event subscription URL

```bash
FEISHU_APP_ID="cli_xxx"
FEISHU_APP_SECRET="xxx..."
FEISHU_ENCRYPT_KEY="xxx..."    # For AES-CBC message decryption
```

---

## QQ

### Setup

1. Register at [QQ Bot Platform](https://q.qq.com)
2. Create a bot application
3. Get credentials

```bash
QQ_APP_ID="123456"
QQ_APP_SECRET="xxx..."
QQ_TOKEN="xxx..."
```

---

## Writing a Custom Channel

Implement the `OptimalSystemAgent.Channels.Behaviour`:

```elixir
defmodule OptimalSystemAgent.Channels.MyChannel do
  use GenServer
  @behaviour OptimalSystemAgent.Channels.Behaviour

  @impl true
  def channel_name, do: :my_channel

  @impl true
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def send_message(chat_id, message, _opts \\ []) do
    # Send message to your platform
    GenServer.call(__MODULE__, {:send, chat_id, message})
  end

  @impl true
  def connected? do
    case Process.whereis(__MODULE__) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  # Route inbound messages through the agent loop:
  def handle_info({:incoming, chat_id, text}, state) do
    OptimalSystemAgent.Agent.Loop.process_message(text, channel: :my_channel, chat_id: chat_id)
    {:noreply, state}
  end
end
```

Register in your supervision tree or Channel Manager configuration.
