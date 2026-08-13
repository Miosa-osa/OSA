#!/usr/bin/env python3
"""Tests for the SWE-bench Pro harness.

Standard library only, no network, no Docker for the default set. Run:

    ./.venv/bin/python test_swebenchpro.py          # fast, offline
    ./.venv/bin/python test_swebenchpro.py --live   # + docker/dataset checks

Every test here exists because something was actually wrong, or because a
correct thing is fragile enough that a silent regression would change a score
rather than break a build. That is the bar: this file is not for coverage, it
is for the specific ways this pipeline can lie.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import dataset as ds  # noqa: E402
import evaluate  # noqa: E402
import runners  # noqa: E402
import shared  # noqa: E402
import workspace as ws  # noqa: E402

LIVE = "--live" in sys.argv


class TestModuleIdentity(unittest.TestCase):
    """`bench/swebenchpro` and `bench/swebench` both define runners/evaluate/workspace.

    The first version of this package did `sys.path.insert(0, '../swebench')`
    and then `import runners`, which resolved to the *other* package's module.
    It surfaced as `AttributeError: module 'runners' has no attribute
    'CONTEXT_MODES'` -- an import bug wearing an attribute bug's clothes. If
    this test fails, someone has reintroduced path-order dependence.
    """

    def test_our_runners_is_ours(self):
        self.assertEqual(Path(runners.__file__).parent, HERE)
        self.assertTrue(hasattr(runners, "CONTEXT_MODES"))

    def test_shared_runners_is_theirs(self):
        self.assertEqual(
            Path(shared.sb_runners.__file__).parent, HERE.parent / "swebench"
        )

    def test_the_two_are_distinct_modules(self):
        self.assertIsNot(runners, shared.sb_runners)

    def test_task_contract_is_shared_not_copied(self):
        # A second definition of Task would eventually disagree with the first.
        self.assertIs(runners.Task, shared.sb_runners.Task)
        self.assertIs(runners.git_diff, shared.sb_runners.git_diff)

    def test_swebench_never_shadows_us_on_the_path(self):
        theirs = str(shared.SWEBENCH_DIR)
        if theirs in sys.path:
            ours = {str(HERE), ".", ""}
            first_ours = next(
                (i for i, e in enumerate(sys.path) if e in ours), len(sys.path)
            )
            self.assertGreater(sys.path.index(theirs), first_ours)


class TestGradedAwayPaths(unittest.TestCase):
    """The revert list must be READ from the grader, never inferred.

    On SWE-bench Verified the inferred version (`"test/" in path`) matched
    `src/_pytest/` and destroyed 19 of 500 gold patches while reporting them as
    "the agent produced no patch". Pro hands us the grader's own command, so
    there is no excuse for guessing -- and no excuse for failing quietly if the
    command ever changes shape.
    """

    def test_reads_the_checkout_line(self):
        inst = {
            "instance_id": "x",
            "before_repo_set_cmd": (
                "git reset --hard aaaa\n"
                "git clean -fd \n"
                "git checkout aaaa \n"
                "git checkout bbbbccccddddeeee1111 -- test/a.js test/b.js"
            ),
        }
        self.assertEqual(ds.graded_away_paths(inst), ["test/a.js", "test/b.js"])

    def test_raises_rather_than_guessing(self):
        # A silent [] here would mean the recorded patch keeps edits the grader
        # threw away; a silent guess would delete the agent's real work.
        with self.assertRaises(ds.RevertListError):
            ds.graded_away_paths({"instance_id": "x", "before_repo_set_cmd": "make test"})
        with self.assertRaises(ds.RevertListError):
            ds.graded_away_paths({"instance_id": "x", "before_repo_set_cmd": ""})

    def test_does_not_match_a_source_path_by_substring(self):
        """The exact defect from Verified, asserted not to be reachable here."""
        inst = {
            "instance_id": "x",
            "before_repo_set_cmd": "git checkout abc123 -- tests/test_flask.py",
        }
        got = ds.graded_away_paths(inst)
        self.assertEqual(got, ["tests/test_flask.py"])
        self.assertNotIn("src/_pytest/main.py", got)
        self.assertNotIn("django/test/client.py", got)

    def test_agreement_cross_check(self):
        inst = {
            "instance_id": "x",
            "before_repo_set_cmd": "git checkout abc123 -- test/a.js",
            "test_patch": "diff --git a/test/a.js b/test/a.js\n@@\n",
        }
        self.assertTrue(ds.revert_list_agrees(inst))
        inst["test_patch"] = "diff --git a/test/other.js b/test/other.js\n@@\n"
        self.assertFalse(ds.revert_list_agrees(inst))


class TestLiteralLists(unittest.TestCase):
    """fail_to_pass / pass_to_pass arrive as Python literals, not JSON.

    The official harness calls `eval()` on them. We do not, but we must parse
    everything `eval()` would: the dataset mixes single- and double-quoted
    forms, and a row whose test names contain apostrophes is JSON-invalid.
    Returning [] for such a row would silently make it unscoreable.
    """

    def test_json_form(self):
        self.assertEqual(ds._literal_list('["a", "b"]'), ["a", "b"])

    def test_python_single_quoted_form(self):
        self.assertEqual(ds._literal_list("['a', 'b']"), ["a", "b"])

    def test_apostrophe_inside_a_test_name(self):
        raw = '["should return null if key doesn\'t exist"]'
        self.assertEqual(ds._literal_list(raw), ["should return null if key doesn't exist"])

    def test_mixed_quoting_as_the_dataset_actually_ships_it(self):
        raw = "[\"test/a.js | one\", 'test/b.js | two']"
        self.assertEqual(ds._literal_list(raw), ["test/a.js | one", "test/b.js | two"])

    def test_empty_and_missing(self):
        self.assertEqual(ds._literal_list(""), [])
        self.assertEqual(ds._literal_list(None), [])


class TestPrompt(unittest.TestCase):
    """The context ablation must actually withhold context."""

    INST = {
        "repo": "a/b", "base_commit": "c" * 40, "repo_language": "go",
        "problem_statement": "PROBLEM_MARKER",
        "requirements": "REQUIREMENTS_MARKER",
        "interface": "INTERFACE_MARKER",
    }

    def test_full_carries_both_extra_fields(self):
        p = runners.build_prompt(self.INST, context_mode="full", test_hint=False)
        for marker in ("PROBLEM_MARKER", "REQUIREMENTS_MARKER", "INTERFACE_MARKER"):
            self.assertIn(marker, p)

    def test_no_spec_withholds_them(self):
        p = runners.build_prompt(self.INST, context_mode="no-spec", test_hint=False)
        self.assertIn("PROBLEM_MARKER", p)
        self.assertNotIn("REQUIREMENTS_MARKER", p)
        self.assertNotIn("INTERFACE_MARKER", p)

    def test_unknown_mode_is_an_error_not_a_default(self):
        # Defaulting would silently produce a run that is a mixture of two
        # different measurements.
        with self.assertRaises(ValueError):
            runners.build_prompt(self.INST, context_mode="partial", test_hint=False)

    def test_no_answer_bearing_field_reaches_the_prompt(self):
        inst = dict(self.INST)
        inst["before_repo_set_cmd"] = "git checkout DEADBEEF -- t.go"
        inst["patch"] = "GOLD_PATCH_MARKER"
        inst["test_patch"] = "TEST_PATCH_MARKER"
        inst["fail_to_pass"] = '["F2P_MARKER"]'
        inst["instance_id"] = "instance_a__b-DEADBEEF"
        p = runners.build_prompt(inst, context_mode="full", test_hint=True)
        for leak in ("GOLD_PATCH_MARKER", "TEST_PATCH_MARKER", "F2P_MARKER", "DEADBEEF"):
            self.assertNotIn(leak, p)


class TestOutcomeClassification(unittest.TestCase):
    """Infrastructure failures must not be scored as the agent being wrong.

    Upstream's `main()` writes `eval_results[iid] = False` both when the patch
    was wrong AND when the container died before writing output.json. Folding
    the second into the score charges our own flakiness to the model.
    """

    INSTANCES = [{"instance_id": "i1", "fail_to_pass": '["t1"]', "pass_to_pass": '["t2"]'}]

    def _collect(self, verdict, output, patch_bytes=100, stderr=""):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            (d / "eval_results.json").write_text(json.dumps(verdict))
            inst_dir = d / "i1"
            inst_dir.mkdir()
            if output is not None:
                (inst_dir / "p_output.json").write_text(json.dumps(output))
            (inst_dir / "p_stderr.log").write_text(stderr)
            (inst_dir / "p_stdout.log").write_text("")
            return evaluate.collect(
                eval_output_dir=d, prefix="p", instances=self.INSTANCES,
                submitted_patch_bytes={"i1": patch_bytes},
            )

    def test_resolved(self):
        out, det = self._collect(
            {"i1": True},
            {"tests": [{"name": "t1", "status": "PASSED"}, {"name": "t2", "status": "PASSED"}]},
        )
        self.assertEqual(out["i1"], "resolved")
        self.assertEqual(det["i1"]["tests_status"]["FAIL_TO_PASS"]["failure"], [])

    def test_unresolved_is_a_real_attempt(self):
        out, det = self._collect(
            {"i1": False},
            {"tests": [{"name": "t1", "status": "FAILED"}, {"name": "t2", "status": "PASSED"}]},
        )
        self.assertEqual(out["i1"], "unresolved")
        self.assertEqual(det["i1"]["tests_status"]["FAIL_TO_PASS"]["failure"], ["t1"])
        self.assertEqual(det["i1"]["tests_status"]["PASS_TO_PASS"]["failure"], [])

    def test_missing_output_json_is_eval_error_not_unresolved(self):
        out, _ = self._collect({"i1": False}, None)
        self.assertEqual(out["i1"], "eval_error")

    def test_empty_patch_beats_the_false_verdict(self):
        out, _ = self._collect({"i1": False}, {"tests": []}, patch_bytes=0)
        self.assertEqual(out["i1"], "empty_patch")

    def test_absent_from_eval_results_is_incomplete(self):
        out, _ = self._collect({}, {"tests": []})
        self.assertEqual(out["i1"], "incomplete")

    def test_regression_is_distinguished_from_incomplete_fix(self):
        _, det = self._collect(
            {"i1": False},
            {"tests": [{"name": "t1", "status": "PASSED"}, {"name": "t2", "status": "FAILED"}]},
        )
        st = det["i1"]["tests_status"]
        self.assertEqual(st["FAIL_TO_PASS"]["failure"], [])
        self.assertEqual(st["PASS_TO_PASS"]["failure"], ["t2"])

    def test_skipped_counts_as_not_passed(self):
        """The official predicate is `⊆ PASSED`, so SKIPPED does not count."""
        _, det = self._collect({"i1": False}, {"tests": [{"name": "t1", "status": "SKIPPED"}]})
        self.assertEqual(det["i1"]["tests_status"]["FAIL_TO_PASS"]["failure"], ["t1"])
        self.assertEqual(det["i1"]["tests_status"]["FAIL_TO_PASS"]["_absent"], [])

    def test_patch_apply_failure_is_detected_from_stderr(self):
        _, det = self._collect(
            {"i1": False}, {"tests": []},
            stderr="Checking patch a.go...\nerror: patch failed: a.go:12\n",
        )
        self.assertFalse(det["i1"]["patch_successfully_applied"])

    def test_clean_apply_is_not_a_false_positive(self):
        # `git apply -v` writes "Checking patch ..." to stderr on SUCCESS too.
        _, det = self._collect(
            {"i1": True}, {"tests": [{"name": "t1", "status": "PASSED"},
                                     {"name": "t2", "status": "PASSED"}]},
            stderr="Checking patch a.go...\nApplied patch a.go cleanly.\n",
        )
        self.assertTrue(det["i1"]["patch_successfully_applied"])


class TestReportLayoutAdapter(unittest.TestCase):
    """We must write where bench/swebench's reporter actually reads."""

    def test_layout_matches_what_report_reads_back(self):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            detail = {"resolved": False, "patch_successfully_applied": False,
                      "tests_status": {"FAIL_TO_PASS": {"success": [], "failure": ["t1"]},
                                       "PASS_TO_PASS": {"success": [], "failure": []}}}
            evaluate.write_swebench_layout(
                report_dir=d, run_id="rid", model="m", details={"i1": detail}
            )
            # The reporter's own private reader, used rather than a duplicated
            # path literal, so this test breaks if THEY move the file.
            got = shared.sb_report._instance_detail(d, "rid", "m", "i1")
            self.assertEqual(got["tests_status"]["FAIL_TO_PASS"]["failure"], ["t1"])
            self.assertTrue(shared.sb_diagnose.patch_apply_failed(d, "rid", "m", "i1"))

    def test_no_apply_marker_when_the_patch_applied(self):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            evaluate.write_swebench_layout(
                report_dir=d, run_id="rid", model="m",
                details={"i1": {"patch_successfully_applied": True, "tests_status": {}}},
            )
            self.assertFalse(shared.sb_diagnose.patch_apply_failed(d, "rid", "m", "i1"))


