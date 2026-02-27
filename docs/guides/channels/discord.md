# Discord

> Gateway WebSocket connection with bot support

## Setup

1. Go to [Discord Developer Portal](https://discord.com/developers/applications)
2. Create an application, then add a Bot
3. Enable **MESSAGE CONTENT** intent under Bot settings
4. Copy credentials:

```bash
DISCORD_BOT_TOKEN="MTIzNDU2Nzg5MDEy..."
DISCORD_APPLICATION_ID="1234567890123"
DISCORD_PUBLIC_KEY="abc123def456..."
```

5. Generate an invite URL with `applications.commands` and `bot` scopes
6. Invite bot to your server

## How It Works

- Uses Discord Gateway WebSocket for real-time events
- Responds to @mentions and DMs
- Supports markdown formatting
- Auto-starts when credentials are present

## Features

- Direct messages and server channels
- Markdown and code block formatting
- Mention-triggered responses
- Slash command registration (future)

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Bot offline | Check MESSAGE CONTENT intent is enabled |
| No responses | Bot needs `Send Messages` permission in channel |
| Connection drops | Normal — Gateway reconnects automatically |
