"""Shared fixtures for the PTY suite.

The PTY tests are the only instrument that can see this codebase's layout and
terminal-state bugs. `cargo test` cannot: `VT100Backend` answers cursor queries
from a perfect model, so a screen that is wrong on a real terminal is right in
the unit suite. Every TUI defect worth having found -- keystrokes swallowed
while connecting, an Esc affordance that stayed on screen after it stopped
working, a turn that ended under an overlay and wedged the session -- was found
here and is pinned here.

This file exists because the `backend` fixture the tests take was never
committed: each test declares `backend: StubBackend`, no `conftest.py` defined
it, and so the entire suite errored at collection with `fixture 'backend' not
found`. It was reported green by whoever had it in their working tree, which is
exactly the failure mode the suite is meant to prevent -- an instrument that
agrees with you because it never ran.
"""

from __future__ import annotations

import os
import socket
import tempfile

import pytest

from stub_backend import StubBackend


@pytest.fixture(scope="session", autouse=True)
def _isolated_home():
    """Keep the harness out of the developer's real `~/.osa`.

    `osa_pty.PtySession` reads `$OSA_PTY_HOME` and falls back to the REAL `$HOME`
    when it is unset. `run.sh` always sets it; running these tests under pytest
    directly does not — so any test that makes OSA write state (a `/theme`, an
    `/a11y`, a `/hide-tools`, anything that lands in `~/.osa/tui.json`) would
    edit the config of whoever ran it. Set it here so both entry points are
    equally safe, and leave an operator-provided value alone.
    """
    if os.environ.get("OSA_PTY_HOME"):
        yield
        return
    with tempfile.TemporaryDirectory(prefix="osa-pty-home-") as home:
        os.environ["OSA_PTY_HOME"] = home
        try:
            yield
        finally:
            os.environ.pop("OSA_PTY_HOME", None)


def _free_port() -> int:
    """Ask the OS for a port, then hand the number to the stub.

    There is a race here -- the socket closes before `StubBackend` binds -- but
    the alternative is a fixed port, and these tests run concurrently with a
    live daemon on 9089 and with other suites. An ephemeral port the kernel just
    handed out is far less likely to collide than a constant someone picked.
    """
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


@pytest.fixture
def backend():
    """A stub OSA backend on a free port, torn down with the test.

    `StubBackend` is a context manager: entering it binds the port and starts
    serving, exiting stops it and releases the port. Yielding from inside the
    `with` block means a test that fails mid-turn still releases the port, which
    matters because these tests hold `/health` and the orchestrate long-poll open
    on purpose.
    """
    with StubBackend(_free_port()) as be:
        yield be
