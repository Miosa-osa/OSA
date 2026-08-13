# OSA Recovery-Bench run — `smoke-replay`

- **Benchmark**: Recovery-Bench over Terminal-Bench 2.0 via Harbor `0.21.0`
- **Corruption source**: `terminus-2 / claude-haiku-4-5 (upstream shared traces)` — the shared upstream traces, so the corrupted states are identical to everyone else's
- **Model (both arms)**: `from OSA config`
- **Message mode**: `none` (`none` = corrupted machine only, no polluted transcript)
- **OSA commit**: `d65ac745`   **release built**: 2026-08-13T19:35:13+00:00
- **Graded by**: each task's own `tests/test.sh`, on final container state

## Headline — the delta is the deliverable

| arm | solved | accuracy |
|---|---|---|
| fresh (pristine container) | 0 / 0 | n/a |
| corrupted (weak agent's failure replayed) | 0 / 0 | n/a |
| **delta** | | **n/a** |

Relative drop: **n/a**. Paired over **n = 0** tasks present in both arms.

> **Subset run.** 0 of 64 tasks in Recovery-Bench's corrupted universe. This is a pipeline and regression signal, not a Recovery-Bench score, and must not be quoted as one.

### Against the published figures

The paper reports **26.3% fresh -> 11.2% corrupted** (57.0% relative drop), averaged over the paper's model set; rankings reorder between the two arms, which is the finding that makes recovery a separate axis. Those are averages over a different model set and a full run; they are an orientation band, not a target.

## What moved, per task

The transition table is the part that carries information. `regressed` is a task OSA could do from scratch but not from a broken machine — that cell *is* the recovery failure. `recovered` is the opposite and is rarer than intuition suggests.

| transition | count | meaning |
|---|---|---|
| held | 0 | solved in both arms — corruption did not matter |
| regressed | 0 | solved fresh, failed corrupted — **recovery failure** |
| recovered | 0 | failed fresh, solved corrupted — prior work helped |
| failed_both | 0 | failed in both arms — task is out of reach either way |

## Harness or model?

OSA failing to boot is not OSA failing to recover. The delta below excludes any pair where either arm suffered a harness fault; if it disagrees with the headline, the headline is partly measuring install reliability.

| metric | raw | excluding harness faults |
|---|---|---|
| paired n | 0 | 0 |
| fresh | n/a | n/a |
| corrupted | n/a | n/a |
| **delta** | **n/a** | **n/a** |

## Per-arm detail

| metric | fresh | corrupted |
|---|---|---|
| tasks attempted | n/a | 1 |
| tasks resolved | n/a | 0 |
| accuracy | n/a | 0.0% |
| harness fault rate | n/a | 100.0% |
| wall-clock total | n/a | 23.4 |
| agent setup mean (install + replay) | n/a | 11.63 |
| turns mean | n/a | n/a |
| tool calls mean | n/a | n/a |
| tokens in | n/a | n/a |
| tokens out | n/a | n/a |

## OSA self-inflicted markers, by arm

Scraped from OSA's own log inside each container. A marker that is **much more common in the corrupted arm** is the strongest available evidence that OSA, not the model, is what fails under recovery.

| marker | fresh | corrupted |
|---|---|---|
| _none observed_ | | |

## Failure taxonomy, by arm

| reason | fresh | corrupted |
|---|---|---|
| no_telemetry_written | 0 | 1 |

## Per paired task

| task | fresh | corrupted | transition | replayed cmds | fresh reason | corrupted reason |
|---|---|---|---|---|---|---|

See `bench/recoverybench/README.md` for what this delta can and cannot claim.
