"""Tests for the run conditions that make a number quotable.

Effort, the Ollama `think` field and the agent timeout multiplier are not
invocation details, they are conditions of the measurement: Anthropic measures
10.3 pp of movement on effort alone under a fixed harness, cline measures 11.2
pp on GLM-5.2 between reasoning medium and off, and a timeout multiplier turns
possible solves into guaranteed fails. A run whose conditions are unrecorded
cannot be compared to anything, and -- worse -- a run whose pin silently fails
to apply looks exactly like a run that was pinned.

So these assert three things that are otherwise invisible:

1. Pinning writes a `config.toml`, and NOT pinning writes none. The absence has
   to stay distinguishable from a pin to OSA's default.
2. `OLLAMA_THINK` reaches `~/.osa/.env`. It is the only reasoning dial that
   reaches the wire on the Ollama serving path.
3. The reporter carries a Wilson interval and the conditions into its output.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

# `report`/`datasets` are ambiguous basenames across bench/ -- see
# `_localimport` for the measured failure. Never `import report` here.
import _localimport  # noqa: E402

report_mod = _localimport.load("report")


def test_run_bench_is_ours():
    """The loader must hand back THIS package's runner, not a sibling's.

    Asserted on the file path rather than on an attribute, because an attribute
    check only catches the collision when the two modules disagree about that
    name -- and the dangerous case is the one where they agree.
    """
    rb = _localimport.load("run_bench")
    assert Path(rb.__file__).parent == HERE
    assert hasattr(rb, "artifact_provenance")


def _load_osa_agent():
    """`osa_agent` imports harbor, which is only in the bench venv.

    Skipped rather than failed when harbor is absent, because these assertions
    are about the adapter's string-building and the rest of the file is still
    worth running under a bare interpreter.
    """
    spec = importlib.util.spec_from_file_location("osa_agent", HERE / "osa_agent.py")
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    try:
        spec.loader.exec_module(mod)
    except Exception as exc:  # noqa: BLE001
        pytest.skip(f"osa_agent unimportable here ({type(exc).__name__}: {exc})")
    return mod


class _Agent:
    """The two string builders under test, bound without Harbor's __init__.

    `OsaAgent.__init__` reaches into `BaseInstalledAgent`, which wants a whole
    Harbor environment. The methods being tested read only `self._provider`,
    `self._port` and `self.model_name`, so they are exercised directly against a
    stand-in rather than by constructing the real thing.
    """

    def __init__(self, cls, model_name=None, provider=None, port=19899):
        self._cls = cls
        self.model_name = model_name
        self._provider = provider
        self._port = port

    # D9 routed every environment read through `OsaAgent._env`, which consults
    # Harbor's `_get_env` (the `--ae` chain) and falls back to `os.environ`.
    # Bound here too, so these tests keep exercising the real lookup rather than
    # a copy of it -- with no `_get_env` on the stand-in, `_env` takes its
    # `os.environ` branch, which is exactly what `monkeypatch.setenv` drives.
    def _env(self, key, default=None):
        return self._cls._env(self, key, default)

    def _ablation_env(self):
        return self._cls._ablation_env(self)

    def dotenv(self) -> str:
        return self._cls._dotenv(self)

    def config_toml(self):
        return self._cls._config_toml(self)


# --------------------------------------------------------------- effort pin


@pytest.mark.parametrize("bad", ["hgih", "maximum", "1", "med"])
def test_an_invalid_effort_rung_is_rejected_at_construction(monkeypatch, tmp_path, bad):
    """D10. The rung is not validated by OSA, so it has to be validated here.

    `Application.resolve_effort/1` does not reject an unknown value -- it logs
    "ignoring unknown [model].effort" and boots at OSA's own default. So before
    the `ENV_VARS` descriptor existed, `OSA_BENCH_EFFORT=hgih` produced a run
    that completed normally, wrote `effort: "hgih"` into `config.json`, and was
    actually unpinned. Effort is the largest single lever anyone has published
    on this axis (10.3 pp, Anthropic Opus 4.6 SC Fig 2.5.A; 11.2 pp on this very
    model, cline), so a silently-unpinned arm is a voided comparison.

    Constructed for real rather than through `_Agent`, because the rejection
    happens in `BaseInstalledAgent.__init__` via `_coerce_value`.
    """
    mod = _load_osa_agent()
    monkeypatch.setenv("OSA_BENCH_EFFORT", bad)
    with pytest.raises(ValueError, match="effort"):
        mod.OsaAgent(logs_dir=tmp_path)


def test_the_kwarg_seam_and_the_env_seam_pin_identically(monkeypatch, tmp_path):
    """`--ak effort=high` and `OSA_BENCH_EFFORT=high` must be the same run."""
    mod = _load_osa_agent()
    monkeypatch.delenv("OSA_BENCH_EFFORT", raising=False)
    by_kwarg = mod.OsaAgent(logs_dir=tmp_path, effort="high")._config_toml()
    monkeypatch.setenv("OSA_BENCH_EFFORT", "high")
    by_env = mod.OsaAgent(logs_dir=tmp_path)._config_toml()
    assert by_kwarg == by_env == '[model]\neffort = "high"\n'
    # Case is normalised to the canonical rung rather than rejected
    # (`_coerce_value`, `base.py:274-279`) -- and normalising matters, because
    # `[model].effort = "HIGH"` is one of the values OSA would silently ignore.
    monkeypatch.setenv("OSA_BENCH_EFFORT", "HIGH")
    assert mod.OsaAgent(logs_dir=tmp_path)._config_toml() == by_env


def test_config_toml_is_none_when_effort_unpinned(monkeypatch):
    mod = _load_osa_agent()
    monkeypatch.delenv("OSA_BENCH_EFFORT", raising=False)
    assert _Agent(mod.OsaAgent).config_toml() is None


def test_config_toml_pins_effort_and_nothing_else(monkeypatch):
    mod = _load_osa_agent()
    monkeypatch.setenv("OSA_BENCH_EFFORT", "high")
    toml = _Agent(mod.OsaAgent).config_toml()
    assert toml is not None
    assert "[model]" in toml
    assert 'effort = "high"' in toml
    # A `[model].provider` here would take TOP precedence in OSA's boot-time
    # resolution, ahead of the OSA_DEFAULT_PROVIDER this adapter sets from the
    # environment -- which would silently override the model the run is pinned
    # to. The table must stay to the one key that has no other seam.
    assert "provider" not in toml
    assert "model =" not in toml


@pytest.mark.parametrize("level", ["fast", "medium", "high", "xhigh", "ultra"])
def test_every_ladder_rung_round_trips(monkeypatch, level):
    """The five rungs OSA's `Application.resolve_effort/1` accepts verbatim.

    A rung that does not round-trip is worse than one that errors: OSA logs
    "ignoring unknown [model].effort" and boots at its own default, so the run
    proceeds and reports a pin it did not have.
    """
    mod = _load_osa_agent()
    monkeypatch.setenv("OSA_BENCH_EFFORT", level)
    assert f'effort = "{level}"' in _Agent(mod.OsaAgent).config_toml()


# ----------------------------------------------------------- think forwarding


def test_ollama_think_reaches_dotenv(monkeypatch):
    mod = _load_osa_agent()
    monkeypatch.setenv("OLLAMA_THINK", "true")
    monkeypatch.setenv("OLLAMA_MODEL", "glm-5.2:cloud")
    env = _Agent(mod.OsaAgent).dotenv()
    assert "OLLAMA_THINK=true" in env


def test_unset_think_writes_no_key(monkeypatch):
    """Absent must mean absent, so OSA's own resolution order applies unchanged.

    Writing `OLLAMA_THINK=` would be read by `config/runtime.exs` as neither
    "true" nor "false" and fall to nil, which happens to be the same outcome --
    but it would also put a key in the file that says the run pinned something.
    """
    mod = _load_osa_agent()
    monkeypatch.delenv("OLLAMA_THINK", raising=False)
    assert "OLLAMA_THINK" not in _Agent(mod.OsaAgent).dotenv()


# ------------------------------------------------------------------- reporting


def _row(name: str, *, resolved: bool) -> dict:
    """The minimum row shape `report.build` reads, with the owner stamped.

    `fault_owner` is computed by `collect` in the real path, not by `build`, so
    a hand-built row has to carry it or `build` raises on the first access.
    """
    reason = None if resolved else "wrong_answer"
    return {
        "task_name": name,
        "resolved": resolved,
        "failure_reason": reason,
        "fault_owner": report_mod._fault_owner(reason),
        "tokens_in": None,
        "tokens_out": None,
        "tokens_cache": None,
        "tokens_cache_read": None,
        "tokens_cache_write": None,
        "cost_usd": None,
        "wall_clock_s": None,
        "agent_setup_s": None,
        "agent_exec_s": None,
        "osa_boot_s": None,
        "turns": None,
        "tool_calls": None,
        "self_inflicted": {},
        "reward": 1.0 if resolved else 0.0,
        "trial": name,
        "peak_context_tokens": None,
        "denials": 0,
        "osa_tool_faults": 0,
        "add_dir_mentions": 0,
    }


def test_wilson_is_actually_loaded():
    """Guards the import, not the arithmetic.

    `bench/report/stats.py` is shadowed by this directory's own `report.py`, so
    the obvious import silently yields no interval. It did exactly that once.
    """
    assert report_mod._wilson is not None


def test_aggregate_carries_a_wilson_interval():
    rows = [_row(f"t{i}", resolved=i < 53) for i in range(89)]
    out = report_mod.build(config={"run_id": "t", "agent": "osa", "dataset_size": 89}, rows=rows)
    ci = out["aggregate"]["accuracy_ci95"]
    assert ci["method"] == "wilson"
    # 53/89 = 59.6%, and the interval is wide enough that cline's 68.5% sits
    # inside it. That is the point of printing it.
    assert ci["low"] < 0.596 < ci["high"]
    assert ci["low"] < 0.685 < ci["high"]


def test_summary_names_the_conditions_even_when_unpinned():
    rows = [_row("t0", resolved=True)]
    out = report_mod.build(config={"run_id": "t", "agent": "osa", "dataset_size": 89}, rows=rows)
    md = report_mod.summary_md(out)
    assert "**Effort**: `UNPINNED`" in md
    assert "**ollama think**: `UNPINNED`" in md
    assert "**timeout multiplier**: `1.0`" in md


def test_summary_prints_the_pins_it_was_given():
    rows = [_row("t0", resolved=True)]
    out = report_mod.build(
        config={
            "run_id": "t",
            "agent": "osa",
            "dataset_size": 89,
            "effort": "high",
            "ollama_think": "true",
            "timeout_multiplier": 2.0,
        },
        rows=rows,
    )
    md = report_mod.summary_md(out)
    assert "**Effort**: `high`" in md
    assert "**ollama think**: `true`" in md
    assert "**timeout multiplier**: `2.0`" in md


# ---------------------------------------------------------------- provenance


def test_lib_dirty_check_is_cwd_independent():
    """The dirty-tree guard must use a top-level-relative pathspec.

    `artifact_provenance` runs git with `cwd=bench/terminalbench`. A plain `lib`
    pathspec resolves against the CURRENT directory, which has no `lib/`, so the
    check reported a clean tree unconditionally -- the one guard against
    benchmarking a half-applied tree, silently answering "clean" for its whole
    life. `:/lib` is git's magic prefix for "relative to the top of the working
    tree" and does not depend on where the process is standing.

    Asserted against the source rather than by mutating the repo, because the
    only honest behavioural test would require dirtying `lib/` -- which other
    agents are actively working in.
    """
    src = (HERE / "run_bench.py").read_text()
    assert '":/lib"' in src, "pathspec must be top-level-relative"
    assert '"--", "lib"' not in src, "cwd-relative pathspec has come back"


def test_provenance_reports_build_sidecar_field():
    """`build` is present whether or not the sidecar exists.

    Absent means "built by a script that did not record its SHA", which is a
    fact about the artefact and has to be legible as one rather than as a
    missing key that a reader assumes was an oversight.
    """
    run_bench = _localimport.load("run_bench")

    out = run_bench.artifact_provenance()
    assert "build" in out


def test_built_after_head_commit_compares_instants_not_digits():
    """Two ISO timestamps at different UTC offsets must not be compared as text.

    `built_at` is rendered UTC-aware ("+00:00"); `head_committed_at` is git's
    %cI in local time ("+07:00"). Lexicographically the first sorts before the
    second while naming a LATER instant, so a sound artefact reported as
    predating the commit it measures -- on the one field whose job is to say
    whether the run is measuring the code it claims to.

    These are the real values from the build this was found on.
    """
    from datetime import datetime

    built = "2026-08-14T17:51:39+00:00"
    committed = "2026-08-15T00:48:17+07:00"
    assert built < committed, "the string comparison that used to be used"
    assert datetime.fromisoformat(built) > datetime.fromisoformat(committed)


def test_provenance_reports_a_true_verdict_for_the_current_artifact():
    run_bench = _localimport.load("run_bench")

    out = run_bench.artifact_provenance()
    if not out.get("present") or not out.get("head_committed_at"):
        pytest.skip("no artefact built here")
    # Not asserting the value -- asserting it is a verdict and not a crash.
    assert out["built_after_head_commit"] in (True, False, None)
    assert "built_after_head_commit_error" not in out


# --------------------------------------------------------------- driver deadline


@pytest.mark.parametrize(
    "mult,expected",
    [(None, None), ("", None), ("1.0", None), ("2.0", 3600), ("0.5", 900),
     ("nonsense", None), ("0", None), ("-2", None)],
)
def test_driver_run_timeout_scales_with_multiplier(monkeypatch, mult, expected):
    """The driver's hardcoded 1800s must follow the multiplier the run claims.

    `driver/osa_headless.py` kills the episode at a fixed 1800s regardless of
    every Harbor multiplier, so an arm invoked at `--timeout-multiplier 2.0`
    recorded a doubled budget and enforced a single one. Unset/1.0/garbage all
    return None so the driver keeps its own default rather than having it
    restated -- an absent multiplier must not start writing an env var that was
    previously absent.
    """
    mod = _load_osa_agent()
    if mult is None:
        monkeypatch.delenv("OSA_BENCH_TIMEOUT_MULTIPLIER", raising=False)
    else:
        monkeypatch.setenv("OSA_BENCH_TIMEOUT_MULTIPLIER", mult)
    assert mod.driver_run_timeout() == expected


def test_driver_base_matches_the_driver_itself():
    """The base is duplicated across a container boundary; keep them equal.

    If the driver's default and this constant drift apart, the scaled deadline
    silently stops being 2x the real one.
    """
    mod = _load_osa_agent()
    src = (HERE / "driver" / "osa_headless.py").read_text()
    assert f'"OSA_BENCH_RUN_TIMEOUT", "{mod.DRIVER_RUN_TIMEOUT_BASE}"' in src


# ------------------------------------------- per-task deadline (grace margin)


def _trial_logs_dir(tmp_path, task_name: str):
    """A path shaped like Harbor's, i.e. `<job>/<task>__<suffix>/agent`."""
    d = tmp_path / f"{task_name}__AbCdEfG" / "agent"
    d.mkdir(parents=True)
    return d


