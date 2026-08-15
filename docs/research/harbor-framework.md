# Harbor: are we running it correctly?

Research pass, 2026-08-15. Revised after a cross-check against a second agent's findings; three
of my own first-pass claims were wrong and are corrected inline with URLs and verbatim quotes.

Sources: `harborframework.com/docs/*`; the upstream repo `harbor-framework/harbor` @ main
(2026-08-14); `harbor-framework/terminal-bench-2` and `-2-1`; the TB 2.0 leaderboard on
HuggingFace; and the Harbor 0.21.0 source installed at
`bench/terminalbench/.venv/lib/python3.12/site-packages/harbor/`.

**Method note.** Two of my first-pass errors came from trusting `WebFetch`'s summary of a
document instead of its bytes. `WebFetch` silently dropped a `# SUBMISSIONS CLOSED` banner from
the top of a README, twice, on two differently-worded prompts. For any document that gates a
published result, fetch the raw bytes and quote them. Every quote below is from raw bytes.

---

## 0. Corrections — including to my own first pass

| Claim | Status | Evidence |
| --- | --- | --- |
| "TB 2.0 and 2.1 submissions are both live" — **my first pass** | **WRONG** | Both are closed. Quotes in §1. I read a summarizer, not the file. |
| "The repo is `laude-institute/harbor`, not `harbor-framework/harbor`" — **my first pass** | **WRONG** | The org moved. `harbor-framework` is canonical; `laude-institute` 301-redirects. §2. |
| "Switching to the canonical Hub dataset recovers several points" — **my first pass** | **WRONG / overstated** | Canonical and legacy are the same task content bar two files. §4. |
| TB 2.0 has no Hub id (`datasets.py:135`, `hub_id=None`; comment at `:22-33`, `:133-134`) | **WRONG (our note)** | `terminal-bench/terminal-bench-2` resolves today: 89 tasks, `sha256:c6fc2e23…`. Downloaded successfully. §4. |
| "TB 2.0 publishes no per-row trial count, so n=1 is fine" | **WRONG (our note)** | Both leaderboards require **≥5 trials per task**. §1. |
| `/docs/migration` implies a breaking version change we're behind on | **WRONG (brief)** | It is a *task-file-format* guide (`task.yaml`→`task.toml`) for `harbor task migrate`. Not a harness migration. |
| We may be on an old Harbor | **No** | 0.21.0 is the newest tag *and* the version on `main` (bumped 2026-08-10). |
| Oracle failures are mostly our machine | **Partly wrong (other agent)** | Byte-identical ≠ would-pass. §3. |
| "`rstan-to-pystan`: canonical Hub *removes* the apt pins, our legacy copy has them" — **§4** | **WRONG, and backwards** | Verified on a fresh `harbor download`: **the Hub copy is the pinned one**, ours is unpinned. So switching datasets would *lose* this task, not recover it. And it fails for neither reason — its oracle dies on `ModuleNotFoundError: pkg_resources`. §4a. |
| "No timeout or resource value changed anywhere" — **§4** | **WRONG** | Three tasks differ, and **ours is more generous in all three**: `crack-7z-hash` 1800s/4096MB vs the Hub's 900s/2048MB, `filter-js-from-html` 4096 vs 2048MB, `gpt2-codegolf` 8192 vs 4096MB. `crack-7z-hash` **passed** in the full-89 run on double the Hub's agent budget. §4a. |
| "Something escaped the exit-0 path; it may be a second bug" — **§9 D2** | **No second bug** | Both `NonZeroAgentExitCodeError`s are the **agent-setup** phase (`agent_execution: null`): `osa_boot_check.py` exits 3 from a separate exec. §9a. |
| "D1: accept `agent_timeout_sec` as a kwarg, per `cline.py`" — **§11.1** | **Not implementable, and the wrong direction** | Harbor passes `agent_timeout_sec` **only when `agent.name == "oracle"`** (`trial/trial.py:822-828`) — our adapter can never receive it. And *deleting* the internal deadline is actively harmful: it is what lets the driver write telemetry and let the verifier grade. §9a. |
| "The 1800s internal deadline pre-empts Harbor" — **§9 D1** | **Backwards in 56 of 89 cases** | At multiplier 2.0 **Harbor pre-empts the driver on 56 of 89 tasks**, hard-killing the exec with no telemetry. §9a. |
| "One `__pycache__`, in `llm-inference-batching-scheduler`" — **§4** | **Understated ~27x** | 27 `__pycache__` directories / 38 `.pyc` files across the task copies. §4a. |
| "D7: cache tokens are counted in `n_input_tokens`, so our figures are inflated" — **the brief for this pass** | **WRONG, and it changes nothing** | The defect was the reverse (we wrote the *uncached* remainder into a field meaning the total), and it moves no published figure: cache measured **0 on all 87 telemetry-writing trials** of the full-89 run. 1,815,273/task and 56.1:1 **stand**. §9b. |
| "Three tasks differ in resources or budget" — **§4a** | **FOUR** | `query-optimize` was missed (verifier 1800 s vs 900 s), and `filter-js-from-html`'s verifier budget is doubled as well as its memory. §9b. |
| "`crack-7z-hash` passed on double the agent budget" — **§4a** | **Inadmissible, but not for that reason** | Its trial records `agent_exec_s = 266.65` — under a third of even the Hub's 900 s. The timeout advantage was never used; only the 2x memory ceiling is unruled-out. §9b. |
| "D4: on tasks with a non-root agent user we write root-owned files" — **§9** | **No such task exists** | All 332 task copies leave `[agent].user` unset, which Harbor defines as the image default (root). D4 stands deliberately and is now guarded. §9b. |
| "The 6 retries died on provider quota" — **the brief for this pass** | **4 of 6** | The other 2 died at agent-setup on `GLIBC_2.34 not found`, already surfaced as `NonZeroAgentExitCodeError`. §9b. |

---

## 1. Contradiction 1 — submission status. I was wrong; the other agent is right.

### TB 2.0 — closed

`https://huggingface.co/datasets/alexgshaw/terminal-bench-2-leaderboard/raw/main/README.md`,
first lines of the file after the YAML front-matter, verbatim:

```
# SUBMISSIONS CLOSED
- All PRs opened before May 14th have been reviewed and merged if valid. If you have already
  run a job, you can use the same files and trajectories in the new submission process once it
  is announced.
- We are working on a new submission process for the Terminal Bench 2.0 Leaderboard. The new
  process will enforce the policies outlined in [this blog post](https://www.tbench.ai/news/leaderboard-integrity-update).
  Check back by end of June for an update.
```

