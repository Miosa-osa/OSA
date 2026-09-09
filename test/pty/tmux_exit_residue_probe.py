#!/usr/bin/env python3
"""Does osagent leave chrome behind on exit that a LATER shell command's own
scrolling then deposits into real tmux scrollback -- across a graceful exit,
an interceptable signal (SIGTERM), and a SIGKILL, repeated over several
cycles in the SAME live pane?

This is the shape team-lead's revised hypothesis asked for, driven directly
rather than inferred from a long-lived pane's history: boot osagent, end it
(gracefully, via SIGTERM, or via SIGKILL), run several ordinary shell
commands with enough output to force the pane to scroll, then read the FULL
scrollback (`capture-pane -S -N`, not `-p` alone) and count chrome markers.
Repeated for 3 cycles per exit style, exactly as instructed ("repeat that
cycle 2-3 times").

A graceful exit runs event_loop.rs's own teardown erase (see
`erase_rows_in_place` at the `/quit` cleanup site) before the shell regains
the pty. SIGTERM (and SIGHUP/SIGQUIT, not separately probed here) now runs
that SAME teardown erase path via the `Event::TerminateSignal` handler --
`dispatch_event` intercepts the signal, quits through the ordinary cleanup,
and only re-raises the signal with its default disposition after the
terminal is already restored -- so it MUST be exactly as fossil-free as a
graceful exit. This probe is what proves that.

SIGKILL runs NONE of that -- no destructor, no panic hook, nothing, and
none can ever be installed for it -- so whatever was on screen at the
instant the kernel reaped the process is exactly what the shell's next
prompt gets printed on top of, and whatever scrolls afterward carries it
into history verbatim. This is an accepted, DOCUMENTED limitation, not a
bug: it is asserted here as a KNOWN LIMITATION (expected to reproduce, not a
failure) specifically so nobody "fixes" it by accident later and quietly
drops the coverage. If the graceful and SIGTERM paths stay clean while
SIGKILL accumulates fossils, that isolates the residue to genuinely
unfixable abnormal termination -- a structurally different class of defect
from the tmux ED0-row-0 quirk already fixed in `erase_rows_in_place`'s four
call sites.

Run: `python3 test/pty/tmux_exit_residue_probe.py`
"""

from __future__ import annotations

import shlex
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from osa_pty import DEFAULT_BIN, SINGLETON_BANDS, USER_HEADER  # noqa: E402
from stub_backend import StubBackend  # noqa: E402

STUB_PORT = 12851
SOCKET = "osadup190_exitresidue"
SESSION = "dup190exit"
W, H = 100, 30
CYCLES = 3


def sh(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["tmux", "-L", SOCKET, *args], capture_output=True, text=True, check=check
    )


def capture(lines: int = 2000) -> str:
    r = sh("capture-pane", "-p", "-t", SESSION, "-S", f"-{lines}", check=False)
    return r.stdout


def counts(text: str) -> dict[str, int]:
    rendered = [line.rstrip() for line in text.splitlines()]
    out: dict[str, int] = {}
    for name, pat in SINGLETON_BANDS.items():
        if name == "composer_top":
            continue
        out[name] = sum(1 for line in rendered if pat.search(line))
    out["composer"] -= sum(1 for line in rendered if USER_HEADER.search(line))
    return out


def send(keys: str) -> None:
    sh("send-keys", "-t", SESSION, "-l", keys)


def enter() -> None:
    sh("send-keys", "-t", SESSION, "Enter")


def pane_pid() -> int:
    r = sh("list-panes", "-t", SESSION, "-F", "#{pane_pid}")
    return int(r.stdout.strip().splitlines()[0])


def child_pid_of(ppid: int) -> int | None:
    r = subprocess.run(["pgrep", "-P", str(ppid)], capture_output=True, text=True)
    lines = [ln for ln in r.stdout.strip().splitlines() if ln]
    return int(lines[0]) if lines else None


def force_scroll(n_commands: int = 6) -> None:
    """Several ordinary shell commands with enough output to scroll the pane
    well past its own height -- the exact intermediate step team-lead's shape
    calls for, absent from both existing relaunch probes."""
    for i in range(n_commands):
        send(f"seq 1 40 | sed 's/^/scroll-filler-{i}-/'")
        enter()
        time.sleep(0.3)


def boot_osagent(base_url: str) -> None:
    # Deliberately NOT `exec`: a real user runs `osagent` as a plain command
    # from an interactive shell, which stays alive underneath it. SIGKILLing
    # the child then leaves the pane (and its shell) alive to print a prompt
    # afterward -- exactly the scenario under test. `exec`, by contrast, would
    # make osagent the pane's own process, and killing it kills the pane.
    binary = str(DEFAULT_BIN)
    cmd = f"OSA_URL={shlex.quote(base_url)} {shlex.quote(binary)}"
    send(cmd)
    enter()
    deadline = time.time() + 20
    while time.time() < deadline:
        if counts(capture()).get("composer", 0) >= 1:
            time.sleep(1.0)
            return
        time.sleep(0.25)
    raise RuntimeError("osagent never booted in tmux pane")


