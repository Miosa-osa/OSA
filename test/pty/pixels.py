#!/usr/bin/env python3
"""Count OSA's chrome bands from a SCREENSHOT, for terminals with no text API.

Why this is needed at all
-------------------------
Every other harness reads the terminal's own screen model back out: tmux has
`capture-pane`, WezTerm `cli get-text`, kitty `@ get-text`, Ghostty
`write_scrollback_file`, xterm `print-everything()`. **Alacritty has none** —
no control socket, no IPC, no escape sequence that reports contents — and
Alacritty is precisely the terminal the resize gate's residual risk was written
about. Leaving it unmeasured leaves the one case the gate might get wrong
unmeasured.

So it is counted from pixels.

What is counted, and why it is a sound proxy
--------------------------------------------
OSA's live region is delimited by **full-width horizontal rules** — a row of
`─` box-drawing characters spanning the whole terminal width. Rendered, that is
a nearly-continuous horizontal line of foreground pixels across essentially
every column of a single scanline. Nothing else OSA draws does that: prose and
the composer's own text reach maybe half the columns, because glyphs have gaps
between them and the lines are not full.

So: threshold the window against its background colour, measure each pixel
row's foreground coverage, and call a row a *rule row* when coverage clears
`RULE_COVERAGE`. Adjacent rule rows belong to one drawn line (a box-drawing
rule is one to three pixels tall at normal font sizes), so they are merged into
*rule bands*. **One rule band per horizontal rule OSA drew.**

Stranded chrome is exactly a repeat of that structure further up the screen, so
counting rule bands counts copies of the live region — which is the assertion
this harness family exists to make.

Why it is not trusted on its own
--------------------------------
A derived measurement that nobody checked is how this investigation went wrong
the first time: `test_resize.py` reported clean for months because pyte does
not reflow. So this module is **cross-validated against kitty**, where the
exact text count IS available: `alacritty_resize.py --calibrate` runs the same
drag under kitty, counts bands both ways, and refuses to proceed if the pixel
count disagrees with the text count. A pixel counter that has drifted out of
agreement with ground truth fails loudly instead of reporting a comfortable
number.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

# Fraction of a row's columns that must be foreground for it to be a rule row.
# A full-width `─` rule covers essentially all of them; the densest text row
# OSA draws covers roughly half. The gap between those is wide, so the exact
# value is not delicate.
RULE_COVERAGE = 0.85

# How far a pixel must sit from the background colour to count as foreground.
# Terminals antialias glyph edges, so an exact-match test would miss the soft
# shoulders of a thin box-drawing line.
FOREGROUND_DELTA = 40


def _pil():
    try:
        from PIL import Image, ImageGrab  # noqa: F401

        return Image, ImageGrab
    except Exception as exc:  # pragma: no cover - environment dependent
        raise RuntimeError(f"Pillow is required for pixel band counting: {exc}") from exc


def grab(bbox: tuple[int, int, int, int]):
    """Screenshot the rectangle `(x, y, w, h)` in root coordinates.

    Uses Pillow's X11 grabber. `xwd` is the fallback everyone reaches for, but
    it writes a format Pillow cannot open, so it would need a hand-rolled
    parser for no benefit.
    """
    _Image, ImageGrab = _pil()
    x, y, w, h = bbox
    return ImageGrab.grab(bbox=(x, y, x + w, y + h), xdisplay="")


def background_value(gray) -> int:
    """The most common grey level — the terminal's background."""
    hist = gray.histogram()
    return max(range(len(hist)), key=lambda i: hist[i])


def row_coverage(img) -> list[float]:
    """Foreground coverage of each pixel row, in one pass.

    The whole row-reduction is done by `resize((1, h), BOX)`: a box filter down
    to a single column averages every row, so the per-row mean arrives from one
    C call instead of a Python loop over a million pixels. Without numpy that
    difference is the difference between a usable harness and a 30-second one.
    """
    Image, _ = _pil()
    gray = img.convert("L")
    bg = background_value(gray)
    # 255 where the pixel is far enough from the background to be ink.
    mask = gray.point(lambda p: 255 if abs(p - bg) > FOREGROUND_DELTA else 0)
    w, h = mask.size
    if w == 0 or h == 0:
        return []
    col = mask.resize((1, h), Image.BOX)
    return [col.getpixel((0, y)) / 255.0 for y in range(h)]


def rule_bands(img, coverage: float = RULE_COVERAGE) -> list[tuple[int, int]]:
    """Contiguous runs of rule rows — one per horizontal rule actually drawn."""
    rows = row_coverage(img)
    bands: list[tuple[int, int]] = []
    start: int | None = None
    for y, c in enumerate(rows):
        if c >= coverage:
            if start is None:
                start = y
        elif start is not None:
            bands.append((start, y - 1))
            start = None
    if start is not None:
        bands.append((start, len(rows) - 1))
    return bands


def count_rule_bands(bbox: tuple[int, int, int, int], save_to: Path | None = None,
                     coverage: float = RULE_COVERAGE) -> tuple[int, list[tuple[int, int]]]:
    """Screenshot `bbox`, optionally save it, and count its rule bands.

    The image is saved either way when `save_to` is given: on this class of bug
    the screen IS the evidence, and a number with no picture behind it is what
    made the earlier "OSA survives on Ghostty" claim unfalsifiable.
    """
    img = grab(bbox)
    if save_to is not None:
        save_to.parent.mkdir(parents=True, exist_ok=True)
        img.save(save_to)
    bands = rule_bands(img, coverage=coverage)
    return len(bands), bands


def have_display() -> bool:
    import os

    return bool(os.environ.get("DISPLAY"))


def have_pillow() -> bool:
    try:
        _pil()
        return True
    except Exception:
        return False


def xdotool_present() -> bool:
    return subprocess.run(["which", "xdotool"], capture_output=True).returncode == 0
