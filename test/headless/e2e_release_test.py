#!/usr/bin/env python3
"""End-to-end tests of `osa run` against a BUILT release and a stub provider.

    MIX_ENV=prod mix release osagent --overwrite
    python3 test/headless/e2e_release_test.py            # all tests
    python3 test/headless/e2e_release_test.py -k resume  # by name

Every test runs the real release binary (`_build/prod/rel/osagent/bin/osagent
run`, or $OSA_RELEASE_DIR) in a fresh HOME/OSA_HOME, with no TTY on stdin,
against `stub_provider.py`. Nothing reaches the network.
"""
import json
import os
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RELEASE = Path(os.environ.get("OSA_RELEASE_DIR", ROOT / "_build/prod/rel/osagent"))
STUB = Path(__file__).with_name("stub_provider.py")
RUN_TIMEOUT = int(os.environ.get("OSA_E2E_TIMEOUT", "240"))


class Stub:
    def __init__(self, workdir):
        self.log = workdir / "stub.log"
        port_file = workdir / "stub.port"
        self.proc = subprocess.Popen(
            [sys.executable, str(STUB), str(port_file)],
            env={**os.environ, "STUB_LOG": str(self.log)},
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        for _ in range(100):
            if port_file.exists() and port_file.read_text():
                break
            time.sleep(0.05)
        self.port = int(port_file.read_text())
        self.url = f"http://127.0.0.1:{self.port}"

    def requests(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines() if line.strip()]

    def agent_requests(self):
        return [r for r in self.requests() if r["has_tools"]]

    def stop(self):
        self.proc.terminate()
        self.proc.wait(timeout=10)


class Run:
    def __init__(self, proc, stdout, stderr):
        self.code = proc.returncode
        self.stdout = stdout
        self.stderr = stderr
        self.events = []
        for line in stdout.splitlines():
            line = line.strip()
            if line.startswith("{"):
                self.events.append(json.loads(line))

    def of(self, kind):
        return [e for e in self.events if e.get("type") == kind]

    @property
    def results(self):
        return self.of("result")

    @property
    def result(self):
        results = self.results
        assert results, f"no result event (exit {self.code})\nstdout:\n{self.stdout}\nstderr:\n{self.stderr[-3000:]}"
        return results[-1]

    @property
    def init(self):
        inits = [e for e in self.events if e.get("type") == "system" and e.get("subtype") == "init"]
        assert inits, f"no init event\nstdout:\n{self.stdout}\nstderr:\n{self.stderr[-3000:]}"
        return inits[0]


class HeadlessCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="osa-e2e-"))
        self.home = self.tmp / "home"
        self.ws = self.tmp / "ws"
        self.home.mkdir()
        self.ws.mkdir()
        self.stub = Stub(self.tmp)

    def tearDown(self):
        self.stub.stop()
        shutil.rmtree(self.tmp, ignore_errors=True)

    @property
    def osa_home(self):
        return self.home / ".osa"

    def base_env(self, **extra):
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": str(self.home),
            "LANG": "C.UTF-8",
            # No platform env file from the machine running the suite.
            "OSA_PLATFORM_ENV_FILE": "",
            # Each run binds no port, but give the setting a value anyway.
            "OSA_HTTP_PORT": str(free_port()),
        }
        env.update(extra)
        return {k: v for k, v in env.items() if v is not None}

    def openai_env(self, **extra):
        return self.base_env(
            OSA_DEFAULT_PROVIDER="openai",
            OPENAI_BASE_URL=f"{self.stub.url}/v1",
            OPENAI_API_KEY="stub-key",
            **extra,
        )

    def osa(self, *args, stdin="", env=None, cwd=None, binary=None):
        cmd = [str(binary or RELEASE / "bin/osagent"), "run", *args]
        proc = subprocess.Popen(
            cmd, cwd=str(cwd or self.ws), env=env or self.openai_env(),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True,
        )
        out, err = proc.communicate(stdin.encode(), timeout=RUN_TIMEOUT)
        return Run(proc, out.decode(), err.decode())

    def stream(self, prompt, *args, **kw):
        return self.osa("--format", "stream-json", "--model", "stub-model", *args, stdin=prompt, **kw)

    def hook(self, body):
        path = self.tmp / "hook.sh"
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(path.stat().st_mode | stat.S_IEXEC)
        return f"/bin/sh {path}"


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


