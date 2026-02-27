# Feishu (飞书)

> ByteDance's enterprise collaboration platform

## Setup

1. Go to [Feishu Open Platform](https://open.feishu.cn)
2. Create an application and add Bot capability
3. Configure event subscription URL
4. Configure:

```bash
FEISHU_APP_ID="cli_xxx"
FEISHU_APP_SECRET="xxx..."
FEISHU_ENCRYPT_KEY="xxx..."    # For AES-CBC message decryption
```

## How It Works

- Receives messages via Feishu event subscription (webhook)
- Sends responses via Feishu Bot API
- Supports AES-CBC encrypted message payloads
- Auto-starts when credentials are present

## Features

- Event subscription for real-time messages
- Encrypted message support
- Rich text and card message formatting
- Group and direct message support

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Event verification failed | Check `FEISHU_ENCRYPT_KEY` matches platform config |
| Bot not responding | Verify app is published and bot scope is enabled |
| Permission denied | Add required permissions in Feishu developer console |
