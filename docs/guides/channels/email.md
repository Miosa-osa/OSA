# Email

> Inbound/outbound email via SendGrid or SMTP

## SendGrid Setup

```bash
EMAIL_FROM="osa@yourdomain.com"
EMAIL_FROM_NAME="OSA Agent"
SENDGRID_API_KEY="SG.xxx..."
```

## SMTP Setup

```bash
EMAIL_FROM="osa@yourdomain.com"
EMAIL_SMTP_HOST="smtp.gmail.com"
EMAIL_SMTP_PORT=587
EMAIL_SMTP_USER="osa@gmail.com"
EMAIL_SMTP_PASSWORD="app-password-here"
```

## How It Works

- Polls for inbound email (IMAP or webhook depending on provider)
- Sends responses via configured provider (SendGrid or SMTP)
- Subject line used as conversation context
- Auto-starts when email credentials are present

## Features

- SendGrid and SMTP support
- Inbound email processing
- Subject-based conversation threading
- HTML and plain text responses

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Emails not sending | Check SendGrid API key permissions or SMTP credentials |
| Gmail SMTP blocked | Use an App Password (not account password) |
| Inbound not working | Verify webhook URL or IMAP polling configuration |