# ── Event stream shape ──────────────────────────────────────────────────


class EventStreamTest(HeadlessCase):
    def test_stream_json_shape(self):
        run = self.stream("REMEMBER secretcolor=teal")
        self.assertEqual(run.code, 0, run.stderr[-2000:])
        events = run.events
        self.assertEqual(events[0]["type"], "system")
        self.assertEqual(events[0]["subtype"], "init")
        self.assertEqual(events[-1]["type"], "result", "result must be the last event")
        sid = run.init["session_id"]
        self.assertTrue(all(e.get("session_id") == sid for e in events), "every event carries the session id")

        init = run.init
        self.assertEqual(init["model"], "stub-model")
        self.assertEqual(init["provider"], "openai")
        self.assertEqual(init["cwd"], str(self.ws.resolve()))
        self.assertFalse(init["resumed"])
        self.assertIn("shell_execute", init["tools"])

        self.assertTrue(run.of("token"), "streamed tokens")
        assistant = run.of("assistant")
        self.assertEqual(assistant[-1]["message"]["content"][0]["text"], "Noted secretcolor.")
        usage = run.of("usage")
        self.assertTrue(usage and usage[0]["usage"]["input_tokens"] > 0)

        result = run.result
        self.assertEqual(result["subtype"], "success")
        self.assertIs(result["is_error"], False)
        self.assertEqual(result["result"], "Noted secretcolor.")
        self.assertEqual(result["content"], result["result"])
        self.assertGreater(result["usage"]["input_tokens"], 0)
        self.assertIn("total_cost_usd", result)
        ctx = result["context"]
        self.assertGreater(ctx["used_tokens"], 0)
        self.assertGreater(ctx["window_tokens"], ctx["used_tokens"])
        self.assertGreater(ctx["compact_at_tokens"], 0)

        # The session is on disk where `--resume` (and MIOSA's guard) look.
        self.assertTrue((self.osa_home / "sessions" / f"{sid}.json").exists())

    def test_text_format_prints_only_the_answer(self):
        run = self.osa("--model", "stub-model", stdin="REMEMBER secretcolor=teal")
        self.assertEqual(run.code, 0, run.stderr[-2000:])
        self.assertEqual(run.stdout, "Noted secretcolor.\n")

    def test_prompt_as_argument(self):
        run = self.osa("--model", "stub-model", "REMEMBER", "secretcolor=teal")
        self.assertEqual(run.stdout, "Noted secretcolor.\n")

    def test_json_format_is_one_result_object(self):
        run = self.osa("--format", "json", "--model", "stub-model", stdin="REMEMBER secretcolor=teal")
        self.assertEqual(run.code, 0, run.stderr[-2000:])
        lines = [line for line in run.stdout.splitlines() if line.strip()]
        self.assertEqual(len(lines), 1)
        self.assertEqual(json.loads(lines[0])["result"], "Noted secretcolor.")

    def test_append_system_prompt_and_output_last_message(self):
        last = self.tmp / "last.txt"
        run = self.stream("REMEMBER secretcolor=teal", "--append-system-prompt", "MARKER-7731 be brief",
                          "--output-last-message", str(last))
        self.assertEqual(run.code, 0, run.stderr[-2000:])
        self.assertIn("MARKER-7731 be brief", self.stub.agent_requests()[-1]["system"])
        self.assertEqual(last.read_text(), "Noted secretcolor.")

    def test_provider_error_is_an_error_result_and_exit_1(self):
        run = self.stream("FAIL")
        self.assertEqual(run.code, 1)
        self.assertIs(run.result["is_error"], True)
        self.assertEqual(run.result["subtype"], "error_during_execution")
        self.assertTrue(run.result["error"])

    def test_usage_errors_exit_2(self):
        self.assertEqual(self.osa("--format", "yaml", stdin="hi").code, 2)
        self.assertEqual(self.osa("--model", "stub-model", stdin="").code, 2)
        self.assertEqual(self.osa("--resume", "../etc/passwd", stdin="hi").code, 2)
        self.assertEqual(self.osa("--no-such-flag", stdin="hi").code, 2)

    def test_binds_no_port(self):
        # A daemon (the TUI's backend, or `osagent serve`) already owns the port.
        with socket.socket() as busy:
            busy.bind(("127.0.0.1", 0))
            busy.listen(1)
            port = busy.getsockname()[1]
            run = self.osa("--model", "stub-model", stdin="REMEMBER secretcolor=teal",
                           env=self.openai_env(OSA_HTTP_PORT=str(port)))
        self.assertEqual(run.code, 0, run.stderr[-2000:])
        self.assertEqual(run.stdout, "Noted secretcolor.\n")


