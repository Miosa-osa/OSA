# OSA TUI — model-output rendering

**Status:** design specification. Nothing here is implemented unless a section says so.

**Scope:** how model output becomes rows on screen — assistant markdown, reasoning/thinking,
file-edit diffs, and hook outcomes. This document is deliberately *not* about OSA's visual
identity. The header row, the `◈ OSA` label, the thick left rail on agent messages, the
turn-status line, the composer and the hint bar all stay exactly as they are. What is
specified here is the **content layer**: the rules that turn a byte stream into styled lines.

Every glyph, column width, colour role, spacing rule and truncation rule is stated
explicitly, so this can be implemented without a screenshot. OSA citations are `path:line`
relative to `priv/rust/tui/` unless the path starts with `lib/`.

Where a mechanism was derived from studying a reference harness, it is stated here directly
as OSA's intended design. The reference is not named, reproduced or attributed.

**Contents**

- Part A — assistant markdown → rows
- Part B — thinking / reasoning display
- Part C — diff and edit rendering
- Part D — hook lifecycle and hook-outcome display
- Part E — what OSA already does well (keep it)
- Part F — ordered implementation plan, with the risky steps called out

---

# Part A — Assistant markdown → rows

## A.0 The two possible architectures, and which one OSA uses

There are exactly two ways to turn markdown into terminal rows, and the choice governs
everything downstream.

**(1) Rebuild.** Parse into blocks, then *construct* each output row from scratch: pick a
bullet glyph, pick an indent, pick how many blank rows separate two blocks. This is what OSA
does today (`render/markdown.rs:24`). The renderer owns the layout.

**(2) Source-faithful overlay.** Keep the model's own bytes as the substrate. Parse only to
learn *byte ranges*, then annotate those ranges with three kinds of overlay:

- a **highlight** — a style over a byte range, where one style bit (`HIDDEN`) is not a visual
  attribute at all but a marker meaning *erase this range when rendering prettily*;
- a **transform** — a character substitution over a byte range (`-` → `•`, `>` → `│`,
  `---` → `───`, `](` → ` (`, `[` → nothing);
- a **replacement** — a whole byte range swapped for pre-rendered content (a formatted table,
  a syntax-highlighted code block).

Then sweep left to right over the source, emitting `text[last..next_event]` verbatim, styled
by the merge of the currently-active highlights, splitting on `\n`. If every active highlight
is `HIDDEN`, skip the run entirely.

**OSA adopts architecture (2) for spacing and marker handling, while keeping architecture (1)
for tables and code blocks** (which are genuine replacements in either model). The reason is
narrow and specific, and it is the single most important idea in this document:

> **Under an overlay renderer, blank rows are the model's own blank lines. `k` consecutive
> newlines between two blocks produce `k − 1` blank rows — for every pair of block types,
> with no exceptions and no lookup table.**

That is what makes output feel airy instead of cramped. Models already emit `\n\n` between
blocks and `\n\n\n` where they want more air. A rebuilder throws that signal away and
substitutes a policy; an overlay renderer honours it. See §A.6 for the exact rule and the
three modifiers.

OSA does not need a full rewrite to get this. §F sequences the change so the spacing rule
lands first, on the existing line-oriented renderer, because that is where the visible win is.

## A.1 Element inventory

