# Rich-output audit

## Implemented in this pass

- The escape-aware cell painter now applies line styles across the complete
  row, then overlays token styles. Fenced diagram backgrounds no longer stop
  at each line's last character. Blank rows and wide-character continuation
  cells receive the same panel background. Existing diagram dimensions stay.
- Truncation stops the whole line at a straddling wide character, rather than
  skipping that character and incorrectly displaying a later span.
- Markdown image references become labeled links with visible targets. Local
  relative paths resolve against the TUI working directory. HTTP, HTTPS, and
  file links are supported; other schemes use an unavailable-preview label.
  Complete data-URI image references do not dump their payload into the view.
  No rendering operation fetches, decodes, or automatically opens the image.
- Full and lean prompt templates describe diagram fencing and real image
  artifacts, and distinguish Mermaid source from graphical rendering.

## Remaining work, not implied by these fixes

1. Structured media results: the tool executor currently reduces image results
   to `[image: path]` for display. Preserve artifact identity, MIME type,
   provenance, dimensions, and a session-scoped reference through SSE and the
   transcript store. Markdown links are a fallback, not that transport.
2. Pixel previews: `render/mod.rs` still has only a commented image module.
   Select a terminal graphics protocol using capability detection; account for
   tmux, SSH, resizing, scrollback, and unsupported terminals. Keep an explicit
   user-controlled viewer with the current link fallback. Bound bytes, pixel
   count, decode work, and cache size before loading untrusted images.
3. Generated-image UX: distinguish pending, completed, cancelled, and failed
   generation; support multiple outputs and explicit open/save actions. Only
   report a generated image after an actual tool artifact exists. Image display
   does not itself add an image-generation provider.
4. Other artifacts: PDFs, video, audio, HTML, and SVG need typed cards and
   explicit viewers. Never execute active content merely to render a response.
5. Theme coverage: the cell tests verify style inheritance, but do not prove
   perceptual contrast in every user theme. Inspect dark/light/high-contrast,
   ANSI-16/256, NO_COLOR, and terminal transparency separately.
6. Wider visual matrix: tables, nested lists, quotes, diffs, math, long fenced
   blocks, images, and interrupted streams need combined golden fixtures across
   widths and terminal emulators. Existing PTY probes are useful but not a
   universal graphics or accessibility certification.

## Verification

`render::cells` tests exercise the final painter, not just Markdown's intermediate
line styles. `test/pty/rich_panel_probe.py` checks terminal background cells in
both the live and settled diagram, including a blank row. The existing rich
reader and streaming probes cover pan/resize and streaming text integrity.
