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


# Four Codex models, as `Onboarding.model_list("openai_codex")` answers them.
# Static — no network call is needed to know them, which is why an
# unauthenticated model list is not a credential question.
_CODEX_MODELS = [
    {"id": "gpt-5.2-codex", "name": "gpt-5.2-codex", "ctx": 400000, "tools": True},
    {"id": "gpt-5.1-codex-max", "name": "gpt-5.1-codex-max", "ctx": 400000, "tools": True},
]

# A cut-down `/onboarding/status`, carrying the fields the provider surface
# renders from: the accounts/keys `tab`, the curated `order`, and the live
# `auth` state. One account provider that is NOT signed in (the exact row that
# used to answer HTTP 401), one that is, and one key-only provider.
_ONBOARDING_STATUS = {
    "needs_onboarding": False,
    "needs_bootstrap": False,
    "system_info": {},
    "detected": {"detected": [], "ollama_local": {"reachable": False, "url": "", "model_count": 0}},
    "providers": [
        {
            "id": "openai_codex",
            "name": "ChatGPT (Codex)",
            "description": "Use your ChatGPT Plus/Pro plan",
            "group": "recommended",
            "requires_key": False,
            "tab": "accounts",
            "order": 6,
            "auth_modes": ["oauth"],
            "usable_auth_modes": ["oauth"],
            # Signed in, so the usage panel has an account, an org and a plan
            # to name — the three things the picker previously showed none of.
            "auth": {
                "state": "connected",
                "can_sign_in": True,
                "can_paste_key": False,
                "account": "luna@example.com",
                "plan": "plus",
            },
            "models": "dynamic",
        },
        {
            "id": "claude_cli",
            "name": "Claude subscription (via Claude Code)",
            "description": "Use your Claude Pro/Max plan",
            "group": "recommended",
            "requires_key": False,
            "tab": "accounts",
            "order": 7,
            "auth_modes": ["oauth"],
            "usable_auth_modes": ["oauth"],
            # Deliberately NOT signed in: this is the row whose only previous
            # answer was a sentence telling the user to quit OSA and run a
            # command somewhere else. The harness drives it to a real pty.
            "auth": {
                "state": "needs_sign_in",
                "can_sign_in": True,
                "can_paste_key": False,
                "account": None,
                "plan": None,
            },
            "models": [{"id": "sonnet", "name": "sonnet", "ctx": 0, "tools": True}],
        },
        {
            "id": "anthropic",
            "name": "Anthropic",
            "description": "Claude models",
            "group": "bring_your_own",
            "requires_key": True,
            "tab": "keys",
            "order": 4,
            "auth_modes": ["api_key"],
            "usable_auth_modes": ["api_key"],
            "auth": {
                "state": "needs_key",
                "can_sign_in": False,
                "can_paste_key": True,
                "account": None,
                "plan": None,
            },
            "models": "dynamic",
        },
    ],
}


# `Auth.Subscription.status_all/0`. `openai_codex` is connected and carries an
# ORG as well as an email — the field the picker used to drop, which left a
# user with a personal and a work plan unable to tell which one was live.
_AUTH_STATUS = {
    "providers": [
        {
            "provider": "openai_codex",
            "connected?": True,
            "verified?": True,
            "account": "luna@example.com",
            "plan": "plus",
            "org": "Acme Inc",
            "expired?": False,
        },
        {
            "provider": "claude_cli",
            "connected?": False,
            "verified?": False,
            "account": None,
            "plan": None,
            "org": None,
            "expired?": False,
        },
    ]
}

# `Usage.RateLimits.all/0`. Exactly one provider has reported — which is the
# realistic case and the interesting one: the OTHER provider must render as
# "not known yet", in words, and MUST NOT get a zeroed bar. A provider that has
# reported nothing is ABSENT from this map; there is deliberately no key for it
# to be defaulted from.
_USAGE_NOW = 1_700_000_000
_USAGE_QUOTA = {
    "providers": {
        "openai_codex": {
            "used_percent": 48.0,
            "window_minutes": 10080,
            "resets_at": "2026-08-18T09:30:00Z",
            "limit_name": None,
            "observed_at": _USAGE_NOW - 7200,
        }
    },
    "now": _USAGE_NOW,
}

# `Auth.Providers.ClaudeCli.cli_state/0`, and the one piece of stub state a
# test mutates: the whole point of the feature is that OSA installs and signs
# in *in place*, so the harness has to be able to say "not installed", watch
# OSA run something, and then say "installed".
#
# `install_argv` / `login_program` point at real, harmless binaries. That is
# not a shortcut around the feature — the feature IS "spawn what the backend
# named on a pty and show me its screen", and pointing it at `/bin/echo` tests
# exactly that without needing npm or an Anthropic account in CI.
CLAUDE_CLI_STATE = {
    "installed": False,
    "path": None,
    "version": None,
    "version_ok": None,
    "min_version": "2.0.0",
    "signed_in": False,
    "account": None,
    "org": None,
    "plan": None,
    "login_program": None,
    "login_argv": None,
    "login_display": None,
    "login_error": None,
    # Prints, then lingers. A real `npm install -g` runs for tens of seconds
    # with output arriving throughout, and that IS the state the pane exists
    # to render; a child that prints and exits in the same millisecond would
    # make the assertion a race against OSA's own re-check.
    "install_argv": ["/bin/sh", "-c", "echo PTY-INSTALL-RAN; sleep 4"],
    "install_url": "https://claude.com/product/claude-code",
}


def set_claude_cli_state(**fields) -> None:
    """Move the stub's Claude Code state, as running a command would."""
    CLAUDE_CLI_STATE.update(fields)


#: Every POST the stub received, as `(path, body)`, oldest first.
#: Appended by `_Handler.do_POST`; read by the tests through `posts_since`.
POSTS: list[tuple[str, str]] = []


def post_mark() -> int:
    """Current length of `POSTS`, to bracket a later `posts_since`."""
    return len(POSTS)


def posts_since(mark: int, path: str | None = None) -> list[tuple[str, str]]:
    """POSTs recorded after `mark`, optionally filtered to one path."""
    tail = POSTS[mark:]
    return [p for p in tail if path is None or p[0] == path]


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
        if path == "/onboarding/status":
            return self._json(_ONBOARDING_STATUS)
        if path == "/auth/status":
            return self._json(_AUTH_STATUS)
        if path == "/usage/quota":
            return self._json(_USAGE_QUOTA)
        if path == "/auth/cli/claude":
            return self._json(dict(CLAUDE_CLI_STATE))
        if path == "/onboarding/models":
            # The shape the real backend answers with. Note the STATUS: 200.
            # The shipped defect answered 401 here for every provider once
            # setup was complete, and the TUI surfaced it verbatim as
            # "Failed to load models: HTTP 401".
            return self._json({"models": _CODEX_MODELS})
        # Everything else: a well-formed empty object beats a 404, because a
        # 404 can raise a toast and a toast is a BAND.
        return self._json({})

    def do_POST(self):  # noqa: N802
        path = self.path.split("?", 1)[0]
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        # Record what actually arrived. A layout harness can only ever prove
        # that the screen looks right; the reported bug ("I send a prompt and
        # nothing happens") needs the other half — whether the keystroke turned
        # into a REQUEST. Without this, a build that renders a perfect composer
        # and dispatches nothing passes every test here.
        POSTS.append((path, raw.decode("utf-8", "replace")))
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