def exit_gracefully() -> None:
    send("\x03")  # Ctrl+C -> quit-confirm dialog
    time.sleep(0.3)
    enter()  # confirm
    time.sleep(1.5)


def exit_via_sigterm() -> None:
    ppid = pane_pid()
    pid = child_pid_of(ppid)
    if pid is None:
        raise RuntimeError("could not find osagent child pid to SIGTERM")
    subprocess.run(["kill", "-15", str(pid)], check=False)
    # Unlike SIGKILL this is NOT instant: the signal handler has to run the
    # real teardown erase (event_loop.rs's `pending_signal` path) and
    # restore the terminal before the process actually exits. Give it real
    # wall-clock time rather than assuming SIGKILL's near-instant death.
    time.sleep(1.0)
    enter()  # wake the shell up so its next prompt actually prints


def exit_via_sigkill() -> None:
    ppid = pane_pid()
    pid = child_pid_of(ppid)
    if pid is None:
        raise RuntimeError("could not find osagent child pid to SIGKILL")
    subprocess.run(["kill", "-9", str(pid)], check=False)
    time.sleep(0.5)
    enter()  # wake the shell up so its next prompt actually prints


def run_cycles(
    base_url: str,
    style: str,
    exit_fn,
    failures: list[str],
    known_limitation: bool = False,
) -> None:
    """Run `CYCLES` boot/exit/scroll rounds and count fossils each time.

    `known_limitation=True` (SIGKILL only) flips fossil counts from a test
    FAILURE into a documented, EXPECTED observation: SIGKILL bypasses every
    line of Rust cleanup, so accumulation here is not a regression, it is
    the reason the SIGTERM/SIGHUP/SIGQUIT handler exists at all. Keeping the
    assertion (rather than deleting the SIGKILL case outright) means a
    future change that silently makes this WORSE, or a harness change that
    accidentally stops exercising SIGKILL at all, is still visible in the
    output instead of quietly disappearing.
    """
    saw_fossil = False
    for cycle in range(1, CYCLES + 1):
        boot_osagent(base_url)
        exit_fn()
        force_scroll()
        dump = capture()
        c = counts(dump)
        print(f"[{style}] cycle {cycle}: {c}")
        bad = {k: v for k, v in c.items() if v > 1}
        if bad:
            saw_fossil = True
            if known_limitation:
                print(
                    f"    (expected for {style}: fossil counts {bad} -- "
                    "SIGKILL runs no destructor/panic hook, see module "
                    "docstring; this is NOT a failure)"
                )
            else:
                failures.append(f"{style} cycle {cycle}: fossil counts {bad}")
                print(f"--- full scrollback after {style} cycle {cycle} ---")
                print(dump)
    if known_limitation and not saw_fossil:
        # Not a failure either way -- SIGKILL timing is inherently racy --
        # but worth a note if the documented limitation stops reproducing,
        # since that would mean the "unfixable" framing needs revisiting.
        print(
            f"    NOTE: {style} did not reproduce the known-limitation "
            "fossil this run (timing-dependent; not treated as a failure)"
        )


def main() -> int:
    failures: list[str] = []
    sh("kill-server", check=False)

    with StubBackend(STUB_PORT) as backend:
        r = sh(
            "new-session", "-d", "-s", SESSION, "-x", str(W), "-y", str(H),
            "/bin/sh",
        )
        print("new-session:", r.returncode, r.stderr.strip())
        try:
            print("\n== graceful /quit exit, repeated, then forced scrolling ==")
            run_cycles(backend.base_url, "graceful", exit_gracefully, failures)

            print("\n== SIGTERM exit, repeated, then forced scrolling ==")
            print("   (must be as fossil-free as graceful -- proves the new")
            print("   signal handler runs the same teardown erase)")
            run_cycles(backend.base_url, "sigterm", exit_via_sigterm, failures)

            print("\n== SIGKILL exit, repeated, then forced scrolling ==")
            print("   (KNOWN LIMITATION: unfixable, no user code ever runs)")
            run_cycles(
                backend.base_url,
                "sigkill",
                exit_via_sigkill,
                failures,
                known_limitation=True,
            )
        finally:
            sh("kill-server", check=False)

    print("\n=== summary ===")
    if failures:
        for f in failures:
            print("FAIL:", f)
        return 1
    print(
        "no fossils observed on graceful or SIGTERM exit "
        "(SIGKILL known-limitation counts, if any, are logged above, not failed)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
