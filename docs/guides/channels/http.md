# HTTP API Channel

> Built-in REST API — always available on port 8089

## Overview

The HTTP API enables programmatic access to OSA. Always running alongside the CLI.

## Configuration

```bash
OSA_HTTP_PORT=8089           # Default port
OSA_REQUIRE_AUTH=true        # Enable authentication
OSA_SHARED_SECRET="secret"   # Shared secret for auth
```

## Authentication

When `OSA_REQUIRE_AUTH=true`, include the secret in requests:

```bash
curl -X POST http://localhost:8089/api/chat \
  -H "Authorization: Bearer your-secret-key" \
  -H "Content-Type: application/json" \
  -d '{"message": "hello"}'
```

## Endpoints

See [HTTP API Reference](../../reference/http-api.md) for full endpoint documentation.

## Headless Mode

Run OSA as a pure API server (no CLI):

```bash
osagent serve
```
