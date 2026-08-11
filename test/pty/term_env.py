#!/usr/bin/env python3
"""Build a clean child environment for a terminal harness.

Why this is not just `os.environ.copy()`
----------------------------------------
Every harness here launches OSA inside some terminal, and OSA decides how to
erase its chrome on resize by looking at terminal-identity environment
variables (`resize_clear_strategy` in `event_loop.rs`: `$TMUX`, `$TERM`,
`$TERM_PROGRAM`, `$VTE_VERSION`).

Those variables describe the terminal the HARNESS is running in, not the one it
is launching. Inheriting them wholesale means the child is told it is somewhere
it is not.

That was not hypothetical. `vte_resize.py` inherited the developer's
environment verbatim, and this repo's development happens inside tmux, so every
"OSA passes under real VTE" run had `TMUX` set in the child and was in fact
exercising the multiplexer branch. The VTE harness had never once tested the
path it existed to test.

So: strip the identity of the OUTER terminal and let the terminal under test
set its own. Anything the harness deliberately wants passed through (the
`OSA_RESIZE_CLEAR` override the matrix uses to force a branch) is opt-in.
"""

from __future__ import annotations

import os

# Variables that name the terminal the harness happens to be sitting in. Any of
# these leaking into the child is a false identity.
IDENTITY_VARS = (
    "TMUX",
    "TMUX_PANE",
    "TMUX_PLUGIN_MANAGER_PATH",
    "TERM",
    "TERM_PROGRAM",
    "TERM_PROGRAM_VERSION",
    "VTE_VERSION",
    "WEZTERM_PANE",
    "WEZTERM_UNIX_SOCKET",
    "WEZTERM_EXECUTABLE",
    "WEZTERM_EXECUTABLE_DIR",
    "GHOSTTY_RESOURCES_DIR",
    "GHOSTTY_BIN_DIR",
    "KITTY_WINDOW_ID",
    "ALACRITTY_WINDOW_ID",
    "ALACRITTY_SOCKET",
    "COLORTERM",
    # A stale size would be read in preference to the real one.
    "LINES",
    "COLUMNS",
)


def clean_env(**extra: str) -> dict[str, str]:
    """A copy of the environment with the outer terminal's identity removed.

    `extra` is merged last, so a harness can add `OSA_BASE_URL` or force a
    branch with `OSA_RESIZE_CLEAR` without having to reason about ordering.
    """
    env = {k: v for k, v in os.environ.items() if k not in IDENTITY_VARS}
    env.update(extra)
    return env


def clean_env_list(**extra: str) -> list[str]:
    """`clean_env` as the `KEY=VALUE` list that `Vte.spawn_sync` wants."""
    return [f"{k}={v}" for k, v in clean_env(**extra).items()]


def passthrough_override() -> dict[str, str]:
    """Forward `OSA_RESIZE_CLEAR` to the child when the caller set it.

    This is how `reflow_matrix.py`-style A/B runs force OSA down one branch on a
    terminal where the other is the default, which is the only way to show that
    the gate's table is keyed on the right terminals rather than merely passing
    by accident.
    """
    val = os.environ.get("OSA_RESIZE_CLEAR")
    return {"OSA_RESIZE_CLEAR": val} if val else {}


def sh_env_prefix(**extra: str) -> str:
    """An `env -u … K=V` prefix that sanitizes identity from INSIDE a shell.

    Some terminals do not spawn the child from the harness's own process — a
    `wezterm cli spawn` is executed by an already-running mux server, so it
    inherits THAT process's environment and nothing the harness sets locally
    reaches the child. The only reliable channel left is the command line, so
    the sanitization travels as part of the command.
    """
    import shlex

    parts = ["env"]
    for var in IDENTITY_VARS:
        # TERM is deliberately not unset: the terminal under test is expected to
        # provide its own, and a child with no TERM at all is a different and
        # uninteresting configuration.
        if var == "TERM":
            continue
        parts += ["-u", var]
    for k, v in extra.items():
        parts.append(f"{k}={shlex.quote(v)}")
    return " ".join(parts)