### TB 2.1 — closed

`https://github.com/harbor-framework/terminal-bench-2-1` `README.md`, under
"## Submitting to the leaderboard", verbatim:

> ***Community submissions are currently closed for Terminal-Bench 2.1. Only submissions run by
> the maintainers will be added to the leaderboard at this time.***

`leaderboard/SUBMIT.md` in the same repo, verbatim:

> **Note**
> Community submissions are currently closed for Terminal-Bench 2.1. Only submissions run by the
> maintainers will be added to the leaderboard at this time.

Both documents exist and say exactly what the other agent quoted. My "both live" came from
tbench.ai/leaderboard, where "Live" describes the **leaderboard's display status**, not whether
it accepts submissions. I conflated the two.

### What this does and does not change

It does **not** weaken the requirements finding — it strengthens it. The gating policy is
identical in both places and both are still the published spec:

- **≥5 trials per task.** HF: *"Each task must be evaluated with a minimum of five trials. We
  recommend the `-k 5` flag for convenience."* TB 2.1 `SUBMIT.md`: *"Cover every task, ≥ 5 trials
  each."*
- **No timeout or resource overrides.** HF: *"`timeout_multiplier` must equal `1.0`"*, *"No agent
  timeout overrides (`override_timeout_sec`, `max_timeout_sec`)"*, *"No verifier timeout
  overrides"*, *"No resource overrides"*.
- TB 2.1's CI makes it machine-checkable —
  `leaderboard/src/leaderboard/ci/static_analysis.py:45-71`:
  `EXPECTED_TASK_COUNT = 89`, `MIN_TRIALS_PER_TASK = 5`, and rejection of **all four** per-phase
  multipliers plus `override_setup_timeout_sec` (which the HF prose does not name).
- And the line that independently confirms my §8 grading analysis, from `SUBMIT.md`:
  > Errored trials count as `reward 0` — they are not excluded from the metric.

**The practical read:** we cannot submit to either leaderboard right now regardless of what we
run. So the value of `-k 5` and multiplier hygiene is no longer "admissibility" — it is that a
number produced any other way is **not comparable to the published rows**, and cannot be made
comparable retroactively. Still worth doing, for a different reason than I gave.

**The new process, for when it opens** (TB 2.1 `README.md`, verbatim):

```shell
harbor run -d terminal-bench/terminal-bench-2-1 \
  -a <agent> -m <provider/model> --ak reasoning_effort=<effort> \
  -e <sandbox> -k 5 -n <concurrency> --upload --public
```
then `cd leaderboard && uv run lb submit https://hub.harborframework.com/jobs/<uuid>`.
Results live on Harbor Hub and CI reads them from there — `--upload --public` is mandatory, and
`harbor auth login` is a prerequisite. We currently do none of this.

---

## 2. Contradiction 2 — the org. Both readings were of real pages; the other agent is right.

The org moved from `laude-institute` to `harbor-framework`, with GitHub redirects in place. I
resolved final URLs directly:

| URL requested | Final URL | Note |
| --- | --- | --- |
| `github.com/laude-institute/harbor` | → `github.com/harbor-framework/harbor` | redirect |
| `github.com/laude-institute/terminal-bench` | → `github.com/harbor-framework/**terminal-bench-1**` | redirect **and rename** |
| `github.com/harbor-framework/terminal-bench` | (itself) | a **different** repo — do not confuse with the above |
| `github.com/laude-institute/terminal-bench-2` | → `github.com/harbor-framework/terminal-bench-2` | redirect |
| `github.com/laude-institute/terminal-bench-2-1` | **404** | never existed under the old org |

**Canonical today:** `harbor-framework/harbor`, `harbor-framework/terminal-bench-2`,
`harbor-framework/terminal-bench-2-1`, `harbor-framework/terminal-bench-1` (the old 1.0),
`harbor-framework/terminal-bench` (separate).

This is exactly the failure mode the coordinator described: `gh api` follows redirects silently,
so every byte I read under `laude-institute/*` was genuine current content served under a stale
name. My data was right; my attribution was wrong. The trap to avoid:
`laude-institute/terminal-bench` and `harbor-framework/terminal-bench` are **not** the same repo —
the first redirects to `terminal-bench-1`.

Note that Harbor still ships the stale URL itself:
`harbor/constants.py:10-12` hardcodes
`DEFAULT_REGISTRY_URL = "https://raw.githubusercontent.com/laude-institute/harbor/main/registry.json"`.
It resolves via redirect, so it works — but it is upstream's own stale reference, not a signal
that `laude-institute` is canonical.

---

## 3. Contradiction 3 — the oracle gap. Both findings are true; the inference from one of them is not.

**The reconciliation is the coordinator's: byte-identical to upstream does not imply "would pass
elsewhere."** I can now prove this rather than assert it.

The single cleanest case is `build-pmars`. Its solve script on the **canonical Hub dataset** is
byte-for-byte identical to ours:

```
d85841eb9c849f92a98e366c251e267c  /tmp/hubtb2/terminal-bench-2/build-pmars/solution/solve.sh
d85841eb9c849f92a98e366c251e267c  bench/.../tasks/terminal-bench-2/build-pmars/solution/solve.sh
```

and line 15 of that canonical, identical file reads:

```
    dpkg-dev=1.22.21 \
```

Our trial log shows what happens when that runs today:

```
E: Version '1.22.21' for 'dpkg-dev' was not found
```

The task is unchanged. Debian is not. This will fail on Daytona, on Modal, and on the
maintainers' own hardware, because the failure is in the live apt index, not in the sandbox. So
the other agent's measurement (byte-identical) is correct and their conclusion (therefore our
machine) does not follow.

Revised per-task verdict, from each trial's own `agent/oracle.txt` and
`verifier/test-stdout.txt`:

| Task | Evidence | Cause | Cloud sandbox fixes it? |
| --- | --- | --- | --- |
| `caffe-cifar-10` | `wget` at **98–116 KB/s**, "6m3s" left; `exit-code.txt` empty; `AgentTimeoutError`; task allows 1200 s | our bandwidth | **Yes** |
| `build-cython-ext` | `exit-code.txt` empty (killed mid-`pip install`), yet **10 of 11 tests passed**; 900 s budget | ran out of time installing | **Probably** |
| `protein-assembly` | `dnachisel … NoSolutionError: … Try running the solver on the same sequence again` | nondeterministic | No — `-k 5` absorbs it |
| `build-pmars` | `E: Version '1.22.21' for 'dpkg-dev' was not found` | frozen apt pin vs live index | **No** |
| `make-doom-for-mips` | apt failed ("try with `--fix-missing`") → `make: clang: No such file or directory` | same class | **No** |
| `mcmc-sampling-stan` | `Error in library(rstan) : there is no package called 'rstan'` | CRAN install failed | **No** |
| `rstan-to-pystan` | output files never created; solve.sh pins `build-essential=12.10ubuntu1`, `gfortran=4:13.2.0-7ubuntu1`, … | frozen apt pins | **No — but see §4** |

**2 environmental, 1 nondeterministic, 4 time-rot.** Daytona recovers ~2 of 7, not 7. An
`exit-code.txt` that is empty is the tell for a timeout kill — `OracleAgent` writes that file
only after the exec returns (`agents/oracle.py:150-153`).

---

## 4. The dataset question — and the retraction of my biggest claim

I claimed the canonical Hub dataset would fix the bit-rot and recover several points. **I
downloaded it and diffed it. It does not.**

`harbor download terminal-bench/terminal-bench-2` → 89 tasks, then
`diff -rq` against our local legacy copy. Across all 89 tasks, the **only** differences outside
`README.md`, `.gitignore` and `task.toml` are:

```
Only in hub:    install-windows-3-11
Only in local:  install-windows-3.11          # a rename
Only in local:  LICENSE
Only in local:  llm-inference-batching-scheduler/tests/__pycache__
Files differ:   overfull-hbox/solution/solve.sh
Files differ:   rstan-to-pystan/solution/solve.sh
```

And the `task.toml` differences are pure serialization churn — `schema_version = "1.1"` +
`artifacts = []` + `[environment.env]` versus `version = "1.0"`, and TOML list formatting.
**No timeout or resource values changed anywhere.** Verified for all 7 failing tasks:

```
build-cython-ext    hub 900/900/600   ==  local 900/900/600
build-pmars         hub 900/900/600   ==  local 900/900/600
caffe-cifar-10      hub 1200/1200/600 ==  local 1200/1200/600
make-doom-for-mips  hub 900/900/600   ==  local 900/900/600
mcmc-sampling-stan  hub 1800/1800/600 ==  local 1800/1800/600
protein-assembly    hub 1800/1800/600 ==  local 1800/1800/600
rstan-to-pystan     hub 1800/1800/600 ==  local 1800/1800/600
```