def _write_task(root, name: str, timeout_sec: float):
    d = root / name
    d.mkdir(parents=True, exist_ok=True)
    (d / "task.toml").write_text(
        f'schema_version = "1.1"\n\n[agent]\ntimeout_sec = {timeout_sec}\n'
    )
    return d


def test_task_timeout_is_resolved_from_the_trial_directory_name(tmp_path, monkeypatch):
    """Harbor never tells an adapter its budget, but the path spells the task."""
    mod = _load_osa_agent()
    tasks = tmp_path / "tasks"
    _write_task(tasks, "some-task", 900.0)
    monkeypatch.setenv("OSA_TBENCH_TASKS_DIR", str(tasks))
    assert mod.task_declared_timeout(_trial_logs_dir(tmp_path, "some-task")) == 900.0


def test_unknown_task_resolves_to_none(tmp_path, monkeypatch):
    mod = _load_osa_agent()
    tasks = tmp_path / "tasks"
    tasks.mkdir()
    monkeypatch.setenv("OSA_TBENCH_TASKS_DIR", str(tasks))
    assert mod.task_declared_timeout(_trial_logs_dir(tmp_path, "absent")) is None


def test_driver_deadline_fires_before_harbors(tmp_path, monkeypatch):
    """The whole point: the driver must lose the race, so it can write telemetry.

    When Harbor's `wait_for` wins, the exec is cancelled where it stands -- no
    telemetry, no session cancel, no exit code -- and the trial is recorded as
    `no_telemetry_written` with its fault attribution lost. Measured before this
    fix: Harbor pre-empted the driver on 56 of TB 2.0's 89 tasks.
    """
    mod = _load_osa_agent()
    tasks = tmp_path / "tasks"
    _write_task(tasks, "short-task", 900.0)
    monkeypatch.setenv("OSA_TBENCH_TASKS_DIR", str(tasks))
    monkeypatch.setenv("OSA_BENCH_TIMEOUT_MULTIPLIER", "2.0")

    # Bound without Harbor's __init__, which needs a built release tarball.
    obj = object.__new__(mod.OsaAgent)
    obj._run_timeout_override = None
    obj.logs_dir = _trial_logs_dir(tmp_path, "short-task")

    harbor_deadline = 900.0 * 2.0
    assert obj._effective_run_timeout() < harbor_deadline


