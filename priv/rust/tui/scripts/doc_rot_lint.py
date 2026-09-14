#!/usr/bin/env python3
"""Fail if a comment cites a Rust symbol that no longer exists.

# The defect this catches

`event_loop.rs:3034` (as of v1.0.189) documented the bottom-alignment padding
in `replay_scrollback` by saying the shape it guards against is "the region
rebuilt at the TOP … which `assert_chrome_bottom_anchored` exists to catch" —
naming a test. That test did not exist anywhere in the tree. A comment had
been "guarding" production code by pointing at a deleted (or never-written)
test, and nothing detected the drift: the comment reads exactly as
authoritative whether or not the thing it cites is real.

This is a doc-rot lint for that specific failure mode: a backtick-quoted
identifier, in a comment, that looks like it names a Rust function or test,
but does not resolve to any symbol actually defined in the source tree.

# Scope and false-positive strategy

Comments constantly name real things (types, methods, other comments' prose)
that are not top-level `fn`/`macro_rules!` definitions, and a lint that flagged
every backtick-quoted word would be mostly noise a human has to keep
triaging — which is worse than no lint, because it trains people to ignore its
output. Three restrictions keep this cheap and near-zero-false-positive:

  1. Only identifiers matching `assert_*` or `test_*` are considered
     candidates. Those two prefixes are exactly the ones a "this test/assertion
     exists to catch X" comment uses to name what it is pointing at — the
     pattern that rotted here — and virtually nothing else in this codebase's
     comments is named that way (verified: sweeping the whole `assert_`/`test_`
     backtick-identifier space across `src/` at the time this lint was written
     found exactly one hit, and it correctly names a Python PTY test — see the
     allowlist below).
  2. A candidate only counts as an offender if it is ALSO not present anywhere
     as plain (non-backtick) text in the tree — i.e. it never resolves even to
     a symbol defined in a different crate/file naming convention this script
     doesn't parse (e.g. a macro-generated fn, or a name that legitimately
     lives in a sibling test harness in another language). This keeps the
     check to "does this identifier appear ANYWHERE as a real definition or
     reference", not "did I correctly parse Rust".
  3. An explicit allowlist file (`doc_rot_allowlist.txt`, one identifier per
     line, `#`-comments allowed) covers legitimate references to symbols this
     script cannot see — non-Rust test names (the PTY suite is Python), symbols
     behind a `cfg` this script does not evaluate, generated code, etc.

# What "resolves" means here

A candidate resolves if `IDENT` appears in the tree as:
  - `fn IDENT` or `macro_rules! IDENT` in any `.rs` file under `priv/rust/tui/src`
    (a real, findable Rust definition), OR
  - the literal text `IDENT` anywhere under `test/` (covers the PTY suite,
    written in Python, which the doc comments in `src/` legitimately cite by
    name), OR
  - is present in the allowlist file.

Anything else is reported as rot: a comment naming something that does not
exist, exactly the failure this lint exists to catch.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
TUI_ROOT = SCRIPT_DIR.parent
SRC_ROOT = TUI_ROOT / "src"
REPO_ROOT = TUI_ROOT.parent.parent.parent
TEST_ROOT = REPO_ROOT / "test"
ALLOWLIST_PATH = SCRIPT_DIR / "doc_rot_allowlist.txt"

# Conservative: only names shaped like the "this exists to catch it" pattern
# doc comments actually use in this codebase. See the module docstring for why
# this is deliberately narrow rather than "any backtick-quoted snake_case".
CANDIDATE_RE = re.compile(r"`((?:assert|test)_[a-zA-Z0-9_]*)`")

# A definition: `fn name` or `macro_rules! name`, anywhere in the Rust source.
DEFINITION_RE = re.compile(r"\b(?:fn|macro_rules!)\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*[(!<{]?")

COMMENT_PREFIXES = ("//", "///", "//!", "*", "/*")


def load_allowlist() -> set[str]:
    if not ALLOWLIST_PATH.exists():
        return set()
    names = set()
    for line in ALLOWLIST_PATH.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            names.add(line)
    return names


def iter_rust_files(root: Path):
    yield from sorted(root.rglob("*.rs"))


def collect_definitions(rust_files: list[Path]) -> set[str]:
    defined: set[str] = set()
    for path in rust_files:
        text = path.read_text(encoding="utf-8", errors="ignore")
        for m in DEFINITION_RE.finditer(text):
            defined.add(m.group(1))
    return defined


def collect_test_tree_text(test_root: Path) -> str:
    if not test_root.exists():
        return ""
    chunks = []
    for path in test_root.rglob("*"):
        if path.is_file():
            try:
                chunks.append(path.read_text(encoding="utf-8", errors="ignore"))
            except OSError:
                continue
    return "\n".join(chunks)


def find_candidates(rust_files: list[Path]):
    """Yield (identifier, file, line_no, line_text) for every backtick-quoted
    assert_*/test_* identifier found inside a comment line."""
    for path in rust_files:
        text = path.read_text(encoding="utf-8", errors="ignore")
        for i, line in enumerate(text.splitlines(), start=1):
            stripped = line.strip()
            if not stripped.startswith(COMMENT_PREFIXES):
                continue
            for m in CANDIDATE_RE.finditer(line):
                yield m.group(1), path, i, stripped


def main() -> int:
    if not SRC_ROOT.exists():
        print(f"doc_rot_lint: source root not found: {SRC_ROOT}", file=sys.stderr)
        return 2

    rust_files = list(iter_rust_files(SRC_ROOT))
    if not rust_files:
        print(f"doc_rot_lint: found no .rs files under {SRC_ROOT}", file=sys.stderr)
        return 2

    defined = collect_definitions(rust_files)
    test_text = collect_test_tree_text(TEST_ROOT)
    allowlist = load_allowlist()

    offenders = []
    for ident, path, line_no, line_text in find_candidates(rust_files):
        if ident in defined:
            continue
        if ident in allowlist:
            continue
        if test_text and ident in test_text:
            continue
        offenders.append((ident, path, line_no, line_text))

    if not offenders:
        print(f"doc_rot_lint: OK — checked {len(rust_files)} files, "
              f"no dangling assert_*/test_* references found")
        return 0

    print("doc_rot_lint: comments cite Rust symbols that do not exist:\n")
    for ident, path, line_no, line_text in offenders:
        rel = path.relative_to(REPO_ROOT) if path.is_relative_to(REPO_ROOT) else path
        print(f"  {rel}:{line_no}: `{ident}`")
        print(f"      {line_text}")
    print(
        "\nEach identifier above is quoted in a doc comment as if it names a "
        "real fn/macro/test, but it resolves to none of: a `fn`/`macro_rules!` "
        "in priv/rust/tui/src, any file under test/, or "
        f"{ALLOWLIST_PATH.relative_to(REPO_ROOT)}.\n"
        "Either write the thing the comment claims exists, correct the comment "
        "to name what actually exists, or add the identifier to the allowlist "
        "if it is a legitimate reference this script cannot resolve."
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
