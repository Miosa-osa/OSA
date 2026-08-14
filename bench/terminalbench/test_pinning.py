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

import report as report_mod  # noqa: E402


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

    def dotenv(self) -> str:
        return self._cls._dotenv(self)

    def config_toml(self):
        return self._cls._config_toml(self)


# --------------------------------------------------------------- effort pin


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
