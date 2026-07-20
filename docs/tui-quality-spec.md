# OSA TUI Quality Spec — best-in-class transcript rendering

Synthesized from four references studied 2026-07-20: Claude Code (`Ink/TSX` + a Rust
`color-diff-napi`), Codex (`codex-rs/tui`), grok-build (`xai-grok-pager`, Rust/ratatui),
opencode (`packages/tui`, tree-sitter). Goal: everything they have, better, and more.

## Cross-reference truth
EVERY high-quality reference syntax-highlights the code INSIDE diffs, foreground-only,
with the +/- band as background. Codex + grok + CC use syntect; opencode uses
tree-sitter. OSA is the only one that does NOT (render/diff.rs has gutter + word-highlight
+ hunk separators but no language coloring, though render/syntax.rs is a full syntect
highlighter already present). This is gap #1.

---

## TIER 1 — file edits / diffs (the core complaint: "edits feel low quality")

1. **Syntax-highlight code inside diffs** [IN PROGRESS]. fg-only syntect spans over the
   +/- background band. Keep the gutter (line number + sigil) and word-level highlights.
   - CC word-diff threshold = **0.4**: only word-highlight a paired line when change
     ratio <= 0.4; above that, full-line highlight (OSA has WORD_DIFF_CHANGE_THRESHOLD;
     confirm it is 0.4). Two-tier bg: whole changed line light band, changed words darker.
   - CC exact colors (light): diffAdded rgb(105,219,124), diffRemoved rgb(255,168,180),
     addedWord rgb(47,157,68), removedWord rgb(209,69,75). Dark: diffAdded rgb(34,92,43),
     removed rgb(122,41,54), words rgb(56,166,96)/rgb(179,89,107). Colorblind: green->blue.
   - grok bands are very dark/low-sat (tokyonight insert bg rgb(15,65,20)) so syntax stays
     readable; "bandless" themes instead paint solid whole-line red/green fg and skip syntax.
   - **Progressive highlight** (grok EditHighlightPhase): paint hunk-only syntect first,
     then a background worker does a full-file pass keyed by new-line-number so multi-line
     scopes (open block comments/strings above the hunk) color right. Caps 2MiB / 50k lines.
2. **Semantic edit header** (CC + grok): bold verb (`Create`/`Edit`, `Updated plan` for
   plan files) + path in accent/orange (basename when collapsed, cwd-relative), + diffstat
   on the collapsed one-liner: `+N` green `/` muted `-M` red (grok) or CC's bold
   `Added N lines, removed M lines`. Suppress diffstat on multi-file/untrusted. OSC-8
   hyperlink on the path span only.
3. **Colored line-number gutter** (grok): tint the number by insert/delete, not only the
   +/- sigil. Right-aligned, width = max_line.ilog10()+1, 2-space content gap.

## TIER 2 — "it's alive" flow (highest motion impact)

4. **Animated luminance-wave accent rail** (grok, steal this first): running cells paint a
   `┃` (U+2503; `│` legacy) left rail with brightness = sin^2((row/wave_rows)*2pi +
   tick*speed), blended bg->accent. A luminance wave travels down the active cell's rail.
   Running=green wave, success=solid green, error=solid red, pending-on-user=frozen full.
   Collapsed=dim thin char. Cheap, reads instantly as working.
5. **Live turn-status line** (grok + CC): spinner (grok braille `⠋⠙⠹⠸⠼⠴⠦⠧` ~7.5fps, or CC
   ping-pong) + activity-colored label (green when a tool runs with empty label since the
   cell shows detail; gray `Thinking…`/`Responding…`; yellow `Retrying (attempt N)…`; red
   `Cancelling…`) + dual timers (phase-elapsed + turn-elapsed, `1m20s`) + token counter
   `⇣12k` (CC: only after 30s, smooth-eased not jumping) + `esc to interrupt` + inline
   `[stop]`/`[↓ bg]` on mouse hosts. CC stall->red: no tokens ~3s interpolates spinner to
   error red. Isolate the animated leaf so only it repaints (~383x/turn), not the transcript.
6. **Goal + elapsed indicator** (Codex thread_goal_actions + status_indicator): show the
   active goal and how long it has been active (`fmt_elapsed_compact`: 12s / 3m 40s /
   1h 05m 22s); pause/resume across restarts.

## TIER 3 — structure & consistency

7. **Turn separators** (Codex separators.rs): muted rule between turns for visual rhythm.
   OSA has none.
8. **Uniform cell/block system** (grok BlockContent trait): one block per action type
   (edit/exec/read/search/list/mcp/web/hook) implementing output/accent/background/
   is_foldable/next_fold_mode with DisplayMode {Collapsed, Truncated, Expanded}. The rail +
   bullet (grok `◆` diamond; CC `●`/`⏺`) are painted by the WRAPPER, not the block.
   **Verb-group folding**: collapse consecutive non-destructive rows into `Read 3 files`,
   `Searched 4 patterns` (present tense while running).
9. **Exec cells** (grok execute.rs + CC): header `$ ` dim + syntax-highlighted bash (or
   `Run <description>`, strip leading "Run"); streamed output on a subtle panel bg; first/
   last-line truncation with a muted `…` line (CC: 3 lines then `… +N lines (ctrl+o to
   expand)`); status by rail color not inline glyph; duration in the status line. CC extras:
   pretty-print JSON output lines, OSC-8 linkify URLs, strip leaked underline ANSI.

## TIER 4 — cross-terminal fidelity + the split-pane bug

10. **Glyph + legacy fallback + color quantization** (grok glyphs.rs): every decorative
    glyph has a CP437/legacy fallback of identical column width (`✓`->`√`, `✗`->`x`,
    `┃`->`│`, `◆`->`♦`, braille->`|/-\`); all colors quantize to truecolor/256/16/none.
11. **Hand-rolled SGR parser** for ANSI in exec output, theme-aware + quantized (grok
    render/terminal_output.rs) rather than a generic ansi-to-tui pass.
12. **Resize reflow** (Codex resize_reflow.rs): fixes the split-pane "gets all f***ed up"
    bug on terminal resize.
13. **MCP elicitation** (Codex mcp_server_elicitation): a server can request input mid-tool.

## BETTER + MORE (beat them)
OSA already exceeds all four on: LaTeX rendering, 35 dialogs, reverse-search history, vim
mode, backtrack-to-edit. Combine grok's wave-rail + CC's exact diff colors + Codex's
goal-flow + a semantic edit header richer than any single one of them.

## Status
render/syntax.rs (syntect) exists; render/diff.rs being wired for TIER-1.1 now.
Build order: T1 (diffs) -> T2 (wave rail + status line + goal) -> T3 (separators + uniform
cells + exec) -> T4 (fidelity + reflow). Each phase gates cargo build+test, ships in a release.
