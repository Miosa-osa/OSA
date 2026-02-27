# WhatsApp

> Business API + experimental WhatsApp Web sidecar

## Business API Setup

1. Go to [Meta Developer Portal](https://developers.facebook.com)
2. Create a WhatsApp Business app
3. Set up a phone number
4. Get a permanent token (System User token for production)

```bash
WHATSAPP_TOKEN="EAABx..."
WHATSAPP_PHONE_NUMBER_ID="15551234567"
WHATSAPP_VERIFY_TOKEN="my-verify-token"
```

5. Set webhook URL to `https://your-domain.com/webhook/whatsapp`
6. Subscribe to `messages` webhook field

## WhatsApp Web Sidecar (Experimental)

For personal WhatsApp (not Business API):

```bash
OSA_WHATSAPP_WEB_ENABLED=true
```

Uses a Puppeteer-like sidecar for WhatsApp Web automation. Requires a Chromium-based browser.

## How It Works

- Receives messages via webhook (Business API) or Web sidecar
- Sends responses via WhatsApp Cloud API
- Auto-starts when credentials are present

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Webhook not verified | Check `WHATSAPP_VERIFY_TOKEN` matches Meta config |
| Messages not sending | Verify phone number ID and token permissions |
| Web sidecar crash | Re-scan QR code, check Chromium is installed |
