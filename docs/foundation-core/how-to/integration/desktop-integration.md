# Desktop App Integration

How the Tauri desktop app connects to the OSA backend. Covers SSE streaming, the sidecar
process model, port configuration, and the lifecycle of the connection.

## Audience

Developers working on the desktop app or debugging connectivity between the Tauri frontend
and the Elixir backend.

---

## Architecture Overview

The desktop app is a Tauri v2 application with a SvelteKit frontend. It communicates with
the OSA backend exclusively via HTTP and SSE (Server-Sent Events). There is no shared
memory or direct process communication between Tauri and the Elixir VM.

```
Tauri App (Rust + SvelteKit)
    |
    | HTTP POST /api/v1/orchestrate
    | GET /api/v1/stream/:session_id  (SSE)
    |
    v
OSA Backend (Elixir/OTP, port 9089)
    |
    +-- Agent.Loop (per session)
    +-- Tools.Registry
    +-- Providers.Registry
```

The desktop app and backend run on the same machine. The backend is either:
1. An **embedded sidecar** process started by Tauri (packaged release builds).
2. An **external process** the user started separately (development mode).

---

## Port Configuration

The backend listens on port **9089** — its default HTTP port — both in local
development and when running as a desktop sidecar.

The Tauri security policy in `tauri.conf.json` allows connections only to:

```
http://localhost:9089
http://127.0.0.1:9089
```

The Rust sidecar module defines this constant:

```rust
// src-tauri/src/sidecar.rs
pub const BACKEND_PORT: u16 = 9089;
pub const HEALTH_URL: &str = "http://127.0.0.1:9089/health";
```

To run OSA on the desktop port during development:

```bash
OSA_HTTP_PORT=9089 iex -S mix
```

---

## Sidecar Lifecycle

When the desktop app launches, `sidecar.rs` manages the backend process:

1. **Port check** — Before spawning a new process, the sidecar checks if something is
   already listening on port 9089 by calling `GET /health`. If a backend is already up,
   it skips spawning.

2. **Spawn** — If no backend is running, Tauri spawns the bundled Elixir release binary
   as a sidecar child process using `tauri_plugin_shell`.

3. **Health check with exponential backoff** — The sidecar polls `GET /health` starting
   at 100ms intervals, doubling up to 2000ms, with a 30-second total timeout. This allows
   the Elixir VM to boot fully before the frontend starts sending requests.

4. **Window reveal** — The main window is shown immediately at startup (before the backend
   is healthy) to avoid a blank screen. The frontend handles backend-not-ready states
   gracefully.

5. **Shutdown** — When the Tauri app closes, it sends `SIGTERM` to the sidecar process.
   The Elixir release handles this with a graceful shutdown.

The global `SIDECAR_RUNNING: AtomicBool` flag tracks whether the sidecar is active.
Tauri tray menu items and commands query this flag via the Rust API.

---

## SSE Streaming

The primary communication pattern for agent responses is SSE (Server-Sent Events).

The frontend opens a long-lived `GET /api/v1/stream/:session_id` connection. The backend
pushes events as they are emitted by the `EventStream` GenServer.

**Event format:**

```
data: {"type":"text_delta","content":"Hello","session_id":"abc123"}

data: {"type":"tool_call","tool":"file_read","session_id":"abc123"}

data: {"type":"done","session_id":"abc123"}
```

**Frontend connection pattern (SvelteKit):**

```typescript
const eventSource = new EventSource(
  `http://localhost:9089/api/v1/stream/${sessionId}`,
  { withCredentials: false }
);

eventSource.onmessage = (event) => {
  const data = JSON.parse(event.data);
  handleAgentEvent(data);
};

eventSource.onerror = () => {
  // Backend not ready or connection dropped — retry after delay
  setTimeout(reconnect, 1000);
};

// Close when done:
eventSource.close();
```

The SSE connection is read-only (server to client). To send a message, the frontend
uses a separate `POST /api/v1/orchestrate`.

---

## Sending Messages

The frontend sends messages via `POST /api/v1/orchestrate`:

```typescript
const response = await fetch('http://localhost:9089/api/v1/orchestrate', {
  method: 'POST',
  headers: {
    'Content-Type': 'application/json',
    'Authorization': `Bearer ${jwtToken}`,
  },
  body: JSON.stringify({
    message: userInput,
    session_id: sessionId,
  }),
});

const result = await response.json();
// The response is an immediate acknowledgment.
// The actual agent reply arrives via SSE.
```

---

## EventStream Architecture

The `EventStream` GenServer manages SSE subscriptions on the backend.

```elixir
# Backend SSE connection handler (simplified from Channels.HTTP):
get "/api/v1/stream/:session_id" do
  session_id = conn.params["session_id"]

  conn =
    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "keep-alive")
    |> send_chunked(200)

  OptimalSystemAgent.EventStream.subscribe(session_id, conn)
end
```

Events emitted via `Events.Bus.emit/3` with a `session_id` are automatically appended
to the corresponding `EventStream` via `Events.Stream.append/2`.

---

## CORS Configuration

The HTTP channel configures CORS to allow requests from the Tauri webview:

```elixir
# In Channels.HTTP:
defp cors_headers(conn, _opts) do
  conn
  |> put_resp_header("access-control-allow-origin", "*")
  |> put_resp_header("access-control-allow-methods", "GET, POST, PUT, DELETE, OPTIONS")
  |> put_resp_header("access-control-allow-headers", "content-type, authorization")
end
```

The Tauri CSP in `tauri.conf.json` also permits connections to `http://localhost:9089`.

---

## Development Workflow

To develop the desktop app while running the backend manually:

```bash
# Terminal 1 — Start the backend on the desktop port:
OSA_HTTP_PORT=9089 iex -S mix

# Terminal 2 — Start the Tauri dev server:
cd desktop
npm run dev
# Or:
make dev
```

The frontend dev server runs on port 5199. Tauri opens a window pointing to it.

To build a release for distribution:

```bash
cd desktop
npm run build       # Build the SvelteKit frontend
npm run tauri build # Bundle with Tauri (includes the Elixir release as sidecar)
```

---

## Debugging the Sidecar Connection

**Backend not starting:**

```bash
# Check if port 9089 is in use:
lsof -i :9089

# Check sidecar logs in the Tauri app data directory:
# macOS: ~/Library/Logs/ai.osa.desktop/
# Linux: ~/.local/share/ai.osa.desktop/logs/
```

**SSE not receiving events:**

```bash
# Test SSE from the terminal:
curl -N http://localhost:9089/api/v1/stream/test-session-id
```

**CORS errors in the console:**

Ensure the backend is running on port 9089. The Tauri CSP only allows
port 9089.

**Window stays blank:**

The frontend shows a loading state while `GET /health` returns non-200. If the window
stays blank for more than 30 seconds, check the sidecar logs for boot errors.
