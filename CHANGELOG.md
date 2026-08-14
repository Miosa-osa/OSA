# Changelog

All notable changes to OSA are documented here. This file tracks
release-level changes; the day-to-day build ledger lives in
[`docs/BACKLOG.md`](docs/BACKLOG.md).

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

---

## [1.0.97] — displays as `v1.0.097`

The benchmark release. Two harnesses were built, competitors were run
head-to-head with the model held fixed, and almost everything below was found by
that work rather than by reading the code.

### Fixed — the verification gate was satisfiable without evidence

Two independent research passes — one reading competitor harness source, one
replaying our own transcripts — converged on a diagnosis that corrected the
working hypothesis.

It is **not** "the test fails and the agent submits anyway". In 12 of 15 failed
instances **no check of any kind ran after the final source edit**, and every
check that did run after one passed. Nobody ends on a red test; they end on an
untested edit. Every failure also stopped **voluntarily with budget remaining** —
13–61 of 60 turns, no blocking limit hit.

Four defects in the ledger the gate reads:

- **A read counted as a check.** `file_read` and friends were classified as
  verification, so re-reading a file discharged the pending write to it — and
  the gate's own directive *advertises* re-reading as a way to satisfy it, while
  `file_edit`'s prompt says "do NOT re-read the file to verify an edit that
  succeeded". The gate was teaching the model how to defeat it, contradicting
  another prompt to do so.
- **A build counted as a test.** One predicate covered both, so `go build`
  passing discharged an edit whose test was red.
- **`run_tests.sh` matched nothing.** The canonical test command in a script —
  the most authoritative check available — registered as zero.
- **A failing check was recorded and discarded.** Every harness examined, ours
  included, gates on the *absence* of verification and none on the *presence* of
  a failure.

### Fixed — tools ran in the wrong directory

`Workspace.Cwd.get/0` reads the process dictionary, which does not propagate to a
spawned Task — and every tool runs in one. So `shell_execute` defaulted to
wherever the *backend* booted. On a shared daemon that is one session's tool
running in another session's directory, and it fails silently, because a command
in the wrong directory still succeeds.

The first fix covered the shell paths only. `file_glob`, `file_grep` and
`codebase_explore` never consult the process dictionary at all — they call
`Path.expand/1`, which resolves against the OS cwd directly. Measured after the
first fix landed: 29 tool results reporting `No files matched pattern ... under
/home/miosa/projects/osa/OSA`, affecting **7 of 12 instances**. The agent asks
for the file it needs, is told it does not exist, and proceeds without it.

### Fixed — Anthropic and Gemini rejected OSA's message shape

Nine sites appended `[assistant(text), system(...)]`, which Anthropic answers
with `role 'system' must follow a 'user' message or an assistant message ending
in a server tool result`. Those nine are the auto-continue nudges, the zero-tool
gate and the verification gate — so on those model families **OSA's entire
self-correction loop never ran once**. The harness had been developed against a
family that tolerates an invalid shape.

Fixing the emitters was not enough: a model reached through OpenRouter still got
the bad shape, because `OpenAICompatProvider` had no message reshaping at all.
The guard now sits at the wire, where every message passes exactly once.

### Fixed — you could not choose a model

`OpenAICompatProvider.default_model/1` returned a compile-time constant and never
read config, and `Agent.Tier` hardcoded a per-provider table for subagents. A
logging proxy showed the wire: with a model named in two config files and
confirmed by `/health`, six requests went to `anthropic/claude-opus-5` and zero
to the configured model. A per-model comparison would have produced a clean table
in which every row was secretly the same model. Verified fixed — 1,795 requests,
zero rewrites needed.

### Fixed — `osa doctor` never returned

`Inspection.report/0` globbed the whole tree with `match_dot: true` and filtered
vendored paths afterwards. 604,157 files here; it did not complete in 300
seconds. Now a pruned descent bounded at four levels: **300+ seconds to 50ms**,
and the test suite goes from timing out to green.

### Fixed — the TUI

The transcript no longer shifts when a block is re-rendered: a synthetic blank
row before code fences depended on the previous rendered row, which cannot
survive a split render, so re-rendering moved every row below it.

`↓ to manage` and `← for agents` now work while agents are running. Both hints
are shown during `Processing`, and both key arms lived only in the Idle handler,
so they were advertised in the one state where they could never fire.

A teammate announces itself once rather than twice with two different clocks. A
queued message says when it will run. The standing `hooks N ok` chip is gone —
failures still show.

### Fixed — smaller things

Cached input tokens were collected under a key nothing read, across five
providers. `mix osa.run --format json` always reported `"cost": 0`. `serve`
printed `:9089` while bound elsewhere. `permission_mode.json` grew without bound.
A tool declaring itself deferred is now actually deferred — which revealed a
pre-existing dead declaration — taking the default toolbox from 34 tools /
14,398 tokens to 22 / 10,843.

### Added — benchmark harnesses

`bench/swebench`, `bench/swebenchpro`, `bench/terminalbench`, `bench/recoverybench`,
`bench/headtohead`, and `bench/report` — a gate that refuses to print a rate for
an unquotable run, and currently refuses every run we have.

Results are in the README. The short version: two benchmarks now report **zero
harness faults**, where a quarter of failures used to be OSA's own fault. And in
a head-to-head with the model held fixed, `mini-swe-agent` — one bash tool, a
243-byte schema — matched codex and beat OSA.

### Known — not fixed

Non-UTF-8 tool output ends the turn with a 0-byte patch and is charged to the
model. OSA's own cost accounting overstates spend ~2.5x, so `cost_usd` must not
be quoted. Both are recorded in `bench/FINDINGS.md`.


## [1.0.96] — displays as `v1.0.096`

Two benchmark harnesses were built and run against OSA for the first time.
They found that a quarter of failures were OSA's fault rather than the model's,
and this release is mostly those fixes.

### Fixed — a nil model silently disabled compaction and shrank the window 30x

A session started without an explicit model carried `model: nil` all the way
through. nil is not an absence here; it is a value that breaks everything keyed
on the model.

`ContextWindow.resolve/1` returned `:unknown`, so the pressure meter read
`max=0 util=0.0%` and `above_compact` could never become true — **compaction
never fired at all**, on 37 of 40 measured sessions. Pricing logged `No price
for model nil`, so cost stayed at $0.00 against 59.9M input tokens and
`max_budget_usd` could never trip.

Worse downstream: a nil model cannot match the `":cloud"` test that exempts
hosted tags from the local ollama ceiling, so **a 1M-token model was budgeted as
32,768**. The "small window" then took the *larger* static prompt (17,733 tokens
instead of 9,332), the dynamic budget went negative and was clamped to its floor
while world state was evicted section by section, and the native tool array was
cut from 37 tools to 10.

Provider and model now resolve at session start through the same path the
request uses.

### Fixed — an ESSENTIAL context block that vanishes is a bug, not a budget

Every world-state section was hardcoded `group: :essential`, so rank-0 tool
doctrine and the rank-3 slash-command catalog screamed at identical severity.
Severity now keys on actual rank. And the 1,000-token floor silently absorbed a
negative budget: a prompt that does not fit now logs at `:error` with the full
arithmetic and emits `[:osa, :context, :overflow]`, stating that the evictions
below it are symptoms rather than the cause.

### Fixed — the injection guard refused ordinary bug reports

A single role header at line start (`SYSTEM:`) refused the turn outright: no
tool calls, no LLM turn, a canned refusal in about a second.
`sklearn.show_versions()` prints a block beginning `System:`, as does
matplotlib's bug template and any pasted log, stack trace or captured
transcript. It refused 15 of 500 SWE-bench instances; outside benchmarks the
blast radius is wider, because pasting a log is one of the most common things
anyone does here.

The signal is not the header but what follows it: an instruction means attack, a
version table means label. The bare pattern is kept for untrusted third-party
text, where a false positive costs a pair of defanging markers rather than the
user's turn.

### Fixed — OSA could not boot as root

`erlexec` started unconditionally, its port program refuses to run as root, and
`CLI.serve/0` raised a `MatchError` on the failure. This broke every
containerised OSA. `erlexec` now leaves the application tree entirely and starts
lazily on first PTY use; running as root logs one line naming PTY as the only
casualty. Verified end to end in a root container on ubuntu:24.04 with a
production release.

### Fixed — a missing `git` took down the whole application

`FSCheckpoint`'s `init/1` shells out to git, and in a container without it the
`:enoent` propagated through the extensions supervisor and killed OSA at boot —
a filesystem-checkpoint convenience taking the agent with it. It degrades now
and names the cause.

### Fixed — overdrive did not bypass the circuit breaker

The breaker was mixing two different things and now says so. Catastrophic
actions stay blocked in every mode, overdrive included. Bounded, recoverable
ones are waived under overdrive with a warning naming the reason and the
authorising mode. Clause order is load-bearing: the catastrophic class is
scanned across all variants first, so a compound command cannot be waived on its
weaker match. A waiver is not an auto-allow — deny rules, safety-ask and the
subagent boundary all still apply.

### Fixed — session settings were daemon-wide

`set_session/2` wrote one shared row, so "session" settings were shared by every
concurrent session, which made per-session tool policy impossible. Now scoped
per session id.

### Fixed — cached input tokens were collected and never counted

`openai_compat.ex` dropped `prompt_tokens_details.cached_tokens` entirely, so
OpenAI, DeepSeek, Groq, OpenRouter and xAI all reported `cache_read = 0` even
when the provider had cached. `openai_responses.ex` read it and stored it under
a key `CacheAttribution` never looks at.

### Fixed — smaller things

`mix osa.run --format json` always reported `"cost": 0` (it indexed an
`{:ok, status}` tuple, and wanted a key that does not exist). `serve` printed
`:9089` while bound elsewhere, ignoring `OSA_HTTP_PORT`. `permission_mode.json`
grew without bound; now capped by age and count, with the timestamp persisted so
a restart cannot reset the age.

### Changed — the TUI

Tool output budget cut from 50 KB to 16 KB. At 50 KB a single tool result
carries ~12.8k tokens, so twenty tool calls could put ~256k tokens into one
request. Nothing is discarded: over-budget results were already persisted whole
and previewed head+tail with a reference the agent can read on demand.

Shell cells show head **and** tail. They were head-only, so a failing
`cargo build` spent its entire budget on `Compiling foo v0.1.0` and hid the
error. Carriage-return redraws collapse to their final frame, so a progress bar
no longer smears every frame it ever painted into one row.

Markdown spacing is now uniform — k newlines produce k−1 blank rows, pinned
across every block-type pair. Fenced code blocks paint a full-row background.
Lists nest on the model's own indentation instead of a rounded guess. Tables get
a real word-break rule that keeps `$145,000` whole while breaking `555-0101`.

Reasoning is visible while it streams: a fixed three-row window onto the tail,
where the default was collapsed. Hook counters render per row. The task panel
no longer drops items past its cap silently. Diff hunks report how many lines
they skipped. A long wait names what it is waiting for instead of showing a
decorative verb.

### Added — benchmark harnesses

`bench/swebench/` runs SWE-bench Verified with grading delegated to the official
`swebench` package, so the same scoring code grades OSA, the gold patch and an
empty control. `bench/terminalbench/` runs Terminal-Bench with OSA installed
*inside* the task container as a self-contained OTP release, because grading
inspects container state rather than a patch.

`bench/report/` is a gate rather than a formatter: Wilson intervals, failure-first
reporting with per-failure transcript paths, a reproducibility manifest, and a
rules engine that refuses to print a rate for an unquotable run.

**No score is published with this release, deliberately.** The gate currently
refuses one, on two blocking findings: a 40-instance subset is not a dataset
score, and OSA runs on the host with web tools available while the container is
airgapped — the six instances that used `web_fetch` resolved six of six.

An audit of the harness found six ways it could mislead, four now fixed. The
worst was ours: a path predicate matched `"test/"` as a substring, which is
contained in `src/_pytest/`, so legitimate source files were stripped from model
patches and the result reported as the agent producing no patch. Checked against
all 500 gold patches, that destroyed 19 of them outright.

### Known — not verified on a real terminal

Three display changes in this release cannot be checked by any automated test,
because the test backend answers cursor queries from a perfect model: Ctrl+T
through the task-panel pin states, a progress-bar command showing its final
frame, and the hook bracket on a narrow terminal. The PTY resize suite and both
screen probes pass.


## [1.0.95] — displays as `v1.0.095`

### Fixed — a long dispatch was killed while its agents were still working

A three-agent dispatch was declared a tool timeout at ten minutes. The agents
were fine: they finished normally at 5m44s, 8m50s and 11m37s, and the delegate
result arrived at 11m42s — to a turn that had already been torn down. **The work
happened and there was nothing left to receive it.**

Three ceilings sat on that one path, each already raised once to chase a
workload that outgrew it: a 600s await in the streaming tool executor, a 300s
`:timeout_ms` passed down from the react loop, and a `:tool_timeout_ms` pinned to
300s in `config.exs` that overrode the code default outright. All three are now
unbounded, and the orchestrator's expiry check is explicit rather than relying on
term ordering to make a comparison against `:infinity` come out false.

The config pin is why the new test earns its place: fixing the code-level default
alone would have looked correct and changed nothing. The test asserts the config
values, and pairs the no-limit case with a 50 ms case that must still expire — so
"no ceiling" cannot quietly become "the check never runs".

A generic wrapper is the wrong place to enforce a duration: it cannot know
whether it is timing a 200 ms file read or a dispatch that legitimately runs for
hours, so every number it picks is wrong for one of them. The layers that *do*
know keep their own bounds — per-command shell timeouts, provider receive
timeouts, the bounded summarizer — and interrupting is always available, which
is the user's call rather than a constant's.

### Fixed — long autonomous runs no longer halt themselves

Two more caps behind the same wall. The stall detector no longer hard-halts: it
watches tool activity, which makes a long reading phase indistinguishable from a
genuine stall, and `/overdrive` already bypassed it — so an identical run lived
or died on which prompt started it. And the iteration cap moved from 200 to
10,000 rather than being removed: a wall-clock cap punishes work for taking long,
a step cap punishes it for going nowhere, and only the second is a fault worth
stopping.

**Not yet proven end to end:** the ceilings are gone in tests, but no multi-hour
dispatch has been run start to finish. If something further out still caps it,
it will be a different mechanism than these.

### Fixed — a six-step plan printed six identical rows

The plan tools were never classified as collapsible at all, so each step emitted
its own `Todos` row.

### Fixed — bare `/compact` showed nothing while it worked

Compaction progress events existed only on the automatic path, so the form people
actually type ran silently.

### Fixed — `← for agents` did nothing in the state that advertises it

The hint is shown only while a turn is processing, and that was the one state the
transition table had no entry for. The fleet roster now opens as a proper overlay
rather than a state transition with a hard-coded exit to idle — without that,
opening the roster mid-turn and closing it would have dropped a live turn to
idle, trading a dead key for a corrupted turn.

## [1.0.94] — displays as `v1.0.094`

### Fixed — a hook that blocked a tool call said nothing

The TUI had a renderer for `hook_blocked` and never once drew it. The backend
emits that event on the internal event bus; the only bridge from the bus to a
session's SSE stream is an allowlist, and `hook_blocked` was not on it. So a
hook that stopped a tool call stopped it **silently**, and the turn simply did
not do the thing, with no explanation anywhere on screen. The Rust side had been
correct and waiting the whole time.

### Added — hook counters in the status bar

`hooks 54 ok, 19 failed`, with a toast only when one actually fails.

What "failed" means had to be decided, because the dispatcher could not
previously answer it: a hook that crashed and a hook that deliberately returned
`:skip` both surfaced as the same bare `:skip`, so a broken hook and a hook with
no opinion were indistinguishable from outside. The failure paths now carry a
tag that never leaves the dispatcher — the chain receives exactly what it always
did, and only the reporting is new.

**A block is not a failure.** A policy hook refusing a dangerous command is the
system working, and counting that as an error would report a correct setup as
broken — a lie the user would act on. An unrecognised outcome counts as ok for
the same reason: the backend owns that vocabulary and may extend it, and a new
verb must not start reddening the status line before anyone has decided it means
failure. The chip omits `0 failed` rather than printing a standing zero, and
omits itself entirely until a hook has run.

**Known limit:** an HTTP webhook hook is fire-and-forget from the dispatcher's
side, so it counts as ok on dispatch regardless of what the POST later does. The
counter measures invocations the dispatcher observed, which is a narrower claim
than "the webhook succeeded".

### Internal — the queue-drain decision is testable without an `App`

The gate behind the queued-`/overdrive` fix was source-audited only. It is now a
free function with tests that pin both directions: `Idle` does not imply the turn
ended, and the turn ending does not imply draining is safe (a permission prompt
or plan review routes through the same completion handlers). Checked by
mutation — reverting the gate to its buggy form fails exactly two of them.

## [1.0.93] — displays as `v1.0.093`

### Removed — the live tool feed above the composer

The activity band painted a row per tool call — `┊ $ executing cargo test  1.2s…`
— stacked above the composer for the length of a turn. It is gone. A run of
tool calls says what it did in **one** committed summary line, and while the run
is still folding, that same line rides the status slot in the present tense:

    Reading 2 files, Searching 1 pattern

Both come from one renderer, so the live line and the line it becomes cannot
word themselves differently.

**The band can no longer change height, which is the real fix.** Its height
policy reserved a per-verbosity ceiling — four rows in `all`, eight in
`verbose` — and reserved-minus-painted is precisely the dead space that shows up
as blank rows above the composer. `height()` is now `1 + details`, and the
maximum equals it. A slot that cannot grow cannot rebuild the inline viewport
mid-turn, which is the mechanism behind a whole family of these gaps rather than
one instance of it.

Two layout invariants that had been pinning defects as characterisation tests —
`new` reserving a row it never inked, and `draw` sizing itself from the rect it
was handed rather than from what it reserved — now assert those defects stay
gone.

Streamed shell output is still collected but is no longer painted into the band;
it is heading for the committed execute block instead. Tool durations are
unaffected — they were always on the committed cell (`● Bash(make)  2.5s`), not
on the feed row.

`/verbosity` still cycles, but it no longer selects a feed depth, because there
is no feed to be deep.

## [1.0.92] — displays as `v1.0.092`

### Changed — reasoning is visible while it streams

The thinking box had two modes and defaulted to collapsed, so for the whole
time the model was reasoning the screen showed a single dim line and the work
appeared only once it was over. A third mode is now the default: a fixed
four-row tail window that follows the reasoning as it arrives. `alt+t` cycles
tail → expanded → collapsed.

**Visible behaviour change:** the thinking box reserves four rows rather than
one whenever reasoning is actively streaming, so a turn takes more vertical
space than it did. An empty box is still one row in every mode, and `alt+t`
returns the old single-line behaviour in two keypresses. The layout-invariant
suite holds on it.

### Changed — the diff hunk separator says how much it skipped

`… 14 unchanged lines` rather than a bare `…`, measured in new-file
coordinates and indented to the gutter. It declines to a bare glyph when the
count cannot be trusted: a coalesced multi-call block numbers each call's hunks
against that call's own snapshot, so a later edit can land above an earlier one
and the arithmetic stops meaning anything.

### Fixed — the orchestrate route terminated a turn twice

`TurnPipeline` broadcasts its own terminal event and *then* returns
`{:error, reason}`, and `POST /api/v1/orchestrate` treated that return as an
unterminated failure and broadcast a second one. Two paths did it — the
turn/budget limit gate and the `UserPromptSubmit` hook block. (The
prompt-injection refusal returns `{:ok, refusal}`, so it never reached the
error branch.)

This was not cosmetic once the queue drain moved onto the turn-end edge in
1.0.91: the first event released a queued message, that message opened a new
turn, and the second event then marked the *new* turn done — reproducing the
early drain through a narrower door. Termination now runs through a claim latch
whose `insert_new` resolves racing terminators to one winner. A session that
never opened a claim is never pre-latched, so the route's crash and `:exit`
fallbacks still fire when genuinely nothing else has broadcast.

## [1.0.91] — displays as `v1.0.091`

### Fixed — a mid-turn resize left a blank band above the live reply

The clear and the rebuild disagreed about where the inline viewport starts.
The clear was anchored at the remembered top; the rebuild placed the viewport
at `rows - height`. On a shrink that lands *below* the remembered top, so the
rows in between were erased and then never reoccupied — a band of blank that
grew with every resize. Both anchors now come from one resolved strategy, so a
full-screen clear rebuilds from the bottom and a surgical clear rebuilds from
the row it actually cleared. A PTY probe that measured seven blank rows now
measures one.

### Changed — typing mid-turn queues instead of diverting the running turn

Plain text sent while a turn was live was posted into that turn as a steer;
only `/` and `!` were queued. So a follow-up thought became a mid-flight
instruction change, which is rarely what typing it meant. Text now queues and
submits when the turn ends — including when the turn ends by interrupt.

### Fixed — a queued message could fire into a turn that was still running

The drain gate was `AppState::Idle`, and `Idle` lies mid-turn: full turn
teardown runs on *every* agent response, and one turn emits several (text →
tool/subagent → more text). So a queued message released early, applying to
session state that the real turn end then overwrote. That is the mechanism
behind a queued `/overdrive` that appeared to do nothing and had to be typed a
second time — it needed a multi-generation turn to reproduce, which is why it
was intermittent. The backend's `done` event is now parsed as a first-class
turn-end edge, and the queue hangs off that. Abnormal terminations — interrupt,
cancel, disconnect, error, local command — set the same flag, so the queue
still drains after an interrupt rather than stranding for the session.

### Changed — one summary row per tool run, with a clause per kind

A run of foldable calls emitted a separate line per kind, because a kind change
flushed the accumulator. Three lines said less than one:

    ◆ Read 1 skill, Searched 8 patterns, Listed 4 dirs, Read 2 files

Verb, noun and fold policy now live on the tool kind rather than in the
formatter, so a newly-added tool cannot silently render as "Ran 1 tools". The
per-kind counters are an ordered bucket list whose append-on-miss *is* the
ordering rule: clauses appear in the order their first call happened, which
makes the row a literal trace rather than a fixed category listing. A lone read
run still names its files. The live label comes off the same renderer, so
`Reading 2 files` and the committed row cannot drift.

### Fixed — headings manufactured a blank row on top of the source's own

Markdown rendering pushed an extra blank line after every heading, on top of
whatever blank line the source already had, so headings rendered
double-spaced against single-spaced body text. Spacing is now uniformly the
source's own: `k` consecutive newlines produce `k-1` blank rows, with no
per-block-pair table. Uniformity is what reads as airy; extra rows read as
drift.

### Fixed — three compaction defects that each failed silently

* **The threshold bands inverted between ~66k and ~71k.** For windows in that
  range `compact_at` took the reserve path while `warn_at` fell through to its
  `0.60 * cw` fallback, and across the whole range `0.60 * cw` exceeds
  `cw - 33_000`. At a 70k window `warn_at` came out at 42k against a
  `compact_at` of 37k. Nothing warned, the microcompaction guard became
  unsatisfiable, and the durable-notes flush clamped itself to a band one token
  wide — so notes were never written before a rollover. The range is reachable
  through a configured local `num_ctx`. The fallback is now a preference rather
  than a licence to exceed `compact_at`, clamped to leave a band at least a
  quarter of `compact_at` wide, with the mirror clamp on `block_at`. Ordering
  is structural now, not something two formulas happen to agree on.
* **Consecutive-message merging corrupted multimodal content.** It joined
  contents as strings, so two user messages carrying block lists merged into a
  JSON *string* and an image block became literal `{"type":"image",...}` text.
  The image was destroyed, and base64 the estimator deliberately charges a flat
  rate became plain text hit by the byte-size floor — a step meant to save
  tokens multiplied them, and the corruption is what reached the provider and
  got persisted. Block lists now concatenate as lists; anything that cannot
  merge cleanly declines to merge.
* **The summary was re-sent uncached every turn.** The compact boundary was
  built as a `system` message and leads the rebuilt conversation, so the
  Anthropic system split absorbed it into the system-prompt block array — which
  sits after both cache breakpoints. A multi-thousand-token summary plus up to
  50k characters of re-injected file bodies rode uncached on every request
  until the next compaction. It leads as a user turn now.

## [1.0.90] — displays as `v1.0.090`

### Fixed — the CLI banner stated two numbers that were both false

It printed `128K context · 81 tools`. The real values for that session were
**1M context · 37 tools**.

* The window came from `Application.get_env(:max_context_tokens, 128_000)` — a
  static config default with no relationship to the model in use. A 1M-window
  model printed "128K" on every single launch. Same defect as the small-window
  gate fixed in v1.0.84: a surface stating a fabricated number instead of asking
  `Registry.effective_context_window/2`, which had the right answer all along.
* The tool count came from `list_tools_direct/0`, the whole registry, while the
  model is sent `list_active/0`. The banner claimed more than double the tools
  the agent can actually call.

