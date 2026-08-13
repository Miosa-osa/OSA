"""Tests for the head-to-head attribution and paired statistics.

The attribution table is the part of this harness most likely to be quietly
wrong, and being wrong in it is expensive: mislabelling a broken arm as "the
model got it wrong" produces a comparison that reads as a capability result and
is not one. Every rule that decides a fault owner has a test here, and the
ordering between rules is tested explicitly because the ordering is the part
that actually failed in practice (a provider outage looked exactly like six
broken harnesses).

Run:
    python3 -m pytest bench/headtohead/test_headtohead.py -q
    # or, with no pytest installed:
    python3 bench/headtohead/test_headtohead.py
"""

from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import attribution  # noqa: E402
import paired  # noqa: E402
import report_h2h  # noqa: E402


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def make_result(*, reward=0.0, exc=None, tin=100, tout=10,
                setup=(True, True), execution=(True, True), meta=None) -> dict:
    def block(pair):
        started, finished = pair
        d = {}
        if started:
            d["started_at"] = "2026-08-14T00:00:00Z"
        if finished:
            d["finished_at"] = "2026-08-14T00:05:00Z"
        return d

    return {
        "task_name": "terminal-bench/t",
        "trial_name": "t__x",
        "started_at": "2026-08-14T00:00:00Z",
        "finished_at": "2026-08-14T00:10:00Z",
        "agent_setup": block(setup),
        "agent_execution": block(execution),
        "agent_info": {"version": "1.0"},
        "agent_result": {"n_input_tokens": tin, "n_output_tokens": tout,
                         "cost_usd": None, "metadata": meta or {}},
        "verifier_result": ({"rewards": {"reward": reward}}
                            if reward is not None else {}),
        "exception_info": ({"exception_type": exc, "exception_message": "m"}
                           if exc else None),
    }


def trial_dir_with_log(text: str | None) -> Path:
    d = Path(tempfile.mkdtemp())
    (d / "agent").mkdir()
    if text is not None:
        (d / "agent" / "agent.log").write_text(text)
    return d


def check(name, got, want):
    status = "ok  " if got == want else "FAIL"
    print(f"  [{status}] {name}: got {got!r}")
    assert got == want, f"{name}: got {got!r}, want {want!r}"


# ---------------------------------------------------------------------------
# attribution
# ---------------------------------------------------------------------------

def test_resolved_beats_everything():
    """A reward of 1.0 is resolved even if the arm also logged an outage."""
    d = trial_dir_with_log("Ollama returned 429: reached your session usage limit")
    reason, owner, _ = attribution.classify(make_result(reward=1.0), d)
    check("reward 1.0 -> resolved", (reason, owner), ("", "resolved"))


def test_provider_outage_outranks_zero_tokens():
    """THE regression that motivated this file.

    A quota-exhausted provider yields zero tokens. Without the outage rule
    firing FIRST, the 0-token rule files it as `agent_never_reached_model`,
    i.e. a harness fault charged to the arm.
    """
    d = trial_dir_with_log(
        "[warning] Ollama returned 429: you have reached your session usage limit")
    reason, owner, _ = attribution.classify(make_result(tin=0, tout=0), d)
    check("429 + 0 tokens -> provider", (reason, owner), ("provider_outage", "provider"))


def test_provider_outage_outranks_crash():
    """An arm that crashed BECAUSE the provider was down is not a broken arm."""
    d = trial_dir_with_log("HTTP 429 rate limit exceeded")
    reason, owner, _ = attribution.classify(
        make_result(exc="NonZeroAgentExitCodeError"), d)
    check("429 + crash -> provider", (reason, owner), ("provider_outage", "provider"))


def test_provider_outage_outranks_timeout():
    d = trial_dir_with_log("model glm-9 was retired at 2026-01-01")
    reason, owner, _ = attribution.classify(make_result(exc="AgentTimeoutError"), d)
    check("retired model -> provider", (reason, owner), ("provider_outage", "provider"))


