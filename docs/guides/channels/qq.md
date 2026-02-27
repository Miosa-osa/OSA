# QQ

> Tencent's messaging platform

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