Below, "erase" means the marker bytes are not emitted (architecture (2)'s `HIDDEN`), and
"indent" is measured in display columns, not bytes.

### Headings

- **No prefix glyph. No underline rule. No uppercasing. No centring. No indent.**
- The marker run is the `#`s **and the spaces after them**, located as
  "everything up to the first character that is neither `#` nor space". That whole run is
  erased, so heading text starts at column 0.
- Heading text gets a per-level colour and per-level modifiers. The level index is
  `min(level - 1, 5)`, so `#######` clamps to h6 rather than panicking.
- OSA's level palette stays as it is (`render/markdown.rs:151-198`): h1 primary +
  `BOLD|UNDERLINED`, h2/h3 primary + `BOLD`, h4 secondary + `BOLD`, h5 muted, h6 muted +
  `ITALIC`. The *modifier* array is the only place an underline may appear; a themed variant
  may substitute `Color::Reset` throughout without changing structure.
- **Remove the manufactured blank rows** currently pushed after h1 and h2
  (`render/markdown.rs:187`, `:196`) and after a setext heading (`:145`). Under §A.6 the
  model's own `\n\n` supplies them, and a model that deliberately wrote `# Title\nBody` on
  adjacent lines must get adjacent lines.

### Paragraphs

- Emitted verbatim with the body text style. No indent, no hanging indent.
- **Soft break** (a lone `\n` inside a paragraph) collapses to a single space — *except* when
  the byte immediately after the break is one of `' '`, `'\t'`, `'>'`, `'|'`. Those four
  signal a list, blockquote or table continuation, and the line ending must survive so the
  continuation gets its own row. OSA today collapses unconditionally
  (`render/markdown.rs:411-446`); add the four-byte guard.
- **Hard break** — a line ending in two or more spaces, or a trailing backslash — keeps its
  newline. OSA already does this (`render/markdown.rs:94`).
- Wrapping happens *after* inline parsing, never before, so a wrap point can never land inside
  `**bold**` or inside a link label. OSA already gets this right and the reasoning is written
  up at `render/markdown.rs:1152-1176`; keep it verbatim.
- A `collapse_soft_breaks(false)` switch is worth adding for line-numbered previews (plan
  files, `/diff` output) where a strict 1:1 source-line-to-row mapping is required.

### Lists

- **Unordered bullet: replace exactly one byte — the `-` or `*` — with `•` (U+2022).** The
  space after it is the source's own space, so the marker column is 2 wide. `+` bullets are
  *not* recognised as bullets and render literally.
- **There is no per-depth bullet cycle.** Every unordered level renders `•`. Nesting is
  expressed purely by the leading spaces the model typed. This is a deliberate simplification
  over OSA's current `• / ◦ / ▪` ladder (`render/markdown.rs:280-284`): the ladder is keyed on
  `indent / 2` (`:278`), which mis-classifies 3-space CommonMark nesting and 4-space nesting
  alike, and produces a different glyph for the same logical depth depending on how the model
  happened to indent. Preserving the model's own indentation is both simpler and correct.
- **Ordered markers are styled but never rewritten.** `1. `, `10) `, `3. ` render literally.
  Marker length is `index_of_separator + 2`, and both `. ` and `) ` are recognised. Drop the
  `1. / a. / i.` depth ladder (`render/markdown.rs:1084-1092`) — it renames the model's own
  numbering, which is wrong whenever the model was numbering something meaningful.
- Marker style is the muted foreground, **not** hidden.
- **Continuation indent is whatever the source contains.** Nothing is inserted. Note the
  consequence: a wrapped list item's continuation rows start at column 0 unless a hanging
  indent is explicitly configured. OSA currently applies a hanging indent
  (`render/markdown.rs:295-305`) and that is a genuine improvement — **keep OSA's hanging
  indent**, measured with `UnicodeWidthStr` as it already is at `:292`. Fix the ordered-list
  branch, which still measures the prefix with `.len()` (`render/markdown.rs:327`) and
  therefore over-indents every continuation row of a multi-byte marker.
- **Task checkboxes render as literal `[ ]` / `[x]`, preceded by the bullet**, styled
  (unchecked = dim, checked = normal). A task item reads `• [x] Done`. OSA today substitutes
  `✓` / `○` and strikes through completed text (`render/markdown.rs:238-252`). Keep OSA's
  glyphs — they read better — but **drop the `CROSSED_OUT` on completed items** (`:249`):
  models routinely write checked items whose text is still the thing you need to read.

### Fenced code blocks

- **No border, no gutter, no line numbers, no language label, no padding rows, no indent.**
- The opening fence line (backticks/tildes plus the info string) and the closing fence line
  are erased. The erase range must be **extended backwards to the line start** whenever the
  bytes between the line start and the fence are pure whitespace. Two things break without
  that extension: the indentation leaks onto the first code row, and the opening/closing fence
  detector inverts (it tests "is the byte before the fence a newline"), emitting a spurious
  blank row.
- The body's only decoration is a **full-row background** applied as a row-level style, so it
  paints the entire terminal row including trailing empty space — including blank rows inside
  the block, and including the final newline-less row of an unterminated fence. Track
  row-code-membership with a boolean flag rather than re-testing the (end-exclusive) byte
  range, or the last row of an unterminated fence loses its background.
- OSA has **no code background at all** today (`render/syntax.rs:390` returns bare styled
  lines; `render/markdown.rs:379` just wraps them). Adding one is the single highest-value
  cosmetic change in Part A: it is what makes a code block read as a block.
- Indented (4-space) code blocks get the background but no language.

### Inline code

- Delimiter backticks are erased. Content is rendered in the code colour, **bold**.
- **No background colour, no padding spaces.** Inline code is a bold coloured run, nothing
  more — a background on a 3-character run is visual noise.
- OSA today renders inline code in `muted` with no bold (`render/markdown.rs:1416`), which
  makes it *less* prominent than surrounding prose. Change to the code colour + `BOLD`.

### Blockquotes

- Per source line, the `>` belonging to *this* nesting level is replaced by `│` (U+2502) and
  styled muted + dim. The space after it comes from the source, giving a 2-column `│ ` prefix.
- Nesting: track quote depth; for each line fragment inside the quote's range, test whether the
  fragment begins at a real source line boundary (previous byte is `\n`). If yes, skip
  `depth - 1` `>` characters and transform the next one; if the fragment starts mid-line (the
  first fragment of a nested quote), skip none. For
  `> Foo\n>\n> > Bar\n> >\n> > - Baz` this yields:

  ```
  │ Foo
  │
  │ │ Bar
  │ │
  │ │ • Baz
  ```

- **Blockquote continuation rows keep the prefix.** This is the one place a hanging indent is
  mandatory: count the leading `│ ` pairs and install exactly that styled prefix as the
  continuation indent, reducing the continuation wrap width by its display width. OSA already
  wraps blockquotes but re-emits the gutter per wrapped row from the *original* depth
  (`render/markdown.rs:219-227`), which is equivalent — keep it.
- **Note the glyph collision:** `│` is also the table vertical. Any downstream code that asks
  "is this a table row?" must disambiguate: a line starting with `│` is a table row only if
  another `│` appears *after* the leading run of `│`/space characters.

### Horizontal rules

- A rule is replaced by the fixed 3-character string `───` (three U+2500), styled muted.
  **It is not stretched to terminal width.**
- OSA currently paints a full-width rule (`render/markdown.rs:204`). Change it. A full-width
  rule inside a reply competes with OSA's own turn separator (`components/chat/message.rs:669`),
  which *is* legitimately full width. Making the markdown rule three columns keeps the two
  unambiguous.

### Links

- `[text](url)` renders in pretty mode as **`text (url)`**. Mechanically: erase the `[`,
  rewrite `](` to `" ("`, keep the final `)`. Link text is the link colour + underline; the
  URL and the surrounding punctuation are muted.
- **Find the structural `](` by an rfind on the prefix before the *last* occurrence of the
  destination URL**, not by a naive forward `find("](")`. Two reasons: the destination may be
  an owned string after percent-decoding or entity expansion and so need not be a sub-slice of
  the source; and `[![badge](img)](repo)` has a nested image whose `](` comes first.
- **Autolinks** `<https://…>` and **reference links** `[text][ref]` fall into the fallback
  branch: the whole span is registered as one link target and the angle brackets / second
  bracket pair remain visible.
- **Images** `![alt](src)` take the identical path with the open-bracket offset shifted by one,
  so the `!` survives: `![img](a.png)` renders as `!img (a.png)`. No image is fetched or drawn.
- **Footnotes are not enabled.** A footnote reference gets link styling and nothing else — no
  superscript, no numbering, no definition rendering.
- **OSC-8:** the markdown layer emits *no escape sequences*. It produces metadata —
  `{line_index, column_range (display cells), url, id}` — and the terminal backend emits the
  escape. A link that spans several rows emits **one target per row, all sharing one `id`**,
  which is precisely why the id exists: terminals use it to hover-group wrapped fragments.
  - Emission is `ESC ] 8 ; id={id} ; {url} BEL`, closed with `ESC ] 8 ; ; BEL`. BEL rather
    than ST, for multiplexer breadth. **Strip control characters from the URL** before
    emitting, or a crafted URL terminates the sequence early.
  - Markdown ids restart per document while OSC-8 `id=` is terminal-global, so ids must be
    **reminted**: consecutive wrap segments with the same `(source_id, url)` reuse the last
    emitted terminal id; anything else takes a fresh one.
  - A second pass scans the *rendered* rows for bare URLs and adds targets, deduped by
    per-line column overlap. This is what makes the ` (url)` suffix clickable: one link
    produces **two** targets with distinct ids and disjoint column ranges.
  - Capability detection is a per-terminal-brand table, and the skip decision has a defined
    precedence: hostile-OSC-parser terminal → unsupported terminal → old VTE (version integer
    below 5004, checked *before* the multiplexer so the user is pointed at the deeper cause) →
    unknown terminal → `screen` → tmux below 3.4. Anything else emits.

  OSA already emits OSC-8 for markdown links and bare URLs (`render/markdown.rs:1725`,
  `:1631-1660`) and already has the escape-aware layout pass that keeps ratatui from
  miscounting escape bytes as columns (`render/cells.rs`, whose module docs are the best
  explanation of the problem in the tree). What OSA lacks is the shared-`id` wrap grouping and
  the capability table. It does correctly refuse to emit a *mutating* hyperlink for a
  half-streamed `[docs](https://exa` (`render/markdown.rs:1608-1627`) — that reasoning is
  right and must survive any rewrite.

### Math

- Inline `$…$` / `\(…\)` converts to a Unicode approximation and renders italic; on failure
  (input over ~4096 bytes, or nothing visible produced) it falls back to inline-code
  presentation. OSA has this (`render/latex.rs`, wired at `render/markdown.rs:1512`).
- Display `$$…$$` renders as a block with each row prefixed by **exactly two spaces**, and the
  replacement range swallows the trailing newline so batch and streaming renders converge.

### HTML

- HTML *blocks* are **not** treated as code. Model output is full of pseudo-XML
  (`<system-reminder>`, `<example>`) that is structural, not markup; syntax-highlighting it
  with a code background looks broken, and the parser ends HTML blocks at blank lines so the
  first half would look like code and the rest like prose.
- Inline HTML is highlighted as `html`, **except** `<br>` / `<br/>` / `<br />`
  (case-insensitive), which becomes a newline in prose and a literal line break inside a
  table cell.
- HTML entities in prose are decoded by a bounded scanner: at most 33 bytes (the longest HTML5
  named entity), scanning only `#`, `a-z`, `A-Z`, `0-9` until the first `;`. **Reject any
  decoded result containing a control character** — otherwise `&#27;` is an escape-injection
  vector. Push a `None`-style highlight over each entity so the render sweep splits exactly
  there, or a substitution straddling a chunk boundary is emitted twice.

## A.2 Tables

This is what the user's screenshot shows, and it is worth getting exactly right.

### Glyphs

One 11-element array, indexed `[H, V, TL, TR, BL, BR, T_T, T_B, T_L, T_R, X]`:

```
BOX    = ['─','│','┌','┐','└','┘','┬','┴','├','┤','┼']
ASCII  = ['-','|','+','+','+','+','+','+','+','+','+']
DOUBLE = ['═','║','╔','╗','╚','╝','╦','╩','╠','╣','╬']
```

`BOX` is the default and the only one used in practice; `ASCII` exists for the legacy-console
path (OSA already has the equal-width fallback machinery at `render/glyphs.rs`, and the table
glyphs should be routed through it).

### Structure

```
┌────────┬────────┐   top:            TL  T_T  TR   H
│ Header │ Header │   header row(s)
├────────┼────────┤   header rule:    T_L  X  T_R   H
│ body   │ body   │   body row 1
├────────┼────────┤   inter-row rule: T_L  X  T_R   H   ← between EVERY pair of body rows
│ body   │ body   │   body row 2
└────────┴────────┘   bottom:         BL  T_B  BR   H
```

- **The header rule and the inter-row rules are identical glyphs.** The header is distinguished
  only by **bold cell text**, never by a heavier or doubled rule.
- A rule is drawn after every body row **except the last**.
- If the header row is empty, both the header row and the header rule are skipped.
- One rule line is: `left`, then for each column `width + 2*padding` copies of `H` with `mid`
  between columns, then `right`.

OSA already matches this exactly (`render/markdown.rs:631-679`, `:734-749`), including the
bold-accent header (`style/mod.rs:598`) and the theme-driven border colour (`style/mod.rs:592`).
**Keep it.**

### Padding

`padding = 1` — one space either side of every cell's content, *inside* the column width.

```
total_width = 1 + Σ(col_width + 2) + (num_cols − 1) + 1
            = num_cols * 3 + Σ(col_width) + 1
```

OSA computes chrome as `4 + (num_cols − 1) * 3` (`render/markdown.rs:603`), which is the same
number written differently — and the comment above it records the off-by-one that used to make
every 2-column table overflow. Keep both the code and the comment.

### Column-width algorithm

**Phase 1, always.** `col_widths[i]` = the maximum, over all rows, of the widest
`\n`-separated line of that cell's plain text, measured in display columns.
`num_cols` = the widest row's length; short rows are blank-padded.

**Phase 2, only when the table exceeds the available width.**

```
overhead       = num_cols * 3 + 1
content_budget = width − overhead
```

If `Σ col_widths ≤ content_budget`, natural widths are kept unchanged. Otherwise:

1. Compute two per-column floors:
   - `min_col_widths[c]` = the widest **unbreakable word** in that column (initialised to 1),
     where "word" is defined by the custom separator in §A.2.5;
   - `hard_floors[c]` = the widest **single grapheme** in that column (initialised to 0, forced
     to at least 1 for a non-empty cell) — the narrowest width at which text can still reflow
     without losing content.
2. Pick the base/target pair:
   - if `Σ min > content_budget` **and** `Σ hard_floors ≤ content_budget` →
     base = `hard_floors`, target = `min_col_widths`. Long unbreakable tokens will be
     hard-split inside their cells rather than blowing the budget.
   - otherwise → base = `min_col_widths`, target = the natural widths.
   - if even the grapheme floors do not fit, keep the word minimums and let the final clip be
     the safety net.
3. `extra_budget = content_budget − Σ base`. Each column *wants* `target[c] − base[c]`.
   Distribute proportionally: `share = floor(want_c × extra_budget / Σ want)`.
4. Hand out the floor-rounding remainder one column at a time, in descending order of
   remaining unmet want, never exceeding that column's target.

**Minimum column width is content-derived, not a constant.**

OSA today water-fills from a fixed `MIN_COL_W = 3` (`render/markdown.rs:753`, `:774-824`).
Water-filling and proportional-shrink agree on the easy cases and disagree on the hard one:
with a 5-column `Topic` beside two 90-column prose columns, water-filling raises a common
ceiling and gives `Topic` its full 5, which is right; but with three columns of *similar*
natural width and a tight budget, water-filling can starve a column below its longest word
while proportional shrink cannot. The concrete upgrade is not the allocator — it is the
**two-floor model** (word-minimum, then grapheme-floor) which OSA does not have at all. Add
the floors; keep water-filling as the distribution rule if it tests equal.

### Cell wrapping and the word separator

Cells **wrap**; they are not clipped. The word separator is the distinctive part:

- A break point sits between a punctuation/symbol character and what follows, when:
  - the next character is **alphabetic** → always break; or
  - the next character is a **digit and the character before the punctuation was also a digit**
    → break, **unless** the punctuation is `,` or `.` (number formatting).
- Consequences: `foo/bar` breaks; `hello-world` breaks; `555-0101` breaks; `2019-03-15`
  breaks; `$145,000` stays whole; `3.14` stays whole; `1.0.2` stays whole; `EMP-1001` stays
  whole (no digit before the `-`).
- **Attachment:** for each break point the punctuation attaches to whichever side minimises
  `max(left_width, right_width)`; ties go left. `foo/bar` → `foo/` + `bar`; `ABCD-EFG` →
  `ABCD` + `-EFG` (max 4, versus 5 the other way).
- **URLs are protected:** each whitespace-delimited token is fed through a real URL parser;
  tokens that parse have all interior break points removed, so click-to-open still works on a
  wrapped cell.
- After wrapping, any row still wider than the column (an unbreakable word) is **hard-split on
  grapheme boundaries** using the same display-width model, so emoji ZWJ and VS16 sequences
  stay intact.
- The wrapper never returns an empty vector; width 0 or empty text yields one empty row.

OSA's cell wrapper (`render/markdown.rs:890-933`) wraps on spaces only and **drops inline
styling on the wrapped path** (`:884-885`). The styled path is only taken when the cell fits on
one line. That is the biggest single gap in OSA's tables: any cell that wraps loses its bold,
its code colour and its link. Fix by slicing the original styled spans onto each wrapped row —
see the cursor rule below.

### Multi-line rows

Each cell wraps independently; the row's height is `max(wrapped_cell_lengths)`. Every visual
line of the row is a full bordered row; short cells emit blanks. **Every row of a table is
exactly the same total display width** — this must be a test, not a hope.

### Alignment

From the delimiter row, per column, defaulting to `Left` beyond the delimiter row's length:

```
pad = col_width − cell_line_width
Left / None → (0, pad)
Right       → (pad, 0)
Center      → (pad/2, pad − pad/2)      // the odd column goes right
```

Each cell emits `" ".repeat(padding + left_pad)` + content + `" ".repeat(right_pad + padding)`
then the `│`. OSA matches this exactly (`render/markdown.rs:936-958`). Keep.

### Cell text colouring

Cells are re-styled from scratch, not inherited from the prose highlight machinery:

```
style = body_text
if is_header or span.bold  → .bold()
if span.italic             → .italic()
if span.code               → style = inline_code_style        // REPLACES
if span.link               → style = style.patch(link_style)  // ADDITIVE, keeps bold/italic
```

Border glyphs use the muted rule colour, dimmed.

**The monotonic source cursor.** To slice the original styled spans onto each wrapped row, keep
a per-column byte cursor and search for each fragment *strictly after* the previous fragment's
match end, snapped down to a char boundary. Without it, whitespace the wrapper consumed lets a
naive `find` re-match an earlier identical substring — a linked `aa` followed by a plain `aa`
leaks link styling and a bogus hyperlink range onto the plain fragment.

### Links inside cells

The prose link path cannot reach into a table, because the table replacement consumes the whole
source range and no text chunk ever walks the cell's link text. Instead: when a link tag opens
inside a table, stash `(url, id)` on the cell state, tag each cell span with it, and have the
formatter emit `{line_offset, column_range, url, id}` in **table-local coordinates**; the
renderer adds the absolute base line. Ids come from the same counter as prose links, so a
label wrapped across rows produces several fragments sharing one id.

### Overflow — the layered policy

1. **Column shrink plus in-cell wrap.** The table gets *taller*, never narrower than its
   floors. Nothing is truncated at this stage.
2. **Table rows are never word-wrapped downstream.** A "is this a table row?" test
   short-circuits the paragraph wrapper: first character is a box-drawing char in
   `U+2500..U+257F` other than `│`/`┃`; or `│` with another `│` after the leading run of
   `│`/space; or an ASCII `|`.
3. **Clip and pad to exactly the content width.** If narrower, pad with spaces; if wider, clip
   on **grapheme boundaries with no ellipsis**, and if a straddling wide grapheme leaves a
   1-column gap, pad it.

**No horizontal scrolling. No dropped borders. No ellipsis.** Relying on the terminal to clip
at the edge desyncs by a column on any glyph the terminal renders wider than measured, which
strands a ghost cell past the trailing border.

OSA's step 3 already exists and is the right shape: `pad_lines_to_width`
(`render/markdown.rs:711-728`) pads every row to the full region width, and the comment above
it (`:694-711`) is the clearest statement in the tree of *why* — a row that does not own its
full width can be sheared permanently once it is handed to native scrollback via
`insert_before`. **Keep that, and extend it with the grapheme clip on the over-wide side.**

OSA's degradation path when the terminal is too narrow for any bordered table
(`render/markdown.rs:608-622`) joins cells with ` · ` and wraps as plain text. That is a good
last resort and has no counterpart in the reference; keep it, but move its trigger to *after*
the grapheme floors have been tried.

OSA's `MAX_CELL_LINES = 8` cap with the centred `▼` marker (`render/markdown.rs:758`,
`:685-692`) also has no counterpart. Keep it — a pasted paragraph inside a 12-column column
would otherwise push the rest of the table off screen — and keep the discipline that the
marker is drawn *only* when content was actually cut (`:628`, `:682-684`).

