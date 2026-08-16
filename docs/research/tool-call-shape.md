# Tool-call shape: what the 9.4% duplicate rate is, and what drives the batching decay

Corpus: 152 sessions / 6,838 tool-bearing turns / 7,687 tool calls, from the 8
Harbor runs that emit `args_hash` on 100% of calls. Fourteen runs were dropped
whole rather than counted partially — a run predating the field would silently
deflate every repeat rate computed from it.

Reproduce with `scripts/tool_call_shape.py duplicates` and `… batching`.

Everything below comes from `args_hash` (SHA-256 over the full argument map),
`tool_result.result` (full payload), and `command_output_delta.command` (full
unclipped shell text). `tool_call.args` is read for content only where
`args_bytes == len(args)` proves it is not clipped.

---

## 1. The 9.4% is mostly a counting artifact. The real waste is 1.25%.

The published figure keyed a "duplicate" on the **result payload**. That counts
every pair of *distinct* calls that happen to return the same constant string.

| definition | repeats | rate |
|---|---|---|
| name + `args_hash` — a call really was repeated | 327 | **4.25%** |
| name + `args_hash`, counting all group members | 518 | 6.74% |
| name + result hash — what the 9.4% counted | 586 | 7.62% |
| name + result hash, all group members | 826 | **10.75%** |

**486 of the 586 result-keyed repeats have different arguments.** They are
dominated by tools with constant success strings:

```
x164  file_edit      'Replaced in /app/vm.js…'      <- 164 DIFFERENT edits
x23   shell_execute  ''                             <- empty output
x21   file_edit      'Replaced in /app/vm.js'
x12   file_grep      'No matches found.'
x11   shell_execute  'Blocked: Blocked potentially dangerous command'
```

This is the same class of error as the retracted 43.5%: a field that does not
mean what the count assumed. `file_edit` answering "Replaced in /app/vm.js" for
164 separate edits is not 164 duplicate calls.

Of the 4.25% that genuinely repeat an argument map, the discriminator is whether
the repeat returned bytes the model already had:

| | calls | rate |
|---|---|---|
| repeated an earlier `(name, args_hash)` | 327 | 4.25% |
| …and got an **identical** result — nothing learned | **96** | **1.25%** |
| …and got a **different** result — the world changed | 231 | 3.01% |

The 3.01% is the edit→build→test loop working correctly. `gcc … && ./image &&
python3 test_similarity.py` re-run five times returns five different results
because the source changed between them. Re-running it is the point.

**Where the 1.25% lives**

| tool | calls | repeats | rate | wasted |
|---|---|---|---|---|
| `bash_output` | 290 | 72 | 24.8% | **62** |
| `shell_execute` | 3,931 | 197 | 5.0% | 18 |
| `file_read` | 1,019 | 36 | 3.5% | 5 |
| `task_write` | 873 | 6 | 0.7% | 5 |

**65% of all wasted repeats are `bash_output` — polling a background command
and getting the same bytes back.** Streak lengths are 2 (x34) and 3 (x12); there
is no long spin. Excluding polls, the genuinely wasteful non-poll repeat rate is
**0.44%** of calls.

Re-reads are not the problem. Of `file_read` repeats, every one that followed an
intervening write returned changed bytes (0 wasted / 9 changed); only 5 re-reads
in the whole corpus returned identical bytes.

**On the 13x gap versus codex.** OSA's argument-identity waste is 0.44–1.25%,
the same order as codex's published 0.7%. I could not establish how the codex
0.7% was measured, so I cannot claim the gap is closed — only that the two
numbers being compared were not the same quantity, and that OSA's comparable
quantity is not 9.4%.

## 2. Why the shipped backstops caught nothing: shape, not corpus age

Both. Simulating `IdenticalCall`'s windowed rule over this corpus reproduces the
shipped replay (0 halts, a handful of nudges), so the simulation is faithful:

| configuration | fires |
|---|---|
| shipped: poll+blank exempt, nudge at 3, halt at 5 | 5 nudges, 0 halts |
| without the poll/blank exemption | 19 nudges |
| threshold lowered to pairs | 31 nudges |
| pairs **and** no exemption | 93 nudges |

Byte-identical repeat group sizes across the corpus: **62 pairs, 18 triples, 1
quad.** The detector nudges at 3 and halts at 5. It is calibrated above the
population — 77% of the groups are pairs it cannot see by construction.

And the largest single concentration of real waste, `bash_output`, is the one
class the detector deliberately exempts: `bash_output` heads `@poll_tools`, and
blank results are separately marked ineligible. The exemption is defensible in
principle — polling is legitimately repeated — but it is exempting 65% of the
measured waste.

Waste also clusters at short range: 47 of 96 wasted repeats are one turn apart.

## 3. The batching decay is real, within-session, and not survivorship

| turn | turns | batch rate |
|---|---|---|
| 0-2 | 455 | 30.8% |
| 3-5 | 439 | 17.8% |
| 6-9 | 561 | 15.2% |
| 10-14 | 647 | 8.3% |
| 15-29 | 1,442 | 7.4% |
| 30-59 | 1,422 | 4.6% |
| 60+ | 1,872 | 1.2% |

