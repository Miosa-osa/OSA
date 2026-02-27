# Telegram

> Bot API with long polling

## Setup

1. Create a bot via [@BotFather](https://t.me/BotFather)
2. Copy the bot token
3. Configure:

```bash
TELEGRAM_BOT_TOKEN="123456789:ABCdefGHIjklMNOpqrsTUVwxyz"
```

4. Restart OSA — Telegram auto-connects

## How It Works

- Uses Telegram Bot API long polling (no webhook URL needed)
- Receives messages, sends responses with markdown formatting
- Group chat support — mention @yourbot or reply to trigger
- Auto-starts when `TELEGRAM_BOT_TOKEN` is present

## Features

- Markdown formatting in responses
- Group and private chat support
- Message threading
- Inline commands

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Bot not responding | Verify token with `curl https://api.telegram.org/bot<TOKEN>/getMe` |
| No messages in groups | Enable group privacy mode in @BotFather settings |
| Rate limited | Telegram allows ~30 msg/sec — reduce response frequency |
