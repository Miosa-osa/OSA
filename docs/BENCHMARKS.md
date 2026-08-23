# OSA Benchmarks

OSA is benchmarked against the standard agentic-coding evaluations, and against
competing harnesses run **on this machine with the model held fixed**.

We do not quote a leaderboard-comparable score, and the reason matters more than
the number would. Published SWE-bench figures are not comparable to each other:
scaffold alone moves the same model by **11–20 points**, labs report against
denominators of 477, 484 and 500, and the official checklist forbids pass@k as a
headline while permitting best-of-k reported as pass@1. UTBoost (ACL 2025) found
**345 patches mis-graded as passing**, changing 24.4% of Verified leaderboard
entries — and the leaderboard was never re-issued.

So the only comparison we consider meaningful is one we run ourselves, with one
model, one task set, and one set of limits.

### Cost per task

The field publishes token and cost figures; ours were far outside them. Divided
out from goose's model-pinned Harbor table:

| harness | input/task | in:out | effective $/M input |
|---|---|---|---|
| Claude Code | 1.15M | 85:1 | $0.24 |
| opencode | 1.25M | 70:1 | $0.42 |
| goose | 0.71–0.88M | 56–67:1 | $3.00 |
| **OSA (before)** | **3–8M** | **~140:1** | **$3.00** |

$3.00/M is the full **uncached** rate; $0.24 implies ~96–100% cache hits. OSA had
both multipliers stacked — several times the field's token volume *and* zero
caching — for 12–35x Claude Code's cost per task.

Measured on `tb-cost-probe-v1`, 8 Terminal-Bench tasks, same provider
(`ollama/glm-5.2:cloud`), same limits, changing only the code:

| | before | after | change |
|---|---|---|---|
| input tokens / task | 4,654,997 | **2,821,177** | **−39.4%** |
| $ / task | $2.8628 | **$1.7310** | **−39.5%** |
| in:out ratio | 146.7:1 | 162.3:1 | +10.6% |
| tasks solved | 5/8 | 5/8 | unchanged |

That puts us at **2.2–3.9x** the field's input volume, down from 3.6–6.5x. It is
progress, not parity.

Four things this table is not, stated because each one could be read as a bigger
claim than we can support:

- **Both arms are priced at the same correct rates.** Our accounting was
  separately found to misprice models by up to 3x; presenting a raw dollar delta
  across that fix would have manufactured an improvement. The delta above tracks
  the token delta exactly, as it must.
- **The prompt-caching win is not in these numbers.** Caching went 0% → 94.1%
  measured live, but the benchmark path runs on Ollama, which has no cache to hit
  and no counter to read. The −39.4% comes from compaction, accounting and loop
  fixes alone; caching is additive on top for Anthropic-routed traffic, and is
  not yet demonstrated end-to-end on a benchmark.
- **The in:out ratio got worse**, because output fell faster than input. The
  ratio is a diagnostic, not a goal.
- **Solve rate is unchanged, not improved**, and its composition moved: one task
  regressed and one improved. The regression was re-run 3 times on the identical
  pre-fix build and flipped without any code change — 4 pass / 2 fail across 6
  observations. It is variance, and single runs on this set are not evidence of
  small differences in either direction.

### Corrections as of 1.0.100

Four claims above are wrong or superseded. They are corrected here rather than
edited away, because the corrections are the more useful record.

- **The dollar figures understate spend.** Both arms were priced with
  `glm-5.2:cloud` carrying the previous generation's rate — `{0.60, 2.20}`
  against Z.ai's `{1.40, 4.40}`. Every dollar number in the table above is
  **2.4x low**. The *percentage* delta survives, because both arms carry the
  same error; the absolute figures do not. Three further mispricings were found
  since: Sonnet 1.50x over, Opus 3.00x over, and every Mistral model reached
  through a gateway billing **$0.00**. All four reported `confidence: :exact`.
- **The 162:1 in:out ratio is not comparable to the field's.** It measures our
  reasoning-suppressed output against competitors' reasoning-inclusive output.
  Measured on the same basis, OSA is **69:1 against codex's 75:1** — inside the
  band, not far outside it.
