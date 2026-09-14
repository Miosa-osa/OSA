"""Real loopback RFB test with recording sink; never posts OS input or captures."""
import os
import selectors
import socket
import struct
import subprocess
import sys


def receive(sock, count):
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        assert chunk, "truncated response"
        data += chunk
    return data


for allow_input in (False, True):
    child = subprocess.Popen([os.path.abspath(sys.argv[1]), *(["--allow-input"] if allow_input else [])],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ)
            assert selector.select(5), "helper did not bind"
            port = int(child.stdout.readline().split(b"=")[1])
        with socket.create_connection(("127.0.0.1", port), timeout=3) as sock:
            assert receive(sock, 12) == b"RFB 003.008\n"
            sock.sendall(b"RFB 003.008\n")
            assert receive(sock, 2) == b"\x01\x01"
            sock.sendall(b"\x01")
            assert receive(sock, 4) == b"\0" * 4
            sock.sendall(b"\x01")
            header = receive(sock, 24)
            receive(sock, struct.unpack_from(">I", header, 20)[0])
            sock.sendall(struct.pack(">BBHI", 4, 1, 0, ord("a")))
            sock.sendall(struct.pack(">BBHH", 5, 1, 2, 3))
            # Frame response is an ordering barrier after both input messages.
            sock.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, 8, 8))
            receive(sock, 16 + 256)
        # EOF cleanup releases held input; no physical keyboard is involved.
        child.stdin.close()
        assert child.wait(timeout=3) == 0
        events = child.stdout.read().splitlines()
        if allow_input:
            assert events == [b"EVENT=10", b"EVENT=1", b"EVENT=11", b"EVENT=2"], events
        else:
            assert events == [], events
    finally:
        if child.poll() is None:
            child.kill()
        child.wait(timeout=3)
print("PASS: read-only RFB, authorized input decoding, disconnect releases")
