# OSA LaTeX Library

Reusable, dependency-free LaTeX building blocks the `latex-author` subagent
`\input`s to produce consistent, compile-clean documents. Everything here is
plain `.tex` content: no code, no packages to install. All files compile under
[`tectonic`](https://tectonic-typesetting.github.io/) (self-contained) and also
under `pdflatex` — the preambles deliberately use `fontenc[T1]` + `lmodern`
rather than `fontspec`, so no XeTeX/LuaTeX is required and no shell-escape is
ever needed.

## Files

| File | Purpose |
|------|---------|
| `macros.tex` | Shared math macros and theorem environments. `\input` **after** `amsmath`/`amssymb`/`amsthm` are loaded (the article/report preambles do this for you). |
| `preambles/article.tex` | Modern `article` preamble: encoding, `geometry`, `amsmath`/`amssymb`/`amsthm`/`mathtools`, `graphicx`/`tikz`, `booktabs`, `siunitx`, `microtype`, `csquotes`, `xcolor`, `hyperref` (loaded last), then `\input`s `macros.tex`. |
| `preambles/report.tex` | `report`-class variant: adds `fancyhdr` running heads for chapters/titlepage documents. |
| `preambles/beamer.tex` | Clean `beamer` preamble: `Madrid` theme, navigation symbols suppressed, `amsmath`. (Does **not** load `macros.tex` — `amsthm` theorem definitions clash with beamer's built-in theorem blocks.) |
| `templates/base-article.tex` | Canonical end-to-end article skeleton: title/author/date, abstract, math (`\[...\]` + `align`), a `booktabs`+`siunitx` table, and a `tikz` figure placeholder. Copy this to start a document. |
| `templates/base-beamer.tex` | Minimal beamer deck: title slide + two content frames. |

## How to `\input` the library

Every template defines a single root pointer, `\LatexLibRoot`, holding the path
to this `priv/latex/` directory **with a trailing slash**. The preambles resolve
`macros.tex` through the same pointer, so you only set it once:

```latex
\documentclass[11pt,a4paper]{article}
\providecommand{\LatexLibRoot}{../}          % path to priv/latex/ (trailing slash)
\input{\LatexLibRoot preambles/article.tex}  % pulls in macros.tex automatically
```

From `templates/`, the correct value is `../`. If you copy a template somewhere
else, set `\LatexLibRoot` to that location's relative/absolute path to
`priv/latex/` (keep the trailing slash), e.g. `{/home/pedroafonso/OSA/priv/latex/}`.

## Compiling with tectonic

From the directory containing your `.tex` file:

```sh
tectonic base-article.tex
```

This resolves the `\input` paths relative to the source file's directory and
emits `base-article.pdf` alongside it. Useful flags:

```sh
tectonic --outdir out base-article.tex   # write artifacts to ./out
tectonic --keep-logs base-article.tex    # keep the .log for debugging
```

`beamer` decks compile identically:

```sh
tectonic base-beamer.tex
```

## House style

- **Tables:** use `booktabs` rules (`\toprule`/`\midrule`/`\bottomrule`) — never
  `\hline` or vertical rules. Align numeric columns with `siunitx` `S` columns.
- **Units:** always typeset with `siunitx` (`\qty{9.8}{\meter\per\second\squared}`,
  `\num{1.2e-3}`), never hand-typed `m/s`.
- **Display math:** use `\[...\]` or `align`/`equation`, never `$$...$$` (which is
  plain-TeX and breaks amsmath spacing).
- **Delimiters:** use the paired-delimiter macros (`\abs{x}`, `\norm{v}`,
  `\set{...}`) so sizing stays consistent; their `*`-form forces `\left..\right`.
- **hyperref:** load it **last** among packages (the preambles already do). Colored
  links via a muted navy, no boxes.
- **Cross-references:** label everything and reference with `\ref`/`\eqref`; links
  are clickable through `hyperref`.
- **Fonts/encoding:** rely on the preamble's `fontenc[T1]` + `lmodern`; do not add
  `fontspec` (keeps pdflatex compatibility).
- **Figures:** prefer `\includegraphics`; the article template ships a `tikz`
  placeholder so a fresh skeleton compiles before any asset exists.