# ── Tools, overdrive and the approval hook ──────────────────────────────


class PermissionTest(HeadlessCase):
    def marker(self):
        return self.ws / "made-by-tool"

    def run_touch(self, *args, env=None):
        return self.stream(f"RUN touch {self.marker()}", *args, env=env)

    def tool_events(self, run):
        uses, results = run.of("tool_use"), run.of("tool_result")
        self.assertEqual(len(uses), 1, run.stdout)
        self.assertEqual(len(results), 1, run.stdout)
        return uses[0], results[0]

    def test_overdrive_runs_tools_without_asking(self):
        run = self.run_touch("--overdrive")
        self.assertEqual(run.code, 0, run.stderr[-2000:])
        use, result = self.tool_events(run)
        self.assertEqual(use["name"], "shell_execute")
        self.assertEqual(use["input"], {"command": f"touch {self.marker()}"})
        self.assertTrue(use["id"])
        self.assertEqual(result["tool_use_id"], use["id"])
        self.assertIs(result["is_error"], False)
        self.assertTrue(self.marker().exists())
        self.assertEqual(run.init["permission_mode"], "bypassPermissions")

    def test_without_overdrive_a_tool_needing_approval_is_denied(self):
        run = self.run_touch()
        self.assertEqual(run.code, 0, run.stderr[-2000:])
        _use, result = self.tool_events(run)
        self.assertIs(result["is_error"], True)
        self.assertIn("requires interactive approval", result["content"])
        self.assertFalse(self.marker().exists())

    def test_hook_allow_decides_for_a_non_overdrive_run(self):
        log = self.tmp / "hook-input.json"
        env = self.openai_env(OSA_PRE_TOOL_HOOK=self.hook(f"cat > {log}\nexit 0\n"))
        run = self.run_touch(env=env)
        self.assertEqual(run.code, 0, run.stderr[-2000:])
        _use, result = self.tool_events(run)
        self.assertIs(result["is_error"], False, result)
        self.assertTrue(self.marker().exists())

        hook_input = json.loads(log.read_text())
        self.assertEqual(hook_input["hook_event_name"], "PreToolUse")
        self.assertEqual(hook_input["tool_name"], "shell_execute")
        self.assertEqual(hook_input["tool_input"], {"command": f"touch {self.marker()}"})
        self.assertEqual(hook_input["tool_use_id"], _use["id"])
        self.assertEqual(hook_input["session_id"], run.init["session_id"])
        self.assertEqual(hook_input["permission_mode"], "default")
        self.assertEqual(hook_input["cwd"], str(self.ws.resolve()))

    def test_hook_exit_2_denies_with_the_stdout_reason(self):
        env = self.openai_env(OSA_PRE_TOOL_HOOK=self.hook("cat >/dev/null\necho 'policy says no'\nexit 2\n"))
        run = self.run_touch("--overdrive", env=env)
        _use, result = self.tool_events(run)
        self.assertIs(result["is_error"], True)
        self.assertIn("policy says no", result["content"])
        self.assertFalse(self.marker().exists())

    def test_hook_claude_json_deny_is_honored_in_overdrive(self):
        # The exact shape MIOSA's approval-gate script prints.
        body = (
            "cat >/dev/null\n"
            "printf '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\","
            "\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"%s\"}}\\n' "
            "'MIOSA blocked it'\nexit 0\n"
        )
        env = self.openai_env(OSA_PRE_TOOL_HOOK=self.hook(body))
        run = self.run_touch("--overdrive", env=env)
        _use, result = self.tool_events(run)
        self.assertIs(result["is_error"], True)
        self.assertIn("MIOSA blocked it", result["content"])
        self.assertFalse(self.marker().exists())

    def test_hook_sees_bypass_mode_in_overdrive(self):
        log = self.tmp / "hook-input.json"
        env = self.openai_env(OSA_PRE_TOOL_HOOK=self.hook(f"cat > {log}\nexit 0\n"))
        run = self.run_touch("--overdrive", env=env)
        self.assertEqual(run.code, 0)
        self.assertEqual(json.loads(log.read_text())["permission_mode"], "bypassPermissions")

    def test_failing_hook_fails_closed(self):
        env = self.openai_env(OSA_PRE_TOOL_HOOK=self.hook("cat >/dev/null\nexit 7\n"))
        run = self.run_touch("--overdrive", env=env)
        _use, result = self.tool_events(run)
        self.assertIs(result["is_error"], True)
        self.assertFalse(self.marker().exists())