Both now read from the same functions the agent itself uses.

## [1.0.89] — displays as `v1.0.089`

### Fixed — the OTP release bundled 38 GB of Rust build artifacts

`mix release` copies `priv/` wholesale, and `priv/rust/tui/target/` is the Rust
build directory. On any machine that has ever built the TUI that is tens of
gigabytes, so `MIX_ENV=prod mix release osagent` produced a **38 GB release
directory** — against CI's 32 MB artifact. Stale versioned lib dirs from earlier
builds added to it, because `--overwrite` leaves them in place: an old
`optimal_system_agent-1.0.58/priv` was contributing another 12 GB on its own.

CI escapes this only by accident of ordering: it assembles the OTP release
*before* building the Rust TUI, so `target/` does not exist yet. Restore that
directory from a cache, reorder the jobs, or build a release on any developer
machine, and the artifact silently balloons a thousandfold. The release has no
use for the build directory either way — the TUI ships as its own binary.

A `prune_build_artifacts/1` release step now removes the Rust target directory
and any stale versioned lib dir during `:assemble`.

    release dir   38 GB  ->  99 MB
    tarball       (never completed)  ->  36 MB

Verified by booting the packaged release: it reports `v1.0.88 (b98f1011)` and
starts normally.

## [1.0.88] — displays as `v1.0.088`

### Fixed — the world-state ledger broke the prompt cache on a timer

The world-state block is diffed per turn and replayed verbatim so the prompt
prefix stays byte-stable, and it carries its **own** `cache_control` breakpoint
(`Agent.Context.build_system_message/4`). Rewriting it invalidates that
breakpoint and everything after it — the volatile block and the **entire
conversation** — so the whole history is re-prefilled at full price instead of
being read from cache at ~10%.

The ledger compacted itself to a fresh snapshot every **6 delta payloads**,
regardless of their size. That schedule had nothing to do with whether
compacting helped:

* In a normal session the deltas are small. Six of a few hundred bytes are
  *cheaper to replay* than a fresh snapshot of every live section — so the break
  was paid to make the block **larger**.
* The reclaim was a few hundred tokens; the break costs a full re-prefill of the
  conversation, ~27k tokens in a session with 30k of history. The trade lost by
  roughly two orders of magnitude, every six turns, forever.

Compaction is now triggered by size, and the floor is sized from what the break
*costs* rather than what it reclaims: the ledger must waste at least 16 KB
(~4k tokens, the same order as the re-prefill) **and** exceed a fresh snapshot
by 20% before it collapses. A payload-count cap of 64 remains purely as a
backstop against unbounded ETS growth.

Measured over 30 turns:

    typical session (~135 B deltas)   5 cache breaks  ->  0
    heavy churn     (~20 KB deltas)   still compacts every turn,
                                      block bounded at 20 KB instead of ~600 KB

The churn case is not a regression: when a section rewrites itself every turn
the block changes anyway, so the cache breaks with or without compaction and
bounding the prompt is free. The win is the normal case, which is every session
that is not pathological.

## [1.0.87] — displays as `v1.0.087`

### Fixed — streaming arrives in chunks (measured this time)

Four attempts at this complaint were argued from synthetic benches, and all four
were wrong, because a bench feeds deltas at a cadence its author chose. This one
starts from a **real trace**: 2,442 deltas / 13,187 characters captured off the
wire from `glm-5.2:cloud` via ollama, with a new `app::stream_probe` module and
`test/pty/stream_shape_probe.py`.

The arrival pattern is the opposite of what every previous fix assumed. Deltas
are **small** — mean 5.4 chars, p90 12, max 29, so there is no slab on the wire.
But they are **clumped in time**: median gap between deltas **0.2 ms**, p90
**25 ms**. A clump lands inside a single TCP read, then ~25 ms of silence.

The event loop coalesces everything available into one frame (by design, for
throughput) and rate-caps at 16 ms. So each clump becomes exactly one paint.
Replaying the real trace through the loop's real frame cadence:

    pacer off    p50 19   p90 35   p99 101   max 358    582 paints
    pacer auto   p50 11   p90 30   p99  64   max 100    900 paints

**That 358-character single frame is the complaint.** The fix is the reveal
pacer that already existed and was disabled: `stream_pace` now defaults to
`auto` instead of `off`, and its engage threshold moved from a 40 ms mean
inter-burst gap to 18 ms (release 25 → 11) — because at 40 ms it never engaged
on a stream whose real gap is ~25 ms. It was tuned against numbers no provider
produces.

Worst frame drops **3.6x**, p99 by 37%, and the median improves too, at the cost
of 900 paints where there were 582 — still inside the 60fps frame budget. Set
`OSA_STREAM_PACE=off` to restore the old behaviour for a provider that already
trickles.

The measurement is now a test, not a memory: `stream_pace::real_trace` replays
the captured trace and fails if the worst paint is not at least halved, if p99
or the median regress, or if the paint count nearly doubles.

### Added — `OSA_STREAM_PROBE`

Set it to a file path and OSA records two things per streaming turn: every delta
as it arrives off the wire, and every paint with the characters it revealed. Off
and free otherwise. This is what turned a four-round guessing game into one
measurement, and it stays in so the next question about streaming shape is
answered the same way.

Incidental finding worth recording: a backend left running from an older release
served the whole reply as a single `agent_response` with **no `streaming_token`
events at all**. If streaming ever looks like one big dump rather than chunks,
check the backend's version before anything else.

## [1.0.86] — displays as `v1.0.086`

### Reverted — the v1.0.85 grow-headroom change (it caused a visible gap)

v1.0.85 made the inline live region a high-water mark that grew in steps of 8
rows, on the theory that per-row viewport rebuilds were what made streaming
arrive in slabs. Reported immediately, and correctly: a **gap** during tool use.
The region only grew, so once a tool cell had pushed it taller it stayed taller,
and the unused rows rendered as blank space between the transcript and the live
preview.

It also did not fix what it was aimed at — streaming still reads as chunked. So
it was a regression in exchange for nothing, and the whole change is out: call
site, method, constant and its four tests. The resumable freeze-boundary scan
from the same release stays, since it is strictly less work per delta and
changes no output.

**The chunked streaming is therefore still unfixed, and the cause is still not
known.** Three candidates have now been eliminated by measurement rather than
argument: syntect highlighting (already memoized, O(N)), per-delta render cost
(357µs worst case, far under the 16ms frame), and viewport rebuild frequency
(this change). What remains unexamined is the shape of the deltas arriving on
the wire — how the provider chunks its SSE, and how the 16ms frame cap
coalesces what lands inside each window. That needs instrumenting a real
session, not another bench.

### Fixed — `--overdrive` displayed a permission mode the backend was not in

Launching with `--overdrive` seeds the status bar into overdrive in `App::new`,
but the backend learns its permission mode only from an explicit command, and
`set_permission_mode` is session-scoped: sent before the session exists it
returns `{:error, :no_session}`, which nothing retries. The existing re-assert
on `SseConnected` races session creation and can land first.

The result was a status bar reading "overdrive (full auto), no prompts" over a
backend gate that was still `ask` — a lie about the effective permission state,
in a display whose entire job is to tell you whether tools run unprompted.

It also desynced the `/overdrive` command, which is how it surfaced: the toggle
reads the TUI's mode, saw "on", and so its FIRST press turned overdrive *off*,
announcing "Overdrive OFF" over a screen that had been claiming it was on. The
second press set both sides, and everything agreed from then on.

Mode + `dangerous_mode` are now also pushed from the `SessionCreated` handler,
where the session provably exists and the command can actually be honoured.

## [1.0.85] — displays as `v1.0.085`

### Fixed — streaming arrived in slabs

The real cause of "it streams in chunks, it looks ugly", and it was not the
renderer. The inline live region grew **one row at a time**, and every one of
those rows committed a viewport rebuild — a scroll-region rewrite plus a full
repaint of the region, **26 of them in a single 5-second turn**. No streaming
text can be painted while a rebuild runs, so everything that arrived meanwhile
landed together on the far side. That is the bimodal profile that was measured
and mis-attributed: ~5% of paints carrying ~50% of the reply, single frames up
to 330 characters.

Rebuild cost is per-rebuild, not per-row, so the region now grows in steps of 8
rows. For the duration of a turn it is a **high-water mark**: it only grows.
Rounding the grow up is not sufficient on its own — `SHRINK_SETTLE_TICKS` is 1,
so the next tick would report the true smaller height and hand the headroom
straight back, costing two rebuilds and saving none. `settle_turn_chrome`
already reclaims the rows when the turn ends, which is the moment the answer
visibly settles into place anyway.

Same 3→29 row growth, counted by test: **26 rebuilds → 4.** The reservation is
clamped to `term_rows - 1` and proved never to sit below what the content needs,
so nothing can clip off the bottom.

Two things were investigated first and cleared, recorded so they are not
re-investigated: syntect highlighting of a growing fence is already memoized and
O(N), and per-delta render cost tops out at 357µs — far under the 16ms frame,
and incapable of producing a 330-character paint. The freeze-boundary scan is
now resumable rather than restarting at byte 0 each delta (strictly less work,
no output change), but it was not the bottleneck either.

### Fixed — the tool array was invisible to the context budget

`token_budget/1` summed the system prompt, the conversation and the response
reserve. The tool schemas sent in the request's native `tools` array were never
counted — and under the `:native_tools` variant they are the *only* place that
content exists, because the prose duplicating them is deliberately stripped from
the prompt. The one variant that moves the weight out of the prompt also moved
it out of the accounting.

Measured on a live registry: **15,496 tokens uncounted against a reported total
of 37,172 — the meter read 41.7% low.** The `/context` display, the reported
headroom and, most importantly, the compaction trigger were all working from
that number, so compaction fired later than it believed it was firing. The array
is now its own budget line, cached against the active tool set.

### Removed — a signal-weight gate that would have broken every short request

`ToolFilter.apply_weight_gate/2` sent the model an **empty tool list** whenever
`state.signal_weight` fell below 0.20. The only thing preventing that was that
`signal_weight` is initialised to `nil` and never written, so the gate silently
did nothing.

Wiring it up would have been a disaster, because the weight it gates on is
`Signal.MessageClassifier.calculate_weight/1` — literally
`min(String.length(message) / 500, 1.0)`. At a 0.20 threshold that means any
message shorter than 100 characters gets no tools at all:

    "fix the bug in auth.ex"   22 chars -> 0.04 -> NO TOOLS
    "run the tests"            13 chars -> 0.03 -> NO TOOLS
    "deploy to staging"        17 chars -> 0.03 -> NO TOOLS

Message length is not a proxy for whether a request needs tools; if anything the
correlation runs the other way. The gate is removed rather than wired, because
the next person to populate `signal_weight` — an obvious, innocuous-looking
change — would have silently broken every terse instruction in the product.

### Fixed — one developer's private rules shipped to every user

`priv/rules/projects/bos.md` was a personal BusinessOS rule file, naming its
author's own `~/Desktop/BOS` checkout and Go module, bundled into the release
and inlined into the cached prefix of **every request every user ever made** —
4,429 bytes of instructions about a repository they cannot see.

Rules could only ever be loaded from `priv/rules/`, so a personal rule had
nowhere else to live. `~/.osa/rules/**/*.md` (honouring `OSA_HOME`) is now read
as a second rules directory, and the file moved there.

With it gone, every remaining bundled rule is either `alwaysApply: false` or an
unfilled template — so a fresh install now renders **no rules block at all**.
That is the honest outcome and is asserted directly: OSA was shipping 21KB of
rules of which none were generically applicable. Static base: 21,739 tokens.

## [1.0.84] — displays as `v1.0.084`

### Fixed — a 1M-context model was being treated as a toy

`Context.small_window?/2` did not exist; the decision was made on the provider's
*name*. Any model served through ollama, lmstudio or llamacpp was assumed small,
so `glm-5.2:cloud` — a **1M-token window** — was routed to the `:lite` static
base (22,971 tokens instead of the 14,527-token `:native_tools` variant) and,
worse, `ToolFilter` trimmed its toolset to ten. That trim was visible in the log
on every turn: `Trimming tools from 37 to 10 for ollama`. The model was told it
had ten tools while thirty-seven were registered.

Both sites now key on `Registry.effective_context_window/2`. A local provider
with a large window keeps the full prefix and **all 37 tools**; a genuinely
small window still gets the lite treatment. The predicate is one function, so
the prompt variant and the tool budget cannot disagree about the same model.

### Fixed — the `◈ OSA` header on tool-first turns

`ToolCallStart` set `agent_header_sent = true` unconditionally, so any turn that
opened with a tool call rendered its entire answer with no header. The live
preview then drew a *second* header of its own, because `new_agent_prerendered`
hardcoded `MessageType::Agent` — which is where the duplicate `◈ OSA` mid-answer
came from. The preview now takes the header as a parameter and renders
`AgentContinuation` when one has already been sent.

### Fixed — every provider call minted a new assistant message

`mint_message_id/1` fired per provider call, and the moduledoc asserted the
behaviour it caused: *"Every generation is a distinct assistant message."* A
single answer interrupted by tool calls therefore arrived as several messages.
IDs are now minted once per turn and re-minted only after a tool call actually
runs, which is the boundary that makes a new message meaningful.

### Fixed — drag-and-dropped screenshots were refused

`PathPolicy.check_read/2` confines reads to `read_roots()`, which is right for
paths the *model* chose and wrong for a file the *user* just dropped onto the
composer. The two cases are now distinguished: `check_read_as/3` dispatches on
`:user` vs `:model`, and `check_user_attachment/2` canonicalises and applies the
sensitive-path blocklist without the roots confinement. The guard was not
loosened — a second trust level was added, because "the user handed me this
file" and "the model asked for this path" are not the same claim.

Found while fixing it: `Protocol.ContextRefs.resolve_file/3` had **no policy
check at all**, so a request carrying
`context_refs: [{"type":"file","path":"~/.ssh/id_rsa"}]` read the key and
inlined it into the prompt. It now goes through the same `:model`-trust path as
every other model-chosen read.

### Added — a lean system prompt, on by default

`priv/prompts/SYSTEM_LEAN.md` replaces prose that restated tool schemas the
model receives natively on the same request. The system prompt drops from
16,059 to **9,332 tokens (−42%)**; the total static prefix from 31,612 to
24,828. Deferred-tool discovery is unaffected — it was never carried by that
prose, but by the `<system-reminder>` block `ToolsSection` emits in every
variant, which names each deferred tool and says to reach it via `tool_search`.

Set `config :optimal_system_agent, :lean_prompt, false` to revert. A user's own
`SYSTEM.md` override always wins over both.

Measured honestly: cutting 5,818 tokens changed time-to-first-token by **nothing**
(~1,430ms before, ~1,418ms after). The prefix was not the latency lever; the
floor is network and provider scheduling. It is still worth shipping for the
per-request cost and the context it hands back to the conversation.

### Added — cache-break attribution

`Providers.CacheAttribution` fingerprints each system block, each tool (name
separately from schema) and each message, so a cache miss reports *what* moved:
`tools changed (tool prompt/schema changed, same tool set)`,
`message history mutated at index 2/4`. 92–118µs on a 192KB body.

### Fixed — test-suite flakes that were hiding behind each other

Two tests failed roughly one full run in three with the victim rotating by seed,
which reads as nondeterminism and was not:

* `UsageTest` "the only probe it will ever make is free and on loopback" drove
  its assertion through `Usage.report/1`, so whether the probe fired depended on
  that function enumerating ollama among its providers — ambient state other
  suites perturb. It now drives `Usage.ollama_account/1`, the single shared probe
  the contract is actually about, and waits on a polled deadline rather than a
  fixed `sleep`. (The sleep was not the bug: it still failed at 2s.)
* `ConversationTest` and `RulesAlwaysApplyTest` pinned literal prompt *wording*
  that the lean template legitimately changed. They now assert the contracts —
  a system message comes first and carries the static base; a rule without an
  `alwaysApply` key is kept — so prompt edits stop reading as regressions.

Full suite: **8,227 tests, 0 failures** at seeds 7 and 991. TUI: 1,307 passed.

### Known, not fixed

The settle-to-scrollback commit still lands in bursts — about 5% of paints carry
roughly half the reply, with single frames up to 330 characters. That is the
remaining "chunky streaming" complaint and it lives in `app/event_loop.rs` and
`components/chat/**`, not in the pacing layer. `app/stream_pace.rs` ships
**disabled by default**: measurement showed pacing made chunking worse
(chars-per-paint p90 rose from 21 to 59), so it is present to iterate on, not on.

## [1.0.83] — displays as `v1.0.083`

### Fixed — the composer froze while a turn streamed

Typing during a streaming turn did nothing. Measured against a real provider:
**7 of 7 keystrokes never echoed within 5 seconds each**, and a paste never
appeared at all. Idle typing was fine at 3.4ms median, so it looked like a
mysterious general slowness rather than one mechanism.

The inline viewport rebuild was **doing a cursor round-trip to learn a number it
had just written itself**. Every rebuild path computes `new_top` and issues
`MoveTo(0, new_top)` immediately before rebuilding — and then `Viewport::Inline`
asked the terminal to read that row back with a DSR query. The reply arrives on
stdin, which the terminal event reader owns, so each rebuild had to abort the
reader, run a priming loop of up to **40 × 25ms of blocking sleep on the event
loop's own thread**, then respawn it. A growing streaming preview commits one
rebuild per row: 12–34 DSR queries per turn, measured on the wire.

The rebuild is now free rather than rare: a backend newtype carries the
already-known cursor position, so there is no DSR, no stdin read, no reader
teardown and no priming loop. Paths where the cursor is genuinely unknown — boot,
and returning from the alternate screen with no remembered top — keep the old
query-and-retry ladder unchanged.

| | before | after |
|---|---|---|
| DSR queries per turn | 12–34 | **0** |
| keystrokes lost mid-stream (DSR dropped) | **7 of 7** | **0** |
| echo latency in that state | never echoed | 1.1ms median, 3.3ms p95 |

**Why this never reproduced here.** On bare Linux the terminal answers DSR in
under a millisecond, so the reader is deaf for about that long and nothing is
lost. It reproduces completely the moment the reply is dropped or delayed — which
is macOS inside tmux, where DSR passthrough is unreliable and where the 40 × 25ms
blocking loop actually fires. A new probe models that with `--drop-dsr`, and it is
the revert-verified gate: the pre-fix binary fails it, the post-fix binary passes.

A stable per-turn ceiling for the streaming band was considered and rejected: the
slot is monotone within a turn, so reserving the ceiling up front is the
pre-1.0.79 high-water ratchet, and `reserved > drawn` is bottom-anchored — it
paints as dead rows above the reply, which is exactly the defect 1.0.79 fixed and
which `blank_rows_probe.py` now gates on.

### Fixed — every finalized block was markdown-parsed twice

`Message::cached_height` was declared, read, and invalidated — and never assigned
anywhere, because `height/1` takes `&self`. So the commit path parsed each block
once to measure it and again to draw it. The field is now a `Cell`, and a single
parse is shared between measuring and drawing. It only ever fills an empty
`prerendered_body`, so the live preview and plan snapshots — where that field is
the content rather than a cache — are untouched.

### Fixed — the test suite was writing into the operator's live `~/.osa`

Six state paths were still at their production defaults, so `mix test` shared
directories with the running agent. Measured before the fix: `fs_checkpoints` held
2,761 commits of which **2,759 were test sessions**; `verification_checkpoints`
held 182 leftover files; `workflows` gained 24 files per run. Because
`Verification.Checkpoint` prunes at 200 files, the suite was **deleting the
operator's real records**. All six are now isolated per run, verified across five
runs by the operator's counters not moving.

Four ordering and cross-run mechanisms were also fixed, each measured rather than
inferred: a test leaking a permission into the process-wide settings cascade; a
`/tmp` fixture colliding with leftovers because `System.unique_integer/1` restarts
low each VM boot, self-perpetuating because its cleanup was registered after the
build that could raise; and a check-then-act `on_exit` on a linked process.
Five consecutive full runs are green, including the two seeds that reliably failed.

### Fixed — a healthy fleet node could have its work discarded

`RunStore.attach_worktree_snapshot/2` created a run file for an id that never
started. `rehydrate/0` rebuilds its index from exactly those files, so the phantom
came back as a real row and `reconcile` settled it to `:failed` — and `Fleet`'s
await polls that status, so a node that completed fine was reported
`{:node_incomplete, :failed}` and its output thrown away. A snapshot marker is
evidence *about* a run and can no longer invent one. Found while chasing a test
flake; it is a production defect.

### Known gaps

Per-delta streaming cost still grows with the size of the **open** markdown block
(655 → 1084µs from 50 to 800 lines) because OSA's only streaming boundary is a
blank line at depth zero outside a fence, so the preview always re-parses one
unterminated block — unbounded inside a code fence or table. Per-frame cost is
flat. The fix is a real streaming boundary primitive and is planned in
`docs/tui-primitives-plan.md`, not attempted here.

Chunked streaming is the cloud provider, not OSA: measured 68% of inter-delta gaps
under 1ms with a 28-character median chunk on the cloud model, versus 0% and 4.5
characters on a local one, on the same code path. Only character-paced rendering
would smooth it, at the cost of roughly one clump interval of added latency.

`fs_checkpoint` commits fail on a machine that sets `commit.gpgsign`, because the
shadow repository inherits it — so `/rollback` silently records nothing there.
Pre-existing and unrelated to this work.

---

## [1.0.82] — displays as `v1.0.082`

### Fixed — the system prompt was frozen at boot

`Soul.static_base/0` caches the rendered system prompt, and that prompt contains
the tool documentation. The cache was invalidated only inside `Soul.load/0` at
boot and by a manual `reload/0` — **nothing invalidated it when the tool set
changed.**

`MCP.Client.Manager` starts after `Tools.Registry` and its servers connect
asynchronously, so MCP tools register after the prompt has already been rendered
and cached. Whatever tool set existed at the first render was frozen for the life
of the node. With a dozen MCP servers configured, the model could be working from
a tool list that no longer matched reality. The `:native_tools` variant made it
sharper still: its decision about which descriptions to strip is read from the
live registry at render time and then cached, so the prose could be computed
against a set that no longer existed.

`Soul.invalidate_static_base/0` is now called from the registry's module
registration and from the single writer of the MCP tool map. It invalidates only
— the lazy rebuild on next read is preserved — and skips writing over an
already-cleared slot, so twelve servers connecting cost one write in total.
Proven by tests that drive the production paths (`Registry.register/1` and
`Manager.report_tools/2`) rather than poking the cache: five of six fail on the
old code.

### Fixed — the test suite was lying, in three unrelated ways

A full run is green for the first time: **8103 tests, 0 failures.** Seven tests
had been failing only inside full runs. The cause was not one mechanism, and it
was not the prompt cache:

- **`HOME` was being deleted, not restored.** One suite's `on_exit` called
  `System.delete_env("HOME")`, leaving the whole VM without a home directory for
  everything that ran afterwards.
- **A directory was left behind where a config file belongs.** One suite chmods
  its fixture path to `0600` on the way out, but another test makes that path a
  *directory* — and `0600` strips the traverse bit, so the cleanup silently
  failed. Since `System.unique_integer/1` restarts low on each VM boot, a later
  run recycled the number and found a directory where its config should be. This
  one failed running *alone*, on four of seven seeds, and had been misfiled as
  cross-suite pollution. Twenty stale directories were found on disk.
- **`:live_env_file_fallback` was being deleted rather than restored**, so every
  test after that point read the developer's real `.env` files. That is what had
  been breaking provider-resolution tests all along.

One test was simply asserting the wrong thing: the active tool list is
`builtin ++ mcp` with each half sorted, deliberately, so a connecting server
appends to the tail instead of rewriting the cached prefix. The test asserted
global sortedness, which a single live MCP tool breaks. It now asserts what the
design actually guarantees.

### Known gaps

Three `FleetTest` cases were seen failing once in a full run and could not be
reproduced — green alone, green in a 2317-test directory run, and green under
saturating CPU load. No mechanism is claimed for them. One case in the tool-prefix
cache suite is a pre-existing intra-file flake, present at HEAD before any of this
work, and its mechanism is likewise undetermined.

---

## [1.0.81] — displays as `v1.0.081`

### Fixed — the answer had no name on it

**Every turn that opened with a tool call rendered under no `◈ OSA` header at
all.** In overdrive the model almost always leads with a tool call and no
preamble, so the whole answer appeared as text from nobody. `handle_backend.rs`
set `agent_header_sent = true` unconditionally in the `ToolCallStart` arm, even
when nothing had been committed and no header had ever been drawn. Every path
that actually draws a header already sets that flag, so the line prevented no
duplicate — it only ever suppressed the one header the turn was owed. Measured
on a real PTY: `tool-first turn: 0 headers` before, `1` after.

### Fixed — one answer split into two blocks