## A.3 Inline styling

| Markdown | Terminal |
|---|---|
| `**x**` | `BOLD`, body foreground |
| `*x*` | `ITALIC`, body foreground |
| `~~x~~` | `CROSSED_OUT`, body foreground |
| `` `x` `` | code foreground, `BOLD` |
| `[t](u)` | `t` in link colour + `UNDERLINED`, then ` (u)` muted |

Delimiters are erased in every case.

**Single-tilde `~x~` must be demoted to literal text.** Only `~~x~~` strikes. Model output
contains `~50ms`, `~**10%**` and similar constantly, and striking through those is both wrong
and confusing. OSA disables strikethrough entirely today
(`render/markdown.rs:14-15`) which over-corrects: implement `~~…~~` and demote `~…~`.

**Composition.** Fold the active styles left to right:

- effects **OR** together, so `***x***` yields `BOLD|ITALIC`;
- `DIM` and `BOLD` are **mutually exclusive** — applying one removes the other, later wins;
- foreground, background and underline colour are **last-wins**;
- `HIDDEN` is a sentinel: if the accumulator picks it up, revert to the previous accumulator
  value and continue; strip `HIDDEN` from the final result so it never reaches the terminal.
  The pretty-mode erase predicate is "there is at least one active style and **every** active
  style is hidden".

Two fixes worth porting verbatim, because both are silent and both fire constantly:

1. **Inside a link, inline-format ancestors contribute effects but not foreground.** Bold,
   italic and strikethrough styles carry the body foreground, and their highlights land *after*
   the link-text highlight; last-wins would silently repaint `**[click](url)**` in body colour.
   Strip the foreground from ancestor styles whenever a link or image is on the tag stack.
2. **The default text style is pushed only when there are no ancestors at all.** Link and image
   push a `None` sentinel purely to make the ancestor list non-empty, so a plain paragraph link
   keeps its link colour.

A whitespace guard applies on any ANSI-string output path: a run that is all `\n`, or all ASCII
whitespace with no effective background (checking background normally, foreground when
`INVERT` is set), is emitted with a plain style, so trailing coloured whitespace does not paint.

## A.4 Syntax highlighting inside fences

- **Engine:** syntect, with an extended syntax set and a TextMate theme loaded from bytes.
  One instance, constructed once, passed by reference. OSA matches (`render/syntax.rs:10-19`)
  but loads only syntect's *defaults*; move to the extended bundle for language coverage.
- **Language detection**, in order:
  1. If the info string is a **line-range citation** of the form `lineStart:lineEnd:path/to/f.ext`
     — validated as digits, `:`, digits, `:`, non-empty path, split into exactly three parts —
     resolve by the path's **file extension**. (Paths containing extra colons in the first two
     segments, e.g. Windows drive letters, are unsupported; use repo-relative forward-slash
     form.)
  2. Otherwise, resolve by token against the **entire** info string. Note the consequence:
     ` ```rust ignore ` will not match by token. If OSA wants ` ```rust ignore ` to work, take
     the first whitespace-delimited word — OSA already trims the info string
     (`render/markdown.rs:81-82`) but passes the whole remainder.
  3. OSA additionally normalises a small alias table (`rs`→`rust`, `js`→`javascript`,
     `ts`→`typescript`, `py`→`python`, `sh|bash|zsh`→`shell`, `ex|exs`→`elixir`) and falls back
     to extension lookup (`render/syntax.rs:273-286`). Keep that; it is strictly better.
- **Unknown or absent language:** highlighting returns nothing, the range is styled with the
  untagged-code style, and it is recorded so the **full-row code background still applies**.
  An untagged block looks like a code block with uniform body-coloured text. OSA's
  `plain_fallback` (`render/syntax.rs:390-396`) styles it `faint` with no background — change
  to body colour plus background.
- **Colour adaptation:** convert each syntect style, substitute the theme's code background,
  then downgrade for the detected colour level: truecolor passes through; 256 quantises RGB to
  the xterm cube; basic quantises both to ANSI-16 against a VGA palette; none drops colour.
  `NO_COLOR` forces none. **Not-a-TTY defaults to truecolor**, because the TUI may be rendering
  to stderr. If the probe reports only 256, upgrade to truecolor when a known-truecolor
  terminal is identifiable from the environment — tmux, SSH and mosh all strip the colour
  hint, so the terminal-brand check is the only reliable signal. OSA has this
  (`render/colors.rs`, used at `render/syntax.rs:27-32`); verify the not-a-TTY default.
- A **polarity-safe** mode is worth having for painting syntax onto the terminal's own
  background: near-gray RGB (chroma below 40) maps to *no colour* (inherit the default
  foreground); chromatic RGB maps by hue to base ANSI accents only, with buckets
  `0–30 | 330–360 → Red`, `30–90 → Yellow`, `90–150 → Green`, `150–210 → Cyan`,
  `210–255 → Blue`, else Magenta. Magenta deliberately starts at 255° so a ~261° purple lands
  Magenta rather than Blue. Bright accents demote to base; white/black become "inherit". The
  point is that a night theme's pastels, quantised, vanish on a light terminal profile.
- **Performance guards: no line cap and no timeout.** Two caches instead, live only while
  streaming:
  1. **Incremental open-block highlighter.** For the single still-open trailing fence, persist
     syntect's `ParseState` and `HighlightState` across re-renders. Newline-terminated lines are
     highlighted once and *committed*; the trailing partial line is highlighted on **clones** of
     both states so the commit point stays anchored at the last `\n`. Rebuild triggers: the
     fence info changed, the block's start offset moved, or the committed prefix no longer
     matches. OSA has exactly this (`render/syntax.rs:66-120` and the resumable highlighter at
     `:306+`), including the measurement that motivated it (8.3 ms of 8.9 ms per delta was
     syntect re-running from line 1). **Keep.**
  2. **Closed-fence memo.** A *closed* fence trapped inside an unfreezable tail (inside an open
     list) is re-parsed every pass. Memoise `fence_info → body → highlighted lines` with a byte
     budget of 256 KB, **cleared wholesale on overflow** — degrading to the pre-memo behaviour,
     never to unbounded memory and never to wrong output. Size it in body bytes, not entries,
     because a list-indented fence is split into per-line events. OSA does **not** have this,
     and OSA's freeze rule (§A.7) has the same blind spot, so it has the same bug.
  - Both paths must be byte-identical to a one-shot batch highlight. Invalidation is wholesale:
    drop the whole cache on any theme, style, pretty-mode, width or soft-break change.

## A.5 The blank-line policy

**The rule, stated once:**

> Sweep the source; every `\n` flushes one output row. Therefore **k consecutive newlines
> between two blocks produce k − 1 blank rows** — for every pair of block types, uniformly.

```
A\n\nB          → ["A", "", "B"]          one blank row
A\n\n\nB        → ["A", "", "", "B"]      two blank rows
A\n\n\n\nB      → three blank rows
A\nB            → ["A", "B"]              zero blank rows
```

There is no `blank_lines_between(a, b)` table and there must not be one. An implementation that
emits "always exactly one blank row between blocks" will look right on the common case and
wrong everywhere the model asked for more or less air.

Three modifiers, and only three:

**Modifier 1 — trailing whitespace suppression (pretty mode only).** After the last render
event, if the remaining tail is entirely ASCII whitespace, discard it. This is what stops a
document ending `"…text\n\n"` from emitting a trailing blank row. In raw mode the tail *is*
emitted. Flush the final partial row only if there is pending content.

Worked example, `"# Heading\n\nParagraph\n\n"`:

- `"# "` is an all-hidden run at a line start → skipped; set `skip_leading_newline`.
- `"Heading"` emitted; it does not start with `\n`, so the flag is consumed without effect.
- The gap `"\n\n"` splits to `["", "", ""]` → two flushes → row 0 `"Heading"`, row 1 `""`.
- `"Paragraph"` accumulates.
- The tail `"\n\n"` is all whitespace → dropped.
- Final flush → row 2 `"Paragraph"`.

