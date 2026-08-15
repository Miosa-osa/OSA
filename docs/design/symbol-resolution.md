# Symbol resolution: what to build, and what not to

**Date** 2026-08-15 · **Status** cheap path shipped; `code_symbols` now always-loaded; LSP client designed and **not recommended for the current benchmark**
**Targets** `docs/roadmap-beat-the-field.md` Tier 1 item 4 ("An LSP client. Codex has one.")
**Companion to** `docs/design/context-free-edits.md` (the same problem, on the write side)

---

## 0. The claim being tested

> Codex ships an LSP client. We do text search where they do symbol resolution — a
> real capability gap on any refactor.

The gap is real as stated. What follows is the evidence about whether closing it
*with a language server* buys anything on the workloads we are actually scored
on, and what the cheaper substitute is worth. Two measurements decided it, and
both contradicted the intuition the roadmap item was written from.

---

## 1. What we already had, and whether it worked

`code_symbols` — a per-file symbol outline. Line-anchored regexes, one file per
call, no index, no cross-file anything.

Three things were true about it before this pass:

1. **It was never called.** Across 118 SWE-bench / SWE-bench-Pro transcripts
   (3,268 tool calls total, of which 868 `file_grep`) it appears **zero times**.
   Across 142 Terminal-Bench event logs (6,637 tool calls) it appears **once**
   — `fix-code-vulnerability`, on `/app/bottle.py`. *[measured]*
2. **It was unreachable for part of that period.** It carried `always_load?` and
   `should_defer?` simultaneously, which meant its prose was billed on every
   request while its name was absent from the native `tools` array — paid for on
   every request, callable on none. That contradiction is fixed (the tool is now
   consistently deferred), and `Agent.Loop.ToolDiscovery` now widens the array on
   a `tool_search` hit, so a deferred tool is genuinely reachable mid-turn.
3. **It answered the wrong question.** It returned an *outline*: names and line
   numbers. The question the transcripts actually ask is not "what is in this
   file" but "what does `X` say" — and an outline sends you to a `file_read` to
   find out.

Point 3 is the one that mattered, and it is what the shipped change addresses.

---

## 2. The measured demand

### 2.1 Symbol location is already grep's job, and grep is good at it

Across the 118 transcripts *[measured]*:

| | count | mean result |
|---|---:|---:|
| `file_grep` calls | 868 | 923 B |
| …with a definition-shaped pattern (`def `/`class `/`function `/`const `/`export `) | **307 (35%)** | 895 B |
| …**immediately followed by a `file_read`** | **312 (36%)** | — |

A `file_grep` for `def delete_cookie` returns **17 bytes**. Symbol *location* is
solved, cheaply, by a tool that is always loaded. Nothing an LSP does about
finding a definition improves on 17 bytes.

### 2.2 Symbol *reading* is where the bytes go

The 312 grep-then-read pairs are one behaviour: locate the definition, then read
a window around it to see what it says. That window is a guess. The transcripts
show both failure modes of guessing — 154 reads classified as *"around line N /
what's at this offset"*, mean 1,737 B, and 53 as *"what does the file look like
now"*, mean 2,091 B.

Related and larger: **737 of 1,184 `file_read` calls (62%) re-read a path already
read earlier in the same transcript**, ≈1.34 MB of the corpus's 2.75 MB of read
payload. *[measured]*

So the shape of the demand is: *give me exactly one definition, and nothing
around it.*

### 2.3 What the benchmark environment allows

A census of **all 89 Terminal-Bench 2.1 task images**, probed with
`docker run --rm --network none … command -v` — 89/89 responded, so this is a
complete count and not a sample *[measured]*:

| tool | images (of 89) |
|---|---:|
| ctags / universal-ctags / etags | **0** |
| clangd | **0** |
| gopls | **0** |
| pyright | **0** |
| pylsp | **0** |
| rust-analyzer | **0** |
| typescript-language-server | **0** |
| tree-sitter | **0** |
| ripgrep (`rg`) | **0** |
| jq | **0** |
| **any language server at all** | **0** |
| perl | 89 (100%) |
| python3 | 63 (71%) |
| gcc | 29 |
| node | 4 |
| go, cargo, java, ruby | 0 |

Base images are a Debian-family monoculture: 41 × `python:3.13-slim-bookworm`,
40 × `ubuntu:24.04`, 8 others. `allow_internet = true` in 89/89 `task.toml`, so
installing a server at runtime is *possible* — against an agent budget of
**900 s in 48 of the 89 tasks**.