def test_harbor_typed_provider_error_is_an_outage_even_with_no_logs():
    """Observed live: mini-swe-agent's 429 surfaced as `ApiRateLimitError`.

    Harbor's own classifier already knows. Trusting it works even for an arm
    that writes no parseable log.
    """
    d = trial_dir_with_log(None)  # no log at all
    reason, owner, _ = attribution.classify(
        make_result(exc="ApiRateLimitError"), d)
    check("ApiRateLimitError -> provider", (reason, owner),
          ("provider_outage", "provider"))


def test_mid_stream_disconnect_is_not_excused_as_an_outage():
    """An arm that cannot survive a dropped stream is showing something about
    itself, so it stays with the harness rather than being written off."""
    d = trial_dir_with_log("stream ended")
    _, owner, _ = attribution.classify(
        make_result(exc="ApiConnectionClosedError"), d)
    check("connection closed -> harness", owner, "harness")


def test_zero_tokens_is_harness_when_provider_is_fine():
    d = trial_dir_with_log("everything looks normal here")
    reason, owner, _ = attribution.classify(make_result(tin=0, tout=0), d)
    check("0 tokens, healthy provider -> harness",
          (reason, owner), ("agent_never_reached_model", "harness"))


def test_install_failure_is_harness():
    d = trial_dir_with_log("")
    reason, owner, _ = attribution.classify(
        make_result(setup=(True, False), exc="AgentSetupTimeoutError"), d)
    check("setup timeout -> harness", (reason, owner), ("agent_install_failed", "harness"))


def test_timeout_is_ambiguous_not_model():
    """A timeout must never be silently charged to the model."""
    d = trial_dir_with_log("")
    reason, owner, _ = attribution.classify(make_result(exc="AgentTimeoutError"), d)
    check("agent timeout -> ambiguous", (reason, owner), ("agent_timeout", "ambiguous"))


def test_verifier_timeout_is_grader_not_agent():
    d = trial_dir_with_log("")
    reason, owner, _ = attribution.classify(make_result(exc="VerifierTimeoutError"), d)
    check("verifier timeout -> grader", (reason, owner), ("verifier_timeout", "grader"))


def test_missing_reward_is_harness():
    d = trial_dir_with_log("")
    reason, owner, _ = attribution.classify(make_result(reward=None), d)
    check("no reward -> harness", (reason, owner), ("no_verifier_reward", "harness"))


def test_plain_wrong_answer_is_model():
    d = trial_dir_with_log("nothing wrong")
    reason, owner, _ = attribution.classify(make_result(reward=0.0), d)
    check("reward 0 -> model", (reason, owner), ("completed_but_wrong", "model"))


def test_osa_status_ok_cannot_rescue_a_failed_run():
    """OSA self-reports `status: ok` on turns where every provider call failed.

    Attribution must not believe it. This is the live defect observed in
    runs/smoke1: status ok, saw_done true, zero tokens, 429s in the log.
    """
    d = trial_dir_with_log("[error] LLM call failed: All providers failed: "
                           "ollama: reached your session usage limit")
    meta = {"osa_status": "ok", "osa_saw_done": True, "osa_tool_calls": 0}
    reason, owner, _ = attribution.classify(
        make_result(tin=0, tout=0, meta=meta), d)
    check("osa says ok, provider was down -> provider",
          (reason, owner), ("provider_outage", "provider"))


def test_per_agent_telemetry_cannot_change_the_owner():
    """OSA's richer instrumentation may refine a reason, never move an owner."""
    d = trial_dir_with_log("healthy")
    meta = {"osa_status": "ok", "osa_tool_calls": 0}
    reason, owner, _ = attribution.classify(make_result(reward=0.0, meta=meta), d)
    check("0 tool calls -> still model", owner, "model")
    check("0 tool calls -> refined reason", reason, "completed_without_acting")


