"""Exercise the actual native executable, without screen-recording permission.

Run: python3 tests/lifecycle.py /absolute/path/to/osa-screen-capture-darwin
Every child has a deadline and is forcibly reaped even when an assertion fails.
"""
import os
import selectors
import signal
import socket
import subprocess
import sys
import time
import unittest

BINARY = os.path.abspath(sys.argv.pop(1))


class Lifecycle(unittest.TestCase):
    def start(self, *args):
        # A nonzero ephemeral port also works with the pre-fix binary.
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        child = subprocess.Popen(
            [BINARY, "--stub", "--port", str(port), *args],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.addCleanup(self.reap, child)
        return child, port

    def reap(self, child):
        if child.poll() is None:
            child.kill()
        child.wait(timeout=3)
        for stream in (child.stdin, child.stdout, child.stderr):
            stream.close()

    def ready(self, child):
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ)
            self.assertTrue(selector.select(timeout=3), "helper did not announce readiness")
            line = child.stdout.readline()
        self.assertTrue(line.startswith(b"PORT="), line)
        return int(line.split(b"=")[1])

    def test_sigterm_exits(self):
        child, _ = self.start()
        self.ready(child)
        child.send_signal(signal.SIGTERM)
        self.assertEqual(child.wait(timeout=2), 0)

    def test_owner_eof_exits(self):
        child, _ = self.start()
        self.ready(child)
        child.stdin.close()
        self.assertEqual(child.wait(timeout=2), 0)

    def test_sigint_exits(self):
        child, _ = self.start()
        self.ready(child)
        child.send_signal(signal.SIGINT)
        self.assertEqual(child.wait(timeout=2), 0)

    def test_owner_death_exits_even_when_stdin_stays_open(self):
        script = (
            "import subprocess,sys,time; "
            "p=subprocess.Popen([sys.argv[1],'--stub','--port','0']); "
            "print('PID='+str(p.pid),flush=True); time.sleep(30)"
        )
        owner = subprocess.Popen([sys.executable, "-c", script, BINARY],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE)
        self.addCleanup(self.reap, owner)
        with selectors.DefaultSelector() as selector:
            selector.register(owner.stdout, selectors.EVENT_READ)
            self.assertTrue(selector.select(timeout=3))
            pid = int(owner.stdout.readline().split(b"=")[1])
        self.assertTrue(owner.stdout.readline().startswith(b"PORT="))
        alive = True
        try:
            # Keep this test's stdin writer open, so EOF cannot explain the exit.
            owner.kill()
            owner.wait(timeout=2)
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                result = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)],
                                        capture_output=True, text=True)
                if result.returncode != 0 or result.stdout.strip().startswith("Z"):
                    alive = False
                    return
                time.sleep(0.05)
            self.fail("helper survived the death of its owner")
        finally:
            if alive:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_memory_budget_exits(self):
        child, _ = self.start("--max-memory-mb", "1")
        self.assertEqual(child.wait(timeout=4), 70)
        self.assertIn(b"memory_limit", child.stderr.read())

    def test_idle_exits(self):
        child, _ = self.start("--idle-seconds", "1")
        self.ready(child)
        self.assertEqual(child.wait(timeout=4), 0)
        self.assertIn(b"idle_timeout", child.stderr.read())

    def test_helper_count_is_bounded(self):
        first, _ = self.start()
        self.ready(first)
        second, _ = self.start()
        self.ready(second)
        third, _ = self.start()
        self.assertEqual(third.wait(timeout=3), 75)
        self.assertIn(b"helper_limit", third.stderr.read())
        first.terminate()
        first.wait(timeout=2)
        replacement, _ = self.start()
        self.ready(replacement)

    def test_ephemeral_port_is_ready_and_loopback_only(self):
        child, _ = self.start("--port", "0")
        port = self.ready(child)
        self.assertGreater(port, 0)
        with socket.create_connection(("127.0.0.1", port), timeout=2) as sock:
            self.assertEqual(sock.recv(12), b"RFB 003.008\n")

    def test_bind_failure_never_announces_ready(self):
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            sock.listen()
            child, _ = self.start("--port", str(sock.getsockname()[1]))
            self.assertNotEqual(child.wait(timeout=3), 0)
            self.assertNotIn(b"PORT=", child.stdout.read())


if __name__ == "__main__":
    unittest.main()
