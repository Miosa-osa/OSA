# HTTP API Reference

OSA exposes a REST API on port 8089 (configurable) for SDK clients, integrations, and external applications.

Base URL: `http://localhost:8089`

---

## Authentication

### Development Mode (Default)

By default, authentication is disabled. All requests are allowed with an "anonymous" user ID.

### Production Mode

Enable authentication by setting:

```bash
export OSA_SHARED_SECRET="your-secret-key-min-32-characters"
export OSA_REQUIRE_AUTH=true
```

All API requests under `/api/v1/` must include a valid JWT token:

```
Authorization: Bearer <token>
```

### Token Format

OSA uses JWT HS256 (HMAC-SHA256) signed with the shared secret.

**Required claims:**

| Claim | Type | Description |
|-------|------|-------------|
| `user_id` | string | Unique user identifier |
| `iat` | integer | Issued-at timestamp (Unix seconds) |
| `exp` | integer | Expiration timestamp (Unix seconds) |

**Optional claims:**

| Claim | Type | Description |
|-------|------|-------------|
| `workspace_id` | string | Workspace/tenant identifier |

### Generating Tokens

From an IEx session:

```elixir
token = OptimalSystemAgent.Channels.HTTP.Auth.generate_token(%{
  "user_id" => "user_123",
  "workspace_id" => "ws_abc"
})
```

Default token lifetime: 15 minutes. Override by setting `exp` in the claims.

From the command line:

```bash
# Generate a token using the mix task (if available)
mix osa.token --user-id user_123
```

### Authentication Errors

| Status | Code | Description |
|--------|------|-------------|
| 401 | `MISSING_TOKEN` | No Authorization header present (auth required) |
| 401 | `INVALID_TOKEN` | Token signature invalid, malformed, or expired |

```json
{
  "error": "unauthorized",
  "code": "INVALID_TOKEN"
}
```

---

## Endpoints

### GET /health

Health check. Always available, no authentication required.

**Request:**

```bash
curl http://localhost:8089/health
```

**Response (200):**

```json
{
  "status": "ok",
  "version": "0.1.0"
}
```

---

### POST /api/v1/orchestrate

Run the full agent loop. This is the primary endpoint — send a message and get a complete response.

**Request:**

```bash
curl -X POST http://localhost:8089/api/v1/orchestrate \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{
    "input": "What files are in my home directory?",
    "session_id": "my-session",
    "user_id": "user_123",
    "workspace_id": "ws_abc"
  }'
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `input` | string | Yes | The user's message |
| `session_id` | string | No | Session identifier. If omitted, a random session ID is generated. Use the same session_id for multi-turn conversations. |
| `user_id` | string | No | User identifier. Falls back to JWT claim or "anonymous". |
| `workspace_id` | string | No | Workspace identifier for multi-tenant setups. |

**Response (200 — Success):**

```json
{
  "session_id": "my-session",
  "output": "Here are the files in your home directory:\n- Desktop\n- Documents\n- Downloads\n...",
  "signal": {
    "mode": "execute",
    "genre": "direct",
    "type": "question",
    "format": "command",
    "weight": 0.85,
    "channel": "http",
    "timestamp": "2026-02-24T10:30:00Z"
  },
  "skills_used": [],
  "iteration_count": 0,
  "execution_ms": 1523,
  "metadata": {}
}
```

**Response (422 — Signal Filtered):**

The message was classified as noise and filtered before reaching the LLM.

```json
{
  "error": "signal_filtered",
  "code": "SIGNAL_BELOW_THRESHOLD",
  "details": "Signal weight 0.2 below threshold",
  "signal": {
    "mode": "assist",
    "genre": "express",
    "type": "general",
    "format": "command",
    "weight": 0.2,
    "channel": "http",
    "timestamp": "2026-02-24T10:30:00Z"
  }
}
```

**Response (400 — Bad Request):**

```json
{
  "error": "invalid_request",
  "details": "Missing required field: input"
}
```

**Response (500 — Agent Error):**

```json
{
  "error": "agent_error",
  "details": "Ollama connection failed: connection refused"
}
```

---

### POST /api/v1/classify

Classify a message using the Signal Theory 5-tuple without running the agent loop. Useful for testing classification, building routing logic, or pre-filtering messages.

**Request:**

```bash
curl -X POST http://localhost:8089/api/v1/classify \
  -H "Content-Type: application/json" \
  -d '{
    "message": "What is our Q3 revenue trend compared to last year?",
    "channel": "telegram"
  }'
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `message` | string | Yes | The message to classify |
| `channel` | string | No | Channel context for format classification. Default: "http". Options: "cli", "telegram", "discord", "slack", "whatsapp", "webhook", "filesystem" |