def test_outage_regex_matches_real_outages():
    """Signatures actually observed, or documented by the providers."""
    for line in [
        'Ollama returned 429: %{"error" => "you have reached your session usage limit"}',
        '"statusCode":429,"isRetryable":true',
        "HTTP 429: rate limit",
        "glm-4.7 was retired at 2026-07-15",
        "openai.RateLimitError: quota exceeded",
        "code: 503 Service Unavailable",
        "insufficient_quota",
        "429 Too Many Requests",
    ]:
        check(f"matches {line[:40]!r}",
              bool(attribution.PROVIDER_OUTAGE.search(line)), True)


def test_outage_regex_does_not_fire_on_log_noise():
    """A detector that voids GOOD runs gets switched off, which is worse.

    The first draft used a bare `\\b429\\b` and would have voided a valid run on
    the line "wrote 429 bytes".
    """
    for line in [
        "wrote 429 bytes to /tmp/out",
        "test 429 passed in 3ms",
        "port 4290 bound",
        "elapsed_steps=429",
        "sha256: a429b7c503de",
        "Retrying request after error",
        "INFO 503 files scanned",
        "exit code 0",
    ]:
        check(f"ignores {line[:40]!r}",
              bool(attribution.PROVIDER_OUTAGE.search(line)), False)


def test_markers_are_namespaced_per_arm():
    d = trial_dir_with_log("[doom] Stall detected — escalate-only\n" * 4)
    counts_osa, _ = attribution.scrape_markers(d, "osa")
    counts_codex, _ = attribution.scrape_markers(d, "codex")
    check("osa marker table matches", counts_osa.get("stall_detector"), 4)
    check("codex table does not claim osa markers",
          counts_codex.get("stall_detector"), None)


# ---------------------------------------------------------------------------
# paired statistics
# ---------------------------------------------------------------------------

def test_mcnemar_needs_six_discordant_pairs():
    """The arithmetic that makes an n=6 run unable to rank anything."""
    check("min discordant for p<0.05", paired.min_discordant_for_significance(), 6)
    check("5-0 sweep is not significant", paired.mcnemar_exact(5, 0)["significant"], False)
    check("6-0 sweep is significant", paired.mcnemar_exact(6, 0)["significant"], True)


def test_mcnemar_no_discordant_pairs_is_not_a_tie_claim():
    r = paired.mcnemar_exact(0, 0)
    check("0 discordant -> p=1.0", r["p_value"], 1.0)
    check("0 discordant -> not significant", r["significant"], False)
    assert "cannot separate them" in r["note"]


def test_mcnemar_is_symmetric():
    check("symmetric p", paired.mcnemar_exact(4, 1)["p_value"],
          paired.mcnemar_exact(1, 4)["p_value"])


def test_pairing_drops_tasks_only_one_arm_ran():
    """An arm that never got a task did not fail it."""
    a = {"t1": {"resolved": True}, "t2": {"resolved": True}}
    b = {"t1": {"resolved": False}}
    c = paired.compare("a", a, "b", b)
    check("n_paired excludes t2", c.n_paired, 1)
    check("a_only counts only shared tasks", c.a_only, 1)


# ---------------------------------------------------------------------------
# reporting
# ---------------------------------------------------------------------------

def _fake_arm(name, family="generic"):
    class A:
        pass
    a = A()
    a.name, a.family, a.wire, a.caveats = name, family, "test", ()
    return a


def _build_run(tmp: Path, plan: dict) -> dict:
    job_dirs = {}
    for arm, tasks in plan.items():
        jd = tmp / arm / "job"
        for t, res in tasks.items():
            td = jd / f"{t}__x"
            (td / "agent").mkdir(parents=True)
            r = make_result(**res)
            r["task_name"] = f"terminal-bench/{t}"
            r["trial_name"] = f"{t}__x"
            (td / "result.json").write_text(json.dumps(r))
            (td / "agent" / "agent.log").write_text(res.pop("_log", "healthy"))
        job_dirs[arm] = str(jd)
    cfg = {
        "run_id": "test", "tasks": sorted({t for v in plan.values() for t in v}),
        "shared_model": "m", "model_held_fixed": True, "model_fixed_caveat": "x",
        "harbor_version": "0", "task_selection": "x", "graded_by": "x",
        "limits": {"wall_clock": "x", "turn_cap": None},
        "arm_wire_protocols": {k: "x" for k in plan}, "blocked_arms": {},
        "provider_probe_before": {"servable": True},
        "provider_probe_after": {"servable": True},
        "disk_free_gb_before": 1, "disk_free_gb_after": 1, "arm_exit_codes": {},
    }
    return report_h2h.build(config=cfg, job_dirs=job_dirs,
                            arms=[_fake_arm(k) for k in plan])