# ── Sessions: resume, continue, session-id, multi-turn ──────────────────


class SessionTest(HeadlessCase):
    def test_resume_missing_session_exits_79(self):
        run = self.stream("hi", "--resume", "headless-does-not-exist")
        self.assertEqual(run.code, 79)
        self.assertIn("HARNESS_SESSION_MISSING", run.stderr)
        self.assertEqual(run.events, [])

    def test_continue_without_a_session_exits_79(self):
        self.assertEqual(self.stream("hi", "--continue").code, 79)

    def test_three_turns_with_resume_recall_turn_one(self):
        first = self.stream("REMEMBER secretcolor=teal")
        sid = first.result["session_id"]
        second = self.stream("FILLER 40", "--resume", sid)
        third = self.stream("RECALL secretcolor", "--resume", sid)
        for run in (first, second, third):
            self.assertEqual(run.code, 0, run.stderr[-2000:])
            self.assertEqual(run.result["session_id"], sid)
        self.assertTrue(second.init["resumed"])
        self.assertGreater(third.init["history_messages"], second.init["history_messages"])
        self.assertEqual(third.result["result"], "secretcolor is teal")

    def test_three_turns_in_one_streaming_input_process(self):
        lines = "\n".join(json.dumps({"type": "user", "message": {"role": "user", "content": text}})
                          for text in ("REMEMBER secretcolor=teal", "FILLER 40", "RECALL secretcolor")) + "\n"
        run = self.osa("--input-format", "stream-json", "--format", "stream-json", "--model", "stub-model",
                       stdin=lines)
        self.assertEqual(run.code, 0, run.stderr[-2000:])
        self.assertEqual(len(run.of("system")), 1, "one init for the process")
        results = run.results
        self.assertEqual(len(results), 3)
        self.assertEqual(len({r["session_id"] for r in results}), 1)
        self.assertEqual(results[0]["result"], "Noted secretcolor.")
        self.assertEqual(results[2]["result"], "secretcolor is teal")

    def test_session_id_is_assigned_up_front_and_cannot_be_reused(self):
        run = self.stream("REMEMBER secretcolor=teal", "--session-id", "chat-0001")
        self.assertEqual(run.code, 0, run.stderr[-2000:])
        self.assertEqual(run.init["session_id"], "chat-0001")
        self.assertTrue((self.osa_home / "sessions" / "chat-0001.json").exists())
        self.assertEqual(self.stream("hi", "--session-id", "chat-0001").code, 2)
        again = self.stream("RECALL secretcolor", "--resume", "chat-0001")
        self.assertEqual(again.result["result"], "secretcolor is teal")

    def test_continue_picks_the_newest_session_in_the_directory(self):
        first = self.stream("REMEMBER secretcolor=teal")
        run = self.stream("RECALL secretcolor", "--continue")
        self.assertEqual(run.result["session_id"], first.result["session_id"])
        self.assertEqual(run.result["result"], "secretcolor is teal")

    def test_resume_does_not_inherit_overdrive(self):
        first = self.stream("REMEMBER secretcolor=teal", "--overdrive")
        sid = first.result["session_id"]
        marker = self.ws / "after-resume"
        run = self.stream(f"RUN touch {marker}", "--resume", sid)
        self.assertEqual(run.init["permission_mode"], "default")
        self.assertIs(run.of("tool_result")[0]["is_error"], True)
        self.assertFalse(marker.exists())