- **Caching is now demonstrated end-to-end**, which the note above said it was
  not. It had been emitted only when the provider was native Anthropic, while
  benchmarks reach Claude through a compat gateway — so on the path that
  actually runs, the feature was dead code. **0% → 92.8%** on a live arm.
- **The prefix is 17.7k tokens, not the 29.8k previously measured**, of which
  7.3k is tool schemas rather than 18.6k. Earlier releases already took that;
  the larger figure was stale when quoted.

One arm was run for 1.0.100, on `anthropic/claude-sonnet-5` with an **8x timeout
multiplier**. It is **not quotable as a result**: 8 of 89 tasks, k=1, and a
multiplier far outside Terminal-Bench's own budget — one task consumed 3h11m
against a declared 30 minutes. It was run to answer one question, and it did.

Of three tasks previously lost to identical 1743s cutoffs, **two were genuinely
clock-bound** (solving at 42m and 3h11m) and **one was never a timeout at all** —
it finished early and wrong, in half the turns. That third diagnosis had been
ours and it was incorrect. Useful calibration: one task needed 1.45x its declared
budget and the other 6.4x, so a 2x multiplier recovers one of them and nothing
else.

The same arm surfaced a cache hit rate falling **95.4% → 63.2%**. That was traced
to a live defect, not to the model or the timeout: the world-state ledger's ETS
table was owned by whichever process created it, and being reached from transient
processes meant the first one to exit destroyed every session's ledger. Fixed in
this release. **Both benchmark arms predate the fix.**

### TUI resize status

The resize break documented in 1.0.102 is fixed.
OSA now owns the visible transcript, reflows retained content at the new width, keeps live surfaces at stable measured heights, and redraws from state instead of relying on terminal scrollback behavior.
Tables, code fences, the composer, thinking output, activity, goals, and status rows therefore resize as one layout rather than leaving stacked or duplicated frames behind.

The status footer uses progressive disclosure at narrow widths.
The context label survives first, its decorative meter shortens when necessary, and optional effort, MCP, and version chips render only when each complete chip fits.
Active goals use their own row so their description and controls do not compete with model and context information.
Active skills also use their own row, collapse excess selections into `+N`, and replay from the current session after SSE reconnect.
Tool heartbeats and session-health recovery notices appear in transient activity or notification surfaces rather than expanding the permanent footer.

`test/pty/test_resize.py` exercises the release binary through a real pseudo-terminal, while `test/pty/vte_content_reflow.py` covers the libvte behavior used by GNOME Terminal and Tilix.

### Prefix cost as of 1.0.101

The static prefix is what every turn pays before any work happens, so it is the
one efficiency number worth quoting on its own. Measured locally, not modelled:

| segment | tokens |
|---|---:|
| tool schemas | 7,259 |
| static base | 6,340 |
| world state | 2,865 |
| volatile tail (uncached by design) | 1,215 |
| **total** | **≈17.7k** |

MCP is separate and used to dominate it. Measured by speaking MCP stdio to 13
configured servers, of which 7 answered with **387 real tools**:

| | prefix tokens |
|---|---:|
| declared as native tool schemas | 72,111 |
| virtualized, every tool name listed | 2,020 |
| virtualized, per-server ceiling (1.0.101) | **417** |

The cost is now **O(servers), not O(tools)** — a server exposing 300 tools costs
one line. Permission gating is unchanged: every MCP call still goes through an
OSA tool with a real schema and a real permission check.

**No benchmark arm was run for 1.0.101.** The last one is described above and is
diagnostic, not comparable.

### Head-to-head, model held fixed

Terminal-Bench 2.0 tasks, all arms on `glm-5.2:cloud` through one local daemon,
wire-verified per arm that no arm silently substituted a model.

**These are Terminal-Bench 2.0 numbers, and 2.0 is superseded.** The live
leaderboards are 2.1 and 3; 2.1 corrects 26 tasks upstream (a byte-diff of the
two trees finds 27). Nothing below has been re-run on the current sets yet.

**The harness-fault column below reads 0 for every arm because it was computed
before we could measure it.** See the correction under *What the benchmarks were
actually for*.