def test_report_marks_a_clean_run_valid_but_unrankable():
    with tempfile.TemporaryDirectory() as d:
        res = _build_run(Path(d), {
            "a": {"t1": {"reward": 1.0}, "t2": {"reward": 0.0}},
            "b": {"t1": {"reward": 0.0}, "t2": {"reward": 0.0}},
        })
        check("comparison valid",
              res["honesty"]["provider_integrity"]["comparison_valid"], True)
        check("ranking not supported", res["comparison"]["ranking_supported"], False)
        assert "DOES NOT SUPPORT A RANKING" in res["honesty"]["claim_label"]
        report_h2h.report_md(res)  # must not raise


def test_report_voids_a_run_with_a_provider_outage():
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        jd = tmp / "a" / "job"
        td = jd / "t1__x"
        (td / "agent").mkdir(parents=True)
        (td / "result.json").write_text(json.dumps(
            dict(make_result(reward=0.0, tin=0, tout=0),
                 task_name="terminal-bench/t1", trial_name="t1__x")))
        (td / "agent" / "agent.log").write_text("HTTP 429 quota exceeded")
        cfg = {
            "run_id": "t", "tasks": ["t1"], "shared_model": "m",
            "model_held_fixed": True, "model_fixed_caveat": "x",
            "harbor_version": "0", "task_selection": "x", "graded_by": "x",
            "limits": {"wall_clock": "x", "turn_cap": None},
            "arm_wire_protocols": {"a": "x"}, "blocked_arms": {},
            "provider_probe_before": {"servable": True},
            "provider_probe_after": {"servable": False},
            "disk_free_gb_before": 1, "disk_free_gb_after": 1, "arm_exit_codes": {},
        }
        res = report_h2h.build(config=cfg, job_dirs={"a": str(jd)},
                               arms=[_fake_arm("a")])
        pi = res["honesty"]["provider_integrity"]
        check("outage voids comparison", pi["comparison_valid"], False)
        check("outage counted", pi["trials_hit_by_provider_outage"], 1)
        assert res["honesty"]["claim_label"].startswith("VOID")
        md = report_h2h.report_md(res)
        assert "THIS RUN IS VOID AS A COMPARISON" in md
        check("arm not blamed",
              res["aggregate_by_arm"]["a"]["fault_owner_counts"]["harness"], 0)


def test_renderer_survives_an_older_results_json():
    """A reporter that cannot re-render last week's artefact stops being used.

    `provider_integrity` did not exist in the first schema; rendering must
    degrade, not raise.
    """
    with tempfile.TemporaryDirectory() as d:
        res = _build_run(Path(d), {"a": {"t1": {"reward": 1.0}}})
        del res["honesty"]["provider_integrity"]
        report_h2h.report_md(res)     # must not raise
        report_h2h.print_headline(res)  # must not raise
        check("degraded render ok", True, True)


def test_missing_cost_renders_as_dash_never_zero():
    check("None -> dash", report_h2h._fmt(None), "-")
    check("0 stays 0", report_h2h._fmt(0), "0")


def main() -> int:
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    failed = 0
    for t in tests:
        print(f"{t.__name__}:")
        try:
            t()
        except AssertionError as e:
            failed += 1
            print(f"  ASSERTION FAILED: {e}")
    print(f"\n{len(tests) - failed}/{len(tests)} tests passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