`llm_client.ex` minted a new `message_id` on every provider call, and the moduledoc
said so plainly: *"Every generation is a distinct assistant message."* The TUI
correctly treats a changed id as a new message, so any continuation with no tool
call between — a verification gate, an output-token target, a crossed compaction
boundary — tore one answer into two `◈ OSA` blocks mid-thought, permanently,
since committed blocks go to the terminal's own scrollback.

A message id now identifies a **segment**, not a generation: it is reused across
consecutive generations and re-minted only after a tool call, because a tool cell
genuinely separates the text around it. Intermediate generations are never
finalized (`agent_response` is emitted once, at turn end), so reusing an id
cannot trip the client's repeat-finalization guard.

### Fixed — the layout took a second to settle

Bands damped their shrink to avoid flicker: a 200ms hold plus four settle ticks
(~0.8s), with any upward move resetting the clock — so a streaming turn held its
tallest reservation throughout and then took about a second to converge. A band
whose content height is zero now shrinks immediately: gone is not oscillating,
and the hold exists to absorb wobble in a band still being written to.

Measured last-token-to-settled on a real PTY, against a turn that actually runs:
**852ms before, 37/99/33ms after**. Stream churn is unchanged at ~0-0.4 region
moves per second, so the jitter the damping guarded against does not return.

### Fixed — the probes were not testing anything

`stream_paint_probe.py` and `smoothness_probe.py` answered the orchestrate call
with `{"status": "accepted"}`, but the client requires `session_id`. The TUI
failed to decode the response, never entered `Processing`, and **silently dropped
every streaming token** — so both probes had been measuring a turn that never
started. The earlier 852ms figure was itself measured that way. One field fixes
both, and the markdown check that had been passing vacuously now runs.

### Measured, and found correct

Written to the record because they were suspected and are not defects: terminal
write volume is 10.9 KiB/s at 40 tok/s and 17.5 KiB/s at 80 (no redraw storm);
stream coalescing works (342 deltas produce 233 draws at 80 tok/s); the surgical
resize path under stress shows no space substitution, no bleed and no duplicated
region across 90 sampled frames; 40x10 terminals render correctly; Esc-to-interrupt
arms and fires with the in-flight tool cell intact.

### Known gaps