# ── Compaction: a long conversation keeps going ─────────────────────────


class CompactionTest(HeadlessCase):
    def test_compaction_past_a_small_window_keeps_the_fact(self):
        env = self.openai_env(OSA_CONTEXT_CEILING="40000")
        first = self.stream("REMEMBER secretcolor=teal", env=env)
        sid = first.result["session_id"]
        compaction = []
        for _ in range(12):
            run = self.stream("FILLER 1500", "--resume", sid, env=env)
            self.assertEqual(run.code, 0, run.stderr[-2000:])
            compaction += run.of("compaction_start") + run.of("compaction_end")
            if any(e["type"] == "compaction_end" for e in compaction):
                break
        self.assertTrue(compaction, "the conversation never compacted")
        start = next(e for e in compaction if e["type"] == "compaction_start")
        end = next(e for e in compaction if e["type"] == "compaction_end")
        self.assertGreater(start["tokens_before"], 0)
        self.assertIs(end["success"], True, end)
        self.assertLess(end["tokens_after"], end["tokens_before"])

        recall = self.stream("RECALL secretcolor", "--resume", sid, env=env)
        self.assertEqual(recall.code, 0, recall.stderr[-2000:])
        self.assertEqual(recall.result["result"], "secretcolor is teal")
        self.assertLess(recall.result["context"]["used_tokens"], 40000)

        # The answer came from the compaction summary: the original REMEMBER
        # message is gone from what the model sees, the fact is not.
        request = [r for r in self.stub.agent_requests() if r["last_user"] == "RECALL secretcolor"][-1]
        self.assertEqual(request["remember_messages"], 0)
        self.assertIn("secretcolor=teal", request["facts"])


# ── Model and provider selection from the environment ───────────────────


class ModelSelectionTest(HeadlessCase):
    def test_model_flag_reaches_the_provider(self):
        self.stream("REMEMBER secretcolor=teal", env=self.openai_env())
        run2 = self.osa("--format", "stream-json", "--model", "stub-alt", stdin="REMEMBER x=y")
        self.assertEqual(run2.code, 0, run2.stderr[-2000:])
        self.assertEqual(run2.init["model"], "stub-alt")
        models = [r["model"] for r in self.stub.agent_requests()]
        self.assertIn("stub-model", models)
        self.assertIn("stub-alt", models)

    def test_resume_keeps_the_session_model(self):
        first = self.stream("REMEMBER secretcolor=teal")
        sid = first.result["session_id"]
        run = self.osa("--format", "stream-json", "--resume", sid, stdin="RECALL secretcolor")
        self.assertEqual(run.code, 0, run.stderr[-2000:])
        self.assertEqual(run.init["model"], "stub-model")
        self.assertEqual(self.stub.agent_requests()[-1]["model"], "stub-model")
        self.assertEqual(run.result["result"], "secretcolor is teal")

    def test_osa_model_env_without_flag(self):
        run = self.osa("--format", "stream-json", stdin="REMEMBER x=y",
                       env=self.openai_env(OSA_MODEL="stub-from-env"))
        self.assertEqual(run.code, 0, run.stderr[-2000:])
        self.assertEqual(run.init["model"], "stub-from-env")
        self.assertEqual(self.stub.agent_requests()[-1]["model"], "stub-from-env")

    def test_miosa_gateway_env_alone(self):
        env = self.base_env(MIOSA_AI_GATEWAY_URL=f"{self.stub.url}/v1", MIOSA_AI_GATEWAY_KEY="mgk_run_key",
                            MIOSA_API_KEY="sandbox-identity-token")
        run = self.osa("--format", "stream-json", "--model", "gateway-model", stdin="REMEMBER x=y", env=env)
        self.assertEqual(run.code, 0, run.stderr[-2000:])
        self.assertEqual(run.init["provider"], "openai")
        request = self.stub.agent_requests()[-1]
        self.assertEqual(request["model"], "gateway-model")
        self.assertEqual(request["authorization"], "Bearer mgk_run_key")

    def test_native_ollama_cloud_with_api_key(self):
        env = self.base_env(OLLAMA_API_KEY="ollama-key", OLLAMA_URL=self.stub.url)
        run = self.osa("--format", "stream-json", "--model", "stub-model:cloud", stdin="REMEMBER x=y", env=env)
        self.assertEqual(run.code, 0, run.stderr[-2000:])
        self.assertEqual(run.init["provider"], "ollama")
        self.assertEqual(run.result["result"], "Noted x.")
        request = [r for r in self.stub.requests() if r["path"].startswith("/api/chat")][-1]
        self.assertEqual(request["model"], "stub-model:cloud")
        self.assertEqual(request["authorization"], "Bearer ollama-key")


