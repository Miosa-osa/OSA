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

**Bottom line on the number.** Our TB 2.0 denominator does not become 89 by changing datasets or
by moving to Daytona. Roughly 4 tasks are broken by time-rot for everyone, ~2 are our bandwidth,
and 1 is nondeterministic. The honest published form is a per-task excluded-with-cause list —
which is what `controls.py` was already built to produce — plus `-k 5` so the nondeterministic
one stops being a coin flip.