The obvious confound is survivorship: turns past 30 come only from sessions that
ran that long, which are the harder ones. **It is not survivorship.** Restricting
to the 75 sessions that themselves reach 30+ turns, each compared against its own
early turns, reproduces the curve almost exactly (33.3% → 1.2%). There is *also*
a between-session effect (short sessions 13.5%, long 6.8%), but the within-session
decay survives it intact.

**Tool mix explains the first drop only.** shell-led turns go 31% → 59% between
bands 0-2 and 3-5 and are flat thereafter, while the batch rate keeps falling
through the flat region. Controlling for the leading tool, position still bites:

```
shell_execute   0-2:22%  →  60+:0%   (n=1058 at the tail)
file_read       0-2:43%  →  60+:4%
task_write      0-2:36%  →  60+:27%   <- barely decays
```

`task_write` is the tell. It is the one common tool with no sequential
dependency — writing several todo items is inherently one multi-call act — and
it is the one that does not decay.

## 4. In-context imitation survives the discriminating test

Autocorrelation alone cannot separate imitation from any slowly-varying latent
state (task phase): both predict it. Two tests separate them.

**Test 1 — does the previous turn add anything on top of a phase proxy?**
Adding the tool composition of the previous 5 turns (shell/read/edit fractions)
to position buys +88.8 log-likelihood. Adding `prev_batched` **on top of that**
buys a further **+98.1** — more than phase supplied in the first place. The
autocorrelation is not a phase proxy.

**Test 2 — is the copying graded?** A latent phase variable predicts a roughly
binary effect. Imitation predicts the model copies the *magnitude*:

| previous turn size | n | mean size of next turn |
|---|---|---|
| 1 | 6,154 | 1.07 |
| 2 | 374 | 1.52 |
| 3 | 122 | 1.94 |
| 5 | 25 | 2.44 |

Monotonic and proportional. **The imitation hypothesis is supported.**

Full model, standardised log-odds per SD: `log_turn −0.925`, `is_shell −0.881`,
`prev_batched +0.521`, `log_ctx +0.268`, `win_shell +0.237`, `prev_err −0.066`.
Context size carries no independent signal once position is held fixed (alone it
scores −0.853; controlled it flips to +0.268 — it is collinear with position).
**Errors do not explain batching at all.**

So three things are real and separable: position, the leading tool, and the
shape of the immediately preceding turn. The mechanism the nudge was designed
against is one of them.

## 5. But the nudge's *trigger* is aimed wrong

`BatchCadence.flat?` fires on six consecutive single-call turns. How often is
that simply the normal state of the session?

| turn | eligible turns | `flat?` true |
|---|---|---|
| 10-14 | 647 | 64% |
| 15-29 | 1,443 | 73% |
| 30-59 | 1,433 | 80% |
| 60+ | 1,872 | **94%** |

Past turn 60 the trigger condition holds for 94% of turns. It is not detecting an
anomaly, it is detecting the tail. Only the doubling cooldown (firing at roughly
turns 8, 18, 38, 78, 158) limits how often it speaks. The trigger cannot
distinguish a model that is needlessly serial from one that is correctly serial —
and past turn 60 the session is 57% shell and 12% `file_edit`, i.e. an
edit→compile→run→read-error loop whose steps genuinely depend on each other.

## 6. And batching does not track solving

| | sessions | batch rate, first 15 turns |
|---|---|---|
| solved | 87 | 14.7% |
| failed | 59 | **19.2%** |

Turn-matched to remove the length confound, failed sessions batch *more*. This is
observational and confounded — harder tasks may invite more parallel exploration —
but it is the only outcome evidence available, and it does not support the premise
that raising the batch rate raises the solve rate.

---

## What this implies

**Do not lower the `IdenticalCall` threshold to pairs.** It would fire 31–93
times on a corpus containing 96 wasted calls, and a pair is frequently rational.
The measured non-poll waste is 0.44% of calls. There is no backstop worth its
false-positive cost here.

**The one duplicate finding with substance is `bash_output`.** 62 wasted calls,
all in streaks of 2–3, in the tool the detector exempts. Any change here is a
change to the exemption in loop control flow, so it is a proposal, not a commit —
and the honest prior is that polling twice while waiting for a build is cheap and
probably correct. It is 0.8% of calls.

**The cadence nudge is aimed at a real mechanism through a trigger that cannot
see it.** Imitation is supported; "six singles in a row" is not evidence of a
missed opportunity, because at the tail it is evidence of nothing at all. A
trigger aimed at the mechanism would key on *opportunity* rather than on
*drought* — the model holding several independent, conflict-free operations —
and `file_read` is the natural place to look, because read/read never conflicts
under `ConflictScope` and its batch rate still falls 43% → 4%.

**What I could not measure.** Live provider access is blocked, so nothing here
tests whether any intervention changes behaviour — the corpus was produced
without the nudge existing, and its effect remains unmeasured. Whether compaction
degrades the imitable transcript is untestable here: 238 `above_compact` events
occur, but no compaction event is emitted to the stream to align against. And the
codex 0.7% could not be re-derived, so the cross-harness comparison stays open.
