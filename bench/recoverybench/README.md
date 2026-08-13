# Recovery-Bench for OSA

A harness that measures **how much of OSA's competence survives being started on
a machine a previous agent already broke**, using
[Recovery-Bench](https://github.com/letta-ai/recovery-bench) over
[Terminal-Bench 2.0](https://www.tbench.ai), graded by
[Harbor](https://www.harborframework.com).

It produces **one number**: the fresh-vs-corrupted delta, with the model held
fixed. Neither arm's absolute score is the deliverable.

---

## Why this benchmark and not another

Almost every agent benchmark measures capability, and capability is dominated by
the model. Recovery-Bench is the only widely-cited one whose measured quantity
is a *difference between two runs of the same model*, which is what makes it an
instrument for the **harness**.

The published result is that recovery is badly damaged and, crucially, that
**the rankings reorder** between the two arms: Claude 4 Sonnet is first on
Terminal-Bench (34.8%) but third on Recovery-Bench, while GPT-5 is 20.2% fresh
and first on recovery. A benchmark whose ordering changes is measuring a
different axis, not a noisier version of the same one. That is the entire
argument for running it here.

| | fresh | corrupted | relative drop |
|---|---|---|---|
| published mean over the paper's model set | 26.3% | 11.2% | 57% |

Those are averages over models OSA is not, on a full 64-task run. They are an
orientation band, **not a target**.

---

## How Recovery-Bench actually works

Not the marketing version, and not a guess — this is what the upstream code in
`upstream/recovery_bench/` does:

1. **A weak agent fails first.** Upstream ships pre-generated traces from
   `terminus-2` driving `claude-haiku-4-5` over all 89 Terminal-Bench 2.0 tasks.
   It solved 25 and **failed 64**. Those 64 are the corrupted universe; a task
   the weak agent solved has no failure to recover from and is not in the
   benchmark.

2. **The corrupted state is produced by replay, not by a snapshot.** A fresh
   task container is started, and the failed agent's own commands are
   re-executed into it (`replay.py: replay_via_exec`). The commands are pulled
   out of the ATIF trajectory's `tool_calls[].arguments.keystrokes`. Two details
   that matter:
   * a command that the original agent immediately followed with `C-c` is
     **skipped** — it was deliberately killed and would only hang the replay;
   * each replayed command has its own timeout and failures are swallowed. The
     replay reproduces *an* end state, not a byte-identical one.

3. **The recovery agent is then pointed at the same task.** It gets the original
   instruction wrapped in a fixed preamble (`prompts.py: RECOVERY_PREAMBLE`),
   which tells it the previous attempt failed and to try a different approach.

4. **What it is told about the failure is a dial**, `--message-mode`:
   * `none` — the corrupted machine and nothing else;
   * `summary` — an LLM-written summary of what was tried;
   * `full` — the entire previous transcript.
   Counter-intuitively, upstream reports `full` performs **worst**: direct
   exposure to the erroneous reasoning actively harms recovery. This harness
   defaults to `none`, which isolates *state* recovery from *context pollution*.

5. **Grading is unchanged.** The task's own `tests/test.sh` runs in the
   container afterwards and writes a reward. Recovery-Bench changes the starting
   state, not the scoring.

**Held fixed between the arms:** task, image, verifier, timeouts, the OSA
release binary, and the model. The only independent variable is the starting
state of the machine.

---

## What was built here, and what was reused

The guiding constraint was that the fresh arm must run the **unmodified**
Terminal-Bench adapter, or it is not a control.

| piece | origin |
|---|---|
| getting OSA into a container (OTP release, erlexec-as-root, `osagent serve` + HTTP/SSE driver) | **reused** from `bench/terminalbench/` unchanged |
| trajectory parsing, command extraction, replay, recovery preamble | **reused** from upstream `recovery_bench/`, vendored under `upstream/` |
| fault attribution (model vs harness), self-inflicted marker scraping | **reused** from `bench/terminalbench/report.py` |
| `recovery_osa_agent.py` | new — 2 methods: `setup` replays, `run` re-prompts. Same shape as upstream's `RecoveryClaudeCode` |
| `run_bench.py` | new — runs both arms over one identical task list |
| `delta_report.py` | new — the paired delta and its guards |
| `fetch_lfs.py` | new — gets the shared traces without `git-lfs` installed |

The recovery preamble is deliberately **not reworded**. The prompt text is part
of the benchmark; changing it makes the number incomparable.

---

## The three ways this measurement can silently lie

All three are guarded, because each one fails in the direction that flatters OSA.

1. **The arms run different task sets** → the delta becomes a task-difficulty
   artefact. Both arms are handed one identical list, and the reporter computes
   the delta over the **intersection** of tasks that produced a valid result in
   both. `paired_n` is printed next to every delta.

2. **The corruption never happened.** A replay that found no commands, or that
   died halfway, leaves a pristine or unknown machine — a second fresh run
   wearing a recovery label, which shrinks the delta toward zero. Every
   corrupted trial writes `agent/recovery-replay.json` during setup, and a trial
   is **dropped** unless it replayed ≥1 command *and* the replay completed.
   Harbor's `trial.log` does not record these execs, so without that manifest
   there is no durable proof the corruption occurred.

3. **Harness faults pooled with model failures.** OSA failing to boot is not OSA
   failing to recover. `delta_excluding_harness` recomputes over pairs where
   neither arm hit a harness fault; if it disagrees with the headline, the
   headline is partly measuring install reliability.

### A fourth one, found while building this

**Subset selection is not neutral.** The number of replayed commands is a proxy
for how badly the machine was left, and it correlates with wall-clock cost. The
obvious way to make a subset cheap — take the N shortest replays — selects the
*least corrupted* tasks in the universe. `largest-eigenval`, the 2-command
minimum, replays two `print()` verification snippets and leaves an essentially
pristine container. A subset built that way drives the delta toward zero.

`select()` therefore takes a **deterministic stratified sample** across the
replay-length distribution rather than the cheapest N. `--list` shows the
command counts so the spread is auditable before anything runs.

---

## Usage

```bash
# one-time
GIT_LFS_SKIP_SMUDGE=1 git clone --depth 1 \
    https://github.com/letta-ai/recovery-bench.git upstream
./fetch_lfs.py            # shared traces; 179 files, not the 13,726 in the repo

# what would run, and how corrupted each task is
./run_bench.py --list --limit 6

# both arms, same tasks, same model
OSA_DEFAULT_PROVIDER=ollama OLLAMA_URL=http://host.docker.internal:11434 \
OLLAMA_MODEL=glm-5.2:cloud \
./run_bench.py --limit 6 --n-concurrent 2

# rebuild the report from an existing run
./run_bench.py --report-only runs/delta-01
```

This reuses `bench/terminalbench`'s `.venv`, its Terminal-Bench task clone, and
its `dist/` release artefact.

> **Rebuild `bench/terminalbench/dist/` before every run.** The release is a
> snapshot of OSA, and a stale one silently benchmarks old code — including
> bugs that have since been fixed, which then get re-reported as live defects.
> `./build_release.sh --force`, ~5 min.

### Constraints inherited from `bench/terminalbench`

* The ERTS release is built on debian-bookworm (glibc 2.36) and **cannot start
  on bullseye** (glibc 2.31). `qemu-startup` and `qemu-alpine-ssh` are excluded
  explicitly rather than allowed to fail into the harness-fault rate.
* OSA needs `git` present or `FSCheckpoint.Server` takes the application down at
  boot, so the adapter installs it into every container.

### Disk

Task images dominate; the release is 17 MB. A 6-task two-arm run reuses the same
images across arms, so the marginal cost of the second arm is zero. The full
64-task universe would need roughly 40–50 GB of image cache. Disk was **not**
the binding constraint on this machine (497 GB free); wall-clock is.

---

## Reading the output

`results.json` / `summary.md` carry the same honesty flags as `bench/report`:

* **`is_full_corrupted_universe`** — false unless all 64 tasks ran. A subset is
  a pipeline and regression signal, never a Recovery-Bench score.
* **`paired_n`** — the denominator of the delta. A delta over 3 tasks and a
  delta over 60 are not the same claim.
* **`transitions`** — the four-way table. `regressed` (solved fresh, failed
  corrupted) is the cell that *is* the recovery failure; `failed_both` carries
  no recovery information at all, because a task OSA cannot do from scratch
  tells you nothing about its recovery.
* **`fault_owner_counts`** per arm — `model` means OSA worked and the answer was
  wrong; `harness` means OSA or the adapter broke.
* **`self_inflicted_totals` per arm** — the strongest available evidence. A
  marker that is *much more common in the corrupted arm* is OSA getting in its
  own way specifically under recovery, which is the thing this whole directory
  exists to find.
