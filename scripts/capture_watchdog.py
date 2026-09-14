#!/usr/bin/python3
"""macOS backstop for legacy OSA capture binaries restored by updates/worktrees.

Run from a per-user LaunchAgent. Only exact native helper processes owned by the
current user are eligible. Revalidate executable and process birth before every
signal, so a recycled PID cannot cause an unrelated process to be terminated.
"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import time

HELPER = "osa-screen-capture-darwin"
LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib")


def identity(pid):
    path = ctypes.create_string_buffer(4096)
    if LIBPROC.proc_pidpath(pid, path, len(path)) <= 0:
        return None
    executable = os.fsdecode(path.value)
    if Path(executable).name != HELPER:
        return None
    usage = ctypes.create_string_buffer(4096)
    if LIBPROC.proc_pid_rusage(pid, 4, usage) != 0:
        return None
    footprint, born = struct.unpack_from("QQ", usage, 72)
    return {"pid": pid, "path": executable, "born": born, "footprint": footprint}


def candidates(only_pid=None):
    output = subprocess.check_output(
        ["/bin/ps", "-axo", "pid=,ppid=,uid=,comm="], text=True
    )
    result = []
    for line in output.splitlines():
        fields = line.split(None, 3)
        if len(fields) != 4:
            continue
        pid, parent, uid = map(int, fields[:3])
        if uid != os.getuid() or (only_pid is not None and pid != only_pid):
            continue
        if Path(fields[3]).name != HELPER:
            continue
        info = identity(pid)
        if info:
            info["parent"] = parent
            result.append(info)
    return result


def same_process(original):
    current = identity(original["pid"])
    return current and (current["path"], current["born"]) == (
        original["path"], original["born"]
    )


def terminate(original):
    if not same_process(original):
        return
    try:
        os.kill(original["pid"], signal.SIGTERM)
        deadline = time.monotonic() + 0.5
        while time.monotonic() < deadline:
            if not same_process(original):
                return
            time.sleep(0.05)
        if same_process(original):
            os.kill(original["pid"], signal.SIGKILL)
    except ProcessLookupError:
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, help="restrict checks to one PID (testing)")
    parser.add_argument("--max-memory-mib", type=int, default=768, choices=range(1, 769))
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    processes = sorted(candidates(args.pid), key=lambda item: item["born"])
    survivors = 0
    for process in processes:
        reason = None
        if process["footprint"] > args.max_memory_mib * 1024**2:
            reason = "memory_limit"
        elif process["parent"] == 1:
            reason = "orphan"
        elif survivors >= 2:
            reason = "helper_limit"
        else:
            survivors += 1
        if reason:
            event = dict(process, reason=reason, timestamp=time.time(), dry_run=args.dry_run)
            print(json.dumps(event), flush=True)
            if not args.dry_run:
                terminate(process)


if __name__ == "__main__":
    main()