So: **6 of our 7 failing tasks are byte-identical on the canonical dataset** (matching the other
agent's "5 of 6"), and switching datasets changes nothing for them.

**The one genuine recovery.** `rstan-to-pystan/solution/solve.sh` differs, and it differs in
precisely the interesting direction — the canonical version **removes** the frozen apt pins:

```diff
-    build-essential=12.10ubuntu1 \        (our legacy copy)
-    gfortran=4:13.2.0-7ubuntu1 \
-    libatlas-base-dev=3.10.3-13ubuntu1 \
+    build-essential \                     (canonical Hub)
+    gfortran \
+    libatlas-base-dev \
```

That is upstream fixing exactly this bit-rot class. So the canonical dataset plausibly recovers
**1 task** (`rstan-to-pystan`), not several. `build-pmars` keeps its `dpkg-dev=1.22.21` pin even
on canonical and stays broken.

**Revised expectation for TB 2.0 on canonical + Daytona: ~85–86/89 oracle, not 89.** Residual
unsound: `build-pmars`, `make-doom-for-mips`, `mcmc-sampling-stan`, and `protein-assembly`
intermittently.

**Still worth switching**, for provenance rather than points: the canonical id is content-hash
pinned and is what CI compares against (TB 2.1's
`leaderboard/src/leaderboard/core/hub.py:26-27` pins
`DATASET = "terminal-bench/terminal-bench-2-1"`,
`DATASET_REF = "sha256:7d7bdc1cbedad549fc1140404bd4dc45e5fd0ea7c4186773687d177ad3a0699a"` —
byte-identical to what I resolved from the Hub, so our resolution path is correct).

**Also found in our local copy, and worth fixing:**
`tasks/terminal-bench-2/llm-inference-batching-scheduler/tests/__pycache__` exists. Harbor
uploads the whole `tests/` directory into the container (`verifier/verifier.py:133-238`), so we
ship stale host-compiled bytecode into a grading environment. Harmless in the common case,
silent contamination in the bad one.

---

## 4a. Corrections to §4, from re-measurement (2026-08-15, implementation pass)

Everything in this section was re-derived from a **fresh**
`harbor download terminal-bench/terminal-bench-2` rather than from the earlier
`/tmp/hubtb2` copy. Three of §4's claims do not survive.

### The `rstan-to-pystan` diff is backwards

§4 presents a diff showing canonical *removing* the apt pins. It is the other
way round. Verbatim from the two files:

```
canonical Hub  rstan-to-pystan/solution/solve.sh:22   build-essential=12.10ubuntu1 \
our local copy rstan-to-pystan/solution/solve.sh:22   build-essential \
```

So the "one genuine recovery" is in fact a **one-task regression** if we switch.
It is moot either way: our unpinned copy's oracle still fails, and not on apt at
all —

```
File "/opt/py310/lib/python3.10/site-packages/stan/plugins.py", line 4, in <module>
    import pkg_resources
ModuleNotFoundError: No module named 'pkg_resources'
```

`setuptools` is absent from the image. Neither pin set touches that.

### Resource and timeout values *did* change — in our favour

§4 states "**No timeout or resource value changed anywhere**" and lists seven
tasks whose values match. Across all 89, three do not:

| Task | Canonical Hub | Our local copy |
| --- | --- | --- |
| `crack-7z-hash` | 900 s / 2048 MB | **1800 s / 4096 MB** |
| `filter-js-from-html` | 1800 s / 2048 MB | 1800 s / **4096 MB** |
| `gpt2-codegolf` | 900 s / 4096 MB | 900 s / **8192 MB** |

Our copy is the more generous one in every case, and on the two divergent
`task.toml` values our copy matches **our TB 2.1 copy exactly** — the legacy git
pin `69671fb` (2025-10-31) is *later* than the Hub package, and picked up
2.1-era fixes. The two are different snapshots of one line, not two versions.

This one changes a number: **`crack-7z-hash` passed in the full-89 run with
double the agent budget the Hub package allows.** Both leaderboards forbid
timeout and resource overrides; running a task copy that already carries larger
values is the same thing arriving by a route that never appears in
`config.json`.

### The `__pycache__` count was understated by ~27x

Not one directory — **27 `__pycache__` directories and 38 `.pyc` files**, spread
across `terminal-bench-2`, `terminal-bench` and `harbor-index`. Every one was
stamped the same day and named `cpython-312-pytest-9.1.1`; the fresh Hub
download contains zero, so all 38 were ours. Cause: **the repo had no pytest
configuration**, so a bare `pytest` from `bench/` collected the benchmark
tasks' own `tests/test_*.py`, imported them on the host, and left the bytecode
inside the directories Harbor uploads into the grading container.

Fixed: `bench/pytest.ini` (`norecursedirs`) stops the collection,
`datasets.py check [--fix]` detects and removes, and `run_bench.py` refuses to
launch a run while a selected task copy is dirty.

---

## 9a. Corrections to §9, from implementation (2026-08-15)

### D2 — there is no second bug

§9 notes that the full-89 run produced two `NonZeroAgentExitCodeError` cases and
that "something escaped this path entirely". Nothing did. Both are the
**agent-setup** phase, not the run phase — `agent_execution` is `null` on both
trials, and the message names the culprit:

```
Command failed (exit 3): python3 -u /installed-agent/osa_boot_check.py ...
[osa-boot-check] FAIL: serve exited during boot with code 1
```

`osa_boot_check.py` is a separate exec during `setup()`, and its exit code was
never routed through the driver. Two further points settled while checking:

- The `| tee` in the run command does **not** swallow the exit code: Harbor
  prefixes every exec with `set -o pipefail` (`agents/installed/base.py:836`),
  and the main service is wrapped in `bash -c`, not `sh -c`
  (`environments/docker/docker_unix.py:205`). Verified independently by
  `runs/osa-first/.../regex-log`, where the driver's own `return 3` **did**
  surface as `NonZeroAgentExitCodeError`.
- So `osa_headless.py:505` really was the whole of D2, and fixing it is
  sufficient.

**The measured cost of D2**, which §9 asserts but does not quantify:
`runs/rerun-timeouts-f6981b61` — the retry of the timed-out tasks — recorded
**4 of 4 trials as `provider_error`, every one with `exception_info: null` and
`reward: 0.0`**. Four infrastructure failures billed to the model, on the run
whose entire purpose was to retry them.

### D1 — the recommendation is not implementable, and points the wrong way

§11.1 says to accept `agent_timeout_sec` as a kwarg "per `cline.py:114`" and
delete the internal deadline. Both halves are wrong:

1. **Harbor will never pass it.** `trial/trial.py:822-828` populates
   `extra_kwargs["agent_timeout_sec"]` only when
   `self.config.agent.name == AgentName.ORACLE.value`. §7 states this correctly
   ("only for the oracle") — §11.1 contradicts §7.
2. **Deleting the internal deadline destroys evidence.** Harbor's `wait_for`
   cancels the exec where it stands: no telemetry, no session cancel, no exit
   code, and the trial is recorded as `no_telemetry_written`. The driver's own
   deadline is what allows a graceful cancel, a written telemetry file, and a
   verifier run against the work already on disk — and on the full-89 run **2 of
   the 5 trials that hit the driver's deadline scored reward 1.0**.

The real defect is the opposite of the one described. Because the deadline was a
fixed 1800 s base, which clock won was an accident of the task's declared
budget. At `--timeout-multiplier 2.0`, **Harbor pre-empted the driver on 56 of
89 tasks**; the driver only won on the 33 whose own budget was ≥ 1800 s.
`gpt2-codegolf` is the worked example: 900 s budget → Harbor at 1800 s against
the driver's 3600 s → `AgentTimeoutError`, `no_telemetry_written`, attribution
lost.

Fixed by resolving the task's own `timeout_sec` host-side — the trial directory
is named `<task>__<suffix>` and the adapter runs on the host — and setting the
driver's deadline a grace margin *under* Harbor's. Measured after the change:
**89 of 89 tasks now have the driver firing first.**

---

### Dataset resolution, canonically

Three sources, discriminated in `DatasetConfig` (`models/job/config.py`):

| Form | Predicate | Route |
| --- | --- | --- |
| `-d org/name[@ref]` | `is_package()` — contains `/` | **Harbor Hub**, content-hash pinned |
| `-d name@version` | `is_registry()` — bare name | **legacy** `registry.json` → git URL + commit pin |
| `-p /path` | `is_local()` | local directory |

The legacy `terminal-bench@2.0` row pins git commit `69671fba` of
`harbor-framework/terminal-bench-2`, dated **2025-10-31**. `run_bench.py:59` bakes that in as
`DEFAULT_LEGACY_DATASET`. The canonical form is `-d terminal-bench/terminal-bench-2`.

---

## 5. Version

**0.21.0 is current** — newest tag and the version on `main`. `main` carries ~40 unreleased
commits; none change grading, reward parsing or result schemas. Worth knowing:

- **`harbor leaderboard` was removed** (submit + validation flow, and the `harbor.leaderboard`
  package), superseded by `harbor hub leaderboard`. Any script of ours referencing it is dead.
- **Hub auth moved to personal API keys** (`sk-harbor-…` in `~/.harbor/credentials.json`).
  Existing logins are not carried over; re-run `harbor auth login`. `HARBOR_API_KEY` still wins.
  `harbor.auth.session/handler/api_key` are gone.
- Egress-control kernel probe on Linux clients was fixed (it was skipped, so
  `network_mode = "allowlist"`/`"no-network"` were accepted against kernels that could not
  enforce them; symptom was an opaque `dependency failed to start`).
- `task.toml` `schema_version` is now `"1.4"`; packages gained `[task].version` /
  `[dataset].version`. Our local copy is on `1.1`/`version = "1.0"` — see §4.

---

## 6. Concurrency and trials

- **`-n`/`--n-concurrent` cannot affect grading directly.** Default is `4`
  (`models/job/config.py:362-369`) — we already match it. It bounds concurrent `Trial` objects;
  each has its own container, reward file and timeouts. Its only path to a score is CPU/IO
  contention making a timeout more likely, which argues for keeping `-n` *low* locally, not for
  copying the docs' `-n 32` (which assumes cloud sandboxes where trials are I/O-bound).
- **`-k`/`--n-attempts` is the trials knob**, orthogonal to retries. Default `1`; both
  leaderboards require ≥5. Harbor computes pass@k automatically when every reward dict is
  single-keyed with values in `{0,1}` (`utils/pass_at_k.py:41-51`). We produce none.

---

## 7. Timeouts (Harbor's)

Four multiplier-aware timeouts, resolved in `Trial._init_timeouts()` (`trial/trial.py:1094-1140`):

| Timeout | Default | Defined | Bounds |
| --- | --- | --- | --- |
| agent execution | `None` (task-declared; TB 2.0 uses 900–1800 s) | `models/task/config.py:340` | `agent.run()`/`resume()`/`load()` (`trial/trial.py:484-487`) |
| verifier | 600 s | `models/task/config.py:562` | all of `verify()` — upload, run, download, parse |
| agent setup | 360 s (class constant, **not** task-configurable) | `trial/trial.py:81` | `agent.setup()` |
| environment build/start | 600 s | `models/task/config.py:422` | `compose build` + `up --wait` |

```python
resolved = multiplier if multiplier is not None else self.config.timeout_multiplier
return min(base_sec, max_sec or inf) * resolved          # trial/trial.py:433-443
```
Flags: `--timeout-multiplier` (global, 1.0) plus `--agent-`, `--verifier-`, `--agent-setup-`,
`--environment-build-timeout-multiplier` (`cli/jobs.py:378-421`); a per-phase value replaces the
global for that phase. `max_timeout_sec` is applied **before** multiplication, so it is not a
hard ceiling.

**Not scaled by anything:** healthcheck (30 s × 3, and the healthcheck *loop* is unbounded,
`trial/trial.py:404`); collect hooks (60 s, failures swallowed); tar upload/download execs
(120 s hardcoded, `environments/base.py:994,1018,1051,1096,1117`); `docker info` preflight (10 s);
egress kernel probe (30 s). Non-Docker environments build with the **raw** unmultiplied
`build_timeout_sec` (`environments/modal.py:789`, `ec2.py:1103`, `gke.py:1988`). The verifier's
test-script exec has **no per-command timeout** (`verifier/verifier.py:199-202`).

**What an adapter can override:** only its own `environment.exec(..., timeout_sec=…)`, and
`override_setup_timeout_sec` if it consumes that kwarg (`agents/factory.py:169-171`; OpenClaw
does at `agents/installed/openclaw.py:394,405`).
**What it cannot:** the agent-execution wall clock. Harbor passes `agent_timeout_sec` into the
constructor **only for the oracle** (`trial/trial.py:822-828`) and exports no `HARBOR_*_TIMEOUT`
into the container. An adapter is simply not told its budget.

Outcomes (`trial/errors.py:4-17`): an **agent** timeout is caught inside the phase
(`single_step.py:82-84`) and **the verifier still runs** — graded, usually 0, with
`exception_info` set. **Verifier / setup / environment-start** timeouts propagate, leave
`verifier_result` `None`, and are unscored-and-errored.

---

## 8. Grading

`Verifier.verify()` (`verifier/verifier.py:133-238`) uploads `tests/` to `/tests`, runs
`test.sh` as `environment.default_user`, downloads `/logs/verifier`, and parses the reward:
`reward.json` (flat `{key: number}`) beats `reward.txt` (bare float) (`:227-236`). Rewards are
`dict[str, float|int]` — **not binary by contract**, though task templates make them binary.
Harbor ignores the test script's exit code entirely: the script **must** write the reward file or
the trial errors (`RewardFileNotFoundError` / `RewardFileEmptyError`). Default aggregation is
`Mean` (`job.py:737-739`).

`OracleAgent` (`agents/oracle.py:18-160`) uploads `solution/`, runs `solve.sh`, and writes the
exit code — but **does not raise on non-zero** (`:150-153`). Expected reward **1.0**.
`NopAgent` (`agents/nop.py:8-33`) does nothing; expected **0.0**. Ours is clean: 0/89 on both
2.0 and 2.1.

**Errored ≠ excluded.** `job.py:935-939` stores `None` for a missing `verifier_result`;
`metrics/base.py:26-34` maps `None → 0`; `Mean` divides by the full trial count. Confirmed
independently by upstream's own submission guide: *"Errored trials count as `reward 0` — they are
not excluded from the metric."* An infrastructure hiccup silently depresses a published score.

**Retries.** `max_retries` defaults to **0** (`models/job/config.py:281-311`).
`exclude_exceptions` defaults to `{AgentTimeoutError, VerifierTimeoutError,
RewardFileNotFoundError, RewardFileEmptyError, VerifierOutputParseError, ApiUsageLimitError,
AgentSafetyRefusalError, AgentAuthenticationError, ModelNotFoundError}` and beats
`include_exceptions`. Not excluded: `AgentSetupTimeoutError`, `EnvironmentStartTimeoutError`,
`HealthcheckError` — the design is "retry infrastructure, never retry the agent".

---

## 9. Our adapter vs the contract

Ranked. Nothing here has been applied; `bench/` is owned by another agent.

### Changes a result

**D1. A hidden 1800 s agent deadline that Harbor cannot see, scaled by a private env var.**
`bench/terminalbench/osa_agent.py:118` (`DRIVER_RUN_TIMEOUT_BASE = 1800`), mirrored at
`bench/terminalbench/driver/osa_headless.py:49`, scaled from `OSA_BENCH_TIMEOUT_MULTIPLIER`
(`osa_agent.py:153`), set by `run_bench.py:456-458`. Effective budget is
`min(Harbor's timeout, 1800 × ours)`.
Note the collision: `mcmc-sampling-stan`, `protein-assembly` and `rstan-to-pystan` all declare
`timeout_sec = 1800.0`, so our cap lands exactly on theirs and can pre-empt them.
This is an undeclared override — worse than the named ones the CI rejects, because it never
appears in the submitted `config.json`. Canonical: `agents/installed/cline/cline.py:114,281-300`
takes `agent_timeout_sec` as a kwarg and defaults its internal deadline to Harbor's.

**D2. The driver exits 0 on every failure.** `driver/osa_headless.py:505` returns `0` for
`timeout`, `stream_closed_without_done`, `orchestrate_rejected` and any `turn_error`; only boot
failure returns 3 (`:313`). `osa_agent.py:502-511` therefore sees success and
`BaseInstalledAgent._exec`'s classifier (`agents/installed/base.py:842-851`) never runs — none of
`ERROR_PATTERNS` (`:441-515`) can fire. A rate limit that every other adapter surfaces as an
error is recorded for us as a legitimate reward-0, and retries are inert. Canonical:
`agents/installed/opencode.py:524-527` raises `NonZeroAgentExitCodeError` when the stream carried
error events despite exit 0.

**D3. The permission-mode command's failure is never checked.**
`driver/osa_headless.py:323-328` posts `permission_mode overdrive` and only logs the status:
```python
st, body = _req("/api/v1/commands/execute",
                {"command": "permission_mode overdrive", "session_id": SESSION}, timeout=30)
log(f"overdrive -> HTTP {st} {body[:160]}")
```
The comment above it says that without it the run "parks on an approval nobody can answer or
fails closed on every mutating tool" — so a silent non-200 is a task-wide zero indistinguishable
from a model failure. Reference adapters make this part of invocation:
`codex.py:1437` (`--dangerously-bypass-approvals-and-sandbox`), `opencode.py:518`,
`claude_code.py:126-135`.

**D4. Everything runs as root.** `osa_agent.py:341,349,379,407,415,430,456` (install) and
`:483,502` (run) use `exec_as_root`. Harbor wraps the run in
`with self.agent_environment.with_default_user(user)` (`trial/trial.py:464`) so that
`exec_as_agent` picks up `task.config.agent.user` (`agents/installed/base.py:875-886`). On tasks
with a non-root agent user, or whose verifier checks ownership, we write root-owned files.
Canonical: `opencode.py:106,501,511`; `claude_code.py:437,1754,1771`; `codex.py:355,1364,1429`.

**D5. `run()` lacks `@with_prompt_template`.** `osa_agent.py:469-475` has `@override` only, and
nothing calls `self.render_instruction()`, so `--agent-prompt-template` is silently ignored.
Canonical: `opencode.py:475-477`, `codex.py:1331-1333`, `claude_code.py:1599-1601`.

**D6. `mcp_servers` and `skills_dir` are dropped.** Harbor injects both when a task or job
declares them (`trial/trial.py:828-840`); `osa_agent.py` reads neither. A task shipping an MCP
server or skill runs against an agent that cannot see it, and is still scored. Canonical:
`claude_code.py:1530-1542,1559-1585`, `opencode.py:425-473`.

**D7. `n_input_tokens` excludes cache.** `osa_agent.py:554-558`. `AgentContext.n_input_tokens` is
documented as "including cache" (`models/agent/context.py:9-11`) and every reference adapter
folds cache-read and cache-creation in (`claude_code.py:755-759`→`:1526`;
`opencode.py:301,308`→`:421`). Doesn't move resolve-rate; makes every token and cost figure we
publish incomparable, understating input by most of the prompt.

### Non-idiomatic

- **D8.** No trajectory export, `SUPPORTS_ATIF = False` (`osa_agent.py:192-193`) — blocks
  `harbor view`, Hub trajectory viewing, `harbor analyze`, handoff, **and the `--upload --public`
  submission path** that both new leaderboard flows require.
- **D9.** Ablation/effort switches read `os.environ` directly (`osa_agent.py:165-171,318,153`)
  instead of `self._get_env(...)`, so `--ae OSA_VERIFICATION_ADEQUACY=0` has no effect while
  `--ae OLLAMA_URL=…` does (`:269` is correct). Precedence: `agents/installed/base.py:583-590`.
- **D10.** No `CLI_FLAGS`/`ENV_VARS` descriptors (`osa_agent.py:196-211` uses raw kwargs) —
  `OSA_BENCH_EFFORT` is textbook `CliFlag(type="enum", env_fallback=...)`.
- **D11.** `parse_version` missing `@override` (`osa_agent.py:229`); duplicate
  `OSA_DEFAULT_PROVIDER` lines in the generated dotenv (`:272-277`).
- **D12.** `-n 4` is fine and already the default; no change needed.

---

## 10. What we could be using and are not

`-k 5`; `-d terminal-bench/terminal-bench-2`; `--upload --public` + `harbor auth login` (required
by both new submission flows); `harbor view jobs` (local viewer for trials, trajectories, token
breakdowns, artifacts, job comparison — overlaps our `report.py`/`failure_shape.py`);
`harbor hub job list/show/tasks/trials/compare` with `--failed-only` and `--include-retries`;
`harbor analyze <job-dir>`; **`harbor run --regrade`** (re-score an existing job without re-running
agents — directly useful for re-baselining); `--ak`/`--ae`; artifact collection and
`[[verifier.collect]]` hooks; `--load-trajectory` / `harbor trial handoff`.

---

## 11. Exact changes needed

Ordered by value. `bench/` is owned by another agent — these are for them to apply.

1. **`bench/terminalbench/osa_agent.py:118,153`** and **`driver/osa_headless.py:49`** — delete the
   1800 s internal deadline and the `OSA_BENCH_TIMEOUT_MULTIPLIER` scaling; accept
   `agent_timeout_sec` as a kwarg (per `cline.py:114,281-300`) and let Harbor's `wait_for` be the
   only clock. Drop `run_bench.py:456-458`.
2. **`driver/osa_headless.py:505`** — return non-zero on `timeout`,
   `stream_closed_without_done`, `orchestrate_rejected`, `turn_error`, with messages matching
   `ERROR_PATTERNS` (`agents/installed/base.py:441-515`); or raise `NonZeroAgentExitCodeError`
   from the adapter as `opencode.py:524-527` does.
3. **`driver/osa_headless.py:323-328`** — fail hard if `permission_mode overdrive` is not 200.
4. **`run_bench.py:413-437`** — add `-k` (5 for anything intended for publication) and record
   `n_attempts` in `config.json`.
5. **`datasets.py:135`** — set `hub_id = "terminal-bench/terminal-bench-2"`; correct the comments
   at `:22-33` and `:133-134`; stop defaulting to `DEFAULT_LEGACY_DATASET` (`run_bench.py:59`).
   Expect **~1 task recovered** (`rstan-to-pystan`), not several — this is a provenance fix, not a
   score fix.
6. **Delete `tasks/terminal-bench-2/llm-inference-batching-scheduler/tests/__pycache__`** and
   re-pull the dataset from the Hub rather than carrying a hand-managed copy.
7. `osa_agent.py` install/run — use `exec_as_agent` except where root is genuinely needed.
8. `osa_agent.py:469` — add `@with_prompt_template`.
9. `osa_agent.py:554-558` — fold cache tokens into `n_input_tokens`.
10. `osa_agent.py` — honour `self.mcp_servers` and `self.skills_dir`.
11. `osa_agent.py:165-171,318,153` — route env reads through `self._get_env`.
12. Re-run oracle/nop controls on canonical TB 2.0, ideally on a cloud sandbox, and record the
    residual unsound set per task. Expect **~85–86/89**, not 89.

---

## 12. What a 5-trial run costs, measured

`-k 5` is now wired through `run_bench.py`, and the reporter distinguishes
pass@1 from pass@k. **No 5-trial run has been launched** — the numbers below are
extrapolated from the k=1 full-89 run at `runs/osa-tb20-full89-f6981b61`
(`ollama/glm-5.2:cloud`, effort `medium`, `--timeout-multiplier 2.0`, `-n 4`),
so they are a projection from measurement, not a measurement.

Measured baseline, k=1:

| Quantity | Value |
| --- | --- |
| Job wall-clock | **3.37 h** |
| Summed trial wall-clock | 13.07 h |
| Observed parallel speed-up at `-n 4` | **3.88x** (near-linear) |
| Median / mean / max trial | 5.0 / 8.8 / 31.4 min |
| Cost | **$92.85** over the 86 trials that reported one ($1.08/trial) |

Projected at `-k 5` (445 trials), holding `-n 4` and the same 3.88x:

| Quantity | Projection |
| --- | --- |
| Summed trial wall-clock | 65.4 h |
| **Job wall-clock** | **≈ 16.9 h** |
| **Cost** | **≈ $480** (445 x $1.08) |

Raising `-n` is the obvious lever and should be resisted: this box has 24 cores
and 62 GB, and TB 2.0 tasks declare up to 8 GB each, so `-n 8` is near the
memory limit — and §6 is right that concurrency reaches the score only by making
timeouts more likely, which biases in the exact direction we are trying to
measure. At `-n 4` a 5-trial run is an overnight job, not an afternoon one.

**The decision this needs.** ~17 h and ~$480 buys the only version of our number
that is admissible under either leaderboard contract, plus the first real
measurement of how much of our run-to-run variance is noise. Both are currently
unknown, and the second is the one that decides whether any tuning delta we have
quoted is real.

---

## 9b. Corrections to §9, from the implementation pass of 2026-08-15 (D4–D11)

Every claim below was re-derived from Harbor 0.21.0's installed source and from
the run artefacts, not from this document. **Four of §9's claims do not
survive**, and one of §4a's is understated.

### D7 was stated backwards, and it changes none of our published figures

§9 D7 says "`n_input_tokens` excludes cache". That is the correct diagnosis of
the *defect* (we wrote the uncached remainder into a field documented as the
total) — but the framing under which this pass was commissioned, that "cache
tokens are counted in `n_input_tokens`" and our figures are therefore inflated,
is the opposite of what was on disk. Both readings imply the published number is
wrong. **It is not.**

Measured across `runs/osa-tb20-full89-f6981b61`, all 87 trials that wrote
telemetry: `cache_read_input_tokens = 0` and `cache_creation_input_tokens = 0`
on every one. `ollama/glm-5.2:cloud` reported no cache tokens at all. And
`report.py` has summed `input + cache_read + cache_write` for
`input_tokens_per_task` since before the run. So:

| Figure | Published | Corrected | Change |
| --- | --- | --- | --- |
| input tokens / task | 1,815,273.4 | **1,815,273.4** | none |
| in:out ratio | 56.1:1 | **56.1:1** | none |
| `cache_read_tokens_total` | 0 | 0 | none |

Re-derived through the corrected reader: `161,559,329 / 89 = 1,815,273.4` and
`161,559,329 / 2,878,654 = 56.1`. Both stand exactly as quoted.

What was genuinely broken is the **adapter's** `AgentContext`, which is what
Harbor Hub, `harbor view` and any external consumer read. Fixed in
`osa_agent.py::populate_context_post_run`. The magnitude it would have had on a
caching provider is measurable: `runs/anthropic-cache-probe-20260814` recorded
101,547 uncached input against 2,320,315 cache reads over 3 trials — a **23x**
understatement. The uncached remainder now rides in
`metadata.osa_uncached_input_tokens`, and its absence is what lets `report.py`
identify a pre-D7 artefact and re-derive it unchanged (verified: the archived
run re-scores to identical figures).

Schema evidence, verbatim: `models/agent/context.py:9-11` — *"The number of
input tokens used including cache."* `models/trajectories/final_metrics.py:11-14`
— *"Sum of all prompt tokens across all steps, including cached tokens"*.
`claude_code.py:755-759` computes `input + cache_read + cache_creation` with the
comment *"Align with Anthropic session totals"*. `n_cache_tokens` is a **subset**
of `n_input_tokens`, not a sibling (`claude_code.py:1526-1527`).

### §4a undercounted the non-conforming tasks: it is FOUR, not three

Re-measured by diffing all 89 `task.toml` files against the retained Hub
download, comparing `[agent].timeout_sec`, `[verifier].timeout_sec`,
`[environment].memory_mb`, `.cpus`, `.storage_mb`:

| Task | Ours (agent / verifier / mem) | Hub | Result in full-89 |
| --- | --- | --- | --- |
| `crack-7z-hash` | 1800 s / 900 s / 4096 MB | 900 / 900 / 2048 | **PASSED** |
| `filter-js-from-html` | 1800 / **1800** / 4096 | 1800 / 900 / 2048 | failed |
| `gpt2-codegolf` | 900 / 900 / **8192** | 900 / 900 / 4096 | failed |
| **`query-optimize`** | 900 / **1800** / 2048 | 900 / 900 / 2048 | failed |

§4a missed `query-optimize` entirely and recorded `filter-js-from-html` as a
memory-only divergence when its **verifier** budget is doubled too. `cpus` and
`storage_mb` match on all 89.

**And the reason `crack-7z-hash` passed is not the extra budget.** Its trial
records `agent_exec_s = 266.65` — under a third of even the Hub's 900 s limit,
which the doubled budget was therefore never used to exceed. The memory half
(4096 vs 2048 MB) is a ceiling rather than a consumable and cannot be ruled out
without a re-run. So the task is **inadmissible** — it ran on a copy no
leaderboard would accept — but the specific claim "it passed on double the
budget" is not supported by its own timing.

This is now machine-checked rather than written down:
`datasets.NONCONFORMING_TASKS` pins the Hub half, `check_conformance()`
re-derives the local half from disk, `run_bench.py` refuses to launch on drift,
and `report.py` marks every affected row `void` with a quotable reason.

### The measured effect of the void set on the headline

```
raw            49 / 89 = 55.1%          (unchanged; still printed first)
excluding void 48 / 85 = 56.5%
```

Only `crack-7z-hash` moves the numerator; the other three failed and could not
have been helped. The raw rate is deliberately **not** overwritten — a shrinking
denominator nobody can audit is the failure mode, and it is no better done in
our favour than against us.

### D4 stands, deliberately, and is now guarded

§9 D4 says root-everywhere writes root-owned files "on tasks with a non-root
agent user". **No such task exists in anything we hold**: all 332 task copies —
89 TB 2.0, 89 TB 2.1, 80 Harbor-Index, 74 terminal-bench — leave `[agent].user`
unset, and Harbor documents unset as *"the environment's default USER (e.g.,
root)"* (`models/task/config.py:341-344`). `exec_as_agent` and `exec_as_root`
therefore resolve to the same user on every task in the house.

