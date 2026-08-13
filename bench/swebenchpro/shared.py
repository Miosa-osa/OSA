"""Load the reusable halves of `bench/swebench` under unambiguous names.

Both benchmark packages have a `runners.py`, an `evaluate.py` and a
`workspace.py`, because they do the same jobs. Putting either directory on
`sys.path` and saying `import runners` therefore resolves to whichever
directory happens to be earlier, and the loser silently gets the wrong module
-- including the case where `bench/swebenchpro/runners.py` imports *itself* and
receives a half-initialised module object with no error.

That is not a hypothetical: the first version of this package did exactly that,
and it presented as `AttributeError: module 'runners' has no attribute
'CONTEXT_MODES'` rather than as an import problem.

So nothing here relies on path order. Each shared module is loaded from its
absolute file path under a `swebench_` prefix, which cannot collide, and is
registered in `sys.modules` under that name. `osa_runner` and `report` are the
exceptions: they import their own siblings by bare name (`import airgap`,
`from runners import ...`), so `bench/swebench` must be on `sys.path` for them
-- it is appended at the *end*, where it cannot shadow ours.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

SWEBENCH_DIR = Path(__file__).resolve().parent.parent / "swebench"


def _ensure_swebench_on_path() -> None:
    """Append (never prepend) bench/swebench, for its internal bare imports.

    "Behind us" is deliberately measured against every spelling of our own
    directory that could be on the path, including the relative `.` and `''`
    that an interactive `sys.path.insert(0, '.')` leaves behind. Taking
    `sys.path.index()` of the absolute form alone raised ValueError in exactly
    that case.
    """
    here = Path(__file__).resolve().parent
    ours = {str(here), ".", "", str(here) + "/"}
    p = str(SWEBENCH_DIR)
    if p in sys.path:
        first_ours = next(
            (i for i, entry in enumerate(sys.path) if entry in ours), len(sys.path)
        )
        if sys.path.index(p) < first_ours:
            sys.path.remove(p)
            sys.path.append(p)
        return
    sys.path.append(p)


def _load(name: str):
    """Import bench/swebench/<name>.py as `swebench_<name>`."""
    alias = f"swebench_{name}"
    if alias in sys.modules:
        return sys.modules[alias]
    _ensure_swebench_on_path()
    path = SWEBENCH_DIR / f"{name}.py"
    if not path.exists():
        raise ImportError(f"bench/swebench/{name}.py not found at {path}")
    spec = importlib.util.spec_from_file_location(alias, path)
    mod = importlib.util.module_from_spec(spec)
    # Registered before exec so that a module importing itself by alias (or a
    # cycle through report -> diagnose) resolves rather than recurses.
    sys.modules[alias] = mod
    spec.loader.exec_module(mod)
    return mod


# The Task/RunResult/git_diff contracts, shared so the two benchmarks cannot
# disagree about what "the patch the agent produced" means.
sb_runners = _load("runners")
# The results schema (SCHEMA_VERSION, aggregate block) that bench/report/ reads.
sb_report = _load("report")
# Failure buckets and the harness-vs-model fault attribution.
sb_diagnose = _load("diagnose")
# Web-lookup prevention: deny-list settings file + live differential probe.
sb_airgap = _load("airgap")


def osa_runner_class():
    """`bench/swebench/osa_runner.OsaRunner`, imported lazily.

    Lazy because it needs `requests`, and the gold/gold-apply/empty controls
    must stay dependency-free: a control that cannot run when the agent's deps
    are broken is not much of a control.
    """
    return _load("osa_runner").OsaRunner