class TestHonestyKeys(unittest.TestCase):
    """The reporter's fail-closed gates must be able to read our config.

    `bench/report/honesty.py` decides whether a run may be quoted by looking up
    specific keys in `config.json`, and treats an ABSENT key as the unsafe
    value. That is the correct default, but it means a Pro run that named the
    same concept differently got flagged for leaking FAIL_TO_PASS test names it
    never leaked. Publishing under the name the checker reads is our job, and
    this test is what keeps the two from drifting apart again.
    """

    def test_run_bench_publishes_f2p_hint(self):
        src = (HERE / "run_bench.py").read_text()
        self.assertIn('"f2p_hint"', src)

    def test_honesty_gate_reads_that_key(self):
        honesty = HERE.parent / "report" / "honesty.py"
        if not honesty.exists():
            self.skipTest("bench/report not present")
        self.assertIn(
            'config.get("f2p_hint"', honesty.read_text(),
            "bench/report/honesty.py no longer gates on config.f2p_hint; "
            "re-check which key it reads and publish that one.",
        )


class TestDockerWaitTimeout(unittest.TestCase):
    """Guard against the upstream defect in PR #111.

    `swe_bench_pro_eval.eval_with_docker` calls `docker.from_env()` and then
    `container.wait()`. If that call inherits docker-py's 60-second default
    read timeout, every suite that runs longer than a minute -- routine for the
    Go and JS repos here -- raises ReadTimeout, writes no output.json, and is
    scored as the model failing. PR #111 reports this as the cause of issues
    #22/#23/#54; it is unmerged.

    MEASURED on this host at docker-py 7.2.0: NOT affected. `Container.wait()`
    passes `timeout=None` down to `APIClient.wait`, and `_set_request_timeout`
    leaves an explicit None alone, so the request has no deadline. A 75-second
    container was waited on successfully end to end.

    This test pins that property statically so a future docker-py bump that
    reintroduces the default cannot silently start deflating scores.
    """

    def test_container_wait_has_no_deadline(self):
        try:
            import docker
            from docker.models.containers import Container
        except ImportError:
            self.skipTest("docker sdk not installed")
        import inspect

        sig = inspect.signature(docker.api.container.ContainerApiMixin.wait)
        self.assertIsNone(
            sig.parameters["timeout"].default,
            "docker-py's APIClient.wait no longer defaults to timeout=None; the "
            "60s read timeout from upstream PR #111 is now live and long test "
            "suites will be scored as model failures. Pass an explicit timeout.",
        )
        self.assertIn("kwargs", inspect.signature(Container.wait).parameters)


