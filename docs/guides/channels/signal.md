# Signal

> Privacy-first messaging via signal-cli

## Setup

1. Install [signal-cli](https://github.com/AsamK/signal-cli) or [signal-cli-rest-api](https://github.com/bbernhard/signal-cli-rest-api)
2. Register a phone number with Signal
3. Start the REST API
4. Configure:

```bash
SIGNAL_API_URL="http://localhost:8080"
SIGNAL_PHONE_NUMBER="+15551234567"
```

## How It Works

- Communicates via signal-cli REST API
- End-to-end encrypted messages
- Supports individual and group chats
- Auto-starts when credentials are present

## Signal-CLI Docker Setup

```bash
docker run -d --name signal-cli-rest-api \
  -p 8080:8080 \
  -v signal-cli-config:/home/.local/share/signal-cli \
  bbernhard/signal-cli-rest-api
```

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Connection refused | Ensure signal-cli REST API is running on configured port |
| Registration failed | Use `signal-cli register` and verify with SMS code |
| Group messages not received | Trust the group in signal-cli first |