### 2.4 There is usually nothing to resolve

Source files under `/app` in the live images *[measured]*:

| | files | bytes |
|---|---:|---:|
| median | **0** | **0** |
| p75 | 1 | 3.1 KB |
| p90 | 10 | 211 KB |
| max | 2,697 | 19.1 MB |

* **42 of 89 tasks ship no pre-existing source code anywhere** — the agent writes
  the program from scratch.
* **80 of 89 have ≤5 source files. 81 of 89 have ≤20.**
* Only **5 have >50**, and 4 of those 5 are C / OCaml / Scheme
  (`fix-ocaml-gc` 2,697 files, `crack-7z-hash` 1,654, `make-mips-interpreter` 197,
  `make-doom-for-mips` 193, `sanitize-git-repo` 83).
* **25 of 89 have no source language at all** — git surgery, QEMU, nginx,
  packaging, recovery.

Language mix *[inferred from reference-solution extensions + `/app` contents]*:
Python 43, C/C++ 13, R 3, Rust 2, JS/TS 2, **Go 0**, other 6, none 25.

---

## 3. The recommendation

**Do not build an LSP client for Terminal-Bench.** Five measured facts, any one of
which would weaken the case and which together close it:

1. **Zero of 89 images have a language server.** Every one would have to be
   installed at runtime, per language, out of a 900-second budget. The two
   easiest servers to install (`pyright`, `pylsp`) both need a Node or pip
   install; 85 of 89 images have no `node` at all.
2. **The median task has no source code.** Symbol resolution has nothing to
   resolve on roughly 80% of the benchmark. The bottleneck on 42 of 89 tasks is
   writing code that does not exist, not navigating code that does.
3. **Where the big codebases are, the servers are hardest.** 4 of the 5 tasks
   with >50 files are C, OCaml and Scheme — `clangd` plus an OCaml server, not
   the Python one.
4. **Where Python dominates, the files are tiny.** The 43 Python tasks are the
   1–5 file ones. A language server would be deployable exactly where it adds
   least.
5. **A server that is sometimes absent is worse than one that never exists.** A
   capability whose availability depends on the task image makes every result
   environment-dependent — the same argument that rejected the `bwrap` sandbox in
   `context-free-edits.md` §2.1b.

This is a statement about **Terminal-Bench 2.0/2.1**, and it should not be
generalised past it. On SWE-bench-style workloads — a real repository, hundreds
of files, an established toolchain in the image — the calculus is different, and
§5 is the design for that case, kept ready rather than built.

**Ship the cheap path instead**, and note that "cheap" here does not mean ctags:
ctags is *also* absent from 89/89 images. The only symbol resolution that is
free everywhere is the one that runs **inside OSA, in Elixir, over bytes it
already has permission to read**. That is `code_symbols`, and it needed one
capability it did not have.

---

## 4. What shipped

### 4.1 `code_symbols` returns definitions, not just an outline

New optional `name` parameter. With it, the tool returns the **source of that one
symbol** and its line range; without it, the outline is unchanged.

```
code_symbols {"path": "/tmp/pipeline.py", "name": "process_batch"}

/tmp/pipeline.py:484-495  [function] process_batch
def process_batch(records, retries=3):
    """Process a batch of records with bounded retries."""
    results = []
    ...
    return results
```

Measured on a 15,667-byte Python file, answering *"what does `process_batch`
do?"* *[measured]*:

| route | bytes of context | calls |
|---|---:|---:|
| `file_grep` + `file_read` (40-line window) | 1,381 | **2** |
| **`code_symbols` with `name`** | **517** | **1** |
| `file_read` (whole file) | 15,745 | 1 |

**2.7× fewer bytes and half the round trips** against the pattern the transcripts
actually show, and 30× against the whole-file read. Cost is O(the definition),
not O(the file) and not O(the window someone guessed).

The body-extraction rule is deliberately simple and chooses itself from the
source rather than from the extension, because brace style is a property of code
and not of language:

* if the definition opens a brace block — at the end of the header, or on its own
  line as Allman style does — the body ends when that brace closes;
* otherwise the body is everything indented deeper than the header, plus the
  closing lines at the header's own indentation.

That is right for C, Go, Rust, Java, JS *and* for Python and Elixir. It is wrong
for a definition whose continuation is indented *less* than its header. The line
range is always reported, so a mis-extraction is visible rather than silent, and
the body is capped at 200 lines with the cap named in the result when it bites.