class TestHistoryStripping(unittest.TestCase):
    """The fix commit must not survive in the workspace we hand the agent.

    Not a hypothetical: measured on the real flipt image, `git show <fix>`
    returned the complete gold patch with the network off. See
    `workspace.strip_future_history`.
    """

    def _repo(self, td: Path) -> tuple[str, str]:
        def g(*a):
            return subprocess.run(["git", *a], cwd=td, capture_output=True, text=True)

        g("init", "-q", "-b", "main")
        g("config", "user.email", "t@t")
        g("config", "user.name", "t")
        (td / "f.txt").write_text("base\n")
        g("add", "-A")
        g("commit", "-qm", "base")
        base = g("rev-parse", "HEAD").stdout.strip()
        (td / "f.txt").write_text("fixed\n")
        g("add", "-A")
        g("commit", "-qm", "THE FIX")
        fix = g("rev-parse", "HEAD").stdout.strip()
        # A tag and a second branch, as the real images carry ~237 refs.
        g("tag", "v1.0")
        g("branch", "release")
        g("remote", "add", "origin", "https://github.com/example/example")
        g("checkout", "-q", base)
        return base, fix

    def test_fix_commit_becomes_unreachable(self):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            base, fix = self._repo(d)
            self.assertTrue(ws.fix_commit_reachable(d, fix), "setup is wrong")
            ws.strip_future_history(d, base)
            self.assertFalse(ws.fix_commit_reachable(d, fix))

    def test_legitimate_ancestry_is_kept(self):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            base, _ = self._repo(d)
            ws.strip_future_history(d, base)
            # base itself, and the ability to diff against it, must survive --
            # an agent without the project's past is being measured on
            # something other than software engineering.
            self.assertTrue(ws.fix_commit_reachable(d, base))
            head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=d,
                                  capture_output=True, text=True).stdout.strip()
            self.assertEqual(head, base)

    def test_remotes_and_extra_refs_are_gone(self):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            base, _ = self._repo(d)
            att = ws.strip_future_history(d, base)
            self.assertEqual(att["remotes_after"], [])
            self.assertEqual(att["refs_after"], [f"refs/heads/{ws.BASE_REF}"])

    def test_git_diff_still_works_afterwards(self):
        # Stripping must not break patch extraction, which is the whole run.
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            base, _ = self._repo(d)
            ws.strip_future_history(d, base)
            (d / "f.txt").write_text("agent edit\n")
            patch, dropped = shared.sb_runners.git_diff(d, strip_paths=[])
            self.assertIn("agent edit", patch)
            self.assertEqual(dropped, [])


