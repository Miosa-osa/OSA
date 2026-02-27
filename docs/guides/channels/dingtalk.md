# DingTalk (钉钉)

> Enterprise messaging for Chinese organizations

## Setup

1. Create a custom robot in a DingTalk group's settings
2. Enable Security Settings (Custom Keywords or IP Whitelist)
3. Configure:

```bash
DINGTALK_ACCESS_TOKEN="xxx..."
DINGTALK_SECRET="SECxxx..."    # If using sign verification
```

## How It Works

- Receives messages via DingTalk webhook callback
- Sends responses via DingTalk Robot API
- Supports sign verification for security
- Auto-starts when credentials are present

## Security Options

- **Custom Keywords**: Messages must contain specific keywords
- **IP Whitelist**: Restrict to specific IP addresses
- **Sign Verification**: HMAC-SHA256 signature on each request (recommended)

## Troubleshooting

| Issue | Fix |
|-------|-----|
| 310000 error | Token expired — regenerate in group settings |
| Signature mismatch | Check `DINGTALK_SECRET` matches group robot config |
| Messages not received | Verify webhook URL is accessible |