A name that is not defined in the file gets a refusal that says so, offers the
closest names actually defined there, and states the tool's real scope — one
file, definitions only. This matters because the failure mode of a
symbol tool is a confident wrong answer.

### 4.2 Language coverage follows the measured mix

Added **C/C++** (13 of 89 TB tasks; 4 of the 5 largest codebases; `gcc` in 29
images, `clangd` in none) and **shell** (25 of 89 tasks are shell/systems-only).
Existing: Python, JS/TS, Go, Rust, Ruby, Java/Kotlin, Elixir.

C function detection excludes prototypes (a trailing `;`) and the control
keywords, which otherwise match the same `name(args)` shape.

### 4.3 It is now always loaded

`should_defer?` is `false` and `always_load?` is `true`, and they agree — the
disagreement between them was the earlier defect (billed on every request,
callable on none).

The deferral argument rested on "invoked zero times", which was true and was not
evidence about demand: for most of that window the tool was not callable, and
when it was it returned an outline, so it could not end a lookup. What is
measured is the behaviour it replaces — 312 grep-then-read pairs across 118
transcripts, 2.6 per task, at 1,381 bytes and two round trips each against 517
bytes and one.

**Measured prefix cost of the change** *[measured, `Registry.list_active/0`
schemas as JSON, OSA's own estimator]*:

| | tools in array | bytes | est tokens |
|---|---:|---:|---:|
| before | 23 | 37,542 | 9,400 |
| after (`code_symbols` + `file_grep` routing line) | 24 | 38,841 | 9,724 |
| **delta** | +1 | **+1,299** | **+324** |

Of that, `code_symbols`'s own schema is 976 bytes and the routing sentence added
to `file_grep`'s description is the remainder. Note that the ~600-byte estimate
in §6 was low by a third — the schema is bigger than the prose, because the
parameter descriptions are re-encoded alongside it.

This is a one-time change to the assembled prefix, which is what the cache
tolerates: hits depend on the prefix being byte-identical across turns *within*
a session, and nothing here varies per turn.

---

## 5. The LSP client, designed but not built

Kept here so the decision in §3 is a decision and not an omission. Build it if a
repository-scale workload becomes the target.

**Transport and protocol.** LSP is JSON-RPC 2.0 over stdio with
`Content-Length`-framed messages. In Elixir: a `Port` in `{:packet, :line}`-free
raw binary mode with an accumulating framer, one `GenServer` per server process,
requests keyed by integer id with a `from` map for replies, and notifications
(`textDocument/publishDiagnostics`) fanned out to subscribers. Nothing exotic —
the framing and the id bookkeeping are the whole of it.

**Lifecycle.** `initialize` (declaring only the capabilities we use:
`definition`, `references`, `documentSymbol`, `workspaceSymbol`, `rename`,
`publishDiagnostics`) → `initialized` → work → `shutdown` → `exit`. Servers are
started lazily on first request for a language, keyed by `{root_uri, language}`,
and reaped on session end and on an idle timeout. Indexing latency is the real
cost: `rust-analyzer` and `clangd` can take minutes on a cold repository, so any
request before the server reports readiness must either wait under a bound or
fall back — it must never block a turn indefinitely. This is the same failure
shape as the 300-second turn cap fixed in `c3935671`.

**Discovery.** A table of `{extension → [server binary, argv, root markers]}`,
resolved through `System.find_executable/1`. No installation is ever attempted:
an agent that apt-installs a toolchain to answer a question has spent more than
the answer is worth, and it mutates the environment under the task.

**Degradation — the part that decides whether this is safe to ship.** When no
server exists for a language, the answer must be *the cheap path's answer*, not
an error and not silence. Concretely: `find_definition` falls through to
`code_symbols` with `name`, and `find_references` falls through to `file_grep`.
The result must state which route produced it, because "no references found" from
a working server and from an absent one mean opposite things. A degradation the
model cannot see is how a capability becomes a liability.

**What it would buy over §4, honestly.** Three things the regex path cannot do:
cross-file go-to-definition through imports and re-exports; find-all-references
with call-site accuracy (regex finds the string, not the binding); and rename
with scope awareness. All three are refactor operations on an existing
repository. None of them appears in the Terminal-Bench task set, and the
transcripts show only 4 read-answered "where are all the callers" instances in
118 sessions.

**What it would cost.** A `Port` supervision tree, a JSON-RPC framer, per-language
discovery and readiness handling, three or four new tool surfaces at the front of
the cached prefix, and a class of failure — a wedged or slow language server —
that can stall a turn. Against a measured demand of 4 instances in 118 sessions.

---

## 6. `file_grep` was defective, and it is the more important finding

§2.1 above prices the cheap path against `file_grep` on the assumption that
`file_grep` works. It did not. Chasing the 262 shell greps and the 16 explicit
complaints produced a defect chain that invalidates any conclusion drawn from
"the model did not call X" on this corpus, including the one this document
originally drew about `code_symbols`.

**Every `file_grep` call in all 118 sessions was served by the pure-Elixir
fallback, not by ripgrep.** *[measured]* `System.cmd("rg", …)` raises `:enoent`
when the binary is not on the BEAM's PATH and the rescue converts that to a
silent fallback. The proof is in the corpus rather than in the environment: of
the 50 successful greps that asked for `context_lines`, **zero** results contain
a context line, and only the fallback ignores that parameter.

That fallback had three defects, none of them announced:

| | effect |
|---|---|
| `Path.wildcard("**/*") \|> Enum.take(500)` | On the NodeBB workspace: **500 of 54,905 files searched — 0.9%** — stopping inside `build/`, never reaching `src/` or `test/`. Reported as "No matches found." |
| `Path.join(path, glob)` | A bare `*.py` matched the **top level only**, where `rg -g` matches at any depth. |
| `context_lines` unread | Silently dropped on all 50 calls that asked for it. |

Corpus outcomes, 862 `file_grep` calls *[measured]*: 535 matched (62%), 285
returned "No matches found." (33%), 42 errored on a missing path (5%). Of the
327 failures, **58 were followed within six calls by a `shell_execute` grep for
the same token that DID return matches** — 21 distinct sessions. The model said
so in as many words: *"the grep tool seems to have a systemic issue with this
repo"*, *"the grep for `parent_link` returned nothing — that's odd"*, *"the grep
tool seems unreliable here"*.

Fixed: the walk prunes dependency directories at the directory level so the
budget buys source files, the cap is 20,000 and **says so when it bites**, `glob`
is recursive and matches basenames the way `rg -g` does, `context_lines` is
implemented in ripgrep's own output shape, and both backends widen — ripgrep to
`--no-ignore --hidden`, the fallback to the pruned directories — when the
ordinary search comes back empty, labelling what they found and where. Priced by
ablation (`:grep_coverage`): the widening and the coverage note cost **158 tokens
across the scenario set (1%)**, and removing them turns one probe `wrong` (a
symbol that exists is reported absent) and one `lost`.

The same measurement retires the argument this document used to make. "The model
never called `code_symbols`" was offered as evidence of no demand; on a corpus
where the always-loaded search tool was itself returning false negatives, the
absence of a call is not evidence of anything.

## 7. Still open

* **Adoption.** The capability is measured; the *use* of it is not. It is now
  always-loaded and `file_grep`'s description routes to it, which removes both
  structural reasons it could not be called. Whether it IS called is the number
  to take from the next benchmark run, and it is the number that decides whether
  the +324 prefix tokens stay.
* **Read re-use, which suppression cannot reach.** 708 of 1,142 corpus
  `file_read` calls (62%, 1.27 MB of 2.63 MB) re-read a path already read in the
  same session — but only **19 of them, 20 KB, 0.8% of the read payload**, ask
  for the identical window. Path-and-range-keyed suppression is working exactly
  as designed and 0.8% is its entire ceiling on this corpus. The bytes are in
  **overlapping** windows (293 calls, 412 KB) and whole-file re-reads (177 calls,
  395 KB). Reclaiming those needs range subtraction — "you already hold 40–80;
  here is 81–120" — not a same/different verdict on the whole call.
* **Cross-file.** Everything here is one file. `file_grep` remains the cross-file
  answer. A repository-wide symbol index built in-process — the ctags idea,
  without ctags — is the next rung, and it is only worth climbing on a workload
  where §2.4's median is not zero.
* **ripgrep's actual absence.** The fallback is now correct, but it is still a
  fallback: an Elixir tree walk is seconds where ripgrep is milliseconds (1.4 s
  for one search of the 55k-file NodeBB workspace). Putting `rg` on the daemon's
  PATH is worth more than any further tuning of the fallback, and nothing in the
  tool can do it.
