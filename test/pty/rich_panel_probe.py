"""Check real terminal cell colors for a diagram, live and settled.

Uses the local stub only. Requires disposable OSA_PTY_HOME and pyte.
"""
import argparse
import os
from pathlib import Path
import threading
import time
from http.server import ThreadingHTTPServer

import rich_output_probe as rich
from osa_pty import PtySession


def check_panel(session):
    rows = rich.base.snapshot(session)
    root = next((y for y, row in enumerate(rows) if "PANEL_ROOT" in row), None)
    assert root is not None, "diagram absent:\n" + "\n".join(rows)
    x = rows[root].index("PANEL_ROOT")
    color = session.screen.buffer[root][x].bg
    assert color != "default", "probe requires a color-capable environment"
    for y in range(root, root + 4):
        for col in range(x, session.cols - 4):
            assert session.screen.buffer[y][col].bg == color, (
                f"jagged panel at ({col},{y}):\n" + "\n".join(rows))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True)
    args = parser.parse_args()
    if not os.environ.get("OSA_PTY_HOME"):
        parser.error("OSA_PTY_HOME must point to disposable test state")
    rich.BODY = "Diagram:\n\n~~~text\nPANEL_ROOT\n  │\n\n  └── leaf\n"
    server = ThreadingHTTPServer(("127.0.0.1", 0), rich.Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with PtySession(f"http://127.0.0.1:{server.server_port}", cols=80, rows=32,
                        binary=Path(args.binary),
                        env={"NO_COLOR": None, "COLORTERM": "truecolor"}) as session:
            session.boot()
            rich.base.type_and_submit(session, "show diagram")
            deadline = time.monotonic() + 10
            while not rich.SENT.is_set() and time.monotonic() < deadline:
                session.pump(0.1)
            assert rich.SENT.is_set(), "turn not submitted"
            session.pump(0.5)
            check_panel(session)
            rich.RELEASE.set()
            session.pump(2)
            check_panel(session)
            print("PASS: rectangular diagram background, including blank rows, live and settled")
    finally:
        rich.RELEASE.set()
        server.shutdown()


if __name__ == "__main__":
    main()