It is also not swappable: `install()` writes
`-erlexec root true user root limit_users [root]` into the release's `vm.args`
because erlexec refuses to start its port program as root without an explicit
effective user. A non-root run against that `vm.args` fails to boot rather than
running correctly. The adapter now **raises** if a task ever declares a non-root
agent user, so the first one produces an attributed error instead of a silent
ownership divergence.

### D6 is not academic — but not on Terminal-Bench

Measured: **0 of 89** TB 2.0 tasks and **0 of 89** TB 2.1 tasks declare
`mcp_servers` or `skills_dir`, so this has never altered a Terminal-Bench
number. It bites on the benchmark we were about to run: **5 of 80 Harbor-Index
tasks** (`gaia2-adapt-hard-1`, `-hard-2`, `gaia2-ambiguous`, `gaia2-timed-1`,
`-2`) declare an `are` server over `streamable-http`, and
`terminal-bench/medical-claims-processing` declares `playwright` over `sse`. A
Harbor-Index run made before this fix would have scored six tasks the agent was
structurally unable to attempt.

`mcp_servers` is now written to `~/.osa/mcp.json`, which is OSA's own
Claude-Desktop-compatible format (`mcp/config.ex:3-13`); Harbor's three
transports collapse to OSA's two without loss because OSA's remote transport
probes StreamableHTTP and falls back to legacy SSE
(`mcp/transport/http.ex:3-15`). **Untested against a live MCP task** — the file
is verified against OSA's parser, not against an `are` sidecar.
`skills_dir` is **refused**, not implemented: Harbor ships Anthropic-style
`SKILL.md` folders and OSA reads `~/.osa/skills/<slug>.json`, so copying would
look like support without being it.

