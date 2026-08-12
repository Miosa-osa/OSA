#!/usr/bin/env python3
"""Drive one REAL streaming turn and report the wire/paint shape.

Three attempts at the "streaming looks chunky" complaint were argued from
synthetic benches and all three were wrong. This drives the actual binary,
against the actual provider, in a real kernel PTY, and reads the two
distributions the `stream_probe` module records:

  * delta — a token as it arrived off the wire
  * paint — a frame, and how many characters it revealed for the first time

If the deltas are smooth and the paints are lumpy, the loop is at fault. If the
deltas themselves arrive in slabs, no paint scheduling can help and the fix has
to be a reveal pacer.

Usage:
    stream_shape_probe.py [--prompt TEXT] [--timeout SECONDS] [--out PATH]
"""

from __future__ import annotations

import argparse
import json
import os
import pty
import select
import signal
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TUI = os.path.join(ROOT, "priv", "rust", "tui", "target", "release", "osagent")

DEFAULT_PROMPT = (
    "Write a 40-line Python function that validates an email address, "
    "with a docstring and inline comments explaining each step."
)


def pct(xs: list[int], p: float) -> float:
    if not xs:
        return 0.0
    s = sorted(xs)
    i = min(int(round(p / 100.0 * (len(s) - 1))), len(s) - 1)
    return float(s[i])


def summarize(name: str, sizes: list[int], times_us: list[int]) -> None:
    if not sizes:
        print(f"  {name:6}  (none recorded)")
        return
    total = sum(sizes)
    gaps = [
        (b - a) / 1000.0 for a, b in zip(times_us, times_us[1:])
    ]  # ms between events
    print(
        f"  {name:6} n={len(sizes):5}  chars={total:6}  "
        f"mean={total / len(sizes):6.1f}  p50={pct(sizes, 50):5.0f}  "
        f"p90={pct(sizes, 90):5.0f}  p99={pct(sizes, 99):5.0f}  max={max(sizes):5}"
    )
    if gaps:
        print(
            f"  {'':6} gap ms: mean={sum(gaps) / len(gaps):6.1f}  "
            f"p50={pct([int(g) for g in gaps], 50):5.0f}  "
            f"p90={pct([int(g) for g in gaps], 90):5.0f}  max={max(gaps):6.1f}"
        )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--prompt", default=DEFAULT_PROMPT)
    ap.add_argument("--timeout", type=float, default=180.0)
    ap.add_argument("--out", default="/tmp/osa-stream-probe.jsonl")
    ap.add_argument("--rows", type=int, default=40)
    ap.add_argument("--cols", type=int, default=100)
    args = ap.parse_args()

    if not os.path.exists(TUI):
        print(f"missing TUI binary: {TUI}", file=sys.stderr)
        return 2

    if os.path.exists(args.out):
        os.unlink(args.out)

    env = dict(os.environ)
    env["OSA_STREAM_PROBE"] = args.out
    env["TERM"] = "xterm-256color"
    # A fresh session id so this never disturbs a session the user is in.
    env["OSA_SESSION_ID"] = f"streamprobe-{int(time.time())}"

    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(env)
        try:
            import fcntl
            import struct
            import termios

            fcntl.ioctl(
                0, termios.TIOCSWINSZ, struct.pack("HHHH", args.rows, args.cols, 0, 0)
            )
        except Exception:
            pass
        os.execve(TUI, [TUI], env)
        os._exit(127)

    deadline = time.time() + args.timeout
    sent = False
    seen = bytearray()

    try:
        while time.time() < deadline:
            r, _, _ = select.select([fd], [], [], 0.25)
            if r:
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                seen += chunk

            # Send the prompt once the composer is up.
            if not sent and (b">" in seen or b"OSA" in seen) and len(seen) > 200:
                time.sleep(2.0)  # let the backend session settle
                os.write(fd, args.prompt.encode() + b"\r")
                sent = True
                continue

            # Stop once the probe file has been quiet for a while post-send.
            if sent and os.path.exists(args.out):
                age = time.time() - os.path.getmtime(args.out)
                if age > 8.0 and os.path.getsize(args.out) > 0:
                    break
    finally:
        try:
            os.write(fd, b"\x03")
            time.sleep(0.3)
            os.kill(pid, signal.SIGTERM)
            time.sleep(0.3)
            os.kill(pid, signal.SIGKILL)
        except Exception:
            pass
        try:
            os.close(fd)
        except Exception:
            pass
        try:
            os.waitpid(pid, 0)
        except Exception:
            pass

    if not os.path.exists(args.out) or os.path.getsize(args.out) == 0:
        print("no probe output — the turn never streamed", file=sys.stderr)
        print(f"last screen bytes:\n{seen[-1500:].decode(errors='replace')}", file=sys.stderr)
        return 1

    deltas: list[int] = []
    delta_t: list[int] = []
    paints: list[int] = []
    paint_t: list[int] = []
    with open(args.out) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if rec.get("kind") == "delta":
                deltas.append(rec["n"])
                delta_t.append(rec["t"])
            elif rec.get("kind") == "paint" and rec.get("n", 0) > 0:
                paints.append(rec["n"])
                paint_t.append(rec["t"])

    print("\n  REAL TURN — streaming shape\n")
    summarize("wire", deltas, delta_t)
    print()
    summarize("paint", paints, paint_t)

    if deltas and paints:
        print()
        print(f"  wire chars {sum(deltas)} vs painted {sum(paints)}")
        # The headline number: does one paint carry a slab?
        big = [n for n in paints if n >= 100]
        print(
            f"  paints >=100 chars: {len(big)} of {len(paints)} "
            f"({100.0 * len(big) / len(paints):.1f}%), carrying "
            f"{100.0 * sum(big) / max(sum(paints), 1):.1f}% of the text"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
