"""Pool several `pace_probe` runs and print one distribution per file.

Percentiles from a 7-second run are noisy; averaging percentiles across runs is
worse than useless because it flattens the tail. This pools the RAW samples.

    python3 test/pty/pace_pool.py before.json after.json
"""

from __future__ import annotations

import json
import statistics
import sys
from pathlib import Path


def pct(values, q: float) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    k = min(len(s) - 1, max(0, int(round(q * (len(s) - 1)))))
    return s[k]


def main() -> int:
    print(
        f"{'file':<26} {'runs':>4} {'paints':>7} {'gap p50':>9} {'gap p90':>9} "
        f"{'gap p99':>9} {'<1ms':>6} {'ch p50':>7} {'ch p90':>7} {'ch max':>7} {'span s':>7}"
    )
    for path in sys.argv[1:]:
        runs = json.loads(Path(path).read_text())
        gaps = [g for r in runs for g in r["gaps_ms"]]
        chars = [c for r in runs for c in r["chars_per_paint"]]
        spans = [r["first_to_last_visible_ms"] / 1000.0 for r in runs]
        under1 = sum(1 for g in gaps if g < 1.0) / len(gaps) if gaps else 0.0
        print(
            f"{Path(path).name:<26} {len(runs):>4} {len(chars):>7} "
            f"{statistics.median(gaps) if gaps else 0:>8.2f}m "
            f"{pct(gaps, 0.90):>8.2f}m {pct(gaps, 0.99):>8.2f}m "
            f"{under1 * 100:>5.1f}% "
            f"{statistics.median(chars) if chars else 0:>7.1f} "
            f"{pct(chars, 0.90):>7.1f} {max(chars) if chars else 0:>7} "
            f"{statistics.mean(spans) if spans else 0:>7.1f}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