class TestLiveDataset(unittest.TestCase):
    """Invariants over the real 731 rows. Needs the dumped jsonl."""

    @classmethod
    def setUpClass(cls):
        p = HERE / "data" / "swebench_pro_public.jsonl"
        if not p.exists():
            raise unittest.SkipTest(f"{p} not present; run run_bench.py once")
        cls.rows = ds.load_rows(str(p))

    def test_public_split_size(self):
        self.assertEqual(len(self.rows), 731)

    def test_every_row_yields_a_revert_list(self):
        for r in self.rows:
            self.assertTrue(ds.graded_away_paths(r), r["instance_id"])

    def test_revert_list_agrees_with_test_patch_everywhere(self):
        bad = [r["instance_id"] for r in self.rows if not ds.revert_list_agrees(r)]
        self.assertEqual(bad, [], f"{len(bad)} instances disagree")

    def test_dockerhub_tags_are_unique(self):
        """211 of 731 tags are truncated at Docker Hub's 128-char limit.

        Truncation is only safe because no two instances collide onto the same
        tag. If that ever changes, one instance would be graded in another's
        environment, which would not look like an error.
        """
        tags = [r["dockerhub_tag"] for r in self.rows]
        self.assertEqual(len(set(tags)), len(tags))

    def test_harness_assets_exist_for_every_instance(self):
        h = HERE / "harness"
        if not h.exists():
            self.skipTest("harness not cloned")
        missing = [
            r["instance_id"] for r in self.rows
            if not (h / "run_scripts" / r["instance_id"] / "run_script.sh").exists()
            or not (h / "dockerfiles" / "base_dockerfile" / r["instance_id"] / "Dockerfile").exists()
        ]
        self.assertEqual(missing, [], f"{len(missing)} instances lack harness assets")


class TestLiveDocker(unittest.TestCase):
    """Confirms the leak this harness exists to close is real. --live only."""

    IMAGE = ("jefzda/sweap-images:flipt-io.flipt-flipt-io__flipt-"
             "518ec324b66a07fdd95464a5e9ca5fe7681ad8f9")
    FIX = "518ec324b66a07fdd95464a5e9ca5fe7681ad8f9"

    def setUp(self):
        if not LIVE:
            self.skipTest("--live not given")
        if not ws.image_present(self.IMAGE):
            self.skipTest("probe image not pulled")

    def test_the_published_image_still_leaks_the_answer(self):
        """If this ever FAILS, upstream PR #94 landed and images were rebuilt."""
        p = subprocess.run(
            ["docker", "run", "--rm", "--entrypoint", "/bin/bash", "--network", "none",
             self.IMAGE, "-c", f"cd /app && git cat-file -t {self.FIX}"],
            capture_output=True, text=True,
        )
        self.assertEqual(p.stdout.strip(), "commit",
                         "the upstream image no longer leaks; revisit workspace.py")


if __name__ == "__main__":
    sys.argv = [a for a in sys.argv if a != "--live"]
    unittest.main(verbosity=2)
