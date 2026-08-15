"""Import this package's own modules under a name that cannot be captured.

## Why this exists

`bench/` holds five sibling directories that are not packages -- `swebench`,
`swebenchpro`, `terminalbench`, `recoverybench`, `headtohead` -- plus
`bench/report`, which pytest sees as a namespace package. They share top-level
basenames on purpose, because they do the same jobs:

    run_bench.py   swebench, swebenchpro, terminalbench, recoverybench
    report.py      swebench, terminalbench   (and the DIRECTORY bench/report)
    runners.py     swebench, swebenchpro
    evaluate.py    swebench, swebenchpro
    workspace.py   swebench, swebenchpro

Each test file prepends its own directory to `sys.path`, and pytest prepends it
again, so under one session `import report` resolves to whichever directory was
prepended last -- a function of collection order and nothing else. Measured
2026-08-15 from `bench/`:

  * `swebenchpro`'s `TestProviderFailureAttribution` was handed
    `terminalbench/run_bench.py` and failed with `AttributeError: module
    'run_bench' has no attribute '_relabel_provider_failures'`. Reverse the
    order and `terminalbench/test_pinning.py` fails instead. Each suite passes
    alone, which is why it survived.
  * under `--import-mode=importlib`, pytest registers a namespace module named
    `report` for `bench/report/`, and `terminalbench`'s `import report` then
    silently got a module with no `build`, no `_fault_owner` and no
    `_reconcile_spend`.

An `AttributeError` is the lucky outcome. Two modules that happen to share an
attribute name produce a silently wrong assertion instead.

## What this does about it

`load(name)` executes `bench/terminalbench/<name>.py` from its absolute path
under the alias `terminalbench_<name>`, which nothing else can claim. Two
further things are necessary and neither is obvious:

  * **`sys.path` is pinned during the exec.** Loading by path fixes which file
    runs; it says nothing about what the file's own body resolves, and
    `run_bench.py` bare-imports `datasets`, `probeset` and `report`. The
    directory goes to the front for the exec and the path is restored after --
    leaving it prepended would be the same defect pointing the other way.
  * **Foreign bare names are stashed out of `sys.modules` during the exec.**
    `sys.path` order is irrelevant once `sys.modules` already holds the name,
    which is exactly the `bench/report` case above. Anything already registered
    under a basename this package also defines, and not loaded from this
    directory, is removed for the duration and put back afterwards.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

#: Every top-level name this package defines. Anything on this list that is
#: already in `sys.modules` from somewhere else is a shadow.
_OURS = frozenset(p.stem for p in HERE.glob("*.py") if not p.stem.startswith("_"))


def _is_foreign(mod) -> bool:
    """True if `mod` was not loaded from this directory.

    Namespace modules (pytest's `report` stand-in for `bench/report/`) have
    `__file__ is None`, and those are foreign by definition: this package ships
    no namespace packages.
    """
    f = getattr(mod, "__file__", None)
    if f is None:
        return True
    try:
        return Path(f).resolve().parent != HERE
    except (OSError, ValueError):
        return True


def load(name: str):
    """Import `bench/terminalbench/<name>.py` as `terminalbench_<name>`."""
    alias = f"terminalbench_{name}"
    if alias in sys.modules:
        return sys.modules[alias]
    path = HERE / f"{name}.py"
    if not path.exists():
        raise ImportError(f"bench/terminalbench/{name}.py not found at {path}")
    spec = importlib.util.spec_from_file_location(alias, path)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    # Registered before exec so a cycle through a sibling resolves rather than
    # recursing, the same reason `swebenchpro/shared.py` does it.
    sys.modules[alias] = mod

    saved_path = list(sys.path)
    sys.path.insert(0, str(HERE))
    stashed = {
        n: sys.modules.pop(n)
        for n in list(sys.modules)
        if n in _OURS and _is_foreign(sys.modules[n])
    }
    try:
        spec.loader.exec_module(mod)
    except BaseException:
        # A half-initialised module left in `sys.modules` is worse than no
        # module: the next caller gets it without an error.
        sys.modules.pop(alias, None)
        raise
    finally:
        sys.path[:] = saved_path
        sys.modules.update(stashed)
    return mod