The owner's reported `Build's1greene— 976rmodules,xclean` corruption is still
**not reproduced** — 90 frames across plain, stress and surgical runs, at two
widths, with both the broken and fixed stubs. It remains unexplained rather than
quietly folded into the escape or anchor fixes.

Raw `**` renders as literal text in the *live streaming preview* while an emphasis
run is unterminated; the settled block is correct. CommonMark does treat an
unclosed run as literal, so this is a deliberate-versus-defect call the renderer's
owner should make.

The system prompt is cached at boot and **not invalidated when the tool set
changes**, so tools registered later — including MCP tools, which connect
asynchronously after `Tools.Registry` starts — may not be reflected in the prose
block. Under investigation; it is also the mechanism behind several tests that
fail only inside a full run.

---

## [1.0.80] — displays as `v1.0.080`

### Changed — every request is 16,145 tokens smaller

The static prefix measured **47,689 tokens**, roughly 5x comparable harnesses. It
is now **31,544** — a 33.9% cut on every request to a provider with a native
tool channel.

The cause was duplication, not verbosity. `Soul.ToolsSection` rendered each
tool's documentation as prose into the cached system prompt while the same tools
also shipped as the JSON `tools` array. Measured per tool: for **all 36 loaded
tools, `prompt/1` returns byte-identical output to `description/0`** — the
residual after subtracting the description is **0 bytes for every one of them**.
The additional 22,178 bytes of `Parameters:` lines are `parameters/0` re-encoded,
i.e. the same map already shipping as `input_schema`. The tool-definitions block
went from 15,297 tokens to 384.

It is implemented as span subtraction rather than deletion: the description span
is removed from wherever it sits inside the `prompt/1` body and the `Parameters:`
line dropped, with everything else surviving verbatim. If anyone enriches a
`prompt/1` later, that surplus is kept automatically.

**Gated on a transport capability, not a provider allowlist** — new optional
`native_tool_schemas?/0`, defaulting to false. This is not a stylistic
preference: `claude_cli` and `copilot_cli` have **no native tool channel** and
fold the tool list into prompt text, so an allowlist matching on "Claude" would
have blinded them entirely. Membership is read per tool from the same
`Registry.list_active/0` that feeds the provider's `:tools` option, which caught a
real divergence — `computer_use` is documented in the prose but absent from the
array, so it still renders in full.

**Rules that said not to apply were applied anyway.** `{{RULES}}` concatenated
every `priv/rules/**/*.md` while ignoring their own frontmatter, so four files
declaring `alwaysApply: false` with narrow globs shipped on every request — a
session editing Elixir carried `.tsx` component rules. Their raw YAML
(`globs:`, `description: "…EDIT THIS FILE…"`) also reached the model as
instruction text. The flag is now honored and frontmatter always stripped.

Both behaviours are config flags defaulting on: `dedupe_native_tool_prompt` and
`rules_respect_always_apply`.

### Fixed — a tool that hung forever, and a healing path that never woke anyone

- **`team_create` deadlocked permanently.** `Manager.init/1` called
  `NervousSystem.start_all/1`, which issues `DynamicSupervisor.start_child`
  against the supervisor that was itself blocked in `proc_lib.sync_start/2`
  waiting for that `init/1`. No timeout on either side. Confirmed with a live
  stack dump. The existing 33-test suite never calls `create_team`, which is why
  it survived. Startup now defers to `handle_continue`.
- **No suspended agent was ever woken.** `notify_agent/2` read
  `session.classification[:agent_pid]`, a key `handle_call/3` never writes — so
  it was unconditionally nil, every wake fell through, and the log said
  "completed". `rebuild_context/1` had the same dead lookup.
- The healing orchestrator did not `trap_exit` while owning its ETS table and
  `start_link`ing its ephemerals, so one abnormal exit deleted every session
  record and skipped the teardown that wakes suspended agents. Its retry path
  also attempted `:diagnosing → :diagnosing`, failing a `{:ok, _} =` match and
  killing the orchestrator outright.
- The session cap evicted **live** sessions; it now only evicts terminal ones.
- **Cross-team leak in the decision graph**: propagation followed edges with no
  team filter while broadcasting on the origin's topic, and `do_traverse/4`
  discarded its `team_id` argument despite the docstring promising isolation.
- **`verify_loop` could steer the wrong session** — it selected over all
  registry keys and took the newest, so guidance could land in another session's
  prompt. It now uses the pid `start_child` returned.
- Upstream verifier: empty criteria passed **vacuously**, releasing every blocked
  dependent; unrecognized keys are now reported. A stale verdict can no longer
  overwrite a retry's result, and a dead verifying process resolves its row
  instead of leaving every waiter to sleep out the full timeout.
- Checkpoint filenames are sanitized on both the verification and crash-recovery
  paths (the rewind path already was).
- Teams: child registration serialized through the manager; agent-state mutations
  moved to compare-and-swap; lock holders monitored so a dead agent's lock is
  released; a rendezvous barrier can no longer be clobbered while waiters are
  blocked on it.
- Conversations: a degraded summary is no longer written to memory as canonical,
  transcript elision keeps head **and** tail, and a debate no longer counts a
  failed voter's previous-round score as current — an all-fail final round used
  to report consensus.

### Known gaps

`priv/rules/projects/bos.md` ships BusinessOS project rules — scoped in their own
text to one machine and one repository — in the bundled prompt to every user on
every request. Flagged, not removed; deleting a bundled asset is an owner
decision. `:lite` mode documents itself as "~4-6k instead of ~24k" and actually
measures **25,925 tokens**. `CLI.Doctor` reads the full static-base slot and will
under-report against a deduplicated session. Tool arrays are not yet tier-aware:
a `:subagent` receives ~2,700 tokens of schemas for tools the executor will
refuse. Three suites pass alone and fail in a full run; the two new ones may
reflect the dedup's new read of `Registry.list_active/0` at render time, which is
correct in production — that is a hypothesis, not a diagnosis.

No live provider was reachable from this machine, so the token counts are
request-body measurements and no `cache_read_input_tokens` figures were observed.

---

## [1.0.79] — displays as `v1.0.079`

### Fixed — the dead rows, and the escape codes painting as text

Two defects the owner was looking at on screen while three releases of layout
fixes shipped against a green test suite.

**Roughly a third of the screen was blank.** Three independent bands — the
streaming preview, the activity feed, and the agents panel — had each made the
same anti-churn trade: reserve a ceiling, paint the live height, bottom-anchor
the result. So a one-row reply in a turn that had once needed twelve reserved
twelve and drew one, and the surplus appeared as a gap *above* the content. One
of those bands already carried a comment describing the symptom exactly:
*"reserved the box's 12 rows and painted 1, leaving 11 dead rows above the
composer."*

All three now share one damped slot: growth is immediate (under-reserving clips
content, which is worse than a gap), and shrink is held for 200ms, re-armed by
any upward move — so an oscillating stream never thrashes the viewport and a
settled one converges on `reserved == drawn`. No quantization, no ratchet.
`measure_bands` runs twice per frame, so a shrink maturing between reservation
and paint would have orphaned rows exactly as the 1.0.75 anchor bug did; one
instant is now latched per frame to make that impossible.

**Escape codes were painting as literal text** — `[1mvite v5.4.10[0m` on screen.
`scrub_rendered_span` dropped only characters failing `is_control()`, so `\x1b[1m`
lost its ESC byte and kept `[1m`. It was a security scrub with no display
counterpart, running on every tool render. It now consumes whole sequences via
the canonical scanner, checking OSA's own OSC-8 hyperlinks first so they survive.
It fails closed: every byte attributed to an escape is dropped, and an
unterminated OSC/DCS or a CSI with no final byte is dropped to the end of the
span — strictly less untrusted text reaching the screen than before.

**The layout suite kept passing because it measured the wrong thing.** The
existing reserved-vs-drawn check only banned over-paint, on one message type. The
new invariant drives the real reservation *and* the real paint across six body
shapes, five widths and four terminal heights, asserting no blank row in the slot
and that the top row carries ink. And `test/pty/blank_rows_probe.py` is now a
gate that exits non-zero with named failures — it previously only printed, which
is how a broken screen shipped under a green suite.

### Fixed — since 1.0.78

- **An auto-paused goal resumed itself.** `GoalTracker` lived entirely in ETS,
  and every `osa` invocation is its own BEAM — so the table died at each CLI
  boundary and a goal paused for `:no_progress` came back with a fresh run
  budget. It is now a durable sidecar that fails closed: an unrecognised status
  decodes to `:paused`, never `:active`. Goals also gained a stable id, so a
  re-issued goal no longer inherits the previous one's log.
- **Cron jobs silently never fired.** Execution ran inside the scheduler process
  and matching used a timestamp read before the work, so any minute spent
  executing was never evaluated — with no missed-tick log. Execution is now off
  the process, with a watermark, per-minute backfill, an in-flight set, and a
  server-side deadline. A gap beyond the backfill window is logged at `:error`.
- **A fan-out lost every finished node if the coordinator died.** There is now an
  append-only journal replayed before anything is spawned, so a resumed run never
  re-executes a completed sibling. Results are also reassembled in submission
  order, and a reaped node keeps its real id instead of an empty string.
- **Images could exfiltrate any readable file.** The `images` parameter read an
  arbitrary caller-supplied path with no confinement, no symlink resolution, no
  size cap, and a media type guessed from the extension — and a path that did not
  exist was shipped to the provider as base64 anyway. Reads are now confined and
  canonicalised, typed from magic bytes, capped, and a bad path is an error the
  user sees.
- **No non-Anthropic provider could receive an image.** Every image block was
  flattened to a placeholder before dispatch, and vision-capable models were told
  a falsehood about why. OpenAI-compatible, Bedrock and Google now encode images
  natively, gated on the model's real capability; an unknown model passes through
  so the provider's own error speaks rather than OSA guessing. The placeholder is
  split by actual cause — transport, model, size budget, or refused at ingestion.
- **Secrets were written world-readable.** The auth token, refresh token, prompt
  history and the compose-in-`$EDITOR` draft were all created at default umask.
  They are now created 0600 before the secret is written, with the descriptor
  fchmod'd rather than the path re-resolved. A test confirms the compose path
  previously followed a planted symlink and clobbered the victim file.
- **A second permission request overwrote the first.** The dialog was a single
  unqueued slot, so with parallel tool calls the user read request A's diff and
  their answer was dispatched for request B. It is now a queue, and the answer's
  id is read from the displayed dialog so no field can drift.
- **Every copy claimed success.** OSC 52 is last in the chain and returns `Ok`
  whenever a write to stdout succeeds, so the failure arms were unreachable and
  the user was always told "Copied". Confidence is now reported honestly, an
  unconfirmed copy is parked at a named path, oversized payloads are refused
  rather than silently dropped by the terminal, and the tmux wrapper no longer
  fires inside an editor's embedded terminal.
- **Hyperlinked rows were truncated.** `unicode-width` returns 1 for ESC, so a
  single `file://` link cost ~80 phantom columns — which also made the row-padding
  guard skip exactly the lines carrying links. Width measurement is now
  escape-aware.
- **Test runs poisoned each other.** Every run shared one `/tmp` durable-log
  directory, and that log is an idempotency cache that returns a recorded result
  *without invoking the tool*. Session ids restart low each VM boot, so run N+1
  inherited run N's cache — sixteen test files affected. This was previously
  recorded here as env pollution; that was wrong, and the correction is the
  reason the suite is now stable.

### Known gaps

The owner's reported `Build's1greene— 976rmodules,xclean` corruption is **not**
explained by the escape fix — that form is single characters substituted for
spaces, and it does not reproduce on the probe. It is a separate overpaint or
column-shear defect and remains open. `scrub_untrusted_document` keeps its
character-level filter deliberately: whole-escape consumption there could swallow
multi-line content on a stray ESC, since it is not row-bounded. Two suites still
fail only inside a full run and pass both alone and paired.

---

## [1.0.78] — displays as `v1.0.078`

### Fixed — text wider than one column sheared every layout it appeared in

`priv/rust/tui/src/util.rs` has one correct display fitter, `fit_cols`, whose own
docstring warns against the two wrong alternatives. The tree contained **39
private char-count copies** of it and **15 more places** measuring a column
budget with `chars().count()` or byte `.len()`.

They render user content — session titles, file paths, memory entries, skill
descriptions, permission rules, MCP server names. One CJK character or emoji in
any of them over-ran its reserved span, pushed every column to its right, and
shoved the trailing badge or timestamp off the pane. All now delegate to
`fit_cols`, with new width-aware `pad_width`/`pad_cols`/`pad_cols_start`
primitives for the padding half, and a source guard so the pattern cannot creep
back.

- **The plan approval box was among them.** `channels/cli/plan_review.ex` held a
  byte-for-byte copy of the already-known-bad `visible_length/1` — `String.length`
  as display width, and an ANSI strip matching only SGR, so cursor-movement CSI
  and OSC-8 hyperlinks counted as visible. Model-authored plan text tore the
  border of the box the user reads *before approving a plan*. Extracted as
  `CLI.Width` with a minimal east-asian-width table, deliberately in Elixir
  rather than calling the TUI: `osa doctor`, `osa usage` and the non-interactive
  plan gate run where no TUI process exists, and a port round-trip failure mode
  underneath a consent gate is the wrong trade.
- **Markdown rows did not own every column.** A table narrower than the pane
  emitted short rows, so a terminal rendering a glyph wider than `unicode-width`
  claims caused the overhang to wrap and sheared every row below it — permanently,
  since finalized content lives in the terminal's own scrollback. Rows are now
  padded to the full region.
- Elixir word wrap could not break an over-long token, so a URL or base64 blob
  blew out every border after it; it also discarded the user's indentation by
  splitting on `\s+`. Both fixed.
- The task box's top border was sized from a hand-counted literal and came out
  **three columns short of every other row, for plain ASCII too**.
- Multi-line tool headers rendered as `export A=1cd /tmpmake`, because ratatui
  treats `\n` inside a span as zero-width.

### Fixed — work that was silently destroyed

- **Subagent worktrees were deleted with no durable snapshot**, and the snapshot
  config defaulted to `false`. The path is deterministic per subagent id, so a
  retry or resume of the same id destroyed the previous run's *uncommitted* tree
  and force-deleted its branch. Reclaim now snapshots a dirty tree before
  removal and **fails rather than destroying** if the ref cannot be written. The
  default is flipped to `true`: with it off, `discard: true` could never be
  honoured for a dirty tree, so the enforcement was vacuous.
- **A fan-out timeout killed the poller, not the worker.** The node kept running
  and writing while being reported as terminally failed, and its result carried a
  nil worktree ref — so everything it wrote was never merged and its branch was
  orphaned. The ceiling now cancels the worker and waits for acknowledgement; a
  node that never acknowledges gets its own `:uncancelled` outcome rather than a
  fabricated one.
- **`Task.await` + `:brutal_kill` destroyed the process that persists the child's
  transcript** — precisely what `resume_subagent` needs — and left the run row
  `:running` forever. The outer deadline is now strictly longer than the inner,
  with a grace window so cleanup lands before anything is killed.
- **The task queue advanced in-memory state on failed writes**, so a `complete`
  whose write failed left the row leased with no result, and the reaper ran the
  task a second time. Writes now happen first. Found while fixing it: every
  reap-to-failed write was writing an atom into a `:string` column, raising
  `Ecto.Query.CastError` and being silently swallowed — the row was never
  persisted at all.

### Fixed — controls that failed open

- **A BOM in `settings.json` silently discarded the whole file** — `permissions`,
  `env`, `hooks`, `permission_mode` — making the agent *more* permissive than
  configured. The BOM is now stripped; a file that exists but cannot be parsed
  logs loudly and **pins `permission_mode` to `ask`** while any layer is
  unreadable, because deny rules cannot be recovered and nothing should run
  unprompted in their absence.
- **Disabled skills still reached the model.** The `.disabled` marker was enforced
  at a flat path while discovery globbed six roots, so every bundled and every
  project-scoped skill was undisableable by construction — and the trigger-match
  path, which injects the full instruction body, checked neither `.disabled` nor
  the `paths:` gate. One canonical check now, matching the one `osa doctor`
  already used.
- **A subagent whose frontmatter would not parse loaded unrestricted**, with
  `tools_blocked: []` and its raw frontmatter as the system prompt. A file that
  *declares* frontmatter it cannot parse is now refused; a file with none still
  loads as a plain prompt, because nothing was declared and nothing discarded.
  Five sibling parsers collapsed into one BOM-tolerant module.
- **`use_skill` enforced a hardcoded `~/.osa/skills`** while the loader used six
  roots, so every repo-scoped skill was advertised and then refused at invoke.
  Now a path-boundary test against the real roots — `~/.osa/skills-backup/…` no
  longer passes a prefix check.

### Fixed — budget and unattended execution

- **Budget enforcement collapsed "unknown" into "zero" in five places**, so an
  absent spend sidecar read as free and kept spawning. An incompleteness signal
  now travels with the rollup and fails closed when a positive cap exists. A
  still-running node is not counted as unknown — it simply has not reached its
  first persist point, which is a measurement rather than a guess.
- Two pricing engines billed the same tokens differently, one of them re-billing
  cache reads at full input rate; `/cost` showed the inflated figure. One usage,
  one price, one engine.
- `record_cost` now resets before accumulating, so spend between midnight and the
  first read is no longer accrued into yesterday and then zeroed.
- **`verification/loop.ex` executed model-authored shell unattended** — any reply
  line starting `$ ` went straight to the shell with no gate. It now runs through
  the existing `DangerousCommands` + `Permissions` stack, and only an explicit
  `allow` executes: `ask` refuses, because nobody is there to ask. A terminated
  loop also refuses late results, which previously could flip it to passed and
  execute more shell.

### Known gaps

Several `async: false` suites mutate `HOME` and application env and interfere
when interleaved — four tests fail in a full run and all pass in isolation. The
code is correct; the isolation is not. Lease epochs are still per-VM: persisting
them needs a migration, and an unapplied migration would now hard-fail task
completion under the new fail-closed writes. OSA still has no in-app scrollback —
finalized content is handed to the terminal at the width it was wrapped for, so a
resize cannot re-wrap it; that is architectural, not a defect to patch.

---

## [1.0.77] — displays as `v1.0.077`

### Fixed — the TUI kept losing its layout

Reported as "it just doesn't have a structure, it loses its structure", with the
model's reply landing in the middle of the screen. One cause, four symptoms.

`Viewport::Inline` has no position of its own — ratatui anchors it wherever the
cursor is — and **two paths decided that, disagreeing**. The commit path leaves
the region immediately below what it just committed (flow-anchored). The
height-change rebuild shipped in 1.0.75 homed it to `rows - inline_h`
(bottom-anchored). The region changes height several times per *turn* — spinner
appears, preview quantizes, composer grows, turn ends — so it teleported between
the two on every turn, with no resize involved.

- Growing, `rows - h` sits **above** the region, so chrome was rebuilt on top of
  rows holding committed conversation. `insert_before` renders `old.diff(&new)`
  against an empty buffer, so blank cells are never emitted and the text
  underneath bleeds through — the banner interleaved with the status bar, two
  composers, two status rows, replies out of order.
- Shrinking, `rows - h` sits **below**, and the vacated rows became a blank band
  the next commit scrolled into scrollback.

The 1.0.75 homing was right for a resize — the screen reflowed, so the old top
genuinely is unknowable — and wrong everywhere else. It is now used only for a
real resize; a plain height change keeps its top, and a grow that would overflow
scrolls the screen by exactly the overflow so rows are **made, not taken**.

Second, independent cause of the dead space: `stream_preview_rows` put its
quantization lattice at `ROWS + k*STEP`, so the first token of a one-line reply
reserved 10 rows and drew one. The preview bottom-anchors its tail, so the
undrawn rows landed between the prompt and the spinner.

Measured on a 100×30 PTY: 5 dead rows before, 0 after — and before the fix a
second turn also truncated the first reply from 9 rows to 3.

The layout suite passed throughout, because `test_resize.py` asserted the
*consequence* (chrome at the bottom) rather than the *invariant* (chrome sits
against the transcript) — the same mistake the product made. Seven new
invariants now fail on the pre-fix code.

### Fixed — two ways to destroy the user's data, and one to run their code

- **`skill_manager` could recursively delete `~/.osa`.** `name` is a bare
  LLM-supplied string, `Path.join` does not normalize `..`, and the kebab-case
  regex guarded only `create` — so `delete` with `name: ".."` reached
  `File.rm_rf!` on the parent: sessions, transcripts, memory, credentials.
  It declared `safety: :write_safe`, i.e. auto-approvable. Now regex **plus** a
  containment proof on the expanded path, and `:write_destructive`. The
  regression test deletes the parent directory on the old code.
- **Editing a file in any cloned repo ran that repo's code.** `verify/post_edit`
  `Code.eval_file`'d the first `.formatter.exs` found walking up 40 parents, and
  it runs on every `file_edit`/`file_write`. A `rescue _ -> []` hid it. Options
  are now read off the AST via `Code.string_to_quoted` + `Macro.quoted_literal?`
  — computed values are dropped rather than executed. The regression test writes
  a canary file on the old code.
- **A failed read fed a whole-file rewrite in seven stores** — cron jobs, MCP
  servers, permission rules and four copies of `config.json`. One BOM or one
  truncated write, then one addition, and the rest was gone. The provider route
  destroyed every other provider's API key and still returned
  `200 {"status":"connected"}`; it now returns 500. The contract OSA already had
  in two places is extracted to `system/json_store.ex`.
- **API keys were written world-readable.** `osa.chat` wrote `~/.osa/.env` at
  0644 and rebuilt it from three env lookups, destroying any other key. Two more
  write-then-chmod TOCTOU holes were found in `onboarding.ex`.

### Fixed — secrets reaching disk, screen and subprocesses

- **Every subprocess inherited every API key.** `shell_execute` opened its port
  with no `:env`, so any model-authored command could read `ANTHROPIC_API_KEY`
  and friends. A shared scrubber now uses Erlang's overlay semantics, so `PATH`,
  `HOME`, `LANG` and the user's own vars survive and builds still work. Proven
  by a canary the child could previously read.
- **Typed text — passwords — was stored and displayed in clear.** Computer-use
  `type`/`fill` text reached the terminal, the render map and the trajectory
  file. Masked structurally by argument name, so shape is kept and the value
  never leaves the executor.
- **Redaction failed open.** On a regex failure it returned the *unredacted*
  original. Worse than reported: `Regex.replace/3` does not raise on invalid
  UTF-8 under OTP 28 — it silently matches nothing, so a secret in a binary with
  one stray byte was written wholly unredacted with no exception. Now fails
  closed, with the text coerced first so the scrubber can see it.
- **Reasoning text bypassed redaction** on its way to the bus and PubSub. The
  redactor also had to be narrowed: `token` is a substring of `max_tokens`, so
  ordinary prose came back as `max_tokens = [REDACTED]`.
- **The VNC path connected to a hardcoded `127.0.0.1:5900`** while its own
  server bound an auto-assigned port — so it could attach to a real
  desktop-sharing server for the user's session and forward remote input into
  it. The real port is threaded through, and the server no longer runs
  unauthenticated, `-shared` and `-forever`.
- **The Windows capture helper was resolved from a user-writable path first**,
  with no signature check. Bundled binary now wins; an override needs a pinned
  SHA-256.

### Fixed — surfaces that reported work that did not happen

- **A failed fleet node was merged into the user's branch.** The await status
  was discarded and `gate: :pass` hardcoded, so the finalizer's existing skip
  never fired and a crashed node's partial worktree was committed.
- **The verification loop could never pass.** The result was sent as
  `{pid, ...}` and matched as `{ref, ...}`, so it never arrived; the task's
  normal exit then hit the crash clause. `succeed/1` was unreachable and every
  run escalated. There was no test file.
- **A mid-stream failure re-emitted the whole answer.** The per-hop fallback had
  no `output_observed?` check, so a stream dying at 80% rendered 180%, and the
  duplicate was persisted as the assistant turn.
- **A structured provider error crashed the code meant to explain it.** Four
  providers interpolated `error.message` with no `is_binary` guard; the raise
  was swallowed, destroying both the HTTP status and the provider's explanation.
- Terminal run states no longer demote, counters no longer decrease, and tree
  spend is read from an unpruned edge ledger instead of an evictable cache.
- Task-queue leases carry epochs, so a slow worker can no longer overwrite the
  result of the worker that replaced it, and reaped tasks count an attempt.

### Changed

Writes into `.git/` internals are now **refused** rather than prompted, in every
permission mode. Prompting was the one answer that could not hold in overdrive,
whose whole purpose is not stopping to ask — and `core.hooksPath` is code
execution on the user's next git command. Two tests asserted the old contract
and were updated to the stronger one.

### Known gaps

`anthropic.ex` still lacks the sync→stream recovery its sibling now has. The
Windows `VncServer.cs` still offers security type None (confirmed, not fixed —
no Windows build here). `desktop_ready` now carries a VNC password the control
plane must read, or desktop sessions will fail the handshake; the auth is
disableable via `config :desktop_vnc_auth, false` if that lands first. Roughly
175 other `Port.open`/`System.cmd` sites still inherit the environment.
`UsageTest` and `LiveKeyResolutionTest` share a boot snapshot and are
order-dependent; both pass in isolation.

---

## [1.0.76] — displays as `v1.0.076`

### Fixed — surfaces that reported things which were not true

A sweep against the fix histories of four other agent harnesses, plus a dead
code audit. The theme is the same in every case: a surface that stated
something confidently while the underlying value said otherwise.

- **Tool durations rendered `0.0s`.** The activity feed formatted every
  completed call with `{:.1}s`, so anything under 50ms floored to a literal
  zero — while the transcript renderer one line below showed the same call as
  `40ms`. The timing was never wrong; only that one formatter was. On screen
  since March.
- **Failed tool calls arrived labelled successful.** The `:end` event hardcoded
  `success: true` in the PubSub broadcast — which is the one the TUI's SSE
  stream actually carries — while the sibling `Bus.emit` two lines above had
  already computed the real value. Failed reads and greps compounded it,
  summarising the error text as though it were content (`Read 1 line`).
- **Outcome was carried in colour alone.** Success and error shared one glyph,
  leaving them indistinguishable under `NO_COLOR`, on a monochrome terminal,
  and to a red/green colour-blind reader. Error is now `✗`.
- **`/rewind` zeroed the spend ledger and removed the budget ceiling.**
  `restore_conversation/1` passed a five-key map to a full-record writer, so
  seven omitted fields were written as defaults: session cost to `$0.0`, four
  token counters to `0`, and `max_budget_usd` to `nil` — uncapped. The sidecar
  then mirrored the zeros to disk. A partial write is now completed from the
  persisted record, never from struct defaults, and the crash checkpoint
  reconciles against the never-cleared sidecar with `max` per accumulator.
- **A successful OAuth refresh whose disk write failed destroyed the
  credential.** Past `{:ok, updated}` the rotation is already spent, so the
  write is retried and the token returned regardless; a failure names the file
  and the recovery instead of silently signing the user out.
- **Silent background agents were reported as failed.** `prune_stale` flipped a
  quiet `Running` row straight to `Failed`, so an agent that was merely slow to
  report appeared to have crashed. It now becomes `Unknown`, and is removed
  rather than libelled if it stays hopeless.
- **`background_agent_stalled` had no consumers on either side.** The TUI now
  renders it and the notifier acts on it — without burning the terminal-result
  token, which would have swallowed the later completion.
- **Usage counters were overwritten with zeros.** The wire type could not
  distinguish absent from zero, so a silent frame wiped accumulated totals.
  `Option`-typed end to end.
- **Swarm timeouts were laundered into `{:ok, "[Agent timed out]"}`**, letting
  the parent model build on work that never happened. `Orchestrator` already
  handled this correctly; `Swarm.Patterns` now matches it.

### Added — compaction is visible, and says what it did

Compaction could run for minutes with nothing on screen. `/compact` fired, showed
a three-second toast, then went quiet for the duration of the call.

- A live line while it runs: spinner, ticking elapsed, `esc to interrupt`.
- A measured `▰▱` progress bar **only on the path that genuinely chunks**
  (`compactor.ex`'s cold-zone step, driven by real `chunk_index/chunk_total`).
  The `/compact` path is a single summarizer call and reports no progress, so
  it shows no bar rather than animating a number the system does not have.
- A completion line with real figures — `✓ Compacted ~84.0k → ~21.0k tokens
  (38 messages folded) · 2m 14s` — and a failure line that says the
  conversation is unchanged, because a vanishing indicator reads as success.
- The events dual-emit on session PubSub as well as the Bus. Emitting on the
  Bus alone is invisible to the TUI, which is the same trap that hid the tool
  success flag above; the test asserts against PubSub specifically, since
  asserting on the Bus would have passed on the broken code.

### Removed — dead code, and five surfaces that were broken rather than unused

Roughly 2,400 lines. The deletions are the least interesting part:

- **`semantic_search` had never returned a result.** Registered and
  model-reachable, but aliasing two modules that do not exist; both branches
  raised and a `rescue` turned it into "search error" text.
- **`team_create` would have crashed on first use.** The supervisor started
  `Teams.Registry`, referenced nowhere, while 27 call sites used a name nothing
  started. Only `validate/2` had test coverage.
- **The DingTalk webhook accepted unauthenticated bodies.** `verify_dingtalk/3`
  existed with zero callers while config advertised the secret as enabling
  verification.
- **Three documented computer-use adapters were unreachable** — Docker,
  RemoteSSH and PlatformVM had no dispatch clause, so even the documented
  override fell through to `Unknown platform`.
- **~50 config keys read as settings but controlled nothing**, including a
  budget cap (`Budget` reads a different key) and twelve `sandbox_*` keys
  (`Sandbox.Docker` reads a nested map). A mix task was instructing users to
  set one of them.

### Known gaps

Carried forward, verified but not yet fixed: the credential store degrading a
failed read to `%{}` before a whole-file write; the single-level `readlink` in
the write guards; subprocesses inheriting provider API keys; command output
truncated head-first; and fleet merging a failed node's worktree. Full-suite
counts are order-dependent — `LiveKeyResolutionTest` and one `UsageTest` case
share a boot snapshot and pass in isolation.

---

## [1.0.75] — displays as `v1.0.075`

### Fixed — the composer no longer jumps to the top of the screen after a resize

The long-running "the TUI breaks and the chat goes all the way to the top, and
I have to scroll down" report. The cause was not the erase — which four
successive fixes targeted — but the **re-anchor immediately after it**.

- `Viewport::Inline` does not choose a position. ratatui's `compute_inline_size`
  anchors the new region on **wherever it finds the cursor**. The resize clear
  homes the cursor to row 0 and erases forward, so the rebuild placed the live
  region at the **top** of the screen.
- Measured on a 30-row terminal: chrome at rows 25-28 before a width resize,
  **rows 1-4 after exactly one** — permanently inverting the bottom-anchored
  invariant the whole inline design rests on.
- The rebuild now homes to `rows - inline_h` explicitly. Same probe, after the
  fix: 25-28 booted, 25-28 after one resize, 25-28 after a second, 24-28 after
  committing a message and after a keystroke.

**One inversion produced three separate symptoms**, which is why they were
chased independently for so long:

1. The composer sitting at the top with dead space below — visible, and *not* a
   duplicate, which is precisely why band-counting harnesses never flagged it.
2. Stacked copies — with the region at rows 0..h, the next `insert_before`
   scrolls at the bottom and pushes those rows into scrollback, where no erase
   can reach them; on a reflowing terminal a later widen pulls them back.
3. Occasional transcript loss — `last_inline_top` is refreshed from the rebuilt
   viewport and becomes 0, so the next pure height change clears from row 0.

The multiplexer branch escaped only incidentally: it homes to the remembered
top rather than row 0, so it happened to preserve the anchor. That is why the
defect looked terminal-specific when it never was.

### Still open — stated honestly

- **One scenario still strands on real libvte**: a width drag with a live
  transcript. Three of four previously-failing scenarios now pass; that one
  reports 5. The shape has changed — what repeats now looks like committed
  transcript lines re-emitted per width step, not chrome at row 0 — so it is a
  different mechanism on the `insert_before` path, or a counting artefact
  (the probe counts `❯`, and committed user messages also begin with `❯`).
  Under investigation; not claimed as fixed.
- Ghostty's band count remains unverified (no text API); Alacritty, kitty and
  xterm are untested. `OSA_RESIZE_CLEAR=surgical|full` overrides the branch.

### Why this took four attempts

Three independent harness flaws made every earlier green result meaningless,
and all three are worth recording:

- The harnesses inherited `$TMUX` from the development shell, so the libvte
  harness had been exercising the multiplexer branch all along — it never once
  tested the path it existed to test.
- They ran with an essentially empty transcript. With nothing above the live
  region, nothing moves on a widen and both branches pass.
- All three real-terminal harnesses pass `OSA_BASE_URL`, which the binary does
  not read (`config/mod.rs:215` reads `OSA_URL`/`OSA_PORT`).

And the assertion itself was the wrong shape: counting band occurrences cannot
see a region that **moved** to row 0 — there is still exactly one of it. The
invariant that catches this class is `viewport.top() == rows - inline_h`.

---

## [1.0.74] — displays as `v1.0.074`

The largest release this project has taken. Boot is **20× faster**, a command
blocklist documented as unbypassable was trivially bypassable, several paths
lost user data silently, and the model could not see any of your MCP tools.
Most of it came from reading what comparable tools had already found and fixed,
then checking each claim against this codebase rather than porting it blind.

### Performance

- **Boot: 8s → 1.2s.** `Tools.Registry.init/1` compiled a goldrush dispatcher
  module at runtime, one branch per tool: 322ms at 20 tools, **6102ms at 82**.
  **Nothing ever called it** — no `:glc.handle` reader exists for it anywhere.
  Six seconds per start, plus a recompile on every tool registration, for a
  module with zero readers. Now lazy. Also added permanent per-child supervisor
  timing, because nothing in the tree reported how long a child took to start,
  which is why this was invisible for so long.
- **Code-fence streaming: 7.4× faster.** A 200-line fence cost 8907µs *per
  token* — 27 seconds of render work across the block. Markdown has no safe
  split point inside an open fence, so the whole block sat in the unstable tail
  and was re-highlighted from line 1 on every token; measurement showed **93% of
  the cost was syntect**. Highlighting is now incremental, proven byte-identical
  against every prefix of the old algorithm.
- Render cadence held to 60fps for consecutive streaming-only batches. Scoped so
  the first token of a message always draws immediately and no keystroke is ever
  delayed.

### Fixed — the command blocklist was bypassable in every mode

- Quoting defeated it: `rm -rf "/"`, `rm -rf '/'`, `"rm" -rf /`, `rm -rf \/` all
  passed. So did `bash -c "…"`, twice over — the payload is opaque to the target
  patterns *and* the `:ask` tier only sees the command head, which is `bash`.
- The breaker is documented in-code as applying in every permission mode
  including full-auto. Because the hole was in the matcher rather than the
  gating, it defeated all of them — and in full-auto it is the only gate, so
  there was nothing between the model and the disk.
- Fixed by normalising before matching (shell-unquote, recursive wrapper
  extraction) rather than hardening regexes, which is an unwinnable race. The
  duplicate blocklist was collapsed into one, with a test asserting they agree.

### Fixed — silent data loss

- **Compaction destroyed the summary it had just produced.** The summary was
  prepended, then a later step in the *same run* sliced positionally from index
  0. Its importance score was never consulted. The LLM-generated summary of the
  entire cold span vanished in the run that created it.
- **`replace_all` rewrote regions that never contained the search string.**
  Seven of nine matching strategies are approximate; a global textual replace of
  an approximate candidate can land in a comment or inside a string literal.
  Corruption on disk, not just a wrong answer.
- **A metadata update clobbered the transcript.** Whole-record read-modify-write
  meant a metadata write racing a turn save destroyed the turn. Metadata now
  lives in a sidecar and never touches the transcript.
- **Every `osa` invocation cancelled the previous one's running agents.** Run
  state is machine-global but liveness was decided by a BEAM-local registry, so
  another process's live run always looked dead — and the cancellation ran even
  with resume disabled. Replaced with an on-disk ownership lease that is
  deliberately *not* released on unclean shutdown.
- **Compaction summaries leaked across sessions** — a global ETS key, never
  deleted, folded one session's summary into another's prompt and shipped it to
  the provider.
- **Hand-written skills were archivable on the curator's first pass**: a skill
  with no usage record was treated as 999 days idle. Curation is now report-only
  by default, with pinning and un-archive.
- **A read error on the durable log failed open into "the log is empty"**,
  duplicating the entire transcript into the immutable log.

### Fixed — token accounting was wrong in three directions

- Anthropic usage was read as `input_tokens` alone, ignoring cache-read and
  cache-creation: a real shape reported **2,000 tokens where the context was
  152,000** — 76× low, and compaction silently stops firing the moment prompt
  caching starts working.
- The estimator was whitespace-blind: a 320KB hex dump estimated at **1 token**.
  Now floored at bytes/4.
- Base64 images were charged at their encoded length — one image at 40,034
  tokens where the provider bills ~1,600.

### Fixed — the model could not see your MCP tools

- Above the virtualization threshold every MCP tool was dropped from the tools
  array and nothing put it back anywhere the model could read. Measured on this
  machine: **servers named in the system prompt 0/3 → 3/3, tools 0/30 → 30/30.**
- Keyword search compared a downcased query against the **raw** tool name, so any
  tool with an uppercase letter — most MCP names — could never match on name.

### Also in this release

Terminal-injection scrubbing across every renderer, proven at the emulator level
with control arms (a permission target could retitle your terminal window from
inside the approval dialog) · TUF signature verification on update metadata,
with a tripwire test that fails if installation is ever wired to unverified
metadata · streaming retry no longer re-emits text you already saw · orphaned
tool results filled across the whole transcript, not just the last message ·
message chunking measured in the unit each provider actually enforces (CJK and
emoji replies had holes in the middle) · `trap_exit` so crash-time history
survives, scoped to outside turns after measurement showed always-on trapping
turned a fast shutdown into a 5.3s hang · SKILL.md validation and `mix
osa.skills.lint` — a typo'd `descrption:` silently produced an empty description
and a relevance score of exactly 0.0 · pre-compaction memory flush · file-read
diagnostics that name the binary type, distinguish empty from past-EOF, retry
unicode filenames, and refuse FIFOs by stat rather than hanging forever ·
`osa doctor --config` showing which markdown files, skills and settings are
actually loaded, from where, and why a skill is not surfaced.

### Known gaps — stated rather than discovered later

- **Duplicated chrome on resize is not fully solved.** Two distinct failure
  shapes are measured (one copy per drag step under a multiplexer; a single
  bounded copy on WezTerm) and the gate is scoped from evidence, but Ghostty's
  band count is unverified — it exposes no text API — and Alacritty, kitty and
  xterm are untested. `OSA_RESIZE_CLEAR=surgical|full` overrides it without a
  rebuild. Two investigations are open, including one that questions whether the
  resize path is the dominant cause at all.
- A text file containing a NUL byte in its first 4KB is now refused as binary
  where it previously read through. Behaviour change.
- The secret redactor is over-aggressive on three prose shapes
  (`"Basic authentication configuration"` → `"Basic [REDACTED] configuration"`).
- Several render surfaces are still unscrubbed, ranked in the source — worst is
  the transcript viewer, which bypasses markdown entirely.
- Multi-process SQLite is documented, not solved: WAL plus busy_timeout gives
  corruption-safety and blocking writers, not serializability.
- OSA wedges at startup when it inherits a screen with too little room for the
  inline viewport.
- `multi_file_edit` is still all-or-nothing: one already-applied hunk kills the
  batch.

---

## [1.0.73] — displays as `v1.0.073`

MCP conformance. The spec moved — HTTP+SSE was replaced by **Streamable HTTP**
in revision `2025-03-26` and is now deprecated — and OSA had drifted from it in
three places, one of which degraded a working connection.

### Fixed — an expired session downgraded OSA to the deprecated transport

- A `404` was classified purely as "this endpoint does not speak Streamable
  HTTP", which is correct only when no session is in play. The transport spec
  is explicit that a 404 **in response to a request carrying `Mcp-Session-Id`**
  means the server terminated the session and the client MUST start a new one
  with a fresh `InitializeRequest`.
- Conflating them meant a healthy modern server that timed a session out sent
  OSA back to the **deprecated** HTTP+SSE transport, so a long-lived session
  silently lost Streamable HTTP after an idle period. The two cases are now
  separated: no session id → protocol probe; session id → re-initialize.

### Fixed — `MCP-Protocol-Version` was never sent

- The spec requires it on every HTTP request after initialization. It failed
  quietly rather than loudly because a server receiving no version header is
  told to **assume `2025-03-26`** — so OSA was being version-negotiated by
  omission, with every server guessing and none of them told.
- Now sent on every Streamable HTTP request, read from the same constant the
  handshake uses so the header and the announcement cannot disagree.

### Noted, deliberately not "fixed" — OSA announces the original revision

- `protocolVersion` is `2024-11-05`: the first MCP revision, whose transport is
  the deprecated HTTP+SSE one. OSA therefore announces a 2024 protocol while
  implementing a 2025 transport, and a server honouring the announcement may
  withhold everything added since.
- Raising it is real work rather than a string edit — later revisions add
  capabilities (structured tool output, elicitation, resource links) a client
  must not claim without implementing, and OSA's own MCP *server* reads the
  same constant. It is left at the honest value with the consequences written
  down, instead of being raised to look current.

---

## [1.0.72] — displays as `v1.0.072`

Same fix as 1.0.71, done properly: the stacked composers are gone **and** your
scroll history survives a resize.

### Fixed — the resize fix no longer costs you your scrollback

- 1.0.71 removed the stranded copies by purging tmux's pane history (`ESC[3J`)
  on every resize. It worked, and it was the wrong trade: it destroyed the
  user's scrollback to clean up a mess the resize path did not need to make.
- **The stranding is now prevented rather than cleaned up.** The full-screen
  wipe exists because "a resize reflows the emulator, so the old chrome's row
  is unknowable" — and that premise is simply false inside a multiplexer.
  tmux and screen do **not** reflow on a width change, so the remembered
  live-region top stays valid and the same surgical clear used for height
  changes is both sufficient and non-destructive. Under a multiplexer the
  resize now clears from that row down; everywhere else the full-screen path
  is unchanged.
- Result: the old chrome is overwritten in place and never becomes pane
  history at all. Verified on the same harness that reproduced the defect —
  one copy of each band after both a slow 12-step drag and a fast one.

### How the answer was found

- Claude Code was measured through the same tmux harness, driven through the
  identical 12-step drag: **one prompt box, no stranding.** That proved the
  defect was avoidable rather than inherent to inline rendering, which is what
  ruled the history-purge trade unacceptable.
- grok's pager takes the other available route — it owns its scrollback
  outright (`ScrollbackState` with a width-keyed layout cache) and never
  deposits into the terminal's. That is the larger refactor this fix does not
  need.

### Rejected, recorded so they are not re-tried

- **ED3 history purge** (shipped in 1.0.71): works, destroys scrollback.
- **Resizing the viewport in place instead of reconstructing it**, on the
  theory that tmux drops the DSR cursor query the rebuild issues: removed the
  query entirely and changed nothing — still 13 copies. The copies arrive
  through ordinary scrolling, not through anchoring.

The `ED3`-on-resize ban in `layout_invariants` is unconditional again, with a
note explaining that a future stranding must be fixed by not creating it.

---

## [1.0.71] — displays as `v1.0.071`

Dragging the window no longer leaves a stack of composers behind. This one has
been reported repeatedly and "fixed" several times; it survived because nothing
that could fail was watching.

### Fixed — a width drag stranded one copy of the live region per resize

- **The cause is tmux, not the terminal.** Reports came from sessions running
  `TERM=tmux-256color`. tmux is not a passthrough: it is its own emulator with
  its own screen model, it does not reflow on a width change, and the live
  region scrolls into its PANE HISTORY as it redraws at each new width. An
  erase — any erase — cannot reach scroll history, so the existing ED0 clear
  wiped the visible screen and left every abandoned copy exactly where it was.
- The copy count tracked the *rebuild* count precisely: a 12-step drag left 13
  copies, a fast (coalesced) drag left 5. That is why raising the settle window
  reduced the symptom without ever removing it.
- `ESC[3J` is the only sequence that reaches pane history, and it now runs on
  resize **inside a multiplexer only**.

### Why previous fixes could not have worked

- The layout harness renders with `pyte`, which does not reflow on resize.
  Real terminals do. A drag that stacked copies on the user's screen rendered
  as clean in the harness, so every fix shipped green.
- Two new harnesses close that gap. `test/pty/vte_resize.py` embeds real
  libvte through GObject introspection — the library GNOME Terminal links —
  and verifies its own resizes actually reach the child before asserting
  anything. `test/pty/tmux_resize.py` drives a real tmux pane on a dedicated
  server and reads history back with `capture-pane`. The tmux one reproduced
  the defect on demand; the VTE one shows libvte reflow never stranded
  anything, which is what scopes the fix.
- A discarded hypothesis, recorded so it is not re-tried: the rebuild's DSR
  cursor query being dropped by tmux. Resizing the viewport in place instead of
  reconstructing it — removing the query entirely — changed nothing. Still 13
  copies. The copies arrive through ordinary scrolling, not through anchoring.

### The trade-off, stated plainly

- **Resizing inside tmux discards that pane's scroll history.** The
  conversation is not lost — every finalized message stays in the transcript
  viewer (Ctrl+O) — but scrolling the pane back past a resize will not show it.
- Outside a multiplexer nothing changes at all: the added code returns
  immediately, so Ghostty, WezTerm, kitty, Alacritty and every plain terminal
  take byte-for-byte the path they took in 1.0.70. A test pins that scoping in
  both directions so the exception cannot be widened by accident.

---

## [1.0.70] — displays as `v1.0.070`

The provider and model pickers now tell you what you are actually looking at:
which models your plan can run, which concrete model an alias resolves to, and
why a sign-in was refused.

### Fixed — a model your Claude plan can run was never offered

- **`fable` was missing from the Claude Code model list.** `claude --help`
  names its own aliases as "'fable', 'opus', or 'sonnet'"; OSA carried
  `sonnet`, `opus`, `haiku`. A subscriber could run Fable and OSA never showed
  it. Read back off the installed binary, which is the only source that cannot
  disagree with the CLI actually present.

### Fixed — provider descriptions silently disappeared

- **The picker was pinned to 82 columns** regardless of terminal width, and its
  rows are two-column (name + status on the left, description right-aligned)
  with the description dropped when what remains is too narrow to read. On a
  long row — "Claude subscription (via Claude Code)  ✓ signed in as
  you@example.com" — the description vanished with no ellipsis while 60 columns
  of screen sat unused beside the dialog. The dialog now grows to 120 columns.
  The drop is still by design (a truncated status is worse than a missing
  description) but is now a last resort on a genuinely narrow terminal.

### Added — the picker names the concrete model

- Claude Code resolves an alias downstream and reports the real id back on the
  first call. That was recorded and shown only in the CLI header, never in the
  TUI, so `/model` said "Opus" and nothing more. The alias row now reads
  "Most capable · now claude-opus-4-5-20260101" once known. Only the alias that
  actually resolved is annotated, and the resolved id is never substituted into
  the model `id` — the alias is what the CLI accepts.

### Fixed — a refused sign-in explains itself

- The device-code endpoint's error body was discarded, leaving a bare status
  number. Device code authorization is an account/organization security setting
  that ships **off** for some ChatGPT accounts, and when it is off the endpoint
  refuses before any code exists — so the user saw a number and had no way to
  learn that a checkbox in their own settings was the entire problem. The
  provider's reason is now surfaced, along with what to enable.
- Deliberately NOT repeated: the provider's verification page says to re-run
  *its own CLI* afterwards. That instruction is wrong inside OSA. The setting
  is the actionable half and is the same setting whichever tool asks.

### Note on 1.0.69

That release went out with a red Rust test: `VERSION` was bumped after the Rust
suite had already run, so the Cargo.toml drift guard fired one release late.
Both version files are now bumped together and the suite re-run afterwards,
which is the order that guard requires to be useful.

---

## [1.0.69] — displays as `v1.0.069`

Two things that made a signed-in account unusable: OSA told you to quit and run
a different program to fix an error you were looking at, and it offered ChatGPT
models your plan stopped carrying three releases ago.

### Fixed — errors no longer send you out of the session

- **29 user-facing strings instructed the user to run `osa setup`.** The one
  most people hit is the *shared* `:not_connected` message in
  `Auth.Subscription` — every subscription provider reuses it, which is why
  this looked like a different bug on each provider and was in fact one string.
  Auth errors now name `/login` (sign in with an account) or `/provider` (add
  or change an API key). The CLI still exists; it is no longer the advice.
- Same treatment for expired sign-ins, revoked tokens, 401/403, missing keys,
  the Bedrock and Anthropic messages, the Claude-subscription entry, and the
  "Ollama is not running" hint.
- **A class guard was added** rather than only fixing the strings. These
  messages are written per provider, so the next provider added would have
  reintroduced the problem. `in_harness_guidance_test.exs` strips comments,
  sweeps the auth/provider sources for shell-exit phrasing, and checks every
  provider in `Subscription.supported()`.
- Six tests asserted the old behaviour — one was named `auth errors point at
  \`osa setup\``, with a comment explaining that `/login` had been dropped when
  OSA was briefly API-key-only after the Anthropic sign-in removal. That
  premise ended when account sign-in landed. They now pin the general
  invariant: an auth error names a slash command and never names a shell.

### Fixed — the ChatGPT model list was three generations stale

- OSA offered `gpt-5.2-codex`, `gpt-5.1-codex-max`, `gpt-5.1-codex-mini` and
  `gpt-5.2`. **None of those ids appear in the Codex picker any more**, so a
  user who signed in was defaulted onto a model their plan no longer carries.
- Replaced with the current line-up — `gpt-5.6-sol` (now the default, matching
  Codex's own current selection), `gpt-5.6-terra`, `gpt-5.6-luna`, `gpt-5.5`,
  `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.3-codex-spark`.
- The catalogue test now pins *the default model is present in the catalogue*
  instead of one hardcoded id, so it fails when the list ages out rather than
  passing while pointing at nothing.

### Known gaps, unchanged from 1.0.67

- No call has been made to a live provider endpoint from this build.
- Stacked chrome after a terminal resize is still unreproduced. The test
  harness does not reflow on resize; real terminals do.
- `claude_cli` still requires Claude Code to be installed and signed in first.
- Account/plan/quota is collected from provider response headers and shown by
  `/usage`, but is not yet drawn in the model picker. It has nothing to draw
  until a turn succeeds.

---

## [1.0.68] — displays as `v1.0.068`

### Added — `/mcp` can turn servers on and off

- The panel listed loaded servers and nothing else: no way to see what could
  be turned on, and no way to turn it on. Servers you had not enabled were
  invisible, so the list looked complete while hiding most of the choices, and
  the footer read "nav / close" because those genuinely were the only two
  things it could do.
- `GET /api/v1/mcp` now also returns discovered-but-not-imported servers with
  status `available`, plus their source and whether each row is toggleable.
- `POST /api/v1/mcp/:name/toggle` edits the allow list in user settings and
  reloads the client, so a toggle takes effect without a restart. Native
  `~/.osa/mcp.json` entries are refused with an explanation rather than
  silently rewritten, and an empty allow list is expanded before removal so
  turning one off is never a no-op.

---

## [1.0.67] — displays as `v1.0.067`

You can now sign in to a provider with an account you already pay for, from
inside OSA, and use it. Before this release you could not: clicking any
provider answered `Failed to load models: HTTP 401`, `/login` did nothing, and
providers that have no API key to paste were labelled "needs key" — a dead end.
Three separate bugs produced that one experience, and all three are fixed.

The picker is now organised the way the choice actually divides: **Connect an
account** for providers you sign in to, **Paste an API key** for providers you
hand a credential. A provider offering both lets you switch between them.

### Fixed — every provider returned HTTP 401 when listing models

- **The models route rejected requests it was supposed to sanitise.** The
  handler's own comment said it strips credential parameters once setup is
  complete; the code rejected the whole request instead. Because the TUI reads
  this route without auth, every provider with a dynamic model catalog answered
  `401` on every set-up machine. This was never specific to ChatGPT — the same
  call failed identically for `anthropic`, `miosa` and `ollama_local`.
- **The same branch could answer with another request's body.** It discarded
  the result of `Plug.Conn.halt/1` and then sent a second response on a conn
  that had already been sent, so concurrent probes could return the *previous*
  request's payload.
- **A keyless provider was treated as a configured one.** Sign-in-only
  providers declare `requires_key: false`, which the picker read as "ready",
  then drilled into a model list for an account nobody had signed into.
  Readiness now comes from the backend's auth state. Keyless is not configured.

### Fixed — a signed-in ChatGPT account silently ran against local Ollama

- **`config/runtime.exs` had no provider-map entry for the account
  providers.** `openai_codex`, `claude_cli`, `copilot_cli` and `bedrock` were
  all absent, and the lookup fell back to `:ollama`. So you could sign in,
  select `gpt-5.2-codex`, restart OSA, and have it ask your local Ollama daemon
  for a model that daemon has never heard of.

### Fixed — reasoning effort did nothing on the Codex transport

- **Only three literal values were accepted.** `low|medium|high` passed;
  `:fast`, `:xhigh` and `:ultra` were dropped silently. Nothing on the turn
  path passed the option through in the first place.
- **Every GPT-5.x model was classified as non-reasoning.** The fallback check
  matched o-series prefixes only, despite a comment claiming GPT-5.x was
  covered — so models whose ids begin with `gpt` answered `false` and were sent
  `temperature` instead of `reasoning_effort`.

### Added — sign in from the TUI

- **`PickerMode::AccountLogin`** renders the verification URL and the device
  code on their own lines, with a live spinner, the provider's anti-phishing
  warning, and Esc-to-cancel that works even before a session id exists.
- **`Auth.LoginBroker`** runs sign-in out of band so the interface never
  blocks: start returns in milliseconds, status polls, cancel goes through the
  existing cooperative cancellation flag. One in-flight sign-in per provider.
  It publishes the user code and URL only — never a token.
- **`OpenAICodex.login/1` gained an `on_verification` callback.** The device
  code was previously recoverable only by scraping it out of console text,
  which is why sign-in worked from `osa setup` and from nowhere else.
- **`/login` opens the provider surface**, `/logout` shares one implementation
  with the CLI, and **`/provider`** now exists.
- **A second, hardcoded capability list was removed.** The Rust picker decided
  auth methods with a `match` on provider id defaulting to "paste a key",
  disagreeing with the backend. Auth methods now derive from `auth_modes`.

### Added — AWS Bedrock

- Sign in with the AWS credentials you already have: environment, or
  `~/.aws/credentials` with `AWS_PROFILE`. A bearer token
  (`AWS_BEARER_TOKEN_BEDROCK`) is the second mode on the same entry.
- **SigV4 is implemented on `:crypto` with no new dependency, and verified
  byte-for-byte against AWS's published `get-vanilla` test vector.**
- **OSA stores no AWS secret.** The marker holds the source, region, pinned
  base URL and the last four characters of the (non-secret) key id;
  credentials are re-read per request, so revoking them ends OSA's access.
- Every credential source is named when resolution fails, including the case
  where a profile uses SSO, `credential_process` or `role_arn` — which OSA
  does not implement — with the command that exports usable credentials.
  A missing region is a hard failure, never a guessed `us-east-1`.
- Uses Bedrock's `Converse` API rather than per-family `invoke` bodies, so one
  request shape covers every model family. Streaming is deliberately not yet
  implemented and falls back to sync.

### Added — Ollama Cloud as an account

- **Selecting Ollama Cloud without a key used to write an unusable config.**
  It set the base URL to `https://ollama.com` with no credential, which fails
  authentication on the first turn. Account mode now resolves to the local
  daemon, so leaving the key blank works.
- The model list comes from the signed-in daemon rather than the shipped
  catalog, because the daemon knows what your account can actually reach.
- OSA reads no private key and signs nothing itself; the daemon remains the
  holder of that credential. `osa` forgetting the account leaves
  `ollama signout` untouched.

### Known gaps in this release

- **No call has been made to a live provider endpoint from this build.** The
  flows, credential shapes and request bodies are verified against stubs and
  recorded fixtures. A completed turn against a real signed-in account is not
  among the evidence.
- **Stacked chrome after a terminal resize is not fixed.** A regression test
  reproducing the reported shape was added and it passes, because the test
  harness does not reflow on resize while real terminals do. Unreproduced,
  not repaired.
- **`claude_cli` still requires Claude Code to be installed and signed in
  beforehand.** Driving that login from inside OSA needs a PTY-backed
  subprocess pane and is not built yet.
- Reversibility — signing out and back in, switching a provider between key
  and account — is not yet exercised end to end.

---

## [1.0.66] — displays as `v1.0.066`

### Fixed — two machines can release without colliding

- The release path would happily mint a version another machine had already
  published. It now refuses, rather than discovering the collision after the
  tag exists.

---

## [1.0.65] — displays as `v1.0.065`

### Added — pick which inherited MCP servers OSA actually runs

- OSA discovers MCP servers configured in other tools, but the switch
  governing them was one boolean over every server in every other tool's
  config. On a real machine that is several config files and around twenty
  servers, so picking the two you want meant enumerating the eighteen you did
  not — and re-editing that list whenever another tool gained a server.
- Adds `mcp_import_only`, an allow list read from the same places as the deny
  list. Empty means no restriction, so existing setups are unchanged. A
  non-empty list means only those names import. The deny list still wins,
  because excluding a server is an explicit decision an allow must not
  override.
- The discovery menu deliberately does **not** apply the allow list: it is the
  list you choose from, and filtering it by the choice already made would hide
  every server you had not yet picked.

---

## [1.0.64] — displays as `v1.0.064`

Typing a message that began with the letter `y` lost that letter. So did a
message beginning with `?`. The cause was a pair of undocumented shortcuts —
bare `y` copied the last message, bare `?` opened help — each guarded on "the
composer is empty", which is exactly the state you are in when you start
typing. Only the first character of a message was ever affected, which made it
read as the terminal dropping input rather than as anything OSA did. Both are
fixed, and fixed as a class: printable text now reaches the composer ahead of
every shortcut, so no future binding can take a character out of what you type.

### Fixed — the first letter of a message no longer disappears

- **Printable keys are routed to the composer first.** A key with a printable
  character and no modifier beyond Shift now goes to the composer *before* the
  keybinding map and before every hardcoded shortcut arm. Previously each
  shortcut decided for itself whether to yield, and two of them decided wrong.
  The rule replaces the judgement: an empty composer is no longer a licence for
  anything to claim a typed character.

- **Chord continuations still work.** Only a bare keystroke is treated as text.
  `ctrl+x y` still completes as a chord, because the non-text prefix has
  already established that you meant a command and not a letter.

- **`keybindings.json` now rejects a binding that starts with a plain
  character.** Such a binding could never fire under the new router, so it is
  refused with an explanation — add ctrl/alt, or use a function key — rather
  than accepted and silently ignored.

- **Confirmations are unaffected.** A permission prompt that is on screen and
  waiting for an answer is a distinct state, and its `y`/`n` quick keys consume
  those keys and confirm exactly as before.

### Changed — two shortcuts moved

- **Copy last message is now `F2`, not `y`.** It remains rebindable as
  `chat:copyLast`.

- **`?` no longer opens help from an empty composer.** Help is on `F1` and
  `/help`; `?` now always types a question mark.

- **A wrong line was removed from the in-app shortcut list.** It advertised
  `j`/`k` as scroll keys on an empty input. They never scrolled — they fell
  through to the composer and typed — so the help text described behaviour that
  did not exist.

### Tests

- A sweep over **every printable ASCII character**, unmodified and
  Shift-modified, asserts each one is classified as text and reaches the input
  buffer. Spot-checking `y` and `?` would have left the next letter someone
  binds; the sweep is what keeps this from recurring on a different key.
- Companion tests hold the boundary from the other side: modified characters
  and non-`Char` keys stay shortcuts, terminals that deliver Enter or Tab as
  `Char` are still routed as control keys, no shipped default binding starts
  with a typable character, and a displayed permission prompt still confirms on
  `y` and declines on `n`.

---

## [1.0.63] — displays as `v1.0.063`

You can now run OSA on a ChatGPT Plus/Pro plan instead of an API key: pick the
provider, choose "connect account", approve in the browser, done. Provider setup
grew a general notion of *how* you want to connect, so a provider that offers
both a sign-in and a key asks once and every setup surface asks it the same way.
Two live security issues are fixed — an Anthropic sign-in OSA should never have
shipped, and two secrets that were readable out of `ps` by any local user. And
the in-app `/setup` provider picker, broken in v1.0.62, works again.

### Added — sign in with your ChatGPT plan

- **`ChatGPT (Codex)` is a new provider entry.** Choose it in `osa setup`, in
  `mix osa.setup.wizard` or in the TUI picker, choose "Sign in with ChatGPT",
  approve in the browser, and the credential is stored and refreshed for you.
  Inference bills against your existing subscription rather than per-token API
  credit.

- **It is a separate provider, not a second auth mode on `openai`.** The two
  differ in more than the credential: a different base URL, a different wire
  protocol, and a Codex-only model list. Same reasoning as the existing
  `ollama_local` / `ollama_cloud` split. The `openai` provider and
  `openai_compat.ex` are byte-for-byte untouched — an OpenAI API key still
  belongs on the `openai` entry, and still behaves exactly as it did.

- **A new Responses-API transport** (`providers/openai_responses.ex`) sits
  alongside the existing chat/completions one rather than replacing it. The two
  protocols disagree on request shape, streaming events and usage keys; a
  working path quietly reshaped by a change aimed at something else is the
  failure mode this project has been bitten by most often.

- **Sign-in runs over the OAuth device flow** (`auth/device_flow.ex`,
  `auth/providers/openai_codex.ex`), with tokens in a 0600 credential store
  separate from your keys, refreshed on use and never written to argv or logs.
  A signed-in provider is badged as configured in the picker exactly like a
  provider with a key in the environment.

- **On the borrowed client id, plainly:** OpenAI publishes no registration path
  for third-party clients here, so this uses the Codex CLI's client id, as every
  other tool offering ChatGPT-plan sign-in does. That is tolerated, not
  licensed, and OpenAI can invalidate it at any time. Unlike the Anthropic flow
  removed in this same release, it is not a documented terms violation and is
  not blocked server-side — that distinction is the whole reason one was deleted
  and this one exists. OSA also sends `osa` as its originator rather than
  claiming to be the Codex CLI.

### Added — provider setup asks how you want to connect

- **`auth_modes` on each provider entry is the single source of truth.** One
  shared fork now drives `osa setup`, `mix osa.setup.wizard` and the TUI picker,
  computed by pure functions (`Onboarding.auth_options/1`, `auth_route_for/2`)
  that all three call. The alternative — one "which providers support sign-in"
  list per surface — is how the tool this was modelled on ended up with three
  lists that disagreed with each other.

- **All 27 existing providers are unchanged.** A provider that declares nothing
  defaults to `[:api_key]` and gets `[]` options back, meaning *do not prompt at
  all*: no extra question, no extra keystroke, identical to before the field
  existed. Verified against a fixture of the pre-change catalog output
  (`test/support/fixtures/providers_list_baseline.exs`), so a future provider
  cannot silently acquire a sign-in prompt it has no implementation for.

- **A failed sign-in never silently switches your billing model.** If sign-in
  fails you are told exactly what happened and, when the provider also takes a
  key, offered that route explicitly. There is no automatic fallback.

### Security — the Anthropic subscription sign-in has been removed

- **OSA shipped an OAuth flow it had no right to ship.** It authenticated
  against `console.anthropic.com` using **Claude Code's first-party client id**
  and sent the subscription request fingerprint. Anthropic's Consumer Terms
  permit automated access only via an Anthropic API key, so the agreement being
  breached was the *user's*, and the account carrying the risk was the user's.
  Anthropic has also blocked it server-side since 2026-01-09, and the token
  endpoint it pointed at now 404s. It has been removed entirely — from
  `osa setup`, `/setup`, `/login`, `/logout`, the HTTP onboarding routes, the
  TUI picker, the desktop onboarding and the Anthropic provider's header
  builder.

- **Stored tokens are deleted on upgrade, with an explanation.** A stale bearer
  credential for a banned, blocked, 404ing flow is worth nothing and is not
  something to leave sitting in a home directory, so `~/.osa/oauth.json` is
  purged at boot and by `osa doctor`. Anyone who was signed in this way gets a
  message naming the API-key replacement rather than an unexplained wall, from
  `osa doctor`, from `/login`, and from the provider's own "no key" error.

- **Anthropic API-key auth is untouched** and is the supported path. The four
  removed HTTP routes answer `410 Gone` with that explanation instead of being
  deleted, so an older desktop or TUI build still calling them says something
  useful rather than 404ing.

- **A duplicate-header bug went with it.** The removed OAuth clause emitted its
  own `anthropic-beta` header, so any request with another beta active carried
  two of them. Betas are now collected in one place and emitted as a single
  comma-joined header, by construction.

### Security — two secrets were readable from `ps`

- **`/proc/<pid>/cmdline` is world-readable on Linux**, and `ps` shows the full
  argument vector to every local user on the machine. Two call sites put a live
  credential there.

- **The Ollama Cloud bearer token, on every single request.** It was passed as
  `-H "Authorization: Bearer <token>"` in curl's argv. It now goes in a 0600
  curl config file passed by path; argv carries nothing sensitive. Both temp
  files are created 0600 *before* anything is written, closing the window in
  which the default umask exposed their contents.

- **The GitHub Actions runner registration token.** It was passed as
  `--token <token>` to `config.sh`. It now travels in
  `ACTIONS_RUNNER_INPUT_TOKEN` — the runner's own documented mechanism, masked
  in its logs and unset after it is read — and a process's environment block is
  owner-readable only.

- **Tree-wide scanners were added so this cannot recur**
  (`test/optimal_system_agent/security/no_secrets_in_argv_test.exs`). They
  assert on the *constructed command*, not on whether the request succeeds: a
  request that works while leaking the token is exactly the bug.

### Fixed — the in-app `/setup` provider picker was broken

- **It was handed `nil` instead of the provider catalog.** `cli/setup.ex` read
  `@providers`, an undefined module attribute that evaluates to `nil` rather
  than failing, so the first step of `/setup` had nothing to list. It now calls
  `providers()`, and a regression test pins the picker's input to the real
  catalog.

---

## [1.0.62] — displays as `v1.0.062`

A community release: three outside contributors found and fixed real bugs. A
fresh install of a prebuilt release now boots against your own home directory
instead of the machine that built it, a session that hit a context compaction
stops failing on every provider forever after, and slash commands work again
over HTTP and in the TUI.

### Fixed — a prebuilt install pointed at the build machine's home

- **Every `~/.osa` path except `config_dir` was frozen at build time.** Found
  and fixed by [@scottlibrando2020](https://github.com/scottlibrando2020) in
  [#99](https://github.com/Miosa-osa/OSA/pull/99). `config/config.exs` derives
  `skills_dir`, `episodic_dir`, `mcp_config_path`, `bootstrap_dir`, `data_dir`,
  `sessions_dir` and the SQLite database path from `Path.expand("~/.osa/...")`,
  which is evaluated during `mix release` on the build host.
  `config/runtime.exs` re-resolved only `config_dir`, so the other seven kept
  the CI runner's home on every install: Exqlite failed to open the database
  with `enoent`, the backend crash-looped before it could persist anything from
  onboarding, and `osa doctor` reported seeded workspace files as missing
  because it was looking in the wrong place. All of them are now derived from
  the same runtime-resolved `config_dir`.

- **The same bug had the test suite writing into your real `~/.osa`.** With
  `config_dir` pointed at a per-run tmp home but `sessions_dir` still frozen to
  `~/.osa/sessions`, every run wrote real session ledgers, briefs and plans into
  the operator's actual home — thousands of files on a developer box. Because
  those files are keyed by an integer unique only within one VM, a later run
  could collide with a leftover ledger and read back a goal it never set, which
  is a genuine cross-run flake source rather than only a tidiness problem.

### Fixed — one context compaction could break a session permanently

- **Compaction wrote a string where every provider requires an object.** Found
  and fixed by [@700steven-png](https://github.com/700steven-png) in
  [#100](https://github.com/Miosa-osa/OSA/pull/100). The compactor stripped
  heavy tool-call arguments by replacing the arguments map with the literal
  string `[args stripped]`. Compacted history is persisted, so the damage was
  permanent and provider-independent: Anthropic answered
  `tool_use.input: Input should be an object`, Ollama answered
  `Value looks like object, but can't find closing '}' symbol`, and because the
  primary provider failed and then every provider in the fallback chain failed
  on the same message, the only error shown was the last hop's — an Ollama parse
  error on a session configured for Anthropic, which switching models could not
  clear.

- **Fixed at the source and at the boundary.** The compactor now writes an empty
  object, and the provider boundary coerces a non-object `arguments` on the way
  out, so sessions already carrying the placeholder on disk heal when they are
  next loaded rather than staying bricked.

- **A fallback hop no longer asks the wrong provider for the wrong model.**
  `opts[:model]` is resolved for the provider the turn started on; forwarding it
  across a hop asked Ollama for `claude-sonnet-5`, so the hop failed for a
  reason unrelated to the original fault — and that impostor was the error
  reported. The model is now dropped on every cross-provider hop while the head
  of the chain keeps it.

- **Ollama no longer crashes on a resumed session's tool calls.** Its message
  formatter used struct-style dot access, which raises `KeyError` on the
  string-keyed tool calls that come back from a persisted session, killing the
  turn before any HTTP request was made.

- **The streaming fallback chain now honours the same non-transient policy as
  the sync path.** An invalid request, bad request shape, auth failure or
  model-not-found is not provider-specific, so re-sending it only produces a
  second, unrelated error from the next provider.

### Fixed — slash commands 500'd over HTTP and in the TUI

- **Every slash command over HTTP crashed.** Found and fixed by
  [@PAMF2](https://github.com/PAMF2) in
  [#98](https://github.com/Miosa-osa/OSA/pull/98). `StringIO.close/1` returns
  `{:ok, {input, output}}`, and the command handler destructured it as
  `{_, captured}`. That matches — `_` binds `:ok` and `captured` binds the inner
  tuple — so nothing failed at the match; it failed one line later in
  `String.replace/4`, which sits outside the surrounding `try/rescue` and so
  escaped as a 500 rather than being converted to an error message. The TUI
  posts every command it does not handle locally to this endpoint.

- **Reattaching to a folder left the session without a live loop.** Also from
  [@PAMF2](https://github.com/PAMF2) in
  [#98](https://github.com/Miosa-osa/OSA/pull/98). A directory-scoped resume
  returned the saved session as `resumed` without starting its loop. Messages
  self-healed, but every route gated on a live loop did not: `GET /:id/context`
  and `POST /:id/steer` both 404'd, so the TUI's context meter died the moment
  it reconnected to its own working directory. The resume path now starts the
  loop, and reports a failure to do so instead of answering `resumed` anyway.

### Fixed — the port preflight's own regression test could never pass

- **The `TIME_WAIT` test from v1.0.60 asserted something the kernel never
  promised.** Linux only lets a bind step over a `TIME_WAIT` when `SO_REUSEADDR`
  is set on both the socket binding now and the socket that left the `TIME_WAIT`
  behind. The fixture created its listener without it, so it failed regardless
  of whether `Port.available?/1` was correct. It now mirrors ThousandIsland,
  which hard-defaults `reuseaddr: true` — the actual production condition — and
  the assertion discriminates: it passes with the fix and fails without it.

---

## [1.0.61] — displays as `v1.0.061`

Auto-extracted memories stopped inventing preferences you never stated.

### Fixed — memory auto-extraction was tuned the wrong way round

- **A false positive is permanent; a false negative costs nothing.** Extracted
  memories are injected into every later turn's context, and the agent can
  always call `memory_save` explicitly, so the extractor is now biased to
  precision. In [#102](https://github.com/Miosa-osa/OSA/pull/102).

- **Machine-authored text is no longer stored as a user preference.** The turn
  pipeline also runs for subagent sessions, where the "user message" is a task
  brief OSA wrote itself; those were being recorded as things you said about
  yourself. Patterns now require explicit standing-preference phrasing — bare
  "I am", "I need", "I want" and "actually" match ordinary task requests far
  more often than durable facts — and only the matching sentence is stored,
  bounded to 12–300 characters, never the whole message.

---

## [1.0.60] — displays as `v1.0.060`

`osa update` can restart the backend again. Two bugs kept a successful rebuild
from ever going live.

### Fixed — a successful update reported that it could not start

- **The stop path killed the launcher and left the BEAM holding the port.** In
  [#101](https://github.com/Miosa-osa/OSA/pull/101). `stop_daemon` signalled the
  pidfile PID's process group, but `mix` can re-exec `beam.smp` into a group of
  its own: the launcher died, the group kill found nothing left to reap, and the
  BEAM kept the listener on `:9089`. The update then correctly refused to claim
  it was live, and the user was told to run `osa stop` by hand — after seeing
  "Backend stopped" immediately above. The port, not the PID, is the contract,
  so the stop path now reclaims it by ownership and waits on the LISTEN socket
  rather than on `/health`.

- **The boot preflight then rejected the restart anyway.** `Port.available?/1`
  probed without `SO_REUSEADDR` while ThousandIsland hard-defaults it to `true`,
  so a `TIME_WAIT` left by a closed connection counted as an occupied port for
  roughly 30 seconds after every restart.

---

## [1.0.59] — displays as `v1.0.059`

An idle OSA now costs essentially nothing. Leaving the daemon running no longer
shows up as a busy core on your machine — it sits at a tenth of a percent of one
CPU instead of pinning several, with no change to how fast it answers.

### Fixed — an idle daemon was burning CPU on every platform

- **A daemon that was doing nothing still ran hot.** Reported by
  [@jmanhype](https://github.com/jmanhype) in
  [#66](https://github.com/Miosa-osa/OSA/issues/66) as 850% CPU on macOS with no
  work in flight. The cause was not OSA's own loops: the BEAM's scheduler
  busy-wait flags were set nowhere in the tree, so every OSA daemon everywhere
  ran on stock OTP defaults, where idle schedulers spin looking for work rather
  than sleeping. On a machine with many cores that is one hot spin loop per
  core, forever, for an agent sitting at a prompt.

- **The flags are now set on every path a real daemon starts from** — the
  release environment script, its Windows equivalent, and the source-tree
  launcher. That last one mattered most and is easy to miss: it never sources
  the release environment at all, and it was the reporter's own reproduction
  path, so a fix applied only to the release would have left the bug exactly
  where it was found. Measured on Linux, idle CPU falls from 0.32% to 0.10%,
  with request latency unchanged within noise.

- **The old behaviour is one environment variable away.** Set
  `OSA_BEAM_BUSY_WAIT=1` to restore spinning schedulers, for the rare workload
  that would rather pay the idle cost to shave scheduler wake-up latency.

### Fixed — the test suite was writing into your real `~/.osa`, and reading it back

- **A goal from one test run could reappear inside a later one.** The suite goes
  to considerable lengths to keep out of the operator's home — the database,
  permissions, the durable log and the bootstrap directory are all redirected to
  temporary paths — but the runtime configuration re-pointed the config directory
  at the real `~/.osa` after all of that had been decided, silently undoing it.
  Session ledgers, briefs and plans were being written into the operator's own
  session directory on every run, thousands of them; and because those files are
  keyed by an identifier that is only unique *within* one VM, a later run could
  draw an identifier that already had a file on disk and read back a goal it had
  never set. That is what made the goal-verifier's "no goal anywhere" gate fail
  in a full run and pass on its own. **The suite now gets its own per-run home
  under the temporary directory**, wiped at load and swept for stale runs, using
  the same scheme the per-run test database already used. Nothing about how OSA
  resolves its home outside of tests changes.

- **Six test files hardcoded `~/.osa` themselves**, as compile-time paths — the
  exact "frozen home" pattern OSA has a dedicated regression test to forbid in
  its own modules. They now resolve the directory at runtime like everything
  else, so they assert against the suite's home rather than the operator's.

- **Cross-turn goal state no longer lives on a borrowed process.** The table
  holding each session's goal status, lifetime run cap and stall breaker was
  created lazily by whichever process anchored a goal first — usually a
  transient one. When that process exited the table went with it, and an
  autonomous run lost its circuit breaker without anything failing loudly. It is
  now created at startup, owned by the application, alongside the other shared
  tables that were moved there for the same reason.

---

## [1.0.58] — displays as `v1.0.058`

OSA's context handling, its tool surface and its record of what a session did
are no longer fixed at compile time: each is now something that can be swapped,
extended or switched on. Nothing here changes what OSA does by default — the two
new capabilities are off until you turn them on. Alongside that, the interface
gains a test lane that drives the real binary on a real terminal, the last
hand-written layout measurements are gone, and a turn that dies no longer takes
its spend with it.

> **This release supersedes `v1.1.000` and `v1.1.001`, which have been
> withdrawn.** Those two were published briefly and carried exactly the content
> below under an incorrect version number; the minor bump was a mistake, and
> OSA's numbering continues on the `1.0.x` line. If you installed OSA in that
> window you are running this same code under a version string that no longer
> exists — reinstall, or pin `OSA_VERSION=v1.0.058`, so that update checks and
> bug reports line up with a release that is actually published.

### Added — the context engine is now a contract, not a single hardcoded implementation

- **Everything that manages the conversation window now goes through one
  interface.** Compaction — deciding when a session has grown too large, what to
  summarize, and what to keep verbatim — was reachable only as one concrete
  module, called directly from seven places. It is now expressed as a behaviour
  with a router in front of it, resolved from application config or
  `config.toml`, so an alternative strategy can be supplied without touching the
  call sites. The existing compactor is unchanged in behaviour and remains the
  default; a no-op engine ships alongside it as a reference implementation.

- **The contract states the units it actually uses.** While wiring this up, the
  declared interface was found to disagree with the code on both sides of it:
  utilization was documented as a fraction while every implementation and every
  reader treated it as a percentage, and the summary formatter was declared to
  return a message list while both implementations returned a string. An engine
  written against the old description would have read a full session as roughly
  one percent full and never compacted. The declaration now matches reality, and
  a router that could not resolve a model's real context window no longer falls
  back to a fabricated one — it reports that the figure is unknown rather than a
  confident wrong number.

### Added — plugins, off by default and verified before anything is loaded

- **OSA can discover and load tools and context engines from
  `~/.osa/plugins/`.** This is **opt-in and disabled by default**: it must be
  enabled explicitly through application config, `[plugins]` in
  `~/.osa/config.toml`, or the user-level `settings.json`. When it is off, no
  directory is created and nothing is read.

- **A project cannot switch it on for you.** The opt-in is read from the *user*
  settings layer only, never the merged cascade — a repository that shipped both
  the flag and a plugin file would otherwise have gained code execution the
  moment you changed directory into it. Workspace-supplied settings cannot
  enable plugin loading at any trust level.

- **Files are verified before they are compiled.** The plugin directory must
  exist, be a directory, be owned by you, and not be writable by anyone else;
  files must be regular, owned by you, and within a size limit; symlinks are
  resolved and refused when they point outside the directory. Every refusal is
  logged with the file and the reason, and the ownership check fails closed when
  it cannot determine the answer.

- **A plugin cannot impersonate a built-in or grant itself privileges.** A
  plugin tool whose name collides with a registered tool is refused rather than
  replacing it, built-in engine ids cannot be claimed, and plugin-contributed
  tools are tracked by provenance and forced onto the approval path regardless
  of the safety level they declare for themselves. A plugin that fails to
  register now costs only itself: registration failures are contained, including
  the timeout case, which previously escaped and would have taken the boot down
  with it.

### Added — trajectory recording, off by default and redacted

- **Each LLM round-trip in a session can be recorded to
  `~/.osa/trajectories/`** — tokens, cost, tool calls and results — for replaying
  or auditing what a session actually did. Like plugins, it is **opt-in and off
  by default**, with a retention window that prunes old files at boot.

- **Credentials are stripped before anything is written.** Tool arguments, tool
  results and assistant responses pass through redaction — provider keys, GitHub
  and Slack tokens, AWS key ids, JWTs, `Bearer`/`Basic` headers and
  credential-shaped assignments — and redaction runs before truncation, so a
  secret cannot survive by being cut in half.

### Added — a layout suite that drives the real binary on a real terminal

- **The worst bug of the last release passed a thousand tests.** A terminal
  resize left one stranded copy of the interface behind at every step of a drag,
  and the existing suite structurally could not see it: it renders through a
  perfect in-process emulator that answers the cursor query from its own model,
  so the re-anchor always lands on the right row and the failure cannot
  materialise. Tests were not missing. The class was unreachable.

- **`test/pty/` closes that from the outside.** It gives the built `osagent` a
  real kernel PTY, resizes it for real — the same signal a window drag delivers —
  renders the resulting byte stream through an independent emulator, and asserts
  that exactly one composer, one hint row and one status bar survive. Three
  cases ship: a width drag, a height drag, and a viewport squeezed to eight rows
  where the composer must still be there. It runs in CI as the `PTY layout`
  workflow, on a plain runner — a PTY is not a GUI, so no display server is
  needed.

- **It was verified by putting the bug back.** Reintroducing the defect turns
  the suite red with several stacked composers, which is what a test that cannot
  fail is missing.

- **What a green run does not prove.** The emulator the harness renders through
  does not re-wrap existing lines when the terminal narrows; GNOME Terminal and
  the other libvte-backed terminals do. So this reproduces the re-anchor half of
  the problem — the half that produced the stacked copies — and under-reproduces
  the reflow half. Concretely, the deliberate choice of clear sequence at the
  resize site, which exists because one of them pushes a snapshot of the live
  region into unreflowable scrollback on a real terminal, would not turn this
  suite red if it were reverted. Changes touching reflow, scrollback or clear
  semantics still want a human looking at a real terminal. The limitation is
  written down in `test/pty/README.md` rather than left to be discovered.

### Changed — one arbiter measures the layout, and the tests can no longer disagree with it

- **The last hand-written band-height helpers are gone.** Four of them survived
  the previous release as test-only functions, each re-stating in a second place
  how tall one band should be. A test that mirrors an expression production has
  stopped using does not check production — it checks the mirror, and passes
  while the screen is wrong. Every measurement now goes through the single
  arbiter the running program uses.

- **The small-height assertions came out stronger, not weaker.** Where the
  mirror sized a band against the rows it *asked* for, it now sizes against the
  rows the arbiter *granted*. On a short viewport those differ, and sizing
  against the request is exactly how a band ends up drawing into rows nothing
  reserved for it.

### Fixed — recording that was supposed to be off was always on

- **The trajectory opt-in never guarded anything.** The check was written as an
  expression whose result was evaluated and then discarded, so the write ran
  unconditionally: trajectory recording was **always on for every user**, despite
  being documented and configured as disabled by default. Since each entry
  carries the assistant response along with raw tool arguments and results, every
  session was appending unredacted conversation content to disk with no way to
  turn it off. The guard is now a real branch, and the content it writes is
  redacted.

### Fixed — every turn was recorded as having cost nothing

- **The transcript recorded zero tokens for all of them.** Per-turn token counts
  are now written as the turn completes, cached tokens included — without those,
  a large turn was recorded as a small one and the figure *fell* as the cache
  warmed, which is exactly backwards. Plan-mode turns, which are often the most
  expensive in a session, recorded nothing at all and are now counted like any
  other. This is groundwork: the figures are recorded, but nothing reads them
  yet, so `/cost` and `/status` are unchanged for now.

### Fixed — a reconnect announced a coordinator change that never happened

- **Losing and regaining the connection raised a notification about a switch
  that had not occurred.** The reconnect path re-announced the coordinator mode
  unconditionally rather than only when it had actually changed. Because an
  identical notification refreshes its dwell instead of stacking, a flapping
  connection could hold a phantom notification on screen indefinitely, and each
  one rebuilt the viewport twice. The announcement is now made only on a real
  change.

### Fixed — a turn that crashed took its spend with it

- **Tokens that had been paid for vanished from the accounting.** When a turn
  errored partway through, the error path returned the state from before the
  turn began — every intermediate state having been carried off by the unwind —
  so a turn that completed three billed round-trips and then failed on the
  fourth was recorded as having cost nothing. The transcript wrote a zero, the
  live spend readout never moved, and the session budget cap went on believing
  the money was still there.

- **The accounting now survives the crash.** Each round-trip's absolute totals
  are surrendered outside the state thread and merged back if the turn dies, so
  the spend that happened is the spend that gets reported. Absolute figures, not
  increments, so a repeated merge cannot double-bill; and the stash is cleared at
  the top of every turn so a turn that fails before spending anything cannot
  inherit the previous one's numbers.

- **Deliberately not recovered: the conversation.** Only the accounting is
  merged back. A message list interrupted mid-cycle can be structurally invalid
  — an assistant tool call with no matching result — and restoring it would
  poison the next request to the provider. Recovering history is a separate and
  larger problem; recovering the money is not, and the money is what was
  silently wrong.

---

## [1.0.57] — displays as `v1.0.057`

### Fixed — resizing the terminal left a stranded copy of the interface behind at every step

- **A single drag could leave nine stacked composers on screen.** Widening the
  window by nine columns left nine copies of the live region, each one column wider
  than the one above it, all of them stale and none of them reflowing. Two separate
  causes, both fixed. First, OSA only learned that the terminal had changed size
  when the resize *event* arrived — but the kernel had already changed the size, and
  every frame drawn in that gap was reconciled behind OSA's back by ratatui, which
  re-anchors the live region and clears only the *new* rectangle, leaving the old
  one painted on the screen. **OSA now takes the size directly from the kernel at
  the top of every frame**, so it is always the first to know rather than the last.

- **A drag now settles before anything is drawn or committed.** Dragging a window
  edge emits a size for every intermediate width, and OSA was rebuilding — and
  committing finished output — at each one, at widths that had already ceased to
  exist by the time the ink landed. The intermediate sizes are now absorbed and only
  the size the drag comes to rest at is drawn.

### Fixed — the interface now fits any terminal

- **Regions could overlap, overdraw, and disagree about their own size.** Each of
  the ten regions of the live area claimed its rows independently, with nothing
  deciding what actually fit in the space available; in a short or narrow terminal
  that produced a checklist painted on top of the reply, a roster reserving thirty
  rows and drawing thirty-four, and a dropdown painting into rows nothing had set
  aside. **All ten regions are now measured by a single arbiter** that grants rows
  and, when space runs out, sheds the least important surfaces in a fixed order —
  never the composer, which is always kept.

- **Heights are measured once and the rectangles derived from them**, so a region's
  reservation and its paint cannot drift apart. The property is enforced by tests
  rather than by discipline: the bands are swept across a range of widths, heights
  and content states and asserted to tile the region exactly — no row shared, no row
  lost — and a check over the source tree fails the build if the terminal size is
  read anywhere other than the one place permitted to read it.

### Fixed — the startup banner could name a model OSA was not running

- **The banner reported `anthropic / llama3.2:latest` directly above a status bar
  reading `claude-opus-5`.** Provider and model were resolved from different sources
  at boot, so a provider chosen from the environment could be paired with a model
  persisted in the config file for an entirely different provider. A model saved for
  one provider is no longer stapled onto another; when it does not apply, OSA falls
  back to that provider's own default, so the pair is coherent by construction.

- **The same false pair reached everything else that names the model.** The settings
  dialog, the dashboard, the model picker and the agent's own prompt each rebuilt the
  answer by hand, and each fell back to an Ollama model — down to a hardcoded
  `llama3.2:latest` — regardless of which provider was serving the turn. **Every
  identity surface now reads one resolver**, so what the banner, the status bar, the
  picker and the agent believe about the running model cannot disagree.

---

## [1.0.56] — displays as `v1.0.056`

### Fixed — replies start faster, because the unchanging part of every prompt is finally cached

- **Every request to the Claude models was re-reading the entire prompt from scratch.**
  The large, unchanging preamble OSA sends on every turn — the instructions, your
  project's context, the tool descriptions, tens of thousands of tokens of it — is
  meant to be cached by the provider and skipped on the next turn. None of it ever
  was. The cache hit rate was a flat zero for every request OSA has ever sent, so
  each turn paid the full cost, in time and in tokens, of material that had not
  changed since the previous one. **That prefix is now genuinely cached**, so a reply
  begins sooner and the repeated part of the prompt is no longer billed at full
  price on every turn.

- **The cause was a timestamp buried inside the cached region.** OSA builds the
  prompt as three parts — a static base, a slowly-changing world state, and a
  volatile tail carrying the clock and the turn count — precisely so the first two
  can be cached and the third cannot. Two separate steps on the way to the wire
  undid that: one dropped the cache markers, and the next flattened all three parts
  into a single block, which was then marked as cacheable *as a whole*. Since that
  now-cached block contained a microsecond-resolution timestamp, every request
  differed from the last by a few bytes at exactly the point where a cache lookup
  needs them to be identical, and nothing could ever match. The three parts now stay
  three parts, the volatile tail sits outside every cached region, and the timestamp
  is rounded to the second.

- **Verified on the wire, not inferred.** Two consecutive real requests are captured
  and the cached prefix compared byte for byte: 137,974 bytes, identical, same
  sha256 — with a control assertion that the volatile tail *does* differ between
  them, so the comparison cannot pass by accident.

### Fixed — image attachments and provider fallback no longer fail outside the Claude models

- **Attaching an image crashed every non-Claude provider.** Images are packaged in
  the Claude models' structured format regardless of which provider is actually
  serving the request, and the other five providers accept only plain text; handed a
  structured block, they raised outright. Any turn with an image attached failed on
  OpenAI, Google, Ollama, Cohere and Replicate — not degraded, crashed.

- **Provider fallback was dead in the one situation it exists for.** When Claude
  returns a 5xx, OSA is supposed to retry the request on another provider. It handed
  that provider the already-built message list, which crashed it the same way, and
  each crash was swallowed and reported as the generic "All providers failed" — so
  an outage at one provider took the whole turn down instead of falling through to a
  working one.

- **Content is now translated at the provider boundary.** Structured content is
  flattened losslessly for the providers that need plain text and passed through
  untouched for the ones that do not. A flattened prompt is byte-identical to what
  those providers received before, so nothing about their behaviour changes. An
  image, which has no text equivalent, becomes an explicit note that it was omitted
  — the model is told the image is missing rather than left to invent it.

### Fixed — a rate-limiter test that could fail on timing alone

- **The HTTP rate limiter's test suite raced the wall clock and intermittently
  reddened an otherwise green run.** The limiter refills its budget in proportion to
  elapsed time, which at the default 60-per-minute limit hands back a whole request
  for every whole second that passes. A test that spent 60 requests and then checked
  the 61st was refused would get an extra one for free whenever those 60 requests
  happened to straddle a second tick — likely on a loaded machine — and the request
  that should have been refused sailed through. **The limiter's clock is now
  injectable**, so the tests pin it and step it deliberately rather than depending on
  how fast the machine happens to be. The limiter's behaviour in production is
  unchanged; two new tests cover refill over time explicitly.

---

## [1.0.55] — displays as `v1.0.055`

### Fixed — resizing the terminal left permanent duplicate copies of the screen in scrollback

- **Every resize deposited a full snapshot of the screen into your scroll history.**
  Dragging a window edge through fifteen columns left fifteen stacked copies above
  the session, each one column narrower than the last — most visibly as a cascade of
  a table's horizontal rules, and it is the same mechanism behind the older reports
  of the composer duplicating down the screen. The copies were permanent and did not
  reflow. The cause: the resize path erased the screen with `ESC[2J`, which looks
  identical to an erase — blank screen, cursor home — but on the VTE family (GNOME
  Terminal and every other libvte embedder) is implemented by *scrolling* the screen
  into the scrollback buffer rather than wiping it. **The resize clear now homes the
  cursor and erases forward**, which clears the same ground without touching scroll
  history.

- **`/clear` handed one last screenful back to the history it had just emptied.** It
  purged the scroll history first and only then emitted the same `ESC[2J`, so the
  final visible screen was scrolled straight back into the buffer that was meant to
  be empty. The screen is now erased before the history is purged, so a `/clear`
  leaves nothing scrollable behind it.

- **Regaining focus now forces a repaint.** An outer layer can repaint OSA's pane
  with no terminal resize at all — tmux redrawing a pane, an nvim `:terminal`
  restoring a window, a multiplexer client re-attaching. Only changed cells are
  rewritten, so rows damaged that way stayed damaged until something else happened
  to move them; focus is regained on essentially every path that causes such damage,
  so it is now taken as the cue to repaint the live region. It repaints only that
  region and can never reach the transcript above it.

---

## [1.0.54] — displays as `v1.0.054`

### Fixed — on Google and Replicate, OSA stopped listening to itself mid-turn

- **A course correction OSA gave itself was filed as background reading instead of
  read as an instruction.** OSA steers itself while a turn is running — keep going,
  write the code, run the verification you promised, stop and check before claiming
  done — and each of those nudges is written to be the last thing the model reads.
  On Google and on Replicate, every such nudge was being lifted out of the
  conversation and folded into the system prompt, arriving as standing context from
  before the turn began rather than as a correction to what was just said. The model
  could therefore keep going in a direction it had already been told to abandon,
  finish a turn it had been told to continue, or skip a check it had been told to
  run. **Mid-turn steering now stays where it was put**, at the end of the
  conversation, so it lands as an instruction about what to do next.

- **Nothing reported this, which is why it lasted.** The same defect on the Claude
  models produced a hard error and was fixed in 1.0.50; here both providers accepted
  the malformed request happily and returned a perfectly ordinary answer, so the only
  visible symptom was an agent that seemed not to take direction. Instructions that
  genuinely belong to the system prompt — the ones present before the conversation
  starts — are still sent exactly as they were.

- **Tool calls are untouched.** Google requires the conversation to alternate
  speakers, so keeping a nudge in place can put two turns from the same side next to
  each other; those are now merged rather than dropped. The merge is limited to plain
  text, so a turn carrying a tool call or a tool result is passed through byte for
  byte and the tool round-trip behaves exactly as before.

---

## [1.0.53] — displays as `v1.0.053`

### Changed — you can read a reply while it is still being written

- **A long answer was unreadable until the turn ended.** The whole reply was held in
  a bounded live region at the bottom of the screen, so as soon as it grew past that
  region the beginning scrolled out of it — and tool activity rendering underneath
  pushed what was left further out of view. Nothing was in the terminal's own
  scrollback yet, so scrolling up did not bring it back either. The answer arrived in
  one lump at the end, which is exactly when you no longer need to read it slowly.
  **Finished blocks now land in scrollback as they finish**: a paragraph, a list, a
  code block or a table is committed the moment it is complete, so on a typical reply
  around nine tenths of the text is readable — and scrollable, and selectable — before
  the turn is over.

- **Only the still-unfinished tail stays in the live region.** The block currently
  being written keeps updating in place as before, so you still see text appear as it
  arrives; it is only the part that can no longer change that moves out. A code fence
  that has not closed counts as unfinished and stays in the tail, so a partial block
  is never committed in a state it will not end in.

- **Completion no longer replays the answer.** Because everything already settled was
  subtracted from what the end of a turn commits, finishing reveals only the last
  unfinished block rather than reprinting the message you have been reading all along
  — and when a reply happens to end exactly on a block boundary, it reveals nothing at
  all. Interrupting mid-reply closes the open block cleanly, so the interrupt notice
  reads as its own paragraph instead of running into the text above it.

### Changed — the multi-agent view now reads as a hierarchy

- **Five surfaces competed for attention at the same visual weight.** The roster, the
  tool feed, the plan checklist, their headers and their chrome were all drawn with
  roughly equal emphasis, so nothing on screen told you where to look and the one row
  that was actually live had to be found by reading. **There is now a three-tier
  ladder**: the accent belongs only to what is genuinely happening right now — the
  running tool, the active plan step — arguments, paths and durations sit a tier below
  in a muted tone, and every label, header and separator recedes into the quietest
  tier. Section titles are labels for the block beneath them, and are now styled that
  way rather than as content.

- **Paths are shown relative to your workspace, with shared prefixes elided.** A trail
  of file operations in one directory printed the same long absolute prefix on every
  row, spending most of the width on the part that never changed. The prefix is
  dropped when doing so hides nothing, so what remains is the part that distinguishes
  one row from the next.

- **Four rows of noise are gone without losing any information.** Batch labels that
  restated what the rows below them already said are suppressed, the "+N earlier"
  count is folded into the row it describes instead of occupying a row of its own, and
  the idle `main` entry — which was on screen permanently whether or not it was doing
  anything — is folded into the roster header. On a representative screen this is four
  fewer rows for the same content.

### Changed — the README and docs describe what OSA actually ships

- **The tool and provider lists were wrong in both directions.** The README advertised
  seven tools that are deliberately not registered — calling one could only ever
  produce a runtime error — and listed seven providers when twenty-seven are offered.
  Named OpenAI models that the picker excludes were presented as available. Two
  keyboard bindings were documented incorrectly, and forty-two slash commands were
  missing entirely. All of it now matches the shipped build.

- **Homebrew instructions have been removed rather than version-bumped.** The release
  tarball contains the Elixir backend only — no Rust TUI and no launcher — so a
  Homebrew install cannot attach a terminal interface at all, and a working formula
  was never one version bump away. `Formula/osa.rb` now carries a header comment
  recording why, so the gap is not mistaken for staleness and "fixed" by bumping a
  version.

---

## [1.0.52] — displays as `v1.0.052`

### Fixed — popups and notifications no longer paint over the conversation

- **A notification could cover the top of the reply you were reading.** Toasts were
  drawn on top of the first three rows of the streaming area, so for the four to six
  seconds one was on screen the beginning of the answer underneath it was simply
  gone — and it came back only once the toast expired. **Toasts now occupy a
  reserved region of their own**, above the reply rather than across it, so nothing
  a notification says costs you the text it lands on.

- **The `@`-mention list overwrote the rows above the composer.** Typing `@` drew the
  file and agent matches upward from the input line into rows that belonged to the
  hint line and whatever sat above it, wiping them for as long as the list was open.
  The same was true of the `/` command popup. **Both now sit in a region the layout
  reserves for them**, so opening either one moves the conversation up rather than
  drawing over it, and closing it gives the rows straight back.

- **The mention list now scrolls to follow your selection.** It always drew the first
  five matches while offering up to ten, so pressing ↓ past the fifth highlighted an
  entry that was not on screen — the list looked frozen while the selection kept
  moving invisibly. The visible window now follows the highlight, so the entry you
  are about to accept is always the one you can see.

- **Long paths and names are measured in screen columns.** Every row of these popups
  and of the toasts is now fitted by display width rather than by character count, so
  a mention of a path containing CJK text or an emoji can no longer overrun the width
  it was given and push a row out of shape.

---

## [1.0.51] — displays as `v1.0.051`

### Changed — tables now render as a proper bordered grid

- **A markdown table had no frame and no separation between its rows.** OSA already
  sized each column to its content, wrapped long values inside the cell rather than
  cutting them off, grew a row to the height of its tallest cell, and accented the
  header — everything except the thing that makes a table read as a table. There was
  no top or bottom border at all, and a single rule under the header was the only
  horizontal line in the whole table, so once a row wrapped onto a second line you
  could no longer tell where one row ended and the next began. **Tables are now drawn
  as a closed grid**: a full outer frame, and a rule between every pair of data rows,
  so wrapped cells stay visually bound to the row they belong to.

- **The grid follows your theme instead of picking its own colours.** The frame and
  rules use the theme's neutral border colour, the header its accent, and the
  "there's more" marker its muted tone — nothing is hardcoded, so a table reads
  correctly in every theme and in both light and dark terminals. The `▼` beneath a
  table now appears only when content was genuinely cut short, rather than as
  decoration, and it is centred under the table it belongs to.

- **Narrow terminals are unaffected.** The borders occupy the space between columns
  that was already reserved, so they cost no horizontal room, and the existing
  fallback ladder for widths too small to hold a table is unchanged.

### Fixed — a finished answer now settles cleanly instead of rendering twice

- **The streaming preview was stuck in a small fixed window no matter how tall your
  terminal was.** A reply in progress was shown through a permanent ten-row
  letterbox, so on any normal-sized screen most of the terminal sat empty while the
  answer scrolled past inside a slot a fraction of its size. **The preview now grows
  with the reply**, in steps, up to half the screen, and only ever grows within a
  turn — so it opens up for a long answer without flickering between sizes as the
  text arrives.

- **The working chrome outlived the answer it belonged to.** The spinner, the tool
  feed, the reasoning box and the agent roster all stayed on screen for several ticks
  after the reply had already landed, so the finished answer appeared with the
  machinery of producing it still running underneath — and the roster of active
  agents was never cleared on the normal completion path at all, only when a turn
  ended some other way. **Teardown now happens as the answer lands**: the chrome is
  retired, the viewport shrinks back and the finished reply is committed to
  scrollback together, in one pass, so a completed turn resolves once instead of
  visibly redrawing itself.

---

## [1.0.50] — displays as `v1.0.050`

### Fixed — turns died outright on the Claude 5 models

- **On Opus 5, Sonnet 5 and Fable 5, a turn could stop dead with
  `This model does not support assistant message prefill`.** OSA steers itself
  mid-turn — a short nudge to keep going, to write the code, to run the verification
  it promised — and those nudges are meant to be the last thing the model reads.
  Instead they were being lifted out of the conversation entirely and folded into the
  system prompt, which left the request ending on OSA's own words. The Claude 5 family
  removed the ability to end a request that way, so it was rejected before the model
  ever saw it. The steering was lost AND the turn was lost. **The nudges now stay in
  the conversation where they belong**, so they do the job they were written for, and
  a request can no longer end on the wrong speaker — checked at the last possible
  moment, keeping whatever had already been written rather than discarding it. Models
  that still accept the old shape are sent exactly what they were sent before.

- **The error told you to switch models, which could not possibly have helped.** The
  failure was in the shape of the request OSA built, so every model would have
  rejected it identically — the one suggestion offered was the one thing guaranteed
  not to work. **OSA now recognises a request it built wrong** and says so plainly,
  instead of blaming the model you chose.

### Fixed — "What's new" was empty after updating

- **A source-checkout update printed an empty release-notes section.** It was reading
  a changelog that stops at 0.9.0 and contains no 1.0 releases at all, so there was
  never anything to find. It now reads the changelog releases are actually written to.

---

## [1.0.49] — displays as `v1.0.049`

### Fixed — you no longer have to restart anything after an update

- **OSA kept a backend running from before the update and quietly served you the old
  build.** OSA's backend deliberately outlives the TUI so the next `osa` is instant —
  but that also means a backend started before an update keeps running the OLD code
  from memory while the new code sits on disk. The version you saw was the running
  one, so a successful update looked like it had never shipped, and the advice was to
  go and run `osa stop` first. That is not an instruction anyone should ever be given,
  and "daemon" is not a word anyone should have to learn. **OSA now detects a backend
  older than the build on disk and refreshes it itself, on launch, in one line** — not
  only after `osa update`, since a plain rebuild produces exactly the same skew.
  A backend that is genuinely mid-turn is left alone rather than having its work
  destroyed; it is refreshed once it is idle. If a stale backend refuses to stop, OSA
  now stops with a clear error instead of attaching to the wrong build.

### Fixed — the updater could not apply its own fixes

- **`osa update` fetched a fixed updater and then ran the old one anyway.** The
  updater IS the script being updated, and the shell has already read it into memory
  before the first byte is downloaded — so a run that collected a fix could not use
  it, and you needed a second, entirely separate update before it took effect. This
  was not hypothetical: the previous release pulled both the backend-restart fix and
  the release-notes fix, then skipped the restart and printed `[Unreleased]`, because
  the code doing the work was the pre-fix code. **The update now hands itself over to
  the version it just installed and finishes there**, so a fix applies on the run that
  delivers it. Nothing is downloaded twice, your local changes travel across the
  hand-off untouched, and handing over more than once is refused outright.

### Fixed — installed copies never received launcher updates at all

- **On the standard one-line install, `osa update` replaced the backend and the TUI
  but never the `osa` command itself.** Every improvement to the launcher — including
  all of the above — reached only the people who happened to re-run the installer by
  hand. That is not a delay; it is permanent, and invisible, and it gets worse the
  longer it goes unnoticed. **`osa update` now also updates the launcher**, taking it
  from the release being installed rather than from whatever is newest, so it always
  matches the binaries beside it. It is refused unless it downloads whole, parses as a
  valid script, and is recognisably OSA's, so a half-finished download or an error page
  cannot replace a working command; the previous one is kept and put back if anything
  goes wrong. Same story as above once installed, the new launcher takes over and
  finishes the update itself.
  - Upgrading **from 1.0.48 or earlier still needs the installer run once** — the old
    launcher has no way to replace itself. From this release onward it is automatic.

### Fixed — two tests that could fail for no reason

- Timing-dependent MCP progress and terminal tests now wait on the condition they
  actually care about instead of on the clock, so a slow machine no longer produces a
  failure that says nothing about the code.

---

## [1.0.48] — displays as `v1.0.048`

### Fixed — web page fetching was completely broken

- **Every successful fetch raised internally, and the crash message was handed back
  as the page.** Response headers arrive as a map of lists; the code assumed a
  string. So a fetch that had genuinely succeeded — the page was retrieved, the
  bytes were there — blew up on the way out, and the resulting error text was
  returned in the slot where the page content belongs. The agent then read that
  error message as though it were the documentation it had asked for, and reasoned
  from it. Nothing signalled that anything had gone wrong.
- Along with the crash, the fetch path was missing most of what real sites require:
  - A **browser User-Agent** is now sent; many hosts refuse the default outright.
  - **303 redirects** are followed, and a **relative `Location`** is resolved
    against the request URL instead of being treated as a whole address.
  - **Empty bodies and bot-challenge pages now report failure** rather than being
    passed upward as legitimate content — an interstitial is not the page you asked
    for, and the agent should not be reasoning over one.

### Fixed — `/model` could switch you to the wrong provider entirely

- **`claude-opus-5` resolved through Azure to OpenAI**, which does not serve it, so
  the session 404'd on every single turn after the switch. You asked for one vendor's
  model and were connected to another's endpoint. Provider resolution is now
  deterministic and prefers the vendor that actually owns the model.

### Fixed — context was compacted at roughly 11% of a large window

- **Compaction divided by a hardcoded 128k instead of the model's real context
  window.** On a large-window model that meant compaction fired at around **11% of
  the space actually available**, over and over — and compaction is lossy and
  irreversible, so each premature run permanently discarded conversation fidelity
  that never needed to go. The real window is now used.

### Fixed — prompt blocks were silently evicted on small-context models

- **Plan-mode instructions, tool doctrine and the runtime block were being dropped
  from the prompt with no signal anywhere.** Two faults drove the budget negative:
  the reserve held back for the response **did not scale with the window**, and a
  truncation helper **overshot its target**, cutting further than it was asked to.
  On a small-context model the remaining budget went below zero and essential blocks
  simply fell out — the agent stopped behaving as if it were in plan mode, and
  nothing said why.

### Fixed — asking you a question deadlocked the turn

- The question now renders **inline in the transcript** rather than blocking the
  turn: keyboard selection for the offered choices, **free-text entry** for anything
  else, and **Esc to decline**, which is delivered to the waiting tool immediately so
  the turn continues.

### Fixed — the long-session guard was ending sessions early

- **The guard read successful edits as failures and distinct edits as repetition.**
  It keyed on the **first 100 characters of a tool result**, which are identical for
  every edit to the same file, so a run of different successful edits looked like one
  action repeated; and it then judged those successes as *failures*. Both halves of
  its verdict were wrong at once, and it ended sessions that were going fine.

### Fixed — session saves were dropped, and tool work was discarded

- **Session saves were silently dropped while the agent was busy.** The save was
  simply skipped, with no error and no retry, so work performed during a busy stretch
  never reached disk.
- **A dropped model connection discarded tool work that had already executed.** Tools
  that ran to completion — with real side effects — had their results thrown away
  because the connection carrying the turn went down afterwards.

### Fixed — worktrees silently omitted submodule and nested-repo contents

- A worktree created for isolated work came up **missing the contents of submodules
  and nested repositories**, so the agent operated on an incomplete tree while
  believing it had the whole project.

### Security

- **A checked-in project settings file could grant itself permissions before any
  trust prompt.** A repository could ship a settings file that took effect on the way
  in — before you were ever asked whether you trusted that workspace.
- **"Allow always" could persist a rule that disabled the command classifier
  entirely.** A single approval could be stored in a form broad enough to switch off
  the classification of subsequent commands, well past the scope of what was approved.
- **The permission "ask" tier was dead code**, so a decision path that was meant to
  stop and ask never did.
- **A refusal could be retried through a different tool.** Denying an action in one
  tool did not prevent the same action being carried out via another route.

### Added

- **Session resume.** `osa resume <id>` picks a previous session back up, and the id
  is printed on exit so it is available when you need it.
- **`--model` and `--provider` flags** for selecting both from the command line.
- **`/map`**, which renders the structure of a monorepo — including submodules and
  nested repositories — rather than stopping at the top-level tree.

### Changed — providers

- **Added:** the Claude 5 family (**Opus 5, Sonnet 5, Fable 5, Haiku 4.5**),
  **GPT-5.6**, **kimi-k3** and **gemma4**.
- **Retired model ids removed** across Google, Groq, Cohere, DeepSeek, xAI, Mistral,
  Replicate, Cerebras and Fireworks, so the catalog no longer offers models that no
  longer answer.
- **Gemini thinking configuration and tool round-trip both fixed** — each was broken,
  so thinking settings did not apply and tool calls did not complete their loop.
- **Onboarding validates keys against each provider's own API**, so a key that will
  not work is caught while you are setting it up rather than at first use.

### Changed — resource growth and timestamps

- **Unbounded memory and disk growth is now bounded** across transcripts, embeddings,
  background task files and several ETS tables, each of which previously grew without
  limit for the life of the process or the install.
- **Timestamps render in local time** instead of leaving you to convert.

---

## [1.0.47] — displays as `v1.0.047`

### Fixed — asking you a question deadlocked the turn

- **The agent could not ask you anything.** The ask-user event was missing from the
  event-forwarder's allowlist, so a question raised by the agent never reached the
  TUI at all. The TUI already contained a complete survey dialog — it was simply
  unreachable, with no path by which it could ever be shown. Every ask therefore
  blocked for the tool's full **five-minute timeout** and then failed, which read as
  the agent hanging mid-turn for no reason.
  - The event is now forwarded, so the dialog appears when the agent asks.
  - **Esc now declines cleanly** instead of leaving the turn stuck: the decline is
    delivered to the waiting tool immediately, and the agent continues with the
    knowledge that you chose not to answer.

### Fixed — work the agent did was invisible or looked like it produced nothing

- **The task checklist never appeared.** Tasks were broadcast on a hardcoded
  `"default"` session id rather than the session that actually requested them, so
  they were published to a topic nobody was listening on. The tool reported success
  and nothing rendered — the most confusing possible failure, because there was no
  error to notice. Broadcasts now carry the real session id.

- **Delegated subagents appeared to return nothing.** Two separate defects
  compounded:
  - Results led with a status header, and the collapsed tool cell shows only the
    first line — so every delegation displayed its status banner and hid the actual
    report underneath it. The report now leads.
  - A child agent that finished without a closing message had **all of its work
    discarded**, so genuine completed work was thrown away rather than returned.

- **Tool cells didn't say what they acted on.** Read, Edit and Write rendered with
  no file path, the task tool showed a bare verb with no subject, and live status
  lines dumped raw JSON or the schema's parameter names instead of the values. A
  transcript of a long session was effectively unreadable — a column of identical
  verbs. Cells now name their target.

- **Internal reminders leaked into visible tool output**, mixing OSA's own
  bookkeeping into the results you read. This included skill files belonging to
  *other* tools, discovered by a lookup that walked as far as **40 directories above
  the workspace** — well outside the project, picking up unrelated content from
  elsewhere on the machine.

### Fixed — the long-session guard was ending sessions that were going fine

- **The doom-loop detector aborted correct work.** It is meant to catch an agent
  stuck repeating a failing action, but it keyed on **the first 100 characters of a
  tool result** — which are identical for every edit to the same file — so a
  sequence of distinct, successful edits looked like one action repeated. It then
  classified those successes as *failures*, because the diff embedded in the result
  happened to contain words like "error". The guard concluded the agent was looping
  and instructed it to abandon work that was correct.
  - Detection is now keyed on the actual call arguments and the real outcome, so
    repetition and failure are each judged on what they are.

### Fixed — the context indicator reported a confident 0%

- Two independent faults stacked into one wrong number:
  - A **transport failure** while probing a model's context window was cached as if
    it were the answer, and cached **permanently** — one blip early on pinned that
    model's window to zero for the entire life of the process, with no recovery.
  - The TUI had **no branch for an unknown window**, so it divided by that zero and
    rendered a confident, precise, wrong `0%`.
- An unknown window now shows a **token count with no percentage**, and a failed
  probe is no longer cached as a result.

### Fixed — multi-agent view, model switching, and markdown tables

- **Multi-agent view** had four simultaneous timers running, a mangled label, raw
  internal session ids on screen, duplicated rows, and a widget drawing **34 rows
  into a 30-row reservation** — overflowing its own space and pushing the layout out
  of shape. One timer, real names, no duplicates, and the widget now fits.
- **Switching model returned 404 on a fresh session.** Sessions are now announced on
  stream subscribe, so the session is known by the time you can act on it. Also
  fixed the underlying cause of related disappearances: an ETS table with **no
  durable owner**, which silently dropped tracked sessions when its owner went away.
- **Markdown tables clipped every column to the same width**, regardless of the
  content, so wide columns lost their text while narrow ones sat mostly empty.
  Columns are now content-sized and wrap rather than truncate.

- **Plans were being invented from prose.** A hook scraped numbered lines out of the
  agent's answers and promoted them into checklist items — so ordinary prose that
  happened to be numbered became a plan the agent had never proposed. Removed.

### Added

- **`--model` and `--provider` flags**, so a run can select both from the command
  line. Relatedly, **unknown flags now error** instead of being silently ignored: a
  typo previously launched a normal session while quietly discarding the option you
  asked for.
- **Locally-installed model tags now take precedence over catalog attribution**, so
  a model you actually have installed is identified as such.
- **kimi-k3 and gemma4**, and Ollama Cloud model registration is consolidated into a
  **single source of truth**. Adding one model previously required coordinated edits
  in **seven separate places**, which is why the set drifted out of agreement.

### Changed

- Agent instructions steer away from re-running commands that overlap work already
  done, and toward **stopping once a question has been answered** rather than
  continuing to investigate past the point of an answer.

---

## [1.0.46] — displays as `v1.0.046`

### Security — a cloned repo could execute code just by having OSA run git in it

- **Every git invocation is now hardened against hostile repository config.** Git
  reads configuration *from the repository it is operating on*, and several of
  those settings name a program that git then executes. A repo you merely cloned
  could therefore set `core.hooksPath` (pointing at attacker-controlled hooks),
  `core.fsmonitor` (an arbitrary binary run on nearly every command), or clean/
  smudge filters (run on checkout and diff) and get **code execution the moment
  OSA ran any git command inside it** — including read-only ones like `git
  status` or `git diff`, which OSA runs routinely as part of context discovery.
  - Introduced `OptimalSystemAgent.Git`, a single choke point that neutralises
    these vectors, and routed **all 56 git call sites** through it — context refs
    (`diff`, `git_log`, `staged`), the worktree and fast-worktree machinery, the
    filesystem checkpoint server, the `git` tool handler, and the CLI.
  - No call site now shells out to `git` directly, so the hardening cannot be
    bypassed by a future caller forgetting to opt in.

- **Terminal titles are sanitised.** The TUI sets the terminal window title from
  session-derived text, which could carry **OSC escape sequences** (an escape
  injection that can drive the host terminal, and on some terminals can be echoed
  back into the input stream) or **Trojan-Source bidirectional control
  characters** (which reorder displayed text so what you read differs from what is
  actually there). Both classes are now stripped before the title is emitted.

### Fixed — `osa update` failed silently, then locked itself in permanently

- **The worst-behaved bug in the updater is gone.** `osa update` swapped the TUI
  binary **unchecked** and stamped the new version **regardless of whether any
  step had succeeded**. The result was a failure mode that hid itself and then
  became permanent: an update that had actually failed reported *success*, left
  the old binary in place, and — because the stamp now claimed the new version —
  every subsequent `osa update` answered **"Already up to date"** forever. The
  user was pinned to a stale build with no error and no way to notice.
  - Every step of the update is now verified before the next one runs.
  - The freshly installed TUI **must report the installed version** before the
    version stamp is written; if it cannot, the stamp is not written and the
    update fails loudly.
  - A stamp/binary mismatch is now **self-healing**: an installation that already
    lost this race detects the disagreement and re-runs the update rather than
    reporting it is current.
  - The identical defect in the **PowerShell installer** (`scripts/install.ps1`)
    was fixed the same way, so Windows is not left on the old behaviour.

### Fixed

- **The context bar no longer shows a percentage against a made-up window size.**
  Cloud models were never probed for their real context length, so the bar
  measured usage against a hardcoded default — a 1,000,000-token model was
  reported as a fraction of **128k**, making a nearly empty context look nearly
  full. Real context windows are now resolved from the provider; when a window
  genuinely cannot be determined, the bar renders the **token count with no
  percentage** rather than a confident wrong one.
- **Plan mode is no longer silently dropped on small-context models.** The context
  budget fitter evicted blocks in plain list order with no error, so on a tight
  budget the plan-mode instructions could simply vanish from the prompt — the
  model stopped behaving as if it were in plan mode, with nothing reported.
  Essential blocks are now **priority-ordered**, so they survive eviction.
- **Fixed a TUI crash** in the activity details block, which wrote outside the
  frame buffer.
- **`POST /:id/provider` returns 404, not 400, for an unknown session.** An
  unrecognised session id was reported as a malformed request.

### Changed

- **Tool errors are non-fatal where recovery is possible.** A failing tool call
  used to halt the turn; the model now receives the error and can correct course
  and continue, instead of the whole turn dying on a recoverable mistake.
- **Paste handling reworked** in the TUI for more reliable handling of large and
  bracketed pastes.
- **Agent instructions substantially expanded**, covering tool usage and
  workflow guidance in materially more detail.

---

## [1.0.41] — displays as `v1.0.041`

### Fixed — switching the model failed before the first message

- **Switching provider/model no longer errors on a fresh session.** Session Loops are
  started **lazily** — the message path calls `ensure_loop` when the first turn
  arrives — but the provider-swap path only *looked up* a Loop and never started one.
  So the extremely common flow of *open OSA → pick a model → then start talking*
  returned `{:error, :not_found}` → HTTP **404 `session_not_found`** → a "switch
  failed" toast, every time. Swapping now materialises the Loop the same way every
  other session-scoped entry point does, so the choice lands on the Loop the first
  turn will use.
  - Verified against a live backend on a session with no Loop: **404
    `session_not_found` → 200 `ok`** (provider, model and context window returned).
  - Added a regression test asserting a switch on a not-yet-started session neither
    404s nor leaves the session unmaterialised.

---

## [1.0.40] — displays as `v1.0.040`

### Fixed — TUI audit: 14 rendering defects across 3 root causes

A full audit of the TUI (live-region geometry, text rendering, turn lifecycle)
found that most visible glitches traced to three structural gaps rather than
independent bugs. All three are now closed.

**Root cause 1 — the live region's height was computed twice, and some components
drew without being in the budget at all.**

- **Typing a `/` command no longer wipes the screen.** The completions popup
  recomputes its height on every keystroke, and that was aliased onto the "terminal
  resized" flag — so each character took the destructive full-screen clear path and
  re-anchored the viewport at row 0. Popup changes now commit promptly but clear
  *surgically*; only a real terminal resize takes the full wipe.
- **No more dead rows under the spinner.** The activity slot reserved a flat 6 rows
  and drew its accent rail across all of them, trailing bare rail glyphs down the
  empty rows. The slot is now sized exactly to the current verbosity and the content
  is bottom-anchored, so the spinner sits tight above the composer.
- **Verbose mode no longer silently drops tool rows** — it needs 9 rows and the flat
  cap gave it 6, clipping the three oldest feed entries.
- **Screen-reader mode no longer leaves 11 blank rows** above the composer (sizing
  reserved the expanded thinking box while drawing the 1-row plain-text line).
- The agents roster's reserved and drawn heights agree again, and it is
  bottom-anchored like the activity feed.

**Root cause 2 — no column-width primitive, so eight near-duplicate "fit to width"
helpers existed at three different correctness levels.**

- Added `util::fit_cols` / `util::cols` as the canonical column-aware fitters and
  routed session titles, file-picker names, toasts, and the agents roster through
  them. Previously these compared **byte** length (or char count) against a **column**
  budget, so any CJK/emoji text was cut to roughly a third of its space — and because
  toasts are right-aligned, they lost their *beginning*.
- **Every wrapped bullet in every reply was mis-indented.** The list renderer measured
  its `"• "` prefix in bytes (4) rather than columns (2), so continuation lines sat two
  columns right of their own first line and wrapped early.
- The welcome banner centred by byte length, so any non-ASCII name or path made the
  first screen lopsided.

**Root cause 3 — width-blind heights + unwrapped prose.**

- **Permission prompts no longer clip the backend's warning and reason.** These
  reserved exactly one row each and rendered unwrapped, so safety text the user is
  being asked to approve could be cut off mid-sentence. Both now wrap, and the
  reserved height is computed from the same wrap.
- Plan/checklist items no longer clip mid-word or show raw `**bold**`: subjects are
  markdown-stripped and fitted to the real render width (threaded through instead of
  guessed), so each occupies exactly the one row the cell reserves. The same three
  fixes were applied to the separate task panel.
- Markdown tables keep their right border — the width cap subtracted the borders but
  forgot the `" │ "` separators, leaving the capped table too wide to fit.

**Turn lifecycle**

- The plan snapshot is now flushed synchronously at turn end and the live checklist
  retired, fixing both the recap/plan ordering race (a ~400ms debounce could land the
  plan *after* "Worked for Ns") and a stale plan redrawing over the **next** turn's
  reply.

**Tests**

- Added the live-region slot invariant (reserved rows ≥ drawn rows, and exactly equal
  when saturated) across every verbosity and screen-reader mode. No test previously
  compared reservation against layout — which is why these regressions shipped green.

---

## [1.0.39] — displays as `v1.0.039`

### Added — action authority + OpenComputers remote client

- **Unified action authority (#93 + #94).** Governed tool execution now routes through one
  fail-closed control-plane authority: HTTP, MCP, scheduled/away-mode jobs, interactive
  agents, deferred tools, and sub-agents share exact capability identifiers and
  server-published versioned fingerprints, with one-time approvals bound to the exact
  parameters and execution surface. Purely local tools stay offline and ungoverned; OSA's
  local non-bypassable machine safety remains a separate earlier layer. Ships the canonical
  MIOSA capability contract (206 capabilities, SHA-pinned) plus the routing that enforces it.
  *(This is an evolving cross-repository feature; behaviour is fail-closed and gated.)*
- **OpenComputers account remote client (#92).** New `osa opencomputers remote hosts` /
  `remote exec --host <id> -- <command>` / `remote agent --host <id> --prompt <prompt>` — a
  versioned, TLS-only remote-client envelope that keeps the MIOSA account credential in memory
  (resolved from `miosa login` or `MIOSA_PLATFORM_API_KEY`, never persisted in host config).
  v1 supports one-shot exec/agent operations; no interactive PTY routing yet.

---

## [1.0.38] — displays as `v1.0.038`

### Fixed — TUI live-region stability (systematic pass, not one-off)

Following a full audit of every inline-viewport height contributor (cross-checked against
ratatui's `insert_before` source), three more instances of the same bug class were fixed so
the composer can no longer stack or the screen wipe during a turn:

- **Agents roster is now a fixed slot.** Like the activity feed and streaming preview, the
  multi-agent roster grew one row per spawned fleet node mid-turn, rebuilding the viewport and
  stacking chrome. It now reserves a constant slot whenever shown.
- **Thinking box is now a fixed slot when expanded.** Expanded reasoning grew the box
  line-by-line as it streamed (1→12 rows), rebuilding the viewport on every line. It now
  reserves its constant max; the header + last ≤10 lines render into it.
- **No more transcript wipe after a message flush.** `last_inline_top` (the anchor for the
  surgical height-change clear) was only refreshed at rebuild points, but `insert_before`
  (flushing finalized messages to scrollback) moves the viewport top down every time. The
  stale anchor made the next clear wipe the just-flushed transcript. It's now refreshed after
  every flush.

Known remaining edge (tracked): on terminals that *reliably* drop the cursor-position query,
a rebuild degrades to full-screen and finalized messages can be silently dropped rather than
shown — a separate fix.

---

## [1.0.37] — displays as `v1.0.037`

### Fixed — composer no longer stacks down the screen during an agent turn

- **The real fix for the mid-turn staircase.** As tools ran during a turn, the live
  activity/tool feed grew one row per tool (`pwd`, then `ls`, then `date`…), and that growth
  grew the inline viewport height **mid-turn** — each growth rebuilt the viewport (a DSR cursor
  re-anchor), stacking a fresh composer + status bar down the whole screen. The streaming
  preview was already given a fixed-height slot to prevent exactly this; the activity feed was
  not. It now reserves a **constant fixed slot** for the whole turn (the feed draws top-down
  into it), so the viewport height stays stable, no per-tool rebuild happens, and nothing
  stacks. **Validated live** against a real agent turn executing shell tools: single composer,
  no stacking, no crash.

---

## [1.0.36] — displays as `v1.0.036`

### Fixed — resize wipe was firing on every height change (regression)

- **The screen no longer wipes/stacks on notices, typing, or scrolling.** The DSR-free
  full-screen `ClearType::All` from the resize fix lived in the shared commit block, which
  fires on **any** inline-height change — not just terminal resizes. So a transient notice
  ("New session", "Coordinator mode off"), the composer growing, or scrolling all wiped the
  whole screen and re-anchored, stacking composers and clearing the transcript on every
  keystroke. Now the full-screen wipe runs **only on an actual terminal resize** (where reflow
  makes surgical clearing impossible); a pure height change clears surgically from the tracked
  region top, preserving the transcript above.

---

## [1.0.35] — displays as `v1.0.035`

### Fixed — update check hit a dead endpoint

- **The update checker no longer fails against a dead service.** `OpenComputers.Updater`
  (the background auto-check and `osa update check/apply`) queried
  `https://api.miosa.ai/api/v1/opencomputers/osa/latest`, which returns **503
  "version_not_configured"** — no release is published there — so every check failed and the
  background loop logged repeated failures. It now checks **GitHub Releases**
  (`/repos/Miosa-osa/OSA/releases/latest`), the same source the installer and the `osa update`
  launcher already use.
- The checker is now **check-only**: it detects a newer published release and reports
  `{:available, version}` (the actual `osa update` launcher applies it via the GitHub release
  tarball — this Elixir path only ever staged a single binary, which never matched how OSA
  ships). Also fixes version comparison against the zero-padded display tag (`v1.0.034`), which
  `Version.parse/1` had been rejecting as an invalid leading zero.

---

## [1.0.34] — displays as `v1.0.034`

### Fixed — Ollama Cloud onboarding (client-blocking)

- **Selecting "Ollama Cloud" with an API key now verifies against `https://ollama.com`, not
  a local daemon.** The onboarding health-check was **local-first**: it probed for a local
  Ollama daemon and only fell back to the cloud endpoint if none was found. So an explicit
  cloud selection could get hijacked to `http://localhost:11434` — which does not serve a
  `:cloud` model like `glm-5.2:cloud` — and verification died with
  `error sending request for url (http://localhost:11434…)`.

  Corrected priority: **cloud selection ⇒ cloud URL, always.** When a key is supplied, verify
  against `ollama.com` with the Bearer key. Only a **keyless** cloud selection falls back to a
  reachable local device-identity daemon. Every other provider was already correct (Anthropic →
  `api.anthropic.com`, OpenAI → `api.openai.com`, OpenRouter → `openrouter.ai`, Ollama Local →
  `localhost:11434`).

---

## [1.0.33] — displays as `v1.0.033`

### Fixed — TUI resize, for real this time (duplication AND crash)

- **Resizing the terminal no longer duplicates the composer or crashes.** On terminals
  that don't answer the cursor-position query (DSR) quickly during a resize — tmux, some
  SSH sessions, and others — the inline live region could not be located after the terminal
  reflowed, so earlier surgical-clear attempts either **stranded a staircase of old
  `N% context used` + divider rows**, or (when left to ratatui's auto-resize) crashed with
  `Error: The cursor position could not be read within a normal duration`.

  Since surgical clearing is impossible without a working DSR, the resize path now does a
  **DSR-free full-screen wipe** (`ClearType::All`) before rebuilding the region fresh —
  exactly one copy of the chrome can ever exist and the reflow position never matters.
  Validated against a DSR-dropping pane across widen / narrow / rapid-resize bursts: no
  duplicate, no crash.

  Trade-off: the on-screen transcript is cleared on resize (it repaints from the live region
  down). The finalized conversation still lives in the terminal's scrollback history and the
  in-app transcript viewer — only the on-screen copy is redrawn.

---

## [1.0.32] — displays as `v1.0.032`

### Fixed

- **TUI resize duplication — corrected anchor.** v1.0.31's fix anchored the inline-region
  clear to the *bottom* of the screen, which is only right when the region is pinned to the
  bottom (a screen full of transcript). In a fresh / near-empty session the live region sits
  high on the screen with blank space below it, so the bottom-anchored clear wiped empty rows
  and left the real composer/status untouched — the duplicate persisted. The clear now homes
  to the region's **actual tracked top** (`last_inline_top`, captured at startup and every
  rebuild), clamped into the resized screen, so it erases the on-screen chrome whether it sits
  high (empty session) or low (full screen); the rebuild re-anchors the fresh region at the
  same row, leaving exactly one copy.

---

## [1.0.31] — displays as `v1.0.031`

### Added — post-edit format + diagnostics loop (stop editing blind)

- **OSA no longer edits code blind.** After every `file_edit` / `multi_file_edit` /
  `file_write` / `file_create`, the touched file is run through a fast, single-file
  **format + diagnostics** pass and any syntax/parse error is injected back into the tool
  result the **same turn** — so the model sees the mistake it just made instead of
  discovering it 20 tool-calls later. This was the top convergent gap versus Claude Code,
  Codex, OpenCode and Grok (`docs/GAP_ANALYSIS.md` G1 + G2).
  - **Auto-format on write** — Elixir formats **in-process** via `Code.format_string!/2`
    (respecting `.formatter.exs` opts, no `mix` startup cost); Go/Rust/JS·TS/Python use
    their single-file formatter (`gofmt -w`, `rustfmt`, `prettier --write`, `ruff format`).
  - **Fast diagnostics** — Elixir syntax via `Code.string_to_quoted/2` (instant, in-process);
    Go via `gofmt -e`, Rust via `rustfmt`, JS via `node --check`, Python via `ruff check` /
    `py_compile`; TS/TSX parse errors surface through `prettier`.
  - Dependency-light and **degrades to a no-op** when a tool binary is absent; each command
    is time-boxed; a file that fails to parse is left byte-for-byte untouched and its error
    reported. Wired via the pluggable `:diagnostics_provider` seam; disable with
    `config :optimal_system_agent, post_edit_verify: [enabled: false]`.

### Fixed

- **TUI — resizing no longer duplicates the composer/status bar.** The inline-region rebuild
  cleared old chrome anchored to a `crossterm::cursor::position()` **DSR query**, which tmux
  and some emulators drop or answer with a stale row during a resize burst (a pane drag fires
  many `Resize` events) — stranding a duplicate composer while a fresh one drew below. The
  clear now anchors to the bottom-anchored region geometry derived from
  `crossterm::terminal::size()` (an ioctl reflecting the applied resize, no escape round-trip
  to drop): deterministic for grow/width-only changes, exact for shrink.

---

## [1.0.30] — displays as `v1.0.030`

### Fixed / robustness

- **A port conflict no longer crashes the whole app.** When `OSA_HTTP_PORT` (default 9089)
  was already in use, OSA hard-crashed on boot — Bandit failed to bind, the supervisor
  restarted it 10×/60s, and the entire OTP tree died with a cryptic dump. Now a boot
  **preflight** halts cleanly with an actionable message that distinguishes *another OSA
  instance already running* ("connect to it, or set `OSA_HTTP_PORT`") from *a foreign
  process holding the port* ("free it — `ss -ltnp | grep 9089` — or set `OSA_HTTP_PORT`"). A
  single shared `Net.Port` helper backs every surface below.
- **`osa doctor`** now reports three distinct states — OSA responding, OSA not running, and
  **port taken by a non-OSA process** (the case it previously misdiagnosed as "API not
  responding"). It also reads `OLLAMA_URL` (was `OLLAMA_HOST`, misaligned with the app).
- **Onboarding** warns if the HTTP port is already taken *before* you finish setup, instead
  of completing "successfully" and then crashing on first launch.
- **TUI** — the "backend unreachable" message now names the port and points at `osa doctor`
  instead of a vague dead-end.

---

## [1.0.29] — displays as `v1.0.029`

### Fixed

- **Context meter read far too high on Ollama Cloud models.** For a `:cloud` model running
  through the `:ollama` provider (e.g. `glm-5.2:cloud`), the usage denominator collapsed to
  the local Ollama KV-cache ceiling (`ollama_num_ctx`, ~32k → ~12.7k after the reserve)
  instead of the model's real context window (1,000,000) — so a normal ~15k-token turn read
  **over 100%** and the bar filled almost instantly. `effective_context_window/2` now skips
  the local KV cap for `:cloud` models, so the meter (and context budgeting + `num_ctx`
  sizing, one source of truth) use the true window. A ~50k-token session now reads ~5%
  instead of pinned-full.

---

## [1.0.28] — displays as `v1.0.028`

This cycle built an agent **fleet**: a Claude-Code-parity roster of full-power
sub-agents, dynamic multi-agent **workflows**, a renamed **effort ladder** that
gates them, and — the capstone — **self-orchestration** so OSA can decompose a
task into disjoint file-owned workstreams, fan out a collision-free wave in
isolated worktrees, verify it, and commit itself. See `docs/FLEETVIEW_DESIGN.md`,
`docs/FLEET_ORCHESTRATION.md`, and `docs/FLEET_EDGE_CASES.md`.

### Agent Fleet

- **FleetView roster** — a live, arrow-selectable panel under the composer: a
  green never-killable `main` root row plus one row per running node (agent-type,
  live activity, elapsed, `↓ tokens`). `←` browses, ↑/↓ select, Enter attaches a
  read-view of a node's stream, `x` stops it. Inline roster is bounded to 8 rows
  (`+K more`); the `/agents` dashboard lists all.
- **Full-power spawn** (`Fleet.spawn_fleet_node`) — each node is a complete OSA
  loop (full tools/MCP/memory/permissions) on its own session with its own
  custom-agent system prompt + tool allowlist, joined to the run tree. Not the
  restricted delegate path.
- **`fleet` tool** — the model auto-invokes it (`action: spawn | workflow`);
  spawning is automatic, `/fg` and `←` are optional viewing. Depth- and
  fleet-cap-guarded (spawn-bomb safe).
- **Dynamic workflows** (`Fleet.fan_out`) — fan out one full-power node per item
  through a 16-concurrent bounded pool with FIFO queue-drain, a 1000-node
  run-lifetime kill switch, and a live `N/16` roster counter. Per-node timeout,
  per-item error isolation, and a whole-tree budget guard that stops spawning when
  the fleet budget is exhausted. Nodes coordinate through the shared scratchpad.

### Effort

- **Ladder renamed** to `fast / medium / high / xhigh / ultra` (was
  `low/medium/high/max`), with a back-compat normalizer so persisted `:low`/`:max`
  settings keep working. Effort = how much it thinks; the current tier is shown
  live in the thinking indicator (e.g. *"thinking harder with ultra effort"*).
- **`ultra`** is the max tier and the gate for dynamic workflows. Effort drives the
  provider thinking budget across Anthropic / OpenAI / Gemini / Ollama (verified
  matrix); opus honors an explicit max budget at `ultra` instead of always adaptive.

### Self-orchestration

- **Worktree-per-node isolation** (`isolation: :worktree`) so parallel nodes edit
  their own worktrees and never collide.
- **`Fleet.Finalizer`** — merges disjoint node diffs, runs an authoritative gate,
  and commits when green (scoped `git add -- <file>`, attribution-clean, never pushes).
- **The loop is closed end-to-end** — `fan_out` waits for each node to complete before
  capturing its worktree diff (so the finalizer merges *real* changes), and the `fleet`
  tool exposes `isolation` + `finalize` (gate + commit) so the coordinator can run the
  whole recon → isolate → merge → gate → commit flow. (Unit-verified end to end; a
  live-repo integration test is the next follow-up.)
- **Fleet Orchestration playbook** (`priv/skills/fleet-orchestration`) — teaches the
  coordinator the disjoint-workstream method: recon → partition by file ownership →
  isolate → structured reports → finalize → checkpoint.

### Durability & recovery

- **Budget survives restart** — the `max_budget_usd` cap is persisted in the
  checkpoint and restored, so a crash can no longer reset it to zero.
- **Crash recovery** — stale `:running` rows are reconciled at boot; an opt-in
  resumer re-dispatches orphaned autonomous runs.

### Hardening

- Fleet edge cases across `fan_out` (timeout / error isolation / empty-huge items),
  fleet-tool argument validation, and scratchpad concurrency (cluster-serialized
  writes). Two provider thinking bugs fixed (OpenAI silently disabling reasoning on
  a bad effort value; Gemini `nil > 0` term-ordering emitting a bogus budget).
  FleetView keyboard navigation verified end-to-end. **TUI resize no longer duplicates
  content** — the inline-viewport clear now anchors to the actual cursor instead of
  ratatui's stale pre-resize geometry, which had been scrolling old chrome into
  scrollback on every resize. Intermittently-flaky tests stabilized at the root cause
  (session-scoped event capture; `async: false` where global app-env is shared). Full
  suite: 5116 tests, 0 failures.

---

## [1.0.10] — displays as `v1.0.010`

This cycle closed out the CC-parity backlog: 16 workstreams across the agent
loop, memory, delegation, tools, ops, and the Rust TUI. Grouped by area
below; see `docs/BACKLOG.md` for the item-by-item scoreboard and commit
references.

### Agent

- **Investigative plan mode** — `enter_plan_mode` / `exit_plan_mode` tools
  route through `Agent.Loop.enter_plan_mode/1`, gating the session to
  read-only tools until the plan is exited. The plan text is a **durable
  file** (`~/.osa/sessions/<id>.plan.md`, next to the progress ledger) rather
  than transient state, so a plan survives context resets, restarts, and the
  approve/reject/edit round-trip.
- **Goal-level verifier** (`Agent.Loop.GoalVerifier`) — an independent,
  read-only skeptic panel (N subagents, majority-refute vote) that judges
  whether the user's *goal* was met, not just whether a file compiles. Off by
  default; fail-closed to `:incomplete` on ties or missing data. Run-capped
  and stall-gated so it never spins forever.
- **Multi-turn goal orchestration** (`Agent.Loop.GoalTracker`) — a
  cross-turn, ETS-backed status machine (`:active | :paused | :completed |
  :off_track`) that survives across top-level turns. Auto-pauses on a
  cross-turn stall (two verification rounds citing the same gap) or a
  lifetime run cap, and gates the (expensive) verifier panel on a reverify
  cadence instead of every turn.
- **Reasoning-only doomloop detector** (`Agent.Loop.DoomLoop.ReasoningOnly`) —
  catches a model spinning in pure thought (zero tool calls) or repeatedly
  erroring, which the existing tool-call-keyed detectors can't see. Halts
  after a small consecutive-streak threshold and forwards to the existing
  `Resample` remedy.
- **Forced max-steps wrap-up** — hitting the iteration cap now triggers one
  final tools-disabled model turn that writes a real state summary/handoff
  instead of a canned line. Guarded so hitting the cap can never crash the
  turn.
- **Header-aware retry** — provider resilience honors a `Retry-After` header
  from the provider (capped at 60s) instead of blind exponential backoff,
  and can rebuild the HTTP/1.1 client / strip images on a header-driven
  retry decision.
- **First-failure self-correction** — the verification gate is *grounded*:
  it re-prompts only after an external check (build/test/lint) actually
  fails, following the CRITIC / "LLMs Cannot Self-Correct" research —
  ungrounded self-judgment is avoided.
- **Token-budget "work to target"** — `target_output_tokens` (state or app
  env) keeps the loop auto-continuing until a caller-specified output-token
  budget is met, capped at a small number of continues.

### Context / Memory

- **Hybrid RAG recall** — vector KNN (`Memory.Search`, cosine similarity)
  fused with MMR diversity re-ranking (`Memory.MMR`) and dependency-free
  query expansion (`Memory.QueryExpansion`, synonym table + stemming) for
  the lexical scoring path. Degrades gracefully to keyword-only scoring when
  no embedding provider is configured or a call fails.
- **Persisted vector store** — embeddings are now durably stored one row per
  memory id in a `memory_vectors` table in the same SQLite database the
  memory store uses, with an ETS warm-read cache in front. Content-hash
  invalidation re-embeds on content drift.
- **Compaction quality**:
  - Verbatim latest-user-query preservation — the most recent `user` message
    is wrapped in `<user_query>` tags and prepended to any generated
    summary, untouched by the summarizing LLM.
  - Token-budgeted, turn-aware tail selection — `preserve_recent_budget`
    (25% of the usable context window, clamped `[2_000, 8_000]`,
    operator-overridable) replaces a fixed message-count tail.
  - Prune tier — a non-LLM pass that erases old (out-of-budget) tool-result
    output outright rather than summarizing it, with a protected-tools
    allowlist and a minimum-reclaim gate before it bothers mutating anything.
  - Media-strip + overflow replay — on context-overflow retries, media
    blocks are stripped from messages before retrying, up to 3 overflow
    retries.
- **Post-compaction auto-continue** — after a compaction pass changes the
  message list, the loop can auto-continue the turn (gated by
  `ProactiveCompaction.continuation_enabled?/0`) instead of silently
  returning a truncated response.

### Delegation

- **Transitive cascading cancel** — `Loop.cancel/1` now BFS-walks the
  parent/child session tree and cancels every descendant sub-agent, plus
  batch-kills their background shell commands in one pass
  (`BackgroundManager.cancel_for_sessions/1`).
- **`task_wait` join-barrier depth ceiling** — a blocking wait on other
  agents' completion can no longer nest arbitrarily deep; `max_depth/0`
  (default 3, `:max_blocking_wait_depth`) is checked before a wait starts,
  denying requests that would exceed the ceiling instead of blocking and
  failing later.
- **Peer-resume (sibling handoff)** — a sub-agent run can be seeded from a
  sibling/peer's accumulated context (`resumed_from`) rather than starting
  fresh or forking from the parent; surfaced in run metadata for lineage.
- **Worktree durable snapshot** — `FastWorktree.snapshot_ref/2` commits any
  uncommitted worktree changes and writes a durable git ref
  (`refs/osa/subagent-snapshots/...` by default) before teardown, so a
  sub-agent's work stays inspectable/resumable without being merged or lost.

### Tools

- **Hashline drift-guard edits** (`FileEdit.DriftGuard`) — a second,
  independent content-hash guard on top of `FileState`'s `{mtime, size}`
  check, closing the blind spot where two different file states collide on
  the same size within the same wall-clock second. Only ever *stricter* than
  the existing guard; never blocks a legitimate re-read/edit cycle.
- **Output-shorten-to-file** (`Agent.Loop.ToolResultStorage`) — tool results
  over 50KB or 2,000 lines are persisted to `~/.osa/tool-results/<id>.txt`
  and replaced inline with a head/tail preview (40/20 lines) plus a file
  reference, preventing context bloat from huge shell/grep output.

### Ops

- **Rollback-safe self-update** (`osa update`, `bin/osa-update`) — dual
  symlink (`current` / `previous`) atomic swap: stage a fresh git-worktree
  checkout, build it, boot-probe its `/health` endpoint, and only then
  atomically repoint `current`. A post-swap health re-check auto-rolls-back
  to `previous` on failure. `osa update --staged`, `osa update --rollback`,
  and `--dry-run` are all supported; nothing is mutated on a dry run or a
  failed build/health gate.

### TUI

- **Composer** — structured `@`-mentions (file/dir/agent, with a per-kind
  glyph in the popup), ghost-text completion, `!`-prefixed bash submit mode,
  a huge-input pill for large pastes, and frecency-ranked mention recall.
- **Render** — LaTeX-to-Unicode conversion, richer table-cell markdown
  (nested quotes, tabs, soft breaks), bold-italic/setext heading support,
  and a raw-source toggle (`alt+r`).
- **Notifications / focus / clipboard** — terminal focus tracking (DECSET
  1004), OSC 9;4 progress reporting, a sleep inhibitor during long runs, an
  audio completion cue, kitty click-to-focus, a layered clipboard, and a
  configurable notification channel (`OSA_NOTIFY_CHANNEL`, opt-out via
  `OSA_NO_NOTIFY`).
- **Status / activity** — esc-again-to-interrupt, a watcher/background cue,
  a queued-message hint, usage-percent + low-balance indicator, an MCP
  status chip, width-gated spinner, and a subagent footer.
- **Fixed-height streaming viewport** — the inline chat viewport now holds a
  constant height while streaming instead of reflowing the terminal on every
  chunk.

### Deferred (documented, not dropped)

See `docs/BACKLOG.md` → "Deferred with rationale" for the reasoning behind
message-derived loop state (crash-resume), structured `@file`/`@agent` refs
on the wire, and the remaining crossterm-blocked mouse items.

---

## Older history

Earlier, pre-cycle entries live in [`docs/operations/changelog.md`](docs/operations/changelog.md).