Result: exactly `["Heading", "", "Paragraph"]`. Pin this as a test.

**Modifier 2 — `skip_leading_newline` after a hidden run at a line start.** Whenever an
all-hidden run begins at a source line start (previous byte is `\n`, or offset 0), set a flag;
if the *next* emitted text begins with `\n`, drop that one newline and only that one. Without
it, an erased fence or heading marker leaves a phantom empty row where its line used to be.

**Modifier 3 — a synthetic blank row before an *opening* code fence (pretty mode only).**
Inside the same branch, trim the hidden text and test for a ` ``` ` or `~~~` prefix. If it is a
fence, and an `in_hidden_code_block` toggle says this is an **opening** fence, and the last
emitted row has non-zero width, push **one** empty row. Then flip the toggle.

This exists because erasing the fence lines would otherwise collapse `1. Hello` directly
against the first code row. Heading markers are also hidden at line start but are *unpaired*,
which is why the test is specifically for fence characters rather than "any hidden run".

**This is the only place the renderer manufactures a blank row the source did not contain.**

Adjacent bookkeeping, not strictly blank-line policy but the same class of bug:

- Flush any pending spans *before* emitting a table, mermaid or display-math replacement. A
  table always starts at a line boundary so it is a no-op there, but display math can occur
  mid-paragraph (`text $$x$$ more`) and without the flush the pending `"text "` spans are
  emitted *after* the block's rows.
- On an ANSI-string output path, before emitting a table, check whether output is empty or ends
  with `\n` or with `\n` followed by a reset sequence, and push a `\n` if not — both forms,
  because a styled chunk ends with a reset *after* its newline.
- At the frozen/tail seam (§A.7): if the frozen source does **not** end with `\n` but the tail
  **starts** with `\n`, advance the tail start by one. That newline is the block-terminating
  newline already consumed by the frozen block; without the skip a spurious blank row appears.

**OSA today.** Blank source rows already pass through one-for-one
(`render/markdown.rs:344-348`), which is most of the rule already. What breaks it is the three
*manufactured* blanks after h1, h2 and setext headings (`:145`, `:187`, `:196`) — those make
`# A\n# B\n# C` render with blanks the model did not ask for, and they make it impossible for a
model to write a tight heading-plus-line pair. Delete them and add Modifier 3.

## A.6 Streaming and partial markdown

### The commit model

Hold: the accumulated source, one output buffer whose prefix is frozen and whose suffix is
re-rendered, and

```
FrozenState { rows_len, source_bytes, next_link_id }
```

On each push:

1. Append the chunk to the source (after delimiter normalisation, below).
2. Re-render the tail:
   - truncate the output rows and the row→source-line map to `frozen.rows_len`;
   - retain hyperlinks with `line_index < frozen.rows_len`, and code-block spans whose row
     range ends at or before it;
   - compute the tail start (with the seam-newline skip from §A.6);
   - **re-parse and re-render the entire tail from scratch**, seeded with `next_link_id` so
     link ids stay continuous;
   - append, offsetting tail hyperlink line indices by `frozen.rows_len` and rebasing tail
     code-block spans by `+rows_len` (output) and `+tail_start` (source);
   - run the bare-URL scan **over the tail slice only**, with a line-index offset so emitted
     indices are document-absolute and the overlap dedup compares correctly against frozen
     targets — this makes the scan idempotent;
   - sort all hyperlinks by `(line_index, column_start)`;
   - if the tail render returned a checkpoint, advance `FrozenState`.

**The prefix up to the last checkpoint is final and never recomputed; everything after it is
thrown away and re-rendered on every push.** O(N²) → ~O(N).

### Safe-prefix detection

A checkpoint is recorded **only at nesting depth 0**, where depth is incremented by blockquote,
list, item and table. Nothing inside a container can ever checkpoint, because the container
might continue.

On a depth-0 block end, take the checkpoint only if:

```
has_blank_line_after(text, range.end)            // first non-space/tab byte after is '\n'
  || (kind == CodeBlock && range.end < text.len())   // the fence is properly closed
```

and record the byte as:

```
range.end + 1   if kind == CodeBlock && has_blank      // include the closing newline
range.end       otherwise                               // deliberately EXCLUDE it
```

The exclusion is deliberate: for paragraphs, headings, quotes and lists the separator newline
must stay in the tail so the blank-row separator is re-rendered when the next chunk arrives.

Deriving the checkpoint's *row count* is the fiddly part:

- Detect when the checkpoint byte falls inside the current text range and **split the range in
  two**, capturing the row count between the halves. **Flush any pending spans before
  capturing** — a horizontal rule can sit in the pending buffer with no trailing newline to
  flush it, and omitting the flush undercounts the row count and makes the row vanish on
  re-render.
- **Snap the checkpoint byte forward to the nearest char boundary.** In edge cases (a rule
  followed by a heading containing a multi-byte character) it can land mid-character. Snapping
  forward only shifts which half counts a newline; the total is unchanged.
- Count newlines over **bytes**, never over string slices. This is safe because `0x0A` can
  never appear as a UTF-8 continuation byte.
- Fallback when no event follows the checkpoint: count newlines before it to get the source
  line, then count rows whose source line is below that. If the checkpoint is at or past the
  end, freeze everything. Clamp to the row count.

### Partial constructs