# ── The installed launcher (`osa run`) ──────────────────────────────────


class LauncherTest(HeadlessCase):
    """The launcher install.sh writes, against a copy of the release, invoked
    the way MIOSA does: through a symlink, by a user whose HOME has no OSA."""

    def setUp(self):
        super().setUp()
        install = self.tmp / "desktop-user" / ".osa"
        (install / "bin").mkdir(parents=True)
        shutil.copytree(RELEASE, install / "release", symlinks=True)
        shutil.rmtree(install / "release" / "tmp", ignore_errors=True)
        source = (ROOT / "scripts/install.sh").read_text()
        launcher = source.split("<<'LAUNCHER_EOF'\n", 1)[1].split("\nLAUNCHER_EOF\n", 1)[0]
        (install / "bin" / "osa").write_text(launcher)
        (install / "bin" / "osa").chmod(0o755)
        self.links = self.tmp / "usr-local-bin"
        self.links.mkdir()
        (self.links / "osa").symlink_to(install / "bin" / "osa")
        # Read-only release, like another user's install.
        for path in [install / "release", *(install / "release").rglob("*")]:
            if path.is_dir() and not path.is_symlink():
                path.chmod(0o555)
        self.install = install

    def tearDown(self):
        for path in [self.install / "release", *(self.install / "release").rglob("*")]:
            if path.is_dir() and not path.is_symlink():
                path.chmod(0o755)
        super().tearDown()

    def test_osa_run_through_a_symlinked_launcher(self):
        proc = subprocess.run(
            [str(self.links / "osa"), "run", "--format", "stream-json", "--model", "stub-model"],
            input=b"REMEMBER secretcolor=teal", cwd=str(self.ws), env=self.openai_env(),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=RUN_TIMEOUT,
        )
        run = Run(proc, proc.stdout.decode(), proc.stderr.decode())
        self.assertEqual(run.code, 0, run.stderr[-3000:])
        self.assertEqual(run.result["result"], "Noted secretcolor.")
        # Sessions live in the RUNNING user's OSA_HOME, where MIOSA's guard looks.
        sid = run.result["session_id"]
        self.assertTrue((self.osa_home / "sessions" / f"{sid}.json").exists())
        # stdout carries nothing but events.
        for line in run.stdout.splitlines():
            if line.strip():
                json.loads(line)

    def test_run_flags_are_not_rewritten_for_the_tui(self):
        first = subprocess.run(
            [str(self.links / "osa"), "run", "--format", "json", "--model", "stub-model"],
            input=b"REMEMBER secretcolor=teal", cwd=str(self.ws), env=self.openai_env(),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=RUN_TIMEOUT,
        )
        sid = json.loads(first.stdout.decode().strip())["session_id"]
        second = subprocess.run(
            [str(self.links / "osa"), "--overdrive", "run", "--resume", sid, "--format", "json",
             "--model", "stub-model"],
            input=b"RECALL secretcolor", cwd=str(self.ws), env=self.openai_env(),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=RUN_TIMEOUT,
        )
        self.assertEqual(second.returncode, 0, second.stderr.decode()[-3000:])
        self.assertEqual(json.loads(second.stdout.decode().strip())["result"], "secretcolor is teal")


if __name__ == "__main__":
    unittest.main(verbosity=2)
