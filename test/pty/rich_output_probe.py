"""Exercise an unfinished wide/long reply through the real TUI reader.

Run with OSA_PTY_HOME pointing at a disposable directory and --binary pointing
at the build under test. No real provider or desktop automation is involved.
"""
import argparse
import os
from pathlib import Path
import threading
import time
from http.server import ThreadingHTTPServer

import stream_paint_probe as base
from osa_pty import PtySession

RELEASE = threading.Event()
SENT = threading.Event()
BODY = "~~~ascii\nFIRST   LEFT" + "-" * 120 + "RIGHTEDGE\n" + "".join(
    f"row {i:03d}   aligned   value\n" for i in range(160)
)


class Handler(base._Handler):
    def do_POST(self):
        if self.path.split("?", 1)[0] != "/api/v1/orchestrate":
            return super().do_POST()
        self.rfile.read(int(self.headers.get("Content-Length") or 0))

        def stream():
            time.sleep(0.2)
            for line in BODY.splitlines(keepends=True):
                base.BUS.send("streaming_token", {
                    "text": line, "session_id": "s", "message_id": "rich",
                })
                time.sleep(0.005)
            SENT.set()
            if RELEASE.wait(30):
                base.BUS.send("agent_response", {
                    "response": BODY + "~~~\n", "response_type": "text",
                    "signal": None, "message_id": "rich",
                })

        threading.Thread(target=stream, daemon=True).start()
        return self._json({"session_id": "s", "status": "accepted"})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True)
    args = parser.parse_args()
    if not os.environ.get("OSA_PTY_HOME"):
        parser.error("OSA_PTY_HOME must point to disposable test state")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with PtySession(f"http://127.0.0.1:{server.server_port}", cols=80, rows=24,
                        binary=Path(args.binary)) as session:
            session.boot()
            base.type_and_submit(session, "show long diagram")
            deadline = time.monotonic() + 10
            while not SENT.is_set() and time.monotonic() < deadline:
                session.pump(0.1)
            assert SENT.is_set(), "the probe never submitted its turn"
            session.pump(0.5)
            session.write(b"\x0f")  # Ctrl+O, while the fence is still open
            session.pump(0.5)
            screen = "\n".join(base.snapshot(session))
            assert "Transcript snapshot" in screen, screen
            assert "row 159" in screen, "unfinished tail is absent from reader"
            session.write(b"w")
            session.pump(0.2)
            session.write(b"/RIGHTEDGE\r")
            session.pump(0.3)
            for _ in range(12):
                session.write(b"\x1b[C")
                session.pump(0.03)
            screen = "\n".join(base.snapshot(session))
            assert "RIGHTEDGE" in screen, screen
            session.resize(62, 20)
            session.pump(0.5)
            assert "Transcript snapshot" in "\n".join(base.snapshot(session))
            session.resize(180, 24)
            session.pump(0.5)
            widened = "\n".join(base.snapshot(session))
            assert "FIRST   LEFT" in widened, "left edge missing after widening:\n" + widened
            session.write(b"\x1b")
            session.pump(0.3)
            RELEASE.set()
            session.pump(2)
            assert "Transcript snapshot" not in "\n".join(base.snapshot(session))
            print("PASS: unfinished 160-row reply, preserved columns, horizontal pan, resize, close")
    finally:
        RELEASE.set()
        server.shutdown()


if __name__ == "__main__":
    main()