| Partial input | Behaviour |
|---|---|
| **Unterminated fence** | The parser synthesises a block end at EOF, so the body renders normally — background and highlighting included. But it is not *properly closed*, so **no checkpoint**: the fence stays in the tail and is re-rendered every push. The incremental highlighter is what makes that affordable. **No code-block span is produced**; closure is detected structurally (a closing fence must exist after the body), not by the parser's synthetic end. |
| **Half-written table** | Until the delimiter row is complete and column-consistent, no table tag fires and the rows render as an ordinary paragraph with raw pipes visible. Once it parses, the whole source range is replaced. An in-progress table cannot checkpoint, so it re-formats every push. |
| **Partial list item** | Depth is above 0 while any list is open → no checkpoint at all until the list closes. The whole list re-renders every push. The bullet transform applies as soon as `"- "` is present; a bare `-` with no following space gets marker length 0 and no transform. |
| **Dangling emphasis / inline-code marker** | CommonMark leaves an unmatched `**` or `` ` `` as literal text, so the raw marker is visible mid-stream and the run flips to styled the instant the closer arrives. No speculative styling. |
| **Chunk boundary inside a link** | Handled by the tail re-render: `[my ` + `link](url) here.` produces exactly the same targets as a one-shot render. |
| **Chunk boundary inside a math delimiter** | A streaming normaliser rewrites `\(…\)`, `\[…\]` and `\begin{…}`/`\end{…}` into canonical `$`/`$$` **before** the text is appended, so every downstream handler sees one form. It **holds back a bounded ambiguous suffix** at a chunk boundary — a partial delimiter, a `$` that might become `$$`, an unclosed opener within its look-ahead — bounded at 4096 bytes. Observable consequence: mid-stream the accumulated source can legitimately be *shorter* than everything pushed. |

### Finish

`finish()` flushes the normaliser's held-back bytes, then does an **unconditional full batch
re-render of the whole source** with fresh buffers, link ids restarted at 0, and the incremental
cache explicitly disabled. Its distinguishing value is the re-render independent of frozen-state
truncation; the URL scan and sort are already done by every render.

### The correctness contract

**Streaming output must equal one-shot full-render output, row for row.** Test at
char-by-char, `[3, 5, 7, 11]`, and `[50, 100, 200]` chunk granularities, in both pretty and raw
modes.

### State resets

Any style, pretty-mode, width or soft-break change, and any explicit clear, must zero the
frozen state, clear the output and drop the incremental highlighter. A clear must **also reset
the max-table-width to none** — otherwise a later `set_max_table_width(prev)` is silently a
no-op because the equality check sees no change, and the expected reset never fires.

### Downstream incremental wrapping

Mirror the freeze boundary one level up: track pre-wrap rows already wrapped and the wrapped
rows they produced; wrap only newly-frozen rows plus the tail each frame; truncate the wrap
cache to the frozen wrapped count. A width or theme change invalidates both counters. This
turns streaming *wrapping* from O(N²) into ~O(N) as well.

### OSA today

OSA's `StreamingRenderer` (`render/markdown_stream.rs`) is the same shape and its module docs
(`:1-40`) derive the safe-split rule correctly for OSA's line-oriented renderer: a split point
is safe when it is at a line start, the previous line was blank, and it is not inside an open
fence. The incremental scan is resumable and carries fence state (`:162-192`), which is the
right O(N) fix. The cursor is `█` (U+2588) appended to the tail (`:50`).

Three real gaps:

1. **The depth-0 rule is only approximated.** OSA's scan tracks fence state and blank lines but
   not list/blockquote/table depth, so a blank line *inside* a list ("loose list") freezes a
   prefix mid-list. For OSA's line-local renderer that happens to be output-identical today,
   but it stops being true the moment lists gain any cross-line state. Add explicit depth
   tracking before changing list rendering.
2. **No closed-fence memo.** A closed fence sitting in an unfreezable tail is re-highlighted
   every delta.
3. **No streaming-equals-batch test at multiple granularities.** `render/stream_bench.rs`
   measures cost; nothing pins equivalence.

---

# Part B — Thinking display

## B.1 Where reasoning lives

Reasoning arrives as its own delta type on the wire and is stored in a **separate block from
the answer**, never interleaved into the assistant text buffer. OSA already does this: the SSE
client decodes `thinking_delta` distinctly (`client/sse.rs:360`, `:1228`), and the TUI holds a
dedicated `ThinkingBox` (`components/chat/thinking_box.rs:22`).

The block carries:

- the accumulated reasoning text;
- an elapsed time, which is **server-reported when available and locally measured otherwise**;
- a start instant, armed on the first content.

Two subtleties worth copying:

- **Replay must not arm the local timer.** Re-applying a persisted session's chunks back to
  back takes microseconds, so a local wall clock freezes at ~0 ms and renders a bogus
  `Thought for 0.0s`. A replay-constructed block leaves the local timer unset so the
  server-reported elapsed (derived from the recorded timestamps) is used instead — the real
  duration the user originally experienced.
- **On finish, freeze the local elapsed** when no server time was set, because the local timer
  captures block-creation to finish, which is what the user perceived.

**One storage decision worth recording even though it is below the TUI.** Reasoning should be a
**sibling item immediately preceding the assistant message**, not a field on it. A field is
last-write-wins and loses N parallel reasoning items when a turn makes several tool calls; the
sibling ordering also keeps the interleaved `[reasoning, tool_call, reasoning, …, message]`
sequence byte-stable, which is what makes a server-side prefix cache actually hit. There is no
dedicated "thinking duration" on the wire in any provider shape — the duration is always either
derived from recorded timestamps or measured locally, which is why §B.1's replay rule matters.

## B.2 Three display modes, not two

| Mode | Renders |
|---|---|
| **Collapsed** | the header row only, truncated to fit |
| **Truncated** (default while running) | optional header, then `…`, then the **last N wrapped rows**, N = 3 |
| **Expanded** | optional header, then the full body |

This is the important departure from OSA. OSA has only collapsed and expanded
(`components/chat/thinking_box.rs:131-146`), and its default is collapsed
(`:43`) — so while the model is reasoning, the user sees one dim line and nothing else. The
**Truncated mode is what "the user wants to see thinking" actually means**: a live, three-row
window onto the tail of the reasoning stream, scrolling as it arrives, without letting it
swallow the screen.

## B.3 The header row

```
running:  Thinking…
done:     Thought for 3.4s
done, no time known:  Thought
```

- The label (`Thinking…` / `Thought`) is **bold**; the ` for 3.4s` detail is muted and
  separate. Colour is muted by default; primary when the entry is selected, or when a
  `header_bright` preference is on — but **never bright while muted-collapsed**, so a legacy
  console collapses uniformly.
- Duration format: `{:.1}s` under a minute, `{m}m{s:.0}s` beyond.
- A dim `  (ctrl+e to expand)` affordance is appended to the *collapsed* header only, and only
  when it fits on the same row — it must never push the header to a second row or into
  truncation.
- By default the header appears in **all three modes**, as the first row, followed by a blank
  row in truncated and expanded.

OSA's header (`components/chat/thinking_box.rs:239-260`) is `∴ Thinking… 2.3s` /
`∴ Thought for 3.4s`, optionally suffixed ` · <title>` where the title is a leading
`**Bold title**` promoted out of the reasoning body (`:280-297`). **Keep both** — the `∴`
prefix is part of OSA's identity and the promoted title is genuinely better than a bare
`Thought for Ns`. Change only: split the label bold from the duration muted, and add the
`(ctrl+e to expand)` fit-guard in place of the unconditional `(alt+t to expand)` at `:163`.

## B.4 Body styling

- The body is rendered through the **full markdown renderer** — lists, code, headings all work
  inside reasoning. OSA already does this (`components/chat/thinking_box.rs:226-229`).
- On top of the markdown styling, two de-emphasis layers:
  1. **Colour blend toward the background.** Every span's foreground is blended with the
     terminal background at a factor of **0.7** (70% original colour, 30% background). This is
     the primary cue and it preserves the markdown structure's colours while pushing the whole
     block back a plane.
  2. **`DIM | ITALIC` attributes**, applied *after* the blend, for surfaces where the blend
     alone cannot separate reasoning from the answer — a terminal-native palette, `NO_COLOR`,
     either polarity. Suppress `ITALIC` on legacy Windows consoles, which have no italic SGR
     and render the request as palette noise. Terminals that merely *ignore* SGR 3 are not
     gated: there is no reliable probe, and they keep the other cues.
- Order matters: **blend before patching attributes**, and do both after any quote-bar
  detection, because blending rewrites foreground colours (which would defeat bar detection)
  while preserving span structure (so computed span indices stay valid).
- Indentation: none beyond the block's own accent rail. OSA indents the body two columns
  (`components/chat/thinking_box.rs:192`) — harmless, keep it if preferred.

OSA today dims only spans that had *no* explicit colour (`components/chat/thinking_box.rs:197-200`)
and italicises everything. Replace the conditional dim with the blend; keep the italic.

## B.5 Live vs. finished

- **Reasoning streams live.** The block is pushed and marked running **before the first delta
  arrives**, so `Thinking…` appears immediately. Deltas append through a dedicated push-chunk
  path with O(1) height invalidation. While running the block sits in truncated mode — the
  `…` head row plus the last 3 wrapped rows.
- **There are two live surfaces, and they are different things.** The block is one. The other
  is the **one-row turn-status widget** between the scrollback and the composer, height 0 when
  idle:

  ```
  ⠧ Thinking…                          1m20s ⇣12k [stop]
  ```

  Its label set is `Thinking…` / `Responding…` / `Verifying…` / `Compacting…` /
  `Retrying (attempt N)…` (warning colour) / `Cancelling…` (error colour) / `Running…` /
  `Waiting…`. Spinner frames are braille `⠋⠙⠹⠸⠼⠴⠦⠧`, with `|/-\` on a legacy console, advanced
  one frame per 4 animation ticks — roughly 7.5 fps at a 30 fps tick, which reads as motion
  without drawing the eye.

  OSA already has this row (`components/activity.rs`, `components/status_bar.rs`) with an
  escalating verb — `thinking` → `thinking more` → `thinking harder` at 8 s and 20 s
  (`components/activity.rs:288-297`). Keep the escalation; it is better than a static label.
- An optional animated accent rail (a travelling wave down the block's left edge) runs while
  the block is active. This is the one animation permitted here, and **it must not change the
  block's height.**

## B.6 Expanding — in place, or an honest re-print, depending on the surface

This is **two mechanisms, not one**, and OSA needs both because OSA uses both surfaces.

**Retained-widget surface (the live viewport).** The block is a widget whose `DisplayMode` is a
field. Toggling: probe whether *any* thinking block is collapsed; pick the target mode as
"expand all" if any is collapsed, else "collapse all"; store that as a **sticky transcript-wide
mode** which future finishing blocks inherit; then per block set the mode, clear any pin,
invalidate the render cache, and mark the id height-dirty so the next layout pass recomputes
it. Nothing is re-printed — the tree re-renders from mutated state.

**Print-once surface (native scrollback via `insert_before`).** Committed terminal text cannot
be mutated. Expansion therefore **appends a fresh full copy below the conversation**, and that
is the honest behaviour, not a workaround. The mechanics:

- Record folded entries into a bounded **expand ring** (capacity 256) as they are committed.
- The expand keybind pops the most recent entry, sets it to expanded, and **re-commits it with
  the row cap disabled** — re-applying the cap would just reprint the same "N more lines"
  footer.
- **A failed terminal write must requeue at the front, not drop.** Print-once means a block
  marked-but-unprinted can never be emitted again.
- Before the initial commit, finalize any still-running block first, specifically so it prints
  `Thought for 12.3s` rather than freezing an animated `Thinking…` into scrollback forever.

**A fold state machine, not a boolean.** The transitions differ by run state:

```
running:   Collapsed | Truncated → Expanded ;  Expanded → Truncated
finished:  Collapsed → Expanded ;              Truncated | Expanded → Collapsed
collapse_mode(running)  = Truncated
collapse_mode(finished) = Collapsed
default_display_mode()  = Truncated
```

So while the model is thinking, the "collapsed" state is the 3-row tail view, not a single
line — you cannot accidentally hide live reasoning to one row. Once finished, it collapses to
one row.

**Empty thinking blocks are deleted, not rendered.** A block that finished with no content must
not appear as `Thought for 0.0s`.

**A visibility gate is separate from the fold state.** A `show_thinking_blocks` preference
(default on) makes thinking entries render **zero rows** — the height function returns 0 and the
renderer early-returns — and makes them fully transparent to any grouping or truncation logic
(skipped, never counted as participants). A full-transcript view force-enables the flag around
its render and restores it afterwards.

**Consequence for OSA's fixed-slot rule.** OSA reserves a constant `EXPANDED_ROWS = 12` while
expanded (`components/chat/thinking_box.rs:129-146`) precisely so that mid-turn growth does not
rebuild the inline viewport and stack the composer down the screen. That constraint is real and
the comment at `:136-145` explains it correctly. Truncated mode is **compatible** with it and
in fact better: a 3-row window plus header plus blank is a constant 5 rows regardless of how
much reasoning arrives. Set the truncated slot to a constant and keep the expanded slot as it is.

## B.7 Keybind

`ctrl+e` cycles the thinking block's display mode. OSA currently binds `alt+t`
(`config/keybindings.rs:357`, dispatched at `app/keymap_dispatch.rs:199`) to a two-state
toggle. Keep `alt+t` as an alias, add `ctrl+e`, and make the action **cycle three modes**
rather than flip two. Drop the toast on toggle (`app/keymap_dispatch.rs:201-203`): the visual
change is its own feedback, and a toast for a display toggle is noise.

---

# Part C — Diff and edit rendering

This is the part the user singled out: *"it says edit, shows the numbers, everything, and then
it says the stuff at the end."* Those three things are the header, the numbered gutter, and the
inter-hunk separator that names how much was skipped.

## C.1 The header row

```
Edit src/app/state.rs +12/-3
Creating docs/design/tui-output-rendering.md
Edit state.rs (4 edits)
```

Composition, left to right:

1. **A verb prefix**, bold: `"Edit "` by default, `"Creating "` for a write/create tool, and a
   domain-specific variant where one applies (e.g. `"Editing workflow "` when the path is a
   workflow script, in which case the displayed name becomes the file stem with no path). The
   prefix is a plain string *including* its trailing space, so a wrapper can measure and
   reserve it.
2. **The path**, in the path colour, carrying an OSC-8 link to the **absolute** file
   regardless of how it is displayed.
3. **A suffix**, shown **only on the collapsed one-liner**:
   - the diffstat ` +{ins}` in the insert colour, `/` in the detail colour, `-{del}` in the
     delete colour — emitted only when at least one of them is non-zero;
   - or, when the call carried several edits and no single diffstat would be meaningful,
     ` ({n} edits)` in the detail colour.
   - **Suppressed entirely when the summary is untrusted** — a multi-file call or a
     title-fallback path, where counts would describe only the first diff and silently lie.

   Expanded and fullscreen surfaces show the hunks themselves, so their headers stay bare.

**Path truncation** is surface-aware and *budget-aware*: the suffix width is computed **first**
and passed into the path formatter as a reservation, so the diffstat is never the thing that
gets cut.

- **Collapsed** → basename only, clipped width-aware (display columns, not bytes).
- **Expanded** → relative to the session cwd when the normalized path is lexically contained
  in it; otherwise the lexically-normalized absolute path, with `~` expanded first.
- **Fullscreen** → always the normalized absolute spelling.

The ellipsis is always `…` (U+2026), never `...`, and it costs exactly **one** reserved column.
A generic line clipper walks spans left to right, cuts mid-span, appends `…` inheriting the
last span's style, and drops the remaining spans.

A fish-style path shortener is worth having for surfaces with a tight budget: abbreviate each
non-final `/`-component to its first character; if still too wide, front-truncate at a `/`
boundary producing `…/tail/part.rs`; only then fall back to a plain right-truncate.

In expanded mode the header **word-wraps with a hanging indent** equal to
`bullet_width + prefix_width`, so a wrapped path aligns under the first path character.

**OSA today already implements almost exactly this** (`tools/file.rs:219-297`,
`:516-553`, `:559-602`):

- a semantic verb chosen per operation (`:249`) — Create / Edit / Update plan / Download;
- basename when collapsed, cwd-relative when expanded, OSC-8 always on the absolute path
  (`:262-266`, `:583-590`);
- `+{added}` green / `-{removed}` red on the collapsed header (`:535-546`);
- ` ({n} edits)` for multi-edit (`:524-530`);
- plus a changed-line range label `L42` / `L42-58` (`:398-404`) that has no counterpart in the
  reference and is a genuine improvement — **keep it**;
- plus a status bullet and a duration (`:569-599`, `tools/mod.rs:344-388`, `:390-404`).

Two gaps: OSA has **no untrusted-summary suppression**, so a multi-file edit shows the first
file's counts as if they covered the call; and OSA does not reserve the suffix width before
truncating the path, so a long path can eat the diffstat.

## C.2 Line numbers

**There is no `+` / `-` sigil column.** Change is conveyed by the *colour of the line number*
and the *background band on the row*. That is the single biggest visual difference from OSA
today, and it is what makes the reference's diffs read as code with annotations rather than as
a patch file.

Layout:

```
  {ln:>w}  {content}
  ^^      ^^
  indent  content gap
