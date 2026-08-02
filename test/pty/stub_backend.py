"""A minimal stand-in for the OSA Elixir backend.

The PTY harness drives the REAL `osagent` binary, and `osagent` refuses to leave
its "Connecting…" splash until `GET /health` answers. That splash owns the whole
alternate screen, so without a backend there is no inline live region to make
assertions about at all.

This stub therefore answers exactly the calls `osagent` makes while booting —
health, login, commands, tools, sessions, and the SSE stream — with the smallest
well-formed payload each one will accept, and 404s everything else. It runs no
model, executes no tools and holds no state: it exists to get the TUI to `Idle`
with a quiet status bar, which is the state the layout assertions are about.

Deliberately NOT a mock of the backend's behaviour. If a test ever needs real
agent behaviour it wants the real backend, not more code here.
"""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Version reported on /health. The TUI only displays it, so any well-formed
# string does; keeping it obviously fake makes a stray screenshot unambiguous.
STUB_VERSION = "0.0.0-pty-stub"

_HEALTH = {
    "status": "ok",
    "version": STUB_VERSION,
    "uptime_seconds": 0,
    "provider": "pty-stub",
    "model": "pty-stub",
    "context_window": 200000,
    "effort": "medium",
    # `billing: null` and `update: null` keep the status bar's spend and
    # update chips OFF, so neither can perturb the bands under test.
    "billing": None,
    "update": None,
}

_LOGIN = {
    "token": "pty-stub-token",
    "refresh_token": "pty-stub-refresh",
    "expires_in": 3600,
}


class _Handler(BaseHTTPRequestHandler):
    # Silence the default per-request stderr logging: the harness's own output
    # is the signal, and a boot storms this with a dozen lines.
    def log_message(self, *_args):  # noqa: D102
        pass

    def _json(self, payload, status: int = 200) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _sse(self) -> None:
        """Hold the event stream open, silently.

        `osagent` reconnects with backoff on a closed stream, and each
        reconnect can surface a status-bar change — noise the layout tests
        would have to tolerate. Holding the connection open and sending only
        comment keepalives keeps the screen still. Ends when the client
        disconnects (the write raises).
        """
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        try:
            while not self.server._stopping:  # type: ignore[attr-defined]
                self.wfile.write(b": keepalive\n\n")
                self.wfile.flush()
                if self.server._stop_event.wait(1.0):  # type: ignore[attr-defined]
                    break
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

    def do_GET(self):  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path == "/health":
            return self._json(_HEALTH)
        if path.startswith("/api/v1/stream/"):
            return self._sse()
        if path == "/api/v1/commands":
            return self._json({"commands": []})
        if path == "/api/v1/tools":
            return self._json({"tools": []})
        if path == "/api/v1/sessions/recent":
            return self._json({"sessions": []})
        if path == "/api/v1/sessions":
            return self._json({"sessions": []})
        if path == "/api/v1/permission-rules":
            return self._json({"rules": []})
        # Everything else: a well-formed empty object beats a 404, because a
        # 404 can raise a toast and a toast is a BAND.
        return self._json({})

    def do_POST(self):  # noqa: N802
        path = self.path.split("?", 1)[0]
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        if path == "/api/v1/auth/login" or path == "/api/v1/auth/refresh":
            return self._json(_LOGIN)
        if path == "/api/v1/sessions":
            return self._json({"session_id": "pty-stub-session", "id": "pty-stub-session"})
        return self._json({})


class StubBackend:
    """Run the stub on `port` for the lifetime of a `with` block."""

    def __init__(self, port: int, host: str = "127.0.0.1") -> None:
        self.port = port
        self.host = host
        self._server: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    @property
    def base_url(self) -> str:
        return f"http://{self.host}:{self.port}"

    def __enter__(self) -> "StubBackend":
        server = ThreadingHTTPServer((self.host, self.port), _Handler)
        server.daemon_threads = True
        server._stopping = False  # type: ignore[attr-defined]
        server._stop_event = threading.Event()  # type: ignore[attr-defined]
        self._server = server
        self._thread = threading.Thread(target=server.serve_forever, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, *_exc) -> None:
        if self._server is not None:
            self._server._stopping = True  # type: ignore[attr-defined]
            self._server._stop_event.set()  # type: ignore[attr-defined]
            self._server.shutdown()
            self._server.server_close()
        if self._thread is not None:
            self._thread.join(timeout=5)