### D10 is mostly inapplicable, and the applicable part was a real hazard

`CLI_FLAGS` builds a command line for an agent binary (`base.py:706-722`). This
adapter never builds one — `osagent serve` is started by the driver and driven
over HTTP — so descriptors for `provider`/`port`/`boot_timeout_sec` would be
ceremony. **`effort` is different.** OSA does not reject an unknown rung: it
logs "ignoring unknown [model].effort" and boots at its default, so
`OSA_BENCH_EFFORT=hgih` produced a run that completed normally and recorded a
pin it did not have — on the axis Anthropic measures at 10.3 pp and cline at
11.2 pp on this exact model. Now an `EnvVar(type="enum", choices=[...])`
descriptor, which rejects it at construction and makes `--ak effort=high` and
`OSA_BENCH_EFFORT=high` the same pin.

### D9's consequence, named

`--ae OSA_VERIFICATION_ADEQUACY=0` was accepted, recorded in `config.json`, and
had **no effect on the run**, because `ablation_env()` read `os.environ`
directly and skipped the first two of Harbor's three precedence sources
(`base.py:583-590`). That is a silently-void ablation, not a style point. All
five direct `os.environ` reads now route through `OsaAgent._env`.

### The quota classification, verified end to end

The 6 retries at `runs/rerun-timeouts-f6981b61` were **not** all quota deaths:
**4 died on provider quota** (`Ollama returned 429: ... you have reached your
session usage limit`), and **2 died on a GLIBC mismatch** at agent-setup
(`erlexec: /lib/x86_64-linux-gnu/libc.so.6: version 'GLIBC_2.34' not found`) —
a bookworm/bullseye artefact problem, already surfaced as
`NonZeroAgentExitCodeError`.