```

- `INDENT = "  "` (2 columns, configurable off).
- `GUTTER_GAP = " "` (1 column, dual mode only).
- `CONTENT_GAP = "  "` (2 columns).
- Width is computed **per hunk**, not per file: `w = ilog10(max_line_number) + 1`.
- Total gutter = `indent + w + 2` in single mode; `indent + w_old + 1 + w_new + 2` in dual.

**Single mode is the default** — one column showing the *relevant* line number:

| Tag | Number shown | Colour |
|---|---|---|
| Equal | new-file number | gutter colour (muted) |
| Delete | **old**-file number | delete foreground |
| Insert | new-file number | insert foreground |

**Dual mode** (opt-in, GitHub-style) shows both columns; a delete blanks the new column, an
insert blanks the old.

Backgrounds:

| Tag | Background |
|---|---|
| Equal | none |
| Delete | delete background |
| Insert | insert background |

**Two rendering regimes**, selected by whether the theme actually defines the bands:

- **Banded theme** (both backgrounds set) — changed rows get the band, and the row text keeps
  **full syntax highlighting**, foreground only, composited over the band.
- **Bandless theme** (backgrounds are `Reset`, i.e. the terminal's own) — no band; the whole
  changed row is painted a solid delete/insert foreground and syntax highlighting is
  **suppressed**. Context rows fall back to the muted context foreground when syntax yields
  nothing.

Choose the band colours so they **quantise to red and green rather than to gray** on a
256-colour terminal — a dark band that quantises to gray loses the add/remove signal entirely.
OSA's dark values (`style/themes.rs:46-51`) are `del_bg rgb(122,41,54)`, `add_bg rgb(34,92,43)`,
with word-highlight bands one step brighter; check them against a 256-colour quantiser.

Two independent switches govern how far the band reaches: `gutter_bg` (band starts at the row
start, including the gutter) and `indent_bg` (band includes the 2-column indent). **Both
default off** — the band covers the content area only, which keeps the number column legible
against it.

An empty content string paints a **single space** so the row still shows a visible band and
stays selectable.

**Wrapping.** Long lines wrap inside the content column. On continuation rows the gutter is
replaced by `" ".repeat(gutter_total)` and the background band continues. Styles are projected
onto the wrap segments; if the projection cannot be aligned, fall back to a solid foreground
per segment.

**Tabs are expanded to the configured tab width before anything else** — before highlighting,
before width measurement, before wrapping. Do it once, at the top.

**Syntax highlighting inside a diff** uses **two independent highlighters, one per side**. A
multi-line construct opened on a removed line must not leak into the added lines. Equal lines
render on the new side and *advance both*. On a banded theme the syntax foreground is
composited over the band; on a bandless theme, changed lines take a solid line foreground
instead and only Equal lines get syntax colour.

There is also a two-phase highlight upgrade worth knowing about, though it is optional: hunks
are first painted with a per-hunk highlighter (cheap, may mis-colour a construct that opened
above the hunk), then optionally re-painted from a **single full-file walk** that retains only
the lines the hunks reference. The upgrade **refuses** if any disk line differs from the hunk
text, so it can never rewrite displayed content. Caps: skip the full-file walk above 2 MB or
50 000 lines.

**OSA today** (`render/diff.rs`) does this:

- right-aligned gutter, width `ilog10(max) + 1`, computed across the whole diff rather than per
  hunk (`:66-77`);
- **a `+` / `-` / ` ` sigil column** after the number (`:344`);
- solid background bars padded to the full render width (`:350-355`);
- syntax highlighting composited foreground-over-band (`:213-259`), with the two-sided
  highlighter split already present (`:63-64` pre-highlights old and new separately);
- grapheme-aware wrapping inside the content column (`:363-391`);
- **no tab expansion** — a tab inside a diff line is one column to `unicode-width` and eight to
  the terminal, which shears the row.

The changes: expand tabs at the top; size the gutter per hunk; colour the number by tag and
drop the sigil (or keep the sigil behind a config flag for `NO_COLOR` legibility — see the risk
note in §F).

## C.3 Hunks and the gap between them

Hunks carry **3 lines of context** either side.

Between two hunks, emit a separator row with no background:

```
… 14 unchanged lines
… 1 unchanged line
…
```

- The separator glyph is configurable: `…` (default), `───`, `⋯`, or empty (no separator).
- The count is `next_hunk_first_new_line − prev_hunk_last_new_line − 1`, computed from the
  **new-file** line numbers of the bordering non-delete lines.
- **Omit the count when it cannot be trusted**: a hunk with no new-file lines, a non-positive
  gap, or non-monotonic line numbers. The last case happens on coalesced multi-call blocks
  where a later edit landed above an earlier one, because each call's hunks are numbered
  against its own snapshot. Fall back to the bare glyph.
- Singular/plural is handled (`1 unchanged line`).
- The separator is indented to match the diff body and styled muted.

Hunks carry at most **3 context lines** per side; leading and trailing all-context runs beyond
that are dropped, then blank context lines are trimmed from both ends. A no-op edit produces
zero hunks.

**Hunk stitching.** When several edits to the same file are coalesced into one block,
overlapping or adjacent hunks are folded into one in post-state coordinates: a context row that
a later call edited is swapped for its remove/add pair; a line edited twice collapses to
`-original +final` with no intermediate state; repeated context is dropped. The merge **bails
out to separate hunks** — falling back to gap-marker rendering — on non-monotonic or
non-adjacent pairs, text disagreement at a shared line number, pure deletes, unpaired inserts,
and multi-line replacement runs. The governing rule is *never render wrong content*; a
best-effort merge that might be wrong is worse than two hunks and a gap marker.

Separator rows are **not selectable** and they **break selection continuity** — each hunk gets
its own incrementing selection-range id, with the header occupying id 0 — so a drag-select
across a gap cannot silently splice two non-contiguous regions into one clipboard payload.

**OSA today** emits a bare dim `…` with no count and no indent (`render/diff.rs:85-90`), and
uses `grouped_ops(3)` for the 3-line context (`:57`). Adding the count is a small change with a
large legibility payoff — it is literally "the stuff at the end" the user liked.

## C.4 The trailing summary

Two distinct things are easy to conflate:

1. **The collapsed header suffix** `+12/-3` (§C.1) — where the counts live when the diff is
   *not* shown.
2. **A leading summary row above the hunks** — `Added 12 lines, removed 3 lines`, with the
   counts bold. This is what OSA emits today at the top of a collapsed edit card
   (`tools/file.rs:353-376`), hanging off the header via the `⎿` connector.

Both are legitimate and they are not redundant, because they appear in different states. Keep
OSA's summary row for the collapsed-with-preview state, and keep the header suffix for the
one-liner state. What must be added is the **untrusted-summary suppression** in both places.

Counting rule: added = inserted lines, removed = deleted lines, context excluded. `No changes`
when both are zero. Singular/plural handled. OSA gets all of this right at
`tools/file.rs:341-375`.

## C.5 Word-level intra-line diffing

Present, and worth keeping exactly as OSA has it:

- pair the i-th delete with the i-th insert within a change run (`render/diff.rs:274-318`);
- compute a word-level ratio and **skip word highlighting when more than 40% of the line
  changed** (`:10`, `:139-145`) — past that threshold the highlight is confetti and plain
  `+`/`-` reads better;
- changed words get a **darker background, no bold** (`:150-186`), so the highlight composites
  cleanly under syntax foreground.

The reference does not have this. It is an OSA advantage; do not regress it.

## C.6 Truncation and expansion

- Collapsed edit card: full hunk diff, capped at **20 rows**, then `… +N lines (ctrl+o to
  expand)` in dim (`tools/file.rs:293`, `tools/mod.rs:407-419`).
- Expanded: capped at 20, or 10 in compact mode (`tools/file.rs:321-322`).
- `ctrl+o` toggles the last tool cell's expansion (`config/keybindings.rs:354`,
  `app/keymap_dispatch.rs:174-182`).
- Whether edit blocks *start* collapsed or expanded is a preference, resolved as: an explicit
  config value wins; unset defers to a global collapsed-blocks flag.

OSA already matches. Three additions worth making.

**(a) A fullscreen block viewer** — a third state above expanded, where the header shows the
full absolute path, no cap applies, and the diff is laid out at a fixed very wide width in
no-wrap mode with per-row metadata (tag, text, old line, new line) kept alongside each rendered
row.

**(b) A print-once row cap, which OSA needs more than the reference does.** In a retained-widget
TUI an expanded 5000-row diff is merely long. In a **print-once** architecture — which is
exactly what OSA is, committing finalized blocks into native scrollback via `insert_before` —
an uncapped commit dumps 5000 rows the user cannot scroll back past usefully and cannot
re-render. The rule:

- Cap committed rows at a configurable `max_commit_rows`, default **2000**, `0` meaning
  unbounded.
- **Lay the block out at its full desired height**, so wrapping is byte-identical to an
  uncapped commit, then commit only the first `cap` rows. Do not re-wrap at the cap; that
  changes the content.
- The final committed row becomes, with `hidden = full_height − (cap − 1)`:

  ```
  … 143 more lines — /transcript to view
  ```

  U+2026 and U+2014, dim, with an explicit `Reset` background so it does not inherit a band.

**(c) A copyable unified patch.** `y` on a selected edit block should yield real
`git apply`-able text — the *only* place `+`/`-`/space prefix characters belong:

```
--- a/{path}
+++ b/{path}
@@ -{old_start},{old_count} +{new_start},{new_count} @@
 context line