**Response (200):**

```json
{
  "signal": {
    "mode": "analyze",
    "genre": "inform",
    "type": "question",
    "format": "message",
    "weight": 0.85,
    "channel": "telegram",
    "timestamp": "2026-02-24T10:30:00Z"
  }
}
```

---

### GET /api/v1/skills

List all registered skills (built-in + SKILL.md + MCP).

**Request:**

```bash
curl http://localhost:8089/api/v1/skills
```

**Response (200):**

```json
{
  "skills": [
    {
      "name": "file_read",
      "description": "Read the contents of a file from the filesystem",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "Absolute path to the file to read"
          }
        },
        "required": ["path"]
      }
    },
    {
      "name": "file_write",
      "description": "Write content to a file on the filesystem",
      "parameters": {
        "type": "object",
        "properties": {
          "path": { "type": "string" },
          "content": { "type": "string" }
        },
        "required": ["path", "content"]
      }
    },
    {
      "name": "shell_execute",
      "description": "Execute a shell command and return stdout/stderr",
      "parameters": {
        "type": "object",
        "properties": {
          "command": { "type": "string" }
        },
        "required": ["command"]
      }
    },
    {
      "name": "web_search",
      "description": "Search the web using Brave Search API",
      "parameters": {
        "type": "object",
        "properties": {
          "query": { "type": "string" }
        },
        "required": ["query"]
      }
    },
    {
      "name": "memory_save",
      "description": "Save information to long-term memory",
      "parameters": {
        "type": "object",
        "properties": {
          "content": { "type": "string" },
          "category": { "type": "string" }
        },
        "required": ["content"]
      }
    }
  ],
  "count": 5
}
```

---

### POST /api/v1/skills/:name/execute

Execute a specific skill directly, bypassing the agent loop. Useful for SDK integrations where you want to call a tool programmatically.

**Request:**

```bash
curl -X POST http://localhost:8089/api/v1/skills/web_search/execute \
  -H "Content-Type: application/json" \
  -d '{
    "arguments": {
      "query": "Elixir OTP 28 release notes"
    }
  }'
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `arguments` | object | No | Arguments matching the skill's parameter schema. Default: `{}` |

**Response (200):**

```json
{
  "skill": "web_search",
  "status": "completed",
  "result": "Top results for 'Elixir OTP 28 release notes':\n1. ..."
}
```

**Response (422 — Skill Error):**

```json
{
  "error": "skill_error",
  "details": "Ticker 'INVALID' not found"
}
```

---

### POST /api/v1/memory

Save an entry to long-term memory (MEMORY.md).

**Request:**

```bash
curl -X POST http://localhost:8089/api/v1/memory \
  -H "Content-Type: application/json" \
  -d '{
    "content": "User prefers concise responses. Location: San Francisco.",
    "category": "preference"
  }'
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `content` | string | Yes | The content to save |
| `category` | string | No | Category tag. Default: "general" |

**Response (201):**

```json
{
  "status": "saved",
  "category": "preference"
}
```

---

### GET /api/v1/memory/recall

Read all long-term memory (MEMORY.md contents).

**Request:**

```bash
curl http://localhost:8089/api/v1/memory/recall
```

**Response (200):**

```json
{
  "content": "## [preference] 2026-02-24T10:30:00Z\nUser prefers concise responses.\n\n## [contact] 2026-02-24T11:00:00Z\nSarah Chen — VP Engineering at Acme Corp.\n"
}
```

