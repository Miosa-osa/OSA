# Streaming output and wide-content reader

OSA's terminal renderer is shared by all providers. It changes presentation,
not model effort, tool budgets, provider requests, or stored assistant text.

## Reading long or wide output

- **Ctrl+O** opens a transcript snapshot, including the unfinished assistant
  block. Generation continues behind the reader. If a tool result is collapsed,
  the first Ctrl+O expands it; press Ctrl+O again for the transcript.
- **w** switches between wrapped reading and preserved-layout source. The latter
  keeps diagram spacing and table columns; tabs expand to four-column stops.
- **Left/Right** pan horizontally in preserved-layout mode.
- **Up/Down, PageUp/PageDown, Home/End** navigate vertically; **/** searches.
- **y** copies the selected message, **Y** copies the full transcript.
- **Esc** or **Ctrl+O** closes the reader. Reopen to refresh the snapshot.

Fenced `ascii`, `diagram`, `text`, `plaintext`, and `mermaid` blocks keep their
row layout in the inline preview. Wide blocks show a reader hint rather than
wrapping diagram rows into a misleading shape. Mermaid is displayed as source;
this is not a graphical Mermaid engine. Ordinary language-tagged code continues
to wrap. The reader always retains the original full source.

## Streaming rules

- The cursor is drawn after Markdown parsing and never adds a wrapping row.
- Unfinished emphasis and links use a provisional display; stored source and
  final rendering remain authoritative, including genuinely unmatched markup.
- Table proportions are established from the header and first data row. Later
  values wrap within those proportions instead of moving preceding columns.
- Incomplete pipe-table rows stay pending until a row boundary is available.
- A continuation does not reserve a second, invisible assistant-header row.
- Code fences use matching marker types and lengths for rendering and settling.
- Scrollback safety checks remain enabled; the snapshot reader provides access
  to blocks that cannot yet be committed safely.

## Verification

Rust tests cover parser correctness, streaming prefixes, layout, sizing,
long-reader caching, and preserved-layout rows. Run in a color-capable test
environment when exercising tests that explicitly assert color/link support:

```sh
env -u NO_COLOR TERM=xterm-256color COLORTERM=truecolor cargo test
```

Run from `priv/rust/tui`. Actual application behavior still honors `NO_COLOR`.

The PTY probes in `test/pty/stream_paint_probe.py` and
`test/pty/rich_output_probe.py` exercise a real TUI binary against a local stub.
Use a disposable `OSA_PTY_HOME`, a Python environment with `pyte`, and the
`--binary` option. The streaming probe rejects runs where its turns were never
submitted. See the PTY README for terminal-emulator coverage limitations.
