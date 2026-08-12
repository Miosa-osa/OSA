"""Ground truth on ARRIVAL shape: how the provider's deltas actually land.

Reads the backend's SSE stream directly — no TUI, no terminal — and reports the
distribution of `streaming_token` sizes and of the gaps between them. This is
the input to every smoothing decision, so it has to be measured rather than
assumed: a pacer is only worth having if the deltas really do arrive clumped.

    python3 test/pty/delta_shape.py --url http://127.0.0.1:19341
"""

from __future__ import annotations

import argparse
import json
import statistics
import threading
import time
import urllib.request
import uuid


def pct(values, q: float) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    k = min(len(s) - 1, max(0, int(round(q * (len(s) - 1)))))
    return s[k]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:19341")
    ap.add_argument(
        "--prompt",
        default="Write four paragraphs about why terminals redraw. No lists, no code, no tools.",
    )
    ap.add_argument("--label", default="")
    ap.add_argument("--timeout", type=float, default=180.0)
    args = ap.parse_args()

    sid = f"delta-shape-{uuid.uuid4().hex[:8]}"
    deltas: list[tuple[float, int]] = []
    done = threading.Event()

    def reader() -> None:
        req = urllib.request.Request(f"{args.url}/api/v1/sessions/{sid}/stream")
        with urllib.request.urlopen(req, timeout=args.timeout) as r:
            event = None
            for raw in r:
                line = raw.decode("utf-8", "replace").rstrip("\n")
                if line.startswith("event:"):
                    event = line[6:].strip()
                elif line.startswith("data:"):
                    now = time.monotonic()
                    payload = line[5:].strip()
                    if event in ("streaming_token", "message"):
                        try:
                            d = json.loads(payload)
                        except json.JSONDecodeError:
                            continue
                        t = d.get("type") or event
                        if t == "streaming_token":
                            text = d.get("content") or d.get("text") or ""
                            if text:
                                deltas.append((now, len(text)))
                        elif t in ("done", "agent_response") and deltas:
                            done.set()
                            return
                    elif event in ("done", "agent_response") and deltas:
                        done.set()
                        return

    th = threading.Thread(target=reader, daemon=True)
    th.start()
    time.sleep(1.0)

    body = json.dumps({"input": args.prompt, "session_id": sid}).encode()
    post = urllib.request.Request(
        f"{args.url}/api/v1/orchestrate",
        data=body,
        headers={"Content-Type": "application/json"},
    )
    try:
        urllib.request.urlopen(post, timeout=args.timeout).read()
    except Exception as e:  # the request is held open for the whole turn
        print(f"(orchestrate returned: {e})")
    done.wait(timeout=15)

    if not deltas:
        print(f"{args.label or args.url}: NO streaming_token events observed")
        return 1
    sizes = [n for _, n in deltas]
    gaps = [(b - a) * 1000.0 for (a, _), (b, _) in zip(deltas, deltas[1:])]
    print(
        f"{args.label or args.url}: deltas={len(sizes)} "
        f"size p50={statistics.median(sizes):.1f} p90={pct(sizes, 0.9):.0f} max={max(sizes)} "
        f"| gap p50={statistics.median(gaps) if gaps else 0:.1f}ms "
        f"p90={pct(gaps, 0.9):.1f}ms "
        f"under1ms={100 * sum(1 for g in gaps if g < 1.0) / len(gaps):.1f}% "
        f"| span={(deltas[-1][0] - deltas[0][0]):.1f}s chars={sum(sizes)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