| harness | solved | harness faults |
|---|---|---|
| codex | 6/6 | 0 |
| mini-swe-agent | 6/6 | 0 |
| **OSA** | **4/6** | **0** |
| opencode | 3/6 | 0 |
| goose | 3/6 | 0 |

**This is not a ranking.** n=6 yields 4 discordant tasks against the ≥6 needed
for p<0.05, and every pairwise exact-McNemar test returned "not
distinguishable". It is published because it is what we measured, not because it
settles anything.

The result we consider most instructive is not ours: **mini-swe-agent — a
deliberately minimal loop around one bash tool, with a 243-byte tool schema —
matched codex and beat OSA.** On the longest task, codex solved it on 3.66M
input tokens while OSA burned 32.5M and timed out.

### SWE-bench Verified and SWE-bench Pro

| benchmark | arm | resolved | 95% CI |
|---|---|---|---|
| Verified (hard subset, airgapped) | OSA | 23/40 | 42.2–71.5% |
| Pro (hard subset) | OSA | 9/12 | 46.8–91.1% |
| Pro (same 12, OpenRouter path) | OSA | 6/12 | 25.4–74.6% |

Controls on the same sets: gold-apply 40/40 and 12/12, empty 0/40 and 0/12, so
the pipelines are sound. **None of these is a dataset score** — every run carries
`is_full_dataset_run: false`, and `bench/report/cli.py gate` refuses to print any
of them as a rate. That refusal is the design working, not a limitation.

At n=100 on Verified, gold-apply scores **98/100** — two instances are broken in
the dataset itself, so the achievable ceiling on that prefix is 98%, not 100%.

### What the benchmarks were actually for

Finding our own bugs. When we started, **a quarter of failures were OSA's
fault** rather than the model's.

**Correction.** An earlier version of this section claimed two benchmarks
reported *zero* harness faults. That claim was produced by a broken instrument
and was false. Four classes of OSA's own errors — encoding faults that killed a
turn, malformed requests, and two kinds of corruption in our own history — were
being emitted as `llm_error` and therefore scored as **model** failures. Every
harness-vs-model split we published was biased in our favour.

Re-scored under corrected attribution, `osa-hard40-airgap` goes from 17 model /
0 harness to **16 model / 1 harness** — a harness-fault share of **5.9% of
failures, not 0%**. Terminal-Bench does not move: 17 telemetry files on disk,
none carrying an affected fault. The gap was smaller than we feared, but it was
not zero, and the instrument that reported zero could not have reported anything
else.

Fixed along the way:

- A nil model silently disabled compaction on 37 of 40 sessions and budgeted a
  1M-token window as 32k
- The prompt-injection guard refused any pasted log containing `System:` — 15 of
  500 instances
- A missing `git` took down the whole application at boot
- OSA could not boot as root, breaking every containerised deployment
- Tools ran in the backend's directory rather than the session's
- Anthropic and Gemini rejected OSA's message shape with a 400, so the
  self-correction loop never ran once on those families

### Honest limits

- **Every number is a single run.** 9 of 40 instances flipped between two runs of
  the same set, so differences smaller than that are noise.
- **No full-dataset run.** 40 of 500 and 12 of 731.
- **Shell egress is a filter, not a boundary.** Web tools are denied and
  probe-verified, but this host refuses unprivileged network namespaces, so
  toolchain fetches (`go: downloading`) are detected post-hoc rather than
  prevented.
- **Every published SWE-bench Pro image ships the answer** in `/app/.git`;
  `git show <fix_commit>` returns the gold patch with the network off. We strip
  it and refuse a workspace where it is still reachable. Any Pro result produced
  without that — including published ones — is an upper bound of unknown
  tightness.

### Reproducing

```bash
bench/run-all.sh smoke        # controls only — prove the pipeline first
bench/run-all.sh swebench     # then a real arm
bench/report/cli.py gate --run <dir>
```

Controls run first and the OSA arm is refused if they fail. Methodology, with
citations, is in [`bench/report/METHODOLOGY.md`](bench/report/METHODOLOGY.md);
open findings are tracked in [`bench/FINDINGS.md`](bench/FINDINGS.md).


---