The exit-code fix now classifies the four correctly, and this was verified by
running Harbor's own `_classify_exec_error` over the driver's real output rather
than by inspection. **It did not work on the first try**, and the reason is
worth recording: `_classify_exec_error` keeps the match with the greatest END
OFFSET in stdout+stderr (`base.py:792-798`), not the first pattern in table
order. The driver's line read `classified: <phrase> (osa category=rate_limit)`,
and `rate_limit` in that trailing annotation matches `rate.?limit` — so the
annotation out-ranked the phrase and every quota death was still classified
`ApiRateLimitError`, which is **not** in `exclude_exceptions` and is therefore
retried against a wallet that will not refill. With the phrase moved last:

```
quota      -> exit 7, "Quota exceeded."  -> ApiUsageLimitError   excluded=True
transient  -> exit 7, "rate limit"       -> ApiRateLimitError    excluded=False
```

All seven `_CATEGORY_PHRASE` entries were re-checked under the new ordering; none
regressed. `report.py` additionally splits `provider_quota_exhausted` out of
`provider_error`, keeps it out of the model's column, and prints a loud line
under the headline naming the affected tasks.

---

**Bottom line on the number.** Our TB 2.0 denominator does not become 89 by changing datasets or
by moving to Daytona. Roughly 4 tasks are broken by time-rot for everyone, ~2 are our bandwidth,
and 1 is nondeterministic. The honest published form is a per-task excluded-with-cause list —
which is what `controls.py` was already built to produce — plus `-k 5` so the nondeterministic
one stops being a coin flip.
