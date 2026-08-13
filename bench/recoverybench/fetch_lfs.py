#!/usr/bin/env python3
"""Fetch git-lfs objects for the upstream recovery-bench traces without git-lfs.

The pre-generated Terminus-2/Haiku-4.5 initial trajectories are the *fixed
corruption source* for Recovery-Bench: every model and agent is scored against
the same failed attempts, which is the only reason cross-run numbers are
comparable at all. They ship as git-lfs pointers, and git-lfs is not installed
on this host, so this talks the LFS batch API directly. Public repo, no auth.
"""

from __future__ import annotations

import json
import random
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


def _urlopen_retry(req, timeout: int = 120, tries: int = 8):
    """GitHub's LFS endpoint rate-limits hard (429). Back off rather than fail."""
    for attempt in range(tries):
        try:
            return urllib.request.urlopen(req, timeout=timeout)
        except urllib.error.HTTPError as e:
            if e.code not in (429, 500, 502, 503) or attempt == tries - 1:
                raise
            delay = min(60, 2**attempt) + random.uniform(0, 2)
            print(f"  http {e.code}, retry in {delay:.1f}s")
            time.sleep(delay)
        except Exception:
            if attempt == tries - 1:
                raise
            time.sleep(min(30, 2**attempt))
    raise RuntimeError("unreachable")

REPO = "https://github.com/letta-ai/recovery-bench.git"
BATCH = f"{REPO}/info/lfs/objects/batch"
ROOT = Path(__file__).resolve().parent / "upstream"

POINTER_MAGIC = b"version https://git-lfs.github.com/spec/v1"

# GitHub throttles unrecognised LFS clients aggressively; identify as git-lfs.
UA = "git-lfs/3.4.0 (GitHub; linux amd64; go 1.21)"


# Recovery-Bench needs exactly two files per task: the trajectory (the failed
# command sequence that gets replayed, plus the transcript for `full` mode) and
# the result (which says whether the weak agent failed, i.e. whether the task is
# in the corrupted set at all).
#
# The upstream traces also ship a per-LLM-call dump — prompt.txt, response.txt
# and debug.json, 12,822 files against the 179 that matter. Fetching those costs
# hours of rate-limited round-trips and buys nothing, so the default is the
# narrow set. Pass --all to mirror the whole thing.
WANTED = {"trajectory.json", "result.json"}


def pointers(names: set[str] | None = WANTED) -> list[tuple[Path, str, int]]:
    """Every file under upstream/ that is still an unresolved LFS pointer."""
    out = []
    for p in ROOT.rglob("*"):
        if not p.is_file() or p.stat().st_size > 400:
            continue
        if names is not None and p.name not in names:
            continue
        try:
            head = p.read_bytes()
        except OSError:
            continue
        if not head.startswith(POINTER_MAGIC):
            continue
        oid = size = None
        for line in head.decode("utf-8", "replace").splitlines():
            if line.startswith("oid sha256:"):
                oid = line.split(":", 1)[1].strip()
            elif line.startswith("size "):
                size = int(line.split()[1])
        if oid and size is not None:
            out.append((p, oid, size))
    return out


def batch(objs: list[tuple[Path, str, int]]) -> dict[str, str]:
    """Ask the LFS server for download hrefs, 100 objects at a time."""
    hrefs: dict[str, str] = {}
    for i in range(0, len(objs), 100):
        chunk = objs[i : i + 100]
        if i:
            time.sleep(3)
        body = json.dumps(
            {
                "operation": "download",
                "transfers": ["basic"],
                "objects": [{"oid": o, "size": s} for _, o, s in chunk],
            }
        ).encode()
        req = urllib.request.Request(
            BATCH,
            data=body,
            headers={
                "Accept": "application/vnd.git-lfs+json",
                "Content-Type": "application/vnd.git-lfs+json",
                "User-Agent": UA,
            },
        )
        with _urlopen_retry(req, timeout=120) as r:
            for o in json.loads(r.read())["objects"]:
                href = (o.get("actions") or {}).get("download", {}).get("href")
                if href:
                    hrefs[o["oid"]] = href
    return hrefs


def fetch(item: tuple[Path, str, int], hrefs: dict[str, str]) -> tuple[Path, bool]:
    path, oid, size = item
    href = hrefs.get(oid)
    if not href:
        return path, False
    try:
        with _urlopen_retry(urllib.request.Request(href, headers={"User-Agent": UA}), timeout=300) as r:
            data = r.read()
    except Exception:
        return path, False
    if len(data) != size:
        return path, False
    path.write_bytes(data)
    return path, True


def main() -> int:
    names = None if "--all" in sys.argv[1:] else WANTED
    objs = pointers(names)
    print(f"{len(objs)} lfs pointers to resolve ({'all files' if names is None else sorted(names)})")
    if not objs:
        return 0
    hrefs = batch(objs)
    print(f"{len(hrefs)} download urls returned")
    ok = bad = 0
    with ThreadPoolExecutor(max_workers=4) as pool:
        for path, good in pool.map(lambda o: fetch(o, hrefs), objs):
            if good:
                ok += 1
            else:
                bad += 1
                print(f"  FAILED {path}")
    print(f"resolved {ok}, failed {bad}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
