---
name: frontend-quality
description: Build, debug, review, or polish user interfaces with responsive layout, accessibility, and pixel-level visual verification. Use for frontend components, browser UI, terminal UI, resize defects, visual regressions, and interaction problems.
tools:
  - file_read
  - file_grep
  - file_glob
  - file_edit
  - shell_execute
  - computer_use
triggers:
  - frontend
  - user interface
  - visual bug
  - resize
  - responsive
  - tui
---

# Frontend Quality

Treat the rendered interface as the product, not merely the source code.

## Procedure

1. Reproduce the current interface in the real browser, terminal, or device surface.
2. Capture the relevant viewport size, state, interaction, and screenshot.
3. Trace layout ownership before editing styles or rendering code.
4. Check narrow, typical, and wide sizes plus content extremes.
5. Preserve hierarchy, spacing rhythm, readable typography, and clear interaction states.
6. Verify keyboard use, focus, contrast, labels, and reduced-motion behavior where applicable.
7. Add an automated visual, component, PTY, or interaction regression when the harness supports it.
8. Re-run the original interaction and inspect the pixels directly.

## Resize and terminal interfaces

- Derive layout from the current frame size rather than stale cached dimensions.
- Keep one authoritative render path for initial draw and resize replay.
- Do not duplicate committed content while redrawing live regions.
- Verify rapid repeated resizes, not only one final resize event.
- Test narrow widths where wrapping changes row counts.

## Completion evidence

Provide the tested dimensions and interaction, not only a successful compilation.
