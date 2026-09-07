"""Test the machine backstop against a real signal-resistant native process."""
import json
import os
import selectors
import subprocess
import sys

child = subprocess.Popen([os.path.abspath(sys.argv[1])], stdout=subprocess.PIPE)
try:
    with selectors.DefaultSelector() as selector:
        selector.register(child.stdout, selectors.EVENT_READ)
        assert selector.select(timeout=3)
        assert child.stdout.readline() == b"READY\n"
    command = [sys.executable, os.path.abspath(sys.argv[2]), "--pid", str(child.pid),
               "--max-memory-mib", "1"]
    dry_run = json.loads(subprocess.check_output(command + ["--dry-run"], text=True))
    assert dry_run["reason"] == "memory_limit" and child.poll() is None
    # A specific unrelated process must not become eligible because --pid is set.
    ignored = subprocess.check_output(command[:-3] + [str(os.getpid()), "--dry-run"], text=True)
    assert ignored == ""
    result = json.loads(subprocess.check_output(command, text=True))
    assert result["pid"] == child.pid and not result["dry_run"]
    assert child.wait(timeout=2) == -9
    print("PASS: external watchdog detects footprint, excludes unrelated process, escalates SIGTERM")
finally:
    if child.poll() is None:
        child.kill()
    child.wait(timeout=3)
