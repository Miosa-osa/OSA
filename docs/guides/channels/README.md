# Channel Guides

> Setup and configuration for each of OSA's 12+ messaging channels

## Overview

Channels are GenServers implementing `OptimalSystemAgent.Channels.Behaviour`. They auto-start when their credentials are configured.

## Channel Status Commands

```
/channels              # List all channels and status
/channels status       # Detailed connection info
/channels connect telegram    # Manually connect
/channels disconnect slack    # Disconnect
/channels test discord        # Send test message
```

## Built-in (Always Available)

| Channel | Guide | Configuration |
|---------|-------|---------------|
| CLI | [cli.md](cli.md) | None required |
| HTTP API | [http.md](http.md) | `OSA_HTTP_PORT` (default 8089) |

## Western Platforms

| Channel | Guide | Key Env Var |
|---------|-------|-------------|
| Telegram | [telegram.md](telegram.md) | `TELEGRAM_BOT_TOKEN` |
| Discord | [discord.md](discord.md) | `DISCORD_BOT_TOKEN` |
| Slack | [slack.md](slack.md) | `SLACK_BOT_TOKEN` |
| WhatsApp | [whatsapp.md](whatsapp.md) | `WHATSAPP_TOKEN` |
| Signal | [signal.md](signal.md) | `SIGNAL_API_URL` |
| Matrix | [matrix.md](matrix.md) | `MATRIX_ACCESS_TOKEN` |
| Email | [email.md](email.md) | `SENDGRID_API_KEY` or SMTP |

## Chinese Platforms

| Channel | Guide | Key Env Var |
|---------|-------|-------------|
| DingTalk (钉钉) | [dingtalk.md](dingtalk.md) | `DINGTALK_ACCESS_TOKEN` |
| Feishu (飞书) | [feishu.md](feishu.md) | `FEISHU_APP_ID` |
| QQ | [qq.md](qq.md) | `QQ_APP_ID` |

## Writing a Custom Channel

See the [custom channel guide](../../architecture/README.md) for implementing `OptimalSystemAgent.Channels.Behaviour`.