-removed line
+added line
```

`old_start` = the first non-insert row's old number (default 1); `new_start` = the first
non-delete row's new number; `old_count` = count of non-insert rows; `new_count` = count of
non-delete rows. Strip trailing `\r`/`\n` and re-append exactly one `\n`. An empty hunk list
yields an empty string. A separate `Y` copies just the path.

This matters because it resolves the sigil question in §C.2 cleanly: **the screen does not need
`+`/`-` prefixes if the clipboard has them.** The user who wants a patch gets a patch.

---

# Part D — Hook lifecycle and hook-outcome display

The *rendering* of hook counters is already specified in
`docs/design/tui-commit-architecture.md` Part 3, including the bracket shapes, the colour
roles, the zero case and the OSA port plan. This section records the **lifecycle model** that
sits underneath it, and the per-run detail rows that Part 3 does not cover.

## D.1 The event set

| Event | Gate | Fires |
|---|---|---|
| `session_start` | observe | once when a session actor is created; `source` is `new` (empty history) or `load` (rehydrated) |
| `user_prompt_submit` | observe | **after** the user message is committed to chat state — it cannot gate or rewrite the prompt |
| `pre_tool_use` | **tool gate** | after MCP resolution and argument validation, **before** the permission prompt. For meta-dispatch tools the *resolved* tool name is used, so matchers key on the real tool |
| `post_tool_use` | observe | after a tool returns successfully |
| `post_tool_use_failure` | observe | after a tool errors |
| `permission_denied` | observe | after policy or the user refuses a permission request |
| `stop` | **stop gate** | genuine turn end (a final message with no further tool calls). **Not** on user interrupt. Also fired observe-only at session teardown, with the decision discarded and blocked results demoted to success so the transcript does not report a block that had no effect |
| `stop_failure` | observe (output *and* exit code ignored) | turn ended on an API error; `error` is one of `rate_limit`, `authentication_failed`, `invalid_request`, `server_error`, `max_output_tokens`, `unknown` |
| `notification` | observe | user-attention events only — permission prompts, agent errors, task completion, idle. Internal and high-frequency updates deliberately excluded |
| `subagent_start` | observe | a subagent is spawned |
| `subagent_stop` | **stop gate** | a subagent finishes |
| `pre_compact` / `post_compact` | observe | around context compaction; `source` is `manual` or `auto` |
| `session_end` | observe | teardown; `reason` is `channel_closed` or `shutdown` |

Only three events are gates: `pre_tool_use`, `stop`, `subagent_stop`. **Assert that set in a
test** — it is the kind of invariant that drifts silently.

Event keys accept PascalCase, snake_case and camelCase spellings, plus per-operation aliases
for the tool events. Unknown keys are **skipped with a warning**, never an error.

**Envelope**, identical for every event and flattened around the payload:
`hook_event_name`, `session_id`, `cwd`, `workspace_root`, `timestamp` (RFC3339), and optional
`transcript_path`, `client_identifier`, `prompt_id`, `permission_mode`. Tool input and result
are truncated at **128 KB** with `" [truncated]"` appended and a corresponding boolean flipped.

## D.2 What a hook may do

**Nothing anywhere modifies the payload.** No tool-input rewriting, no prompt rewriting, no
result rewriting. The options are: deny, block-and-continue, force-stop, inject context (stop
gates only), or observe.

**`pre_tool_use`** — allow/deny only:

```json
{"decision": "allow" | "deny", "reason": "…"}
```

- A JSON `deny` is honoured **on any exit code** (fail-safe).
- A JSON `allow` **loses to exit 2** — stdout is not trusted on exit 2.
- Any decision string other than `allow`/`deny` is a **failure**, not a silent allow, so typos
  surface.
- Deny **short-circuits** the chain.

**`stop` / `subagent_stop`** — block, force-stop, inject context:

```json
{"decision": "block"|"approve", "reason": "…", "continue": false,
 "stopReason": "…", "hookSpecificOutput": {"additionalContext": "…"}}
```

- `block` + reason → the agent keeps working; the reason is fed back to the model.
- `continue: false` → **force-stop**, overriding all blocks. First force-stop wins.
- `additionalContext` alone, with no block, **also keeps the agent working**.
- Blocks and context **accumulate across all hooks** — no short-circuit, so the model sees
  every reason at once. Continuations are capped at **8 per turn**.

**Exit-code ladder**, when stdout carries no usable JSON:

| Code | Observe | Tool gate | Stop gate |
|---|---|---|---|
| 0 | success | allow | allow-stop |
| 2 | failure | **deny**, reason = first stderr line, capped 256 chars | **block**, reason = full trimmed stderr |
| other | failure | failure (fails open) | failure (fails open) |

The asymmetry on exit 2 is deliberate: a deny reason is a one-line user-facing message, while a
stop block's feedback is model-facing instruction text and is often multi-line.

**Fail-open, uniformly.** Timeouts, crashes, command-not-found, malformed output and unknown
decision values all fail open — recorded and shown, but the action proceeds. Induced-failure
bypass is explicitly out of the threat model. A **bad matcher regex fails closed** (matches
nothing), which is the opposite direction and also deliberate.

## D.3 Runner

- **Sequential, in config order, awaited inline.** No parallelism across file hooks.
- **Timeouts:** 5 s default; **600 s for stop gates**, because they run real verification
  (builds, tests) and fail open on timeout, so a short default silently disables a policy. A
  session-end dispatch has a hard 5 s total budget.
- **Command hooks:** the envelope JSON on stdin, written **concurrently with output draining**
  and under the timeout, so a hook that never reads stdin cannot block the write outside the
  deadline. stdout and stderr capped at 64 KB each. The child is **detached from the
  controlling terminal** — otherwise a subprocess like a pinentry opens `/dev/tty` and corrupts
  the TUI — and enrolled in a process group so grandchildren are reaped on timeout or session
  close.
- **Env vars are applied last** so they always beat a user-declared `env` map, and the same
  keys are **stripped from user maps at load** with a warning. A hook script reads them for
  policy and audit, so they must not be spoofable.
- **HTTP hooks:** HTTPS only; the host is resolved and every resolved address checked against
  RFC1918, link-local, CGNAT and unspecified ranges, with **loopback explicitly allowed** for
  local dev; redirects disabled entirely. All logging and display use the **pre-expansion** URL
  so `env`-map secrets never leak.
- **Matching:** empty or `*` matches all; a pattern of only `[A-Za-z0-9_|]` is an **exact**
  match per `|`-separated term (plus alias expansion), *not* a regex — naively anchoring an
  alternation as `^a|b|c$` anchors only the first and last term and silently over-matches;
  anything else is an unanchored regex. Whitespace is **not** trimmed, so `"   "` matches
  nothing rather than becoming match-all. What the matcher tests against varies per event
  (tool name, notification type, subagent type, source, reason); `stop` and
  `user_prompt_submit` **ignore matchers entirely** and warn if one is configured.
- **Trust:** project-level hook config is gated wholesale on folder trust, using the same trust
  store as repo-local MCP. When untrusted, the project source list is emptied *before any file
  is read*. User-global sources are never gated. The verdict **fails closed on an unrecorded
  decision**.

## D.4 UI surfacing

**Not silent, but quiet.** Suppressed entirely when the result list is empty **or every result
is skipped**. Otherwise:

- **Collapsed:** the `[hooks: …]` counter on the tool header, per
  `docs/design/tui-commit-architecture.md` §3.3.
- **Expanded:** a bold-muted section header at 4-column indent naming the event, then one row
  per hook at 6-column indent:

| Outcome | Row | Glyph and colour |
|---|---|---|
| Success | `✓ <name> (12ms)` | `✓` (U+2713; `√` on legacy Windows) in success; name and elapsed muted |
| Skipped | `- <name> skipped` | literal `- `, all muted |
| Blocked | `↩ <name> (3ms)` + up to 3 detail rows at 10-column indent | `↩` (U+21A9) in the **running/warning** accent, not error; detail text same colour |
| Failed | `✗ <name> (3ms)` + up to 3 error rows at 10-column indent | `✗` (U+2717; `x` on legacy Windows) in error; error text error-coloured |

- Detail and error text truncate at **120 chars**, capped at **3 rows**. A redundant
  `hook '<name>' ` prefix is stripped from error text.
- A muted `───` separator sits between the tool's own output and the hook section.
- **A timeout is not a distinct visual** — it is a Failed row whose text is
  `timed out after Nms`.
- **Blocked is deliberately distinct from failed**: a block is the hook's decision, not a
  malfunction.

Detail strings: `denied: {reason}` for a tool deny; `blocked stop: {reason}`;
`prevented continuation: {reason}`.

**A blocked tool call renders four ways differently:**

1. the tool block itself renders as **Failed**, with output text literally
   `Hook denied: {reason}` — the same string the model receives;
2. an extra annotation row below it:
   `⚠ \`{tool}\` blocked by hook \`{hook}\`: {reason}`;
3. the attached `pre_tool_use` row shows the magenta `↩`, not the red `✗`;
4. the collapsed counter still counts it **green** — only the labelled aggregate shape names it
   as `blocked`, and a blocked hook does **not** mark a verb group as failed.

Other annotation one-liners:

| Situation | Text |
|---|---|
| Force-stop | `⚠ Hook \`{name}\` stopped the agent: {reason}` |
| Stop block, continuing | `↩ Stop blocked by hook \`{name}\`, continuing: {reason}` |
| Context-only, continuing | `↩ Stop hook feedback, continuing: {context}` |
| Continuation cap | `⚠ Stop hooks kept the agent working 8 times this turn: limit reached, ending the turn` |

**Hooks never toast.** Hook execution and hook annotations are excluded from the notification
path entirely; they belong in the transcript, next to the call they wrapped.

## D.5 OSA today

OSA's **backend model maps almost exactly.** `lib/optimal_system_agent/agent/hooks.ex:22-30`
documents the same lifecycle vocabulary, and the type at `:64-89` is a superset —
OSA additionally has `pre_response`, `pre_session_resume`, `session_error`, `task_completed`,
`task_failed`, `permission_request`, `permission_granted`, `file_changed`, `file_read`,
`worktree_create`, `worktree_remove`. The handler protocol
(`lib/optimal_system_agent/agent/hooks.ex:36-40`) is `{:ok, payload}` / `:allow` / `:skip` /
`{:block, reason}` / `{:rewrite_input, …}` / `{:rewrite_output, …}` / `{:inject_context, …}` —
strictly *more* capable, since OSA can rewrite input and output. The shell runner
(`lib/optimal_system_agent/agent/hooks/shell_hook.ex:21-44`) already implements the stdin-JSON
protocol, the exit-0 JSON shape with `decision` / `reason` / `hookSpecificOutput`, the exit-2
blocking convention with stderr as the reason, the per-hook timeout (default 600 s, `:49`), and
the blocking-event list (`:54-60`).

**The gap is entirely in the TUI, and it is total.** The TUI knows about exactly two hook
events: `HookBlocked { hook_name, reason }` (`event/backend.rs:432`) and
`HooksLoaded` (`:464`). A block surfaces as a **transient warning toast**
(`app/handle_backend.rs:2137-2142`) — it scrolls away, it is not attached to the call it
blocked, and there is no record of it in the transcript. Successful and failed hook runs are
invisible.

The blocking first step is a backend `HookRun` event carrying
`{tool_call_id, phase, hook_name, outcome, elapsed_ms, detail}`, emitted from the dispatch path
for both the sync and async runners. Everything in §D.4 and in
`docs/design/tui-commit-architecture.md` §3 is unimplementable without it.

