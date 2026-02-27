# Matrix

> Decentralized, federated messaging with E2EE support

## Setup

1. Create a Matrix account for your bot on any homeserver
2. Get an access token (via login API or Element client)
3. Configure:

```bash
MATRIX_HOMESERVER="https://matrix.org"
MATRIX_ACCESS_TOKEN="syt_xxx..."
MATRIX_USER_ID="@osa-bot:matrix.org"
```

## How It Works

- Long polling via Matrix Client-Server API (`/sync`)
- Joins invited rooms automatically
- End-to-end encryption support (if configured)
- Supports any Matrix homeserver (matrix.org, Element, Synapse, etc.)
- Auto-starts when credentials are present

## Features

- Federated — works across any Matrix server
- E2EE support
- Room invites auto-accepted
- Markdown formatting in responses

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Can't join rooms | Bot must be invited first, or room must be public |
| Token expired | Generate a new access token via Element or login API |
| E2EE not working | Ensure crypto libraries are available |
