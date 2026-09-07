"""Bounded real TCP/frame conversion test; never captures the user's screen."""
import ctypes
import os
import selectors
import socket
import struct
import subprocess
import sys
import time

libproc = ctypes.CDLL("/usr/lib/libproc.dylib")


def footprint(pid):
    usage = ctypes.create_string_buffer(4096)
    if libproc.proc_pid_rusage(pid, 4, usage) != 0:
        raise RuntimeError("cannot measure helper footprint")
    # sys/resource.h rusage_info_v4: UUID[16], seven uint64s, phys_footprint.
    return struct.unpack_from("Q", usage, 16 + 7 * 8)[0]


def receive(sock, size):
    data = bytearray()
    while len(data) < size:
        part = sock.recv(min(size - len(data), 65536))
        if not part:
            raise AssertionError("truncated RFB frame")
        data.extend(part)
    return data


child = subprocess.Popen([os.path.abspath(sys.argv[1])], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    with selectors.DefaultSelector() as selector:
        selector.register(child.stdout, selectors.EVENT_READ)
        assert selector.select(timeout=3), "no readiness announcement"
        port = int(child.stdout.readline().split(b"=")[1])
    with socket.create_connection(("127.0.0.1", port), timeout=3) as sock:
        assert receive(sock, 12) == b"RFB 003.008\n"
        sock.sendall(b"RFB 003.008\n")
        assert receive(sock, 2) == b"\x01\x01"
        sock.sendall(b"\x01")
        assert receive(sock, 4) == b"\0" * 4
        sock.sendall(b"\x01")
        initial = receive(sock, 24)
        width, height = struct.unpack_from(">HH", initial)
        receive(sock, struct.unpack_from(">I", initial, 20)[0])
        assert initial[4] == 32
        request = struct.pack(">BBHHHH", 3, 0, 0, 0, width, height)
        time.sleep(0.2)
        measurements = []
        started = time.monotonic()
        frames = 0
        while time.monotonic() - started < 15:
            sock.sendall(request)
            header = receive(sock, 16)
            assert struct.unpack_from(">H", header, 2)[0] == 1
            assert struct.unpack_from(">HH", header, 8) == (width, height)
            pixels = receive(sock, width * height * 4)
            assert pixels[:4] == b"Z" * 4, "fixture did not reach live frame conversion"
            del pixels
            measurements.append(footprint(child.pid))
            assert measurements[-1] < 256 * 1024**2, "helper exceeded test memory budget"
            frames += 1
        # Slow reader: request many updates, stop consuming, keep producing frames.
        sock.sendall(request * 500)
        time.sleep(3)
        measurements.append(footprint(child.pid))
        assert max(measurements) < 256 * 1024**2
        assert measurements[-1] - measurements[len(measurements) // 2] < 64 * 1024**2
        print(f"PASS: {frames} live frames; peak {max(measurements)/1024**2:.1f} MiB; slow reader bounded")
    child.stdin.close()
    assert child.wait(timeout=2) == 0
finally:
    if child.poll() is None:
        child.kill()
    child.wait(timeout=3)