def test_explicit_override_is_honoured(tmp_path, monkeypatch):
    """An operator who passes a deadline gets exactly that deadline."""
    mod = _load_osa_agent()
    obj = object.__new__(mod.OsaAgent)
    obj._run_timeout_override = 123
    obj.logs_dir = _trial_logs_dir(tmp_path, "whatever")
    assert obj._effective_run_timeout() == 123


def test_ambiguous_task_name_refuses_to_guess(tmp_path, monkeypatch):
    """Two datasets disagreeing about a task's budget must resolve to unknown.

    Task names are NOT unique across the dataset copies on disk -- real case:
    `gpt2-codegolf` is 900s in TB 2.0 and 18000s elsewhere. Picking the larger
    one puts Harbor back in front of the driver, which is worse than not
    knowing, so disagreement resolves to None and the caller falls back.
    """
    mod = _load_osa_agent()
    monkeypatch.delenv("OSA_TBENCH_TASKS_DIR", raising=False)
    monkeypatch.delenv("OSA_BENCH_TASKS_DIR", raising=False)
    root = tmp_path / "tasks"
    _write_task(root / "ds-a", "clash", 900.0)
    _write_task(root / "ds-b", "clash", 18000.0)
    monkeypatch.setattr(mod, "HERE", tmp_path)
    assert mod.task_declared_timeout(_trial_logs_dir(tmp_path, "clash")) is None


def test_agreeing_datasets_still_resolve(tmp_path, monkeypatch):
    mod = _load_osa_agent()
    monkeypatch.delenv("OSA_TBENCH_TASKS_DIR", raising=False)
    monkeypatch.delenv("OSA_BENCH_TASKS_DIR", raising=False)
    root = tmp_path / "tasks"
    _write_task(root / "ds-a", "agree", 900.0)
    _write_task(root / "ds-b", "agree", 900.0)
    monkeypatch.setattr(mod, "HERE", tmp_path)
    assert mod.task_declared_timeout(_trial_logs_dir(tmp_path, "agree")) == 900.0
