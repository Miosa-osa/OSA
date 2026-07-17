# QQ

> Tencent's messaging platform

> **⚠️ STATUS: PLANNED / NOT YET IMPLEMENTED.** As of v1.0.3 there is **no QQ
> channel adapter** in `lib/optimal_system_agent/channels/`. The only QQ code that
> ships is a placeholder route — `POST /qq/webhook` returns
> `501 not_implemented` with the message *"QQ channel not yet available"*
> (`lib/optimal_system_agent/channels/http/api/channel_routes.ex`). The bot does
> **not** auto-start on credentials, and none of the setup, features, or
> troubleshooting below is functional yet. This page documents the *intended*
> integration only. (For a working reference, see the built-in channels such as
> Discord, Telegram, Slack, Feishu, DingTalk, or WeCom.)

## Setup

1. Register at [QQ Bot Platform](https://q.qq.com)
2. Create a bot application
3. Get credentials:

```bash
QQ_APP_ID="123456"
QQ_APP_SECRET="xxx..."
QQ_TOKEN="xxx..."
```

## How It Works

- Connects via QQ Bot API
- Supports guild (server) and direct messages
- Auto-starts when credentials are present

## Features

- Guild (server) channel support
- Direct message support
- Rich message formatting
- Slash command support

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Authentication failed | Verify all three credentials (app ID, secret, token) |
| Bot not in guild | Invite bot via QQ Bot Platform admin |
| Messages not received | Check bot has correct intents enabled |
