# Slack

> Socket Mode connection — no public URL needed

## Setup

1. Go to [Slack API](https://api.slack.com/apps) and create a new app
2. Add Bot Token Scopes: `chat:write`, `app_mentions:read`, `channels:history`, `im:history`
3. Install to workspace
4. Enable Socket Mode and generate an App-Level Token
5. Configure:

```bash
SLACK_BOT_TOKEN="xoxb-1234-5678-abcdef"
SLACK_APP_TOKEN="xapp-1-A0123-..."
SLACK_SIGNING_SECRET="abc123..."
```

## How It Works

- Uses Slack Socket Mode (no public URL or ngrok needed)
- Responds to @mentions and direct messages
- Thread support — replies in-thread when mentioned in a thread
- Auto-starts when credentials are present

## Features

- Socket Mode (no public URL)
- Thread-aware responses
- Block Kit formatting
- @mention and DM support

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Bot not responding | Check Socket Mode is enabled in app settings |
| Missing messages | Add `channels:history` scope and reinstall |
| Thread replies not working | Ensure `im:history` scope is added |