---

### GET /api/v1/machines

List active machines and their count.

**Request:**

```bash
curl http://localhost:8089/api/v1/machines
```

**Response (200):**

```json
{
  "machines": ["core", "research"],
  "count": 2
}
```

---

### GET /api/v1/stream/:session_id

Server-Sent Events (SSE) stream for a specific session. Connect to this endpoint before sending a message to that session to receive real-time events.

**Request:**

```bash
curl -N http://localhost:8089/api/v1/stream/my-session
```

**SSE Protocol:**

```
event: connected
data: {"session_id": "my-session"}

event: agent_response
data: {"type":"agent_response","session_id":"my-session","response":"Here are the files..."}

: keepalive

event: system_event
data: {"type":"system_event","event":"heartbeat_completed","completed":2,"total":3}
```

### SSE Event Types

| Event | Description |
|-------|-------------|
| `connected` | Initial connection confirmation |
| `user_message` | User message received |
| `llm_request` | LLM call initiated |
| `llm_response` | LLM response received |
| `tool_call` | Tool execution started |
| `tool_result` | Tool execution completed |
| `agent_response` | Final agent response |
| `system_event` | System events (heartbeat, signal filtered, etc.) |

### Keepalive

A keepalive comment (`: keepalive\n\n`) is sent every 30 seconds to prevent connection timeouts.

### Disconnection

When the client disconnects, the server detects the broken pipe and cleans up the connection. No explicit close message is needed.

---

## Error Codes

| HTTP Status | Error Code | Description |
|-------------|------------|-------------|
| 400 | `invalid_request` | Missing required field or malformed JSON |
| 401 | `MISSING_TOKEN` | Authentication required but no token provided |
| 401 | `INVALID_TOKEN` | Token is invalid, expired, or has bad signature |
| 404 | `not_found` | Endpoint does not exist |
| 422 | `SIGNAL_BELOW_THRESHOLD` | Message classified as noise and filtered |
| 422 | `skill_error` | Skill execution failed with expected error |
| 500 | `agent_error` | Unexpected error in the agent loop |

All error responses follow this format:

```json
{
  "error": "error_type",
  "code": "ERROR_CODE",
  "details": "Human-readable description of what went wrong"
}
```

---

## Rate Limiting

OSA does not currently enforce rate limiting at the HTTP layer. If you need rate limiting for production deployments, add it at the reverse proxy level (Nginx, Caddy, Cloudflare):

```nginx
# Nginx example
limit_req_zone $binary_remote_addr zone=osa:10m rate=10r/s;

location /api/ {
    limit_req zone=osa burst=20 nodelay;
    proxy_pass http://localhost:8089;
}
```

The LLM provider itself may rate-limit you (Anthropic, OpenAI). The Provider Registry handles these errors and returns them as `agent_error` responses.

---

## CORS

CORS headers are not set by default. For browser-based SDK clients, configure your reverse proxy:

```nginx
location /api/ {
    add_header Access-Control-Allow-Origin "https://your-app.com";
    add_header Access-Control-Allow-Methods "GET, POST, OPTIONS";
    add_header Access-Control-Allow-Headers "Authorization, Content-Type";
    proxy_pass http://localhost:8089;
}
```

---

## Content Types

- All request bodies must be `application/json`
- All JSON responses are `application/json`
- SSE streams are `text/event-stream`

---

## SDK Integration Example

A complete SDK integration workflow:

```bash
# 1. Generate a session token (if auth enabled)
TOKEN=$(mix osa.token --user-id sdk-client-1 2>/dev/null)

# 2. Start listening for events (background)
curl -N -H "Authorization: Bearer $TOKEN" \
  http://localhost:8089/api/v1/stream/sdk-session &

# 3. Send a message
curl -X POST http://localhost:8089/api/v1/orchestrate \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "input": "Search for the latest AI news and summarize the top 3 stories",
    "session_id": "sdk-session"
  }'

# 4. The SSE stream will show tool_call events as the agent works,
#    followed by the final agent_response event.
```
