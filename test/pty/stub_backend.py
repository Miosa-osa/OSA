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
import pathlib
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Version reported on /health. The TUI compares it against its own version
# and paints a multi-row "Version mismatch" banner when they differ, which
# steals screen rows from the bands under test. Report the working tree's
# real version (repo-root VERSION file, same source mix.exs reads) so the
# banner stays off, like the `billing`/`update` nulls below.
STUB_VERSION = (
    (pathlib.Path(__file__).resolve().parents[2] / "VERSION").read_text().strip()
)

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
    "detected": {
        "detected": [],
        # Reachable, so `ollama_local` below is READY and Enter drills into its
        # dynamic catalog instead of opening a key screen. That drill-in is the
        # path the model-switch report is about.
        "ollama_local": {
            "reachable": True,
            "url": "http://127.0.0.1:11434",
            "model_count": 3,
        },
    },
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
        {
            # The provider from the report: local Ollama, whose catalog is
            # `:dynamic` (it is whatever the daemon has pulled), so selecting
            # it must go to the network before any model can be listed.
            "id": "ollama_local",
            "name": "Ollama Local",
            "description": "Private — needs a local GPU",
            "group": "bring_your_own",
            "requires_key": False,
            "tab": "keys",
            "order": 5,
            "base_url": "http://127.0.0.1:11434",
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


# --- gates: holding the TUI in a state long enough to press keys at it -------
#
# Two of the tests here are about what the INPUT layer does in a state, not
# about what the screen looks like once it has left it. Both states are ones the
# stub normally blows through in single-digit milliseconds:
#
#   * `Connecting` — held open by making `/health` not answer yet. This is a
#     faithful stand-in for the real cause (a backend that is slow or dead;
#     `handle_health_result` retries twelve times before giving up), and it is
#     the window in which every keystroke used to be discarded.
#   * `Processing` — held open by making `POST /api/v1/orchestrate` not answer.
#     That call is a long poll for a whole turn, so a stub that returns
#     instantly means the TUI is never in the state where Esc means "interrupt".
#
# Both are `threading.Event`s rather than sleeps so a test can release them the
# moment it is done, and both carry a ceiling so a wedged gate fails a test
# instead of hanging the suite.
_HEALTH_GATE = threading.Event()
_HEALTH_GATE.set()
_TURN_GATE = threading.Event()
_TURN_GATE.set()

# Number of upcoming SSE attaches that should answer 404. This reproduces the
# real stale-session failure without stopping the backend: /health remains
# healthy while only the requested session stream is gone.
_SSE_REJECT_LOCK = threading.Lock()
_SSE_REJECT_COUNT = 0
_SSE_REJECT_SESSION_ID: str | None = None

#: Longest a gated request will ever be held, whatever the test forgets to do.
GATE_CEILING = 30.0

#: How long `/onboarding/models` takes to answer. Long enough that a test can
#: read the screen mid-fetch, short enough not to pad the suite.
CATALOG_DELAY = 1.5


def hold_health() -> None:
    """Stop `/health` answering, so the TUI stays on the connect splash."""
    _HEALTH_GATE.clear()


def release_health() -> None:
    _HEALTH_GATE.set()


# Deliberately never a real release number; used by the stale-daemon test to
# force the TUI's "Version mismatch" banner on demand.
STALE_VERSION = "0.0.0-pty-stub"


def report_stale_version() -> None:
    """Make `/health` report a fake version, so the TUI sees a stale daemon."""
    _HEALTH["version"] = STALE_VERSION


def report_real_version() -> None:
    _HEALTH["version"] = STUB_VERSION


def hold_turn() -> None:
    """Stop `/api/v1/orchestrate` answering, so the turn stays in flight."""
    _TURN_GATE.clear()


def release_turn() -> None:
    _TURN_GATE.set()


def reject_next_sse(count: int = 1, session_id: str | None = None) -> None:
    """Make the next matching `count` session streams answer HTTP 404."""
    global _SSE_REJECT_COUNT, _SSE_REJECT_SESSION_ID
    with _SSE_REJECT_LOCK:
        _SSE_REJECT_COUNT = count
        _SSE_REJECT_SESSION_ID = session_id


def _should_reject_sse(path: str) -> bool:
    global _SSE_REJECT_COUNT
    with _SSE_REJECT_LOCK:
        if _SSE_REJECT_COUNT <= 0:
            return False
        if _SSE_REJECT_SESSION_ID is not None and not path.endswith(
            f"/{_SSE_REJECT_SESSION_ID}"
        ):
            return False
        _SSE_REJECT_COUNT -= 1
        return True


# --- pushing events down the SSE stream --------------------------------------
#
# The stream used to be keepalives and nothing else, which is fine for layout
# but cannot express the single most important fact about a turn: that it ENDED.
# The HTTP response to `POST /orchestrate` is deliberately only an
# acknowledgement — `handle_backend.rs` will not leave `Processing` on it, by
# design — so the ONLY thing that ends a turn on a connected stream is an
# `agent_response` frame. A test about what happens after a turn ends therefore
# has to be able to send one.
_SSE_OUTBOX: list[bytes] = []
_SSE_LOCK = threading.Lock()


def push_sse(event: str, payload: dict) -> None:
    """Queue one SSE frame for delivery on every open stream."""
    frame = f"event: {event}\ndata: {json.dumps(payload)}\n\n".encode()
    with _SSE_LOCK:
        _SSE_OUTBOX.append(frame)


def end_turn(response: str = "done thinking") -> None:
    """End the in-flight turn the way the real backend does.

    `agent_response` is the frame that drives `Processing -> Idle`. Sent alone
    it is exactly what a normal, successful turn looks like from the TUI's side.
    """
    push_sse(
        "agent_response",
        {"response": response, "response_type": "text", "message_id": "stub-msg-1"},
    )


def reset_sse() -> None:
    with _SSE_LOCK:
        _SSE_OUTBOX.clear()


#: The id `POST /sessions/:id/clear` hands back. Deliberately NOT the id the TUI
#: started with, so "did the client adopt the new session?" is answerable by
#: looking at where its next request went.
CLEARED_SESSION_ID = "pty-stub-session-cleared"

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


#: Every GET the stub received, as `path`, oldest first.
#:
#: POSTs alone could not answer the model-switch report. Choosing a provider
#: whose catalog is `:dynamic` issues a GET, and the defect was that ONE
#: keypress could issue SEVERAL of them — a fact about the wire that no
#: screenshot can show, since the duplicates rendered identically.
GETS: list[str] = []


def get_mark() -> int:
    """Current length of `GETS`, to bracket a later `gets_since`."""
    return len(GETS)


def gets_since(mark: int, path: str | None = None) -> list[str]:
    """GETs recorded after `mark`, optionally filtered to one path."""
    tail = GETS[mark:]
    return [g for g in tail if path is None or g == path]


#: What `POST /commands/execute {"command":"goal"}` answers with, as the real
#: backend's `handle_goal_command/2` does: the captured terminal text plus a
#: STRUCTURED snapshot of `GoalTracker`'s state.
#:
#: A test sets this to say whether the goal is still live. That is the whole
#: point of routing `/goal` to the backend: the TUI drives another turn only
#: while the backend says the goal is active, instead of stopping when the
#: model's last line happens to read `DONE`.
_GOAL: dict = {
    "output": "No goal is active.",
    "goal": None,
}


def set_goal_state(active: bool, status: str, pause_reason: str | None = None,
                   goal: str = "ship the parser", turn_count: int = 1,
                   output: str = "Goal status") -> None:
    """Set what the next `/goal` answer reports."""
    _GOAL["output"] = output
    _GOAL["goal"] = {
        "active": active,
        "status": status,
        "goal": goal,
        "goal_id": "g-1",
        "turn_count": turn_count,
        "pause_reason": pause_reason,
    }


def reset_goal_state() -> None:
    set_goal_state(True, "active", output="Goal anchored")


def clear_goal_state() -> None:
    """Make reconnect goal sync report that this session has no goal."""
    _GOAL["output"] = "No goal is active."
    _GOAL["goal"] = None


class _Handler(BaseHTTPRequestHandler):
    # Silence the default per-request stderr logging: the harness's own output
    # is the signal, and a boot storms this with a dozen lines.
    def log_message(self, *_args):  # noqa: D102
        pass

    def _json(self, payload, status: int = 200) -> None:
        body = json.dumps(payload).encode()
        # A GATED request (see the gate comment above) is deliberately still
        # being held when its test kills the session, so the client is often
        # gone by the time the answer is written. That is the harness working,
        # not a failure — but socketserver's default is to print a full
        # traceback for it, which buries the suite's own output. Swallow the
        # disconnect and nothing else.
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

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
        # Each stream tracks how much of the shared outbox it has already sent,
        # so a frame pushed by a test reaches every open stream exactly once.
        # A stream only ever sends frames pushed AFTER it opened. The outbox is
        # process-global and a test may leave frames in it, so starting at the
        # current end (rather than 0) stops a previous test's turn-end leaking
        # into the next session's stream.
        with _SSE_LOCK:
            sent = len(_SSE_OUTBOX)
        last_keepalive = 0.0
        try:
            while not self.server._stopping:  # type: ignore[attr-defined]
                with _SSE_LOCK:
                    pending = _SSE_OUTBOX[sent:]
                    sent = len(_SSE_OUTBOX)
                for frame in pending:
                    self.wfile.write(frame)
                # Keepalive cadence is unchanged at ~1s: it exists to hold the
                # connection, and the layout tests are calibrated to that much
                # quiet. Only the POLL is fast, so a pushed frame is not stuck
                # behind a one-second sleep.
                now = time.time()
                if not pending and now - last_keepalive >= 1.0:
                    self.wfile.write(b": keepalive\n\n")
                    last_keepalive = now
                self.wfile.flush()
                if self.server._stop_event.wait(0.05):  # type: ignore[attr-defined]
                    break
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

    def do_GET(self):  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path == "/health":
            # See the gate comment above: held open, this is what keeps the TUI
            # on the connect splash long enough to press keys at it.
            _HEALTH_GATE.wait(GATE_CEILING)
            return self._json(_HEALTH)
        if path.startswith("/api/v1/stream/"):
            GETS.append(path)
            if _should_reject_sse(path):
                return self._json({"error": "session not found"}, status=404)
            return self._sse()
        if path == "/api/v1/commands":
            return self._json({"commands": []})
        if path == "/api/v1/tools":
            return self._json({"tools": []})
        if path == "/api/v1/sessions/recent":
            return self._json({"sessions": []})
        GETS.append(path)
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
            # Deliberately SLOW. A dynamic catalog is a real network round-trip
            # (for Ollama, a local daemon that may be cold), and the reported
            # defect lived entirely inside that window: the dialog showed no
            # sign of the fetch, so the keypress read as dropped. An instant
            # stub closes the window and hides the very thing under test.
            time.sleep(CATALOG_DELAY)
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
        if path.endswith("/steer"):
            # `POST /sessions/:id/steer` — the real backend parks the text in an
            # ETS queue the busy loop can still read and folds it in at the next
            # ReAct step boundary, answering 202. The stub only has to accept it
            # and record it: what the tests need to see is that the queued text
            # reached the wire WHILE the original turn was still outstanding,
            # which is a fact about the request, not about the model.
            return self._json({"status": "steered"}, 202)
        if path == "/api/v1/commands/execute":
            try:
                body = json.loads(raw or b"{}")
            except ValueError:
                body = {}
            if str(body.get("command", "")).lower() == "goal":
                arg = body.get("arg") or ""
                return self._json(
                    {
                        "output": _GOAL["output"],
                        "command": ("goal " + arg).strip(),
                        "goal": _GOAL["goal"],
                    }
                )
            if str(body.get("command", "")).lower() == "fast":
                return self._json(
                    {"output": "Fast mode enabled", "command": "fast", "effort": "fast"}
                )
            return self._json({"output": "", "command": body.get("command", "")})
        if path == "/api/v1/orchestrate":
            # Recorded ABOVE, then held: a test can see the turn start while it
            # is still in flight, which is the whole point — Esc only means
            # "interrupt" while the long poll is outstanding.
            _TURN_GATE.wait(GATE_CEILING)
            return self._json({})
        if path.startswith("/api/v1/sessions/") and path.endswith("/clear"):
            # The real endpoint is a session SWAP, not an in-place wipe: it stops
            # the old loop and returns a NEW id, with the old one as
            # `parent_session` (session_routes.ex `post "/:id/clear"`). The stub
            # has to return the same shape or it cannot tell a client that adopts
            # the new id from one that drops it on the floor — which was the
            # actual defect, and is invisible to any check that only looks at
            # whether a 2xx came back.
            return self._json(
                {
                    "id": CLEARED_SESSION_ID,
                    "status": "cleared",
                    "parent_session": path.split("/")[4],
                    "working_dir": "/tmp",
                },
                status=201,
            )
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