---

# Part E — What OSA already does well

These are not to be regressed by anything in Part F.

1. **Escape-aware line layout.** `render/cells.rs` lays lines out with true visible widths and
   attaches each escape to the following cell's symbol, because ratatui measures ESC as one
   column and truncates rows carrying OSC-8. Finalized rows go to native scrollback and can
   never be repainted, so this is not cosmetic.
2. **Every row owns its full width.** `render/markdown.rs:711-728` pads table rows out to the
   region width so a mis-measured wide glyph's overhang lands on space the row already owns.
   The note at `:694-711` is the definitive statement of the hazard.
3. **Input scrubbing at one entry point.** `render/markdown.rs:36` scrubs the whole document
   once, so every construct below it — and every construct added later — is covered.
   `render/diff.rs:53-54` does the same for both diff sides. Keep the single-entry discipline.
4. **Styled wrapping, not source wrapping.** `render/markdown.rs:1177-1320` wraps the *parsed*
   spans, groups words across span boundaries, and treats an escape-carrying span as atomic.
   The comment at `:1152-1176` explains why wrapping raw markdown is wrong.
5. **Correct grapheme and emoji measurement.** `render/markdown.rs:1015-1021` measures whole
   strings rather than per char, because ZWJ sequences resolve at the string level.
6. **The resumable syntax highlighter.** `render/syntax.rs:66-120` and the streaming
   highlighter below it, with the measurement that justified them.
7. **Word-level intra-line diffing with a change-ratio cutoff** (`render/diff.rs:10`,
   `:139-186`) — the reference has no equivalent.
8. **The `L42-58` changed-range label on edit headers** (`tools/file.rs:398-404`).
9. **Failure legibility as text, not colour.** `tools/mod.rs:150-195` promotes a tool's error
   into the body rather than relying on a red bullet, explicitly because the bullet is invisible
   under `NO_COLOR` and to a red/green-colour-blind reader. That principle should govern the
   `+`/`-` sigil decision in §F too.
10. **Legacy-console glyph fallbacks of identical column width** (`render/glyphs.rs`).
11. **The narrow-terminal table degradation** to ` · `-joined wrapped text
    (`render/markdown.rs:608-622`) and the conditional `▼` overflow marker (`:682-692`).
12. **The mutating-hyperlink refusal for half-streamed links**
    (`render/markdown.rs:1608-1627`).
13. **Fixed-height inline slots** for anything that grows mid-turn
    (`components/chat/thinking_box.rs:136-146`), which is what keeps the composer from walking
    down the screen.

---

# Part F — Implementation plan

Ordered so that each step is independently shippable and independently revertible. Risky steps
are called out; a risky step must not be bundled with a cosmetic one.

### Phase 1 — spacing and inline (visible win, low risk)

1. **Delete the manufactured blank rows** after h1, h2 and setext headings
   (`render/markdown.rs:145`, `:187`, `:196`). Add Modifier 3 (§A.6): one blank row before an
   opening fence when the previous row is non-empty. Pin the `# H\n\nP\n\n` → 3 rows example
   as a test.
2. **Inline code → code colour + BOLD** (`render/markdown.rs:1416`).
3. **Horizontal rule → `───`, three columns** (`render/markdown.rs:204`).
4. **Drop `CROSSED_OUT` on checked task items** (`render/markdown.rs:249`).
5. **Implement `~~x~~` as strikethrough and demote `~x~` to literal** — replacing the current
   blanket disable (`render/markdown.rs:14-15`).
6. **Fix the ordered-list continuation indent** to measure with `UnicodeWidthStr` rather than
   `.len()` (`render/markdown.rs:327`).
7. **Add the soft-break continuation guard**: do not collapse a soft break when the next byte
   is `' '`, `'\t'`, `'>'` or `'|'` (`render/markdown.rs:411-446`).

### Phase 2 — code blocks

8. **Row-level code background.** Apply it as a `Line`-level style so it paints trailing empty
   space, including on blank rows inside the block and on the final newline-less row of an
   unterminated fence. Track membership with a flag, not a range test.
   **Risky:** this changes every row's background in a block that OSA hands to native
   scrollback. Verify visually on light and dark themes, under `NO_COLOR`, and in a
   16-colour terminal before merging — a background that quantises to the foreground colour
   makes code unreadable and cannot be repainted.
9. **Untagged/unknown-language fences take body colour plus the background**, not `faint`
   (`render/syntax.rs:390-396`).
10. **Take the first whitespace-delimited word of the info string** for language resolution, so
    ` ```rust ignore ` highlights (`render/markdown.rs:81-82`).
11. **Move to the extended syntect syntax set** (`render/syntax.rs:13-15`).

### Phase 3 — tables

12. **Preserve inline styling on wrapped cells.** Slice the original styled spans onto each
    wrapped row using a **monotonic per-column source cursor** (§A.2.7). This replaces the
    markup-stripping fallback at `render/markdown.rs:911-925`.
    **Risky:** the cursor is the whole correctness argument. Without it, repeated substrings
    re-match earlier bytes and link styling leaks. Test with a cell containing a linked `aa`
    followed by a plain `aa`.
13. **Add the two-floor width model** — word-minimum and grapheme-floor — ahead of the
    existing water-fill (`render/markdown.rs:774-824`), and move the narrow-terminal
    degradation trigger to after the floors have been tried.
14. **Add the custom word separator** for cell wrapping (§A.2.5), including URL protection.
15. **Add the grapheme clip** on the over-wide side of `pad_lines_to_width`
    (`render/markdown.rs:711-728`), with no ellipsis.

### Phase 4 — thinking

16. **Add a third display mode.** `DisplayMode::{Collapsed, Truncated, Expanded}` on
    `ThinkingBox`, with `Truncated` the default while running: header, blank, `…`, last 3
    wrapped rows. Reserve a constant 5-row slot for it, per §B.6.
17. **Replace the conditional dim with a 0.7 colour blend toward the background**
    (`components/chat/thinking_box.rs:197-200`), keeping the italic and gating it off on legacy
    Windows consoles.
18. **Split the header label bold from the duration muted**
    (`components/chat/thinking_box.rs:239-260`); keep `∴` and keep the promoted `· Title`.
19. **Bind `ctrl+e` to cycle the three modes**, keep `alt+t` as an alias, and drop the toast
    (`config/keybindings.rs:357`, `app/keymap_dispatch.rs:199-205`).
20. **Do not arm the local timer on replay**, so a rehydrated session shows the real duration
    rather than `Thought for 0.0s` (`components/chat/thinking_box.rs:56-74`). **Delete empty
    thinking blocks** rather than rendering them.
21. **Replace the two-state toggle with the fold state machine** of §B.6, including the sticky
    transcript-wide mode, and add the **expand ring** for the print-once path so an expand
    re-commits an uncapped copy below the conversation.
    **Risky:** print-once means a block marked-but-unprinted can never be emitted again. A
    failed terminal write must requeue at the front of the ring, not drop. Test the failure
    path explicitly.
22. **Add a `show_thinking_blocks` preference** that makes thinking entries render zero rows
    and go transparent to grouping.

### Phase 5 — diffs

23. **Expand tabs at the top of the diff pipeline**, before highlighting, measurement and
    wrapping (`render/diff.rs:39`).
    **Risky in the sense that it is load-bearing:** every width computation downstream assumes
    it. Do it first and alone.
24. **Size the gutter per hunk** rather than across the whole diff (`render/diff.rs:66-77`).
25. **Colour the line number by tag** — delete foreground on a delete, insert foreground on an
    insert, muted on context — and show the **old** number on deletes (`render/diff.rs:338-344`).
26. **Count the gap between hunks**: `… N unchanged lines`, computed from bordering new-file
    line numbers, falling back to a bare `…` when the numbers are missing or non-monotonic
    (`render/diff.rs:85-90`).
27. **Reserve the header suffix width before truncating the path**, so a long path can never
    eat the diffstat (`tools/file.rs:262-279`).
28. **Add untrusted-summary suppression** for multi-file and title-fallback edit calls, in both
    the header suffix and the `Added N lines, removed M lines` row (`tools/file.rs:254-257`,
    `:353-376`).
29. **Add the copyable unified patch** (§C.6c) and a path-only copy.
30. **Add the print-once row cap** (§C.6b): lay out at full height, commit `min(full, 2000)`
    rows, and make the last committed row the `… N more lines — /transcript to view` marker.
31. **Consider dropping the `+`/`-` sigil column** (`render/diff.rs:344`).
    **Risky, and the one item here that should not be done on aesthetics alone.** The sigil is
    the only *textual* signal of add-versus-remove; the colour and the band are the only others,
    and both vanish under `NO_COLOR` and in a monochrome terminal. This is exactly the failure
    mode `tools/mod.rs:150-170` was written to prevent. **Recommendation: keep the sigil when
    the detected colour level is `None`, drop it otherwise**, and make that conditional a
    single function so it is testable.

### Phase 6 — streaming correctness

32. **Add explicit depth tracking** (blockquote, list, item, table) to the freeze scan, so a
    blank line inside a loose list cannot freeze a prefix mid-list
    (`render/markdown_stream.rs:162-192`).
33. **Add the closed-fence memo** with a 256 KB byte budget, cleared wholesale on overflow.
34. **Add the streaming-equals-batch equivalence test** at char-by-char, `[3,5,7,11]` and
    `[50,100,200]` granularities, in both modes. This is the test that makes every later
    streaming change safe.

### Phase 7 — hooks

35. **Backend: emit a `HookRun` event** carrying
    `{tool_call_id, phase, hook_name, outcome, elapsed_ms, detail}` from both the sync and async
    dispatch paths in `lib/optimal_system_agent/agent/hooks.ex`. **Blocking step — nothing else
    in this phase is implementable without it.** Keep `HookBlocked`
    (`event/backend.rs:432`) as a deprecated alias until it lands.
36. **Attach runs to the call** by `tool_call_id` on `ToolCallData`, never by tool name — hooks
    land out of order for the same reason results do.
37. **Render the per-run detail rows** of §D.4 in the expanded tool cell, and the counter of
    `docs/design/tui-commit-architecture.md` §3 in the collapsed header.
38. **Render the blocked-tool annotation row** and stop it from being a toast
    (`app/handle_backend.rs:2137-2142`).

### Sequencing constraints

- Phase 1 before Phase 6: the spacing rule must be stable before the freeze scan is changed,
  or a streaming-vs-batch divergence will be attributed to the wrong change.
- Step 23 before steps 24–26: every gutter and wrap computation depends on tab expansion.
- Step 12 before step 13: the width model is only worth improving once wrapped cells keep their
  styling; otherwise a better allocation just produces better-looking stripped text.
- Step 29 before step 31: the clipboard must carry `+`/`-` before the screen stops showing it.
- Step 35 before 36–38, absolutely.
- Step 8, step 21 and step 31 should each ship alone, with a visual check, not bundled.
