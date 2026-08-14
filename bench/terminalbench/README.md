# Harbor benchmarks for OSA

A harness that runs OSA against [Terminal-Bench](https://www.tbench.ai) and the
other datasets in the [Harbor](https://www.harborframework.com) registry, graded
by Harbor itself, inside the real task containers.

**The dataset is a flag, and it is recorded.** See `datasets.py`:

| key | set | tasks | status |
|---|---|---|---|
| `tb2.1` | Terminal-Bench 2.1 | 89 | **current, default** |
| `tb3` | Terminal-Bench 3 (continuous) | 74 | current |
| `harbor-index` | Harbor-Index | 80 | current |
| `tb2.0` | Terminal-Bench 2.0 | 89 | superseded — kept on purpose |
| `tb-pro` | Terminal-Bench Pro (public) | 200 | legacy registry only, not fetched |

```bash
./datasets.py list          # what is defined, and what is actually on disk
./datasets.py sync tb2.1    # (re-)download from the Harbor Hub
./datasets.py diff tb2.0 tb2.1
```

This used to be hard-coded to a local clone of **2.0**, which is superseded: 2.1
modified 26 of the same 89 tasks (27 differ byte-for-byte on disk — see
`datasets.DIFF_TB20_TB21`). A historical failure on one of those 27 may be an
artefact of a task that has since been fixed, and there is no way to tell after
the fact. 2.0 stays runnable so old results remain re-derivable and the 2.0-2.1
delta can be attributed rather than guessed.

### How these datasets resolve (and why `harbor dataset list` will mislead you)

Harbor has two resolution paths and only one is current.

* **Legacy registry** — `registry.json` in the harbor repo, mirrored to a public
  Supabase table. `harbor download name@version`, `harbor run -d name@version`.
  80 datasets. **Its newest Terminal-Bench entry is 2.0.** It has no 2.1, no 3,
  and no Harbor-Index, and `harbor dataset list` reads from it.
* **Harbor Hub** — `harbor download org/name[@ref]`, `harbor run -d org/name`.
  This is where the current datasets live:
  `terminal-bench/terminal-bench-2-1`, `terminal-bench/terminal-bench`,
  `harbor-index/harbor-index`.

Verified 2026-08-14 against Harbor **0.21.0**, which is the newest release
(published 2026-08-10). So this is not fixed by upgrading Harbor — the legacy
registry is simply stale, and the Hub path is the one to use.

### Controls are not optional

```bash
./controls.py run --dataset-key tb2.1     # oracle + nop, no model, free
./controls.py status
./controls.py gate runs/<osa-run>         # exit 1 if the run's tasks are unsound

# a sweep can be run in slices, or salvaged after an interruption
./controls.py import --dataset-key tb2.1 --agent oracle <harbor-job-dir>
```

`oracle` runs each task's own reference solution and must solve everything;
`nop` does nothing and must solve nothing.

An oracle miss is reported as one of **two kinds**, because they are different
problems with different remedies and pooling them is the mistake this whole
harness exists to avoid:

* **`graded_wrong`** — the verifier ran and returned < 1.0. The task does not
  pass with its own reference solution. Exclude it from every denominator.
  *Observed here:* `build-cython-ext` on TB 2.1 — 10 of 11 verifier tests pass;
  `test_pyknotid_repository_tests` shells out to the upstream repo's own suite
  and gets one failure back.
* **`infrastructure`** — no reward was written at all; Harbor raised. The task
  is probably fine and the machine is not. **Retry**, and if it recurs, record
  it as a property of the host. *Observed here:*
  `torch-pipeline-parallelism` — `VerifierTimeoutError`, having spent its entire
  900 s budget pulling ~2.5 GB of CUDA wheels (torch 825 MB, cudnn 544 MB,
  cublas 375 MB) without reaching a single test.

That second kind is the local reproduction of the thing the Harbor-noise
critique describes. It is not hypothetical and it is not rare.

**The split is a proxy, and it under-reports the infrastructure side.** It keys
on "was a reward written", so a task whose *reference solution* fetches from a
live third-party index fails outside the container's control and still lands in
`graded_wrong`. `mcmc-sampling-stan` is the specimen: its `solve.sh` installs
rstan from CRAN at solve time, CRAN did not serve `StanHeaders`/`RcppParallel`,
so `/app/analysis.R` was never written and 4 of 6 tests failed on the missing
artefact. Nothing about that task is broken. Notably TB **2.1's own change to
that task was to unpin the apt versions of `gfortran`/`liblapack-dev`/
`libblas-dev`** — a fix for exactly this class of problem, one layer lower, that
did not reach the CRAN layer. Read `graded_wrong` as "exclude this task", never
as "upstream shipped a broken task", without opening the oracle log first. Anything the oracle misses is a task
broken *on this machine*, and an OSA failure on it is not evidence about OSA.
Anything `nop` solves is a free point every agent collects. Neither calls a
model, so there is no budget argument for skipping them. This is the same
discipline `bench/swebench` already applies with gold-apply and empty-patch.

### The fixed cost probe

```bash
./probeset.py show tb2.1
./run_bench.py --agent osa --probe
./probeset.py compare runs/<before> runs/<after>

# N arms at once, every arm re-priced from tokens at the SAME rates
./probeset.py arms "before=runs/a,runs/a2" "after=runs/b"
```

Eight tasks that never change, so token and cost figures across optimisation
attempts are **paired**. Reports `input_tokens/task`, `in:out ratio`,
`cache_hit_rate` and `$/task` — the four columns the field publishes. It is not
a pass-rate measurement and the reporter refuses to call it one.

`arms` exists because `compare` reads each run's stored `cost_usd`, and runs on
either side of the 2026-08-14 pricing fix stored dollars computed at rates up to
3x apart. `arms` ignores the stored figure and re-derives every arm's `$` from
its token counts at one rate table, so a dollar delta is a real dollar delta and
not a pricing-bug artefact. It also folds multi-job arms (a `hard6` plus a
`long4`) into one arm, and shouts if the solve rate dropped — fewer tokens with
fewer solves is not a cost win.

#### One-variable ablations: flip a switch, do not rebuild

An arm built from an older commit is not an arm. Between `a18732dd` and the
commit before the verification-adequacy gate there are also the workspace fix,
the doom-loop work and the tool-perf changes, so "rebuild without the feature"
moves four things and prices none of them. The way to price one feature is to
run the **same artefact twice** and flip its runtime kill switch.

`osa_agent.OSA_ABLATION_ENV_KEYS` is the list of switches forwarded from the
host process into the container, on both seams that reach the agent
(`~/.osa/.env`, and the `env=` of the run exec which becomes `osagent serve`'s
OS environment). Whatever is set is recorded into the run's `config.json` as
`ablation_env`, so an arm can state its own switches.

```bash
OSA_VERIFICATION_ADEQUACY=0 ./run_bench.py --agent osa --probe \
  --model ollama/glm-5.2:cloud --run-id probe-adequacy-off-a18732dd
```

**Prove the flag arrived.** A flag that never left the host and a flag that
arrived and did nothing produce the same null result, and nothing in the numbers
distinguishes them. Three receipts, all cheap:

1. `config.json` → `ablation_env` — the run asked for it.
2. `grep '\[ablation\]' runs/<id>/harbor/*/*/agent/osa-driver.log` — one line
   per trial, printed by the driver *inside the container* immediately before
   `osagent serve` is spawned, from the env it is about to hand over.
3. a behavioural difference in the logs. For this switch,
   `grep -o 'verification-gate\] [a-z_]*'` over the agent dirs: the `off` arm
   must show **zero** `inadequate_test`, and should still show
   `unchecked_write`, because the flag covers clause 3 only. Both together
   prove the gate was live *and* the one clause was off — a silent whole-gate
   failure would show neither.

Verified directly against the pinned artefact, which is the layer all three
receipts assume works:

```
$ OSA_VERIFICATION_ADEQUACY=0 osagent/bin/osagent_release eval \
    'IO.puts(inspect(System.get_env("OSA_VERIFICATION_ADEQUACY")))'
"0"
```

**What the adequacy ablation measured** (2026-08-15, artefact `8cb0e2b3…`,
8 tasks, `-n 2`, `probe-workspacefix-a18732dd` vs `probe-adequacy-off-a18732dd`):

| slice | input tok/task, gate ON → OFF | turns |
|---|---|---|
| all 8 | 5,814,330 → 5,441,540 (**-6.4%**) | 415 → 291 |
| the 6 that finished inside their agent timeout | 1,281,310 → 990,617 (**-22.7%**) | 229 → 168 |
| the 4 short tasks where the clause actually fired | 1,201,248 → 824,897 (**-31.3%**) | 154 → 105 |
| `dna-assembly` (control: clause never fired) | 1,846,598 → 1,939,261 (**+5.0%**) | 41 → 39 |

The gate is expensive where it fires and it does not fire on the expensive
tasks. `make-mips-interpreter` and `path-tracing` are **83.5%** of the bill and
both run to the 1800 s ceiling either way; the clause fired once on the first
and never on the second. So it is not the cause of the arm-2→arm-3 token
doubling, and the run-level -6.4% badly understates its cost on ordinary work.

The `6/8 → 5/8` is not a lost solve. `make-mips-interpreter` died to
`AgentTimeoutError` at **1838 s** against an **1800 s** ceiling it cleared by
29 s in the ON arm. Both arms failed exactly the same two tasks on the model
(`dna-assembly`, `cancel-async-tasks`); excluding harness faults it is 6/8 vs
5/7. **A verdict on a task sitting on its timeout is a coin flip, and neither
arm's number for those two tasks should be read as a measurement.**

**Scope: this switches clause 3 of the completion gate, not the whole feature.**
`8afcfb36` also added `VerificationGate.first_write_nudge/1`, wired through
`Agent.Reminders` collector 5, and that is **not** covered by
`OSA_VERIFICATION_ADEQUACY` — it fires once per session in both arms. The
ablation prices the end-of-turn pushback with the early test-first steer held
constant.

#### Workspace-denial counters

`report.py` reads the `fault_owner: :osa` stamp that
`Permissions.denial_fault_owner/3` puts on tool calls OSA refused for a path
**inside the session's own workspace**, off both the `tool_call` phase-`end` and
`tool_result` frames, de-duplicated per `tool_call_id`. A failed task carrying
that stamp is reported as `osa_workspace_denied` and owned by the **harness**,
not the model.

That stamp existed and nothing read it. `Agent.Safety.PathPolicy` allowed writes
only under `~` and `/tmp` and never consulted the working directory, so in a
container with `HOME=/root` and a workspace of `/app` every workspace
`file_write`/`file_read`/`dir_list` was denied — 142 denials on one task, `cp`
shuttles as a workaround, one episode telling a headless benchmark to type
`/add-dir /app`. The published harness fault rate for that run was 0.0%.

Four counters travel with every run, per task and in the aggregate:

| counter | what it means |
|---|---|
| `osa_tool_faults` | OSA refused a path **inside** the workspace. Any non-zero value is a harness bug. |
| `denials` | every path refusal the model saw. A refused `/etc/shadow` belongs here and **not** above — that is the boundary working. |
| `add_dir_mentions` | the give-up signature. A headless episode cannot type a slash command, so asking for one means the agent has concluded its workspace is unreachable. |
| `write_ops` / `peak_context_tokens` | the shape of the workaround. The `cp` shuttle inflates both. |

A task that **passed** is never relabelled by these counters — the verifier is
the authority on whether the work got done — but its obstruction is still
reported, because a scraped pass is not evidence the bug is gone.

This exists as a **diagnostic instrument**, not a scoreboard. Terminal-Bench is
long-horizon terminal work judged on the final state of a machine, which is
precisely the shape of work where OSA's own defects show up. A low score on hard
tasks is a useful outcome. A score that quietly hides a broken agent install is
not, which is why the reporter separates *the model got it wrong* from *OSA got
in its own way* and refuses to pool them.

### Corrections to `docs/research/what-harnesses-benchmark.md`

That document was assembled from web sources. Checked against the installed
Harbor on 2026-08-14, four of its claims are wrong or misleading. They do not
change its conclusions, but they change what a reader should expect to happen
when they type the command.

1. **"Everything we want to run is one `--dataset` flag away."** Not for the
   datasets it recommends most. Terminal-Bench 2.1, Terminal-Bench 3 and
   Harbor-Index are **not in the legacy registry** the installed Harbor's
   `dataset list` and `-d name@version` read, and querying it for them returns
   "Dataset not found". They resolve only through the Hub path
   (`harbor download org/name`), which is a different, undocumented-in-that-doc
   command shape. It is still one flag once you know which flag.
2. **Harbor-Index is 80 tasks, not 82.** Upstream's own README says 80, and 80
   is what downloads. The `harbor-index.org` figure of 82 is stale; released
   tags run `harbor-index-1.1` … `1.4`.
3. **Terminal-Bench 2.1 fixed 26 tasks, not 28.** Upstream README: "26 tasks
   were modified". A byte comparison of the two task trees finds 27 differing
   (`datasets.DIFF_TB20_TB21`); either way, not 28.
4. **Harbor-Index cannot be fully graded without an Anthropic key.** The doc
   presents it as the cheap instrument and says nothing about this. Its own
   `job-config.yaml` pins an LLM-judge verifier — `claude-opus-5`, 3 votes —
   for the `hle-*`, `omnimath-*`, `gaia2-*` and `widesearch-*` families, and
   says they "crash with '... must be set' without all three JUDGE_* vars".
   That is **16 of the 80 tasks**. On a machine with no key the gradeable
   denominator is 64, which is a different benchmark from the leaderboard's,
   and `controls.py` records the skip explicitly rather than letting the
   denominator move quietly.

Two further things the doc did not mention that matter for running it:
Terminal-Bench 3 is a **continuous** benchmark whose `@latest` moves, so a run
has to pin its task copy or two runs are not comparable; and Terminal-Bench 2.1
**closed community leaderboard submissions** (maintainer-run only), so our
number can be compared against that board but never added to it.

---

## How Terminal-Bench actually works

Not the marketing version:

* **A task is a directory**, not a dataset row:

  ```
  regex-log/
    task.toml               metadata, timeouts, docker_image, cpus/memory, allow_internet
    instruction.md          the prompt, verbatim
    environment/Dockerfile  the image (all 89 are prebuilt and published)
    solution/solve.sh       the oracle solution
    tests/test.sh           the verifier
  ```

* **Grading inspects the container, not a diff.** `tests/test.sh` runs *inside
  the task container after the agent has finished* and writes a float to
  `/logs/verifier/reward.txt`. Most tasks run pytest via `uvx` and write 1 or 0.
  There is no patch, no `git diff`, and nothing the agent returns as text is
  read. If the machine is not in the right state, the reward is 0.

* **The agent must therefore run inside the container.** Harbor's
  `BaseInstalledAgent` gives two hooks:

  * `install(environment)` — runs before the episode. `exec_as_root` /
    `exec_as_agent` / `environment.upload_file` are the tools.
  * `run(instruction, environment, context)` — runs the agent against the
    instruction, still inside the container.
  * `populate_context_post_run(context)` — optional, lifts token/cost telemetry
    back out into Harbor's `AgentContext`.

  Every stock adapter (`claude_code`, `codex`, `pi`, `fx`, `grok_build`) is the
  same three methods: install from npm or a `curl | sh` installer, then exec the
  agent's own headless flag with the instruction shell-quoted, then parse the
  agent's JSON output for usage. This adapter mirrors that shape exactly.

* **Timeouts are per task**, in `task.toml`: `agent.timeout_sec` (900–7200) and
  `verifier.timeout_sec`. Harbor multiplies them with
  `--agent-timeout-multiplier`.

* **Custom agents** are selected by import path: `-a module:ClassName`, with the
  module on `PYTHONPATH`. There is no registration step.

---

## How OSA gets into a container, and why this way

OSA is an Elixir/OTP application. The task images are arbitrary Linux
(41× `python:3.13-slim-bookworm`, 40× `ubuntu:24.04`, plus a few debian slims).
Three routes were evaluated:

| route | verdict |
|---|---|
| Install Erlang+Elixir in the task container and build OSA there | **Rejected.** ~800 MB of apt plus a multi-minute compile *per task*, requiring network egress a task may not have, and it mutates the environment under test before the agent starts. |
| Run OSA on the host, drive the container through a thin shim | **Rejected.** The agent's shell would not be the graded container's shell. The exact failure modes worth hunting (long-horizon recovery, compaction, truncated tool output) would be measured against a fake terminal. |
| **Ship a self-contained OTP release with bundled ERTS** | **Chosen.** |

OSA already produces exactly this artefact — `mix release osagent`, see
`.github/workflows/release.yml` — and it needs no Elixir, no Erlang and no
toolchain on the target. It is **17 MB** and installs in about 20 s per trial.

### The two constraints that route has

1. **ERTS is native code.** A release built on this host (Ubuntu 24.04,
   glibc 2.39) will not start on a bookworm image (glibc 2.36); glibc is not
   forward compatible. So `build_release.sh` builds the release *inside a
   debian-bookworm container* (`Dockerfile.release`), which covers 87 of the 89
   tasks. `debian:bullseye-slim` (glibc 2.31) is the exception — that is the two
   `qemu-startup` and `qemu-alpine-ssh` tasks.

   **Verify with the boot check, never with `osagent version`.** `bin/osagent
   version` is `<release> eval OptimalSystemAgent.CLI.version()`, and a Mix
   release's `eval` starts the VM *without* starting the OTP application tree:
   no supervisor `init/1` runs and no boot-time NIF is loaded. An artefact whose
   `version` passes on every image can still fail to boot on all of them — that
   is exactly what happened on one 89-task run (`install_or_boot_failed`
   everywhere, charged to the model). `driver/osa_boot_check.py` boots `serve`
   and waits for `/health`, which is the capability the episode actually needs,
   and it runs as part of `install()`.

   Measured with that check (2026-08-14, release 1.0.97):

   | artefact | `debian:bullseye-slim` | `python:3.13-slim-bookworm` | `ubuntu:24.04` |
   |---|---|---|---|
   | `dist/` (bookworm build) | not tested (glibc 2.31 < 2.36) | boots | boots |
   | `dist-bullseye/` (`--bullseye`) | boots | boots | boots |

   The bullseye variant needs two things beyond a base-image swap, both now in
   `Dockerfile.release.bullseye`: the vendored-library wiring below (bullseye has
   `libcrypto.so.1.1`, no `.so.3`), and `config :exqlite, force_build: true` —
   exqlite prefers a **precompiled** `sqlite3_nif.so` that requires `GLIBC_2.33`,
   so merely building on bullseye still produces an artefact that dies at boot
   with ``version `GLIBC_2.33' not found``. It is a config key read at build
   time, not an env var, so `EXQLITE_FORCE_BUILD=1` does nothing.

   `dist-bullseye/` is built separately (`./build_release.sh --bullseye`) and
   never overwrites `dist/`.

   **Vendored libraries.** `Dockerfile.release*` copies `libcrypto`/`libssl`/
   `libtinfo` out of the build image into `<release>/vendor/`. That is only
   useful if the loader looks there, so `install()` appends to the release's
   `releases/<vsn>/env.sh`:

   ```sh
   export LD_LIBRARY_PATH="$RELEASE_ROOT/vendor${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
   ```

   Without it the crypto NIF resolves against the task image's system
   `libcrypto.so.3` (measured: `/usr/lib/x86_64-linux-gnu/libcrypto.so.3`), which
   is an undeclared dependency on the environment. The boot check's
   `--require-vendor` asserts the running VM mapped the release's own copy.

2. **The release has no one-shot headless mode.** `bin/osagent` dispatches
   `chat | setup | serve | doctor | version` and nothing else. The one-shot path
   (`mix osa.run --format stream-json`) is a Mix task, and Mix tasks are not
   shipped in a release. So the adapter boots `osagent serve` *inside* the
   container and drives it over OSA's own HTTP/SSE API with
   `driver/osa_headless.py` — the same real entry point `bench/swebench`'s http
   transport uses. Nothing is mocked.

---

## OSA defects this harness had to work around

These are **OSA bugs, not benchmark quirks**. They are worked around here so the
benchmark can run at all; they should be fixed in OSA.

### 1. OSA cannot boot as root — hard blocker for any container

```
Not allowed to run as root without setting effective user (-user option)! [exec.cpp:598]
** (MatchError) no match of right hand side value:
     {:error, {:erlexec, {{:shutdown, {:failed_to_start_child, :exec,
       {:port_exited_with_status, 4}}}, ...}}}
   (optimal_system_agent 1.0.95) lib/optimal_system_agent/cli.ex:44
```

`erlexec` starts unconditionally as an OTP application dependency, and its C
port program refuses to run as root unless an effective user was explicitly
requested. Every Terminal-Bench container — and every stock Docker image — runs
as root. `CLI.serve/0` then `MatchError`s on the failed
`ensure_all_started`, so the whole application dies at boot.

Only `OpenComputers.Executor.Direct.PTY` uses erlexec, so OSA takes a total boot
failure for a feature almost nothing in a headless run touches.

Workaround applied in `osa_agent.py`: set the setuid bit on `exec-port` and
append to the release's `vm.args`:

```
-erlexec root true user root limit_users [root]
```

Note the app-env key is **`erlexec`**, not `exec` — `exec_app.erl` reads
`application:get_env(erlexec, ...)` while the OTP application is named `exec`.
`USER=root` and `SHELL` must also be set in the environment or the port program
exits 4 regardless.

**Suggested fix:** make erlexec optional (start it lazily from the PTY executor,
or `Application.ensure_started` with a rescue), and never `MatchError` on
application start in `CLI.serve/0`.

### 2. Missing `git` takes the whole application down

```
** (ErlangError) Erlang error: :enoent
    System.cmd("git", ["--no-pager", ..., "init"], cd: "/root/.osa/fs_checkpoints")
    lib/optimal_system_agent/fs_checkpoint/server.ex:285 ensure_shadow_repo/1
    lib/optimal_system_agent/fs_checkpoint/server.ex:203 init/1
```

`FSCheckpoint.Server.init/1` shells out to `git` and does not rescue `:enoent`.
On any image without git, the exception propagates through
`Supervisors.Extensions` and OSA refuses to boot. Worked around by installing
git into every task container — which is a real modification of the environment
under test and should not have been necessary.

**Suggested fix:** rescue `:enoent` and degrade to checkpoints-disabled.

### 3. ESSENTIAL context blocks are silently dropped — and both tasks it hit, failed

OSA's own log, on `dna-assembly`, all within the same millisecond:

```
[warning] [Context] ESSENTIAL context block truncated: label=ws:tools
    wanted=1367tok kept=812tok — the model will NOT see all of this block.
[warning] [Context] ESSENTIAL context block dropped: label=ws:environment       wanted=77tok  kept=0tok
[warning] [Context] ESSENTIAL context block dropped: label=ws:context_guidance  wanted=140tok kept=0tok
[warning] [Context] ESSENTIAL context block dropped: label=ws:apps              wanted=716tok kept=0tok
[warning] [Context] ESSENTIAL context block dropped: label=ws:agent_roles       wanted=774tok kept=0tok
```

The model was handed a partial tool list and no environment description, and
OSA continued as if nothing had happened. Across 10 hard tasks this fired on
exactly two — `dna-assembly` and `make-mips-interpreter` — **and those are two of
the three tasks that failed.** The other seven never dropped a block; six of
them passed.

n=2 is a lead, not a proof. But a defect that degrades the prompt and reports
itself only as a warning line is exactly the failure this benchmark exists to
surface, and it should be treated as a blocker until the correlation is
disproved. Tracked as the `essential_context_dropped` marker.

### 4. The stall detector fires constantly on normal work

`[doom] Stall detected — escalate-only (autonomous mode), continuing` fired
**224 times across 6 of 10 tasks**, including four that passed — 81 times on
`path-tracing` alone. It is no longer halting turns (escalate-only), so it is
currently harmless, but a detector that fires on most successful long-horizon
work is not measuring what it thinks it is. If anything ever re-arms it to halt,
it will halt healthy runs.

### 5. Overdrive does not bypass the circuit breaker

```
[error] [loop] CIRCUIT-BREAKER blocked shell_execute: force-push to a protected
    branch is never permitted (mode=overdrive, tier=full, session: ...)
```

Four times on `configure-git-webserver`, in `mode=overdrive`. Overdrive is
documented as full-auto. The task passed anyway, but a task that legitimately
needs the blocked operation has no recourse and no way to tell the operator why.

### 6. Context grows unbounded; no prompt caching at all

Per-turn input tokens on `make-mips-interpreter` grew from 20.8k on turn 1 to
**143.7k by turn 154**, for **13.8M input tokens on a single task**. Across ten
hard tasks: **39.2M input tokens against 281k output — a 140:1 ratio.**

`cache_read_tokens` and `cache_creation_tokens` were **0 on every single task**.
Whether that is OSA not requesting caching or the Ollama path not reporting it
is not established here and must be checked against a hosted provider before
being called an OSA bug — but with a priced provider these volumes are the
difference between a cheap benchmark run and an unaffordable one.

### 7. Two OSA telemetry sources disagree

The summed `cost_update` SSE frames and `~/.osa/sessions/<id>.spend.json`
disagree on input tokens by 0–6.6% depending on the task. Both are recorded in
`osa-telemetry.json` (`usage_sum` vs `spend_sidecar`) rather than silently
reconciled, so the divergence stays visible.

### 8. `serve` prints the wrong port

`CLI.serve/0` prints `Application.get_env(@app, :http_port, 9089)` rather than
the port actually bound by `Net.Port` (which honours `OSA_HTTP_PORT`). With
`OSA_HTTP_PORT=19899` it binds 19899 and prints `OSA serving on :9089`.
Cosmetic, but it is the line an operator reads when diagnosing a port problem.

---

## The one externally comparable arm

Every number this harness has produced so far is on a 6–8 task subset, single
run, against a noise floor where a task flips 4-pass/2-fail with no code change.
None of it is comparable to anything published. **There is exactly one external
comparison available to us**, and it is worth stating its terms precisely
because they are what the arm has to match.

cline published a full Terminal-Bench 2.0 dataset — 89 tasks, pass@1,
`openrouter:z-ai/glm-5.2`, reasoning medium, `--timeout-multiplier 2.0`, Modal,
June 24–25 2026 (`cline/benchmark-results`,
`terminal-bench/2026-06-open-weights`):

| harness | GLM-5.2, same 89 tasks |
|---|---:|
| **cline CLI 3.0.29** | **68.5%** (61/89) |
| opencode 1.17.9 | 59.6% (53/89) |
| pi 0.73.1 | 57.3% (51/89) |
| cline CLI, reasoning **off** | 57.3% (51/89) |

That last row is the one to keep in view: **reasoning off costs the same model
11.2 points under an unchanged harness** — larger than the 11.2-point spread
across all three harnesses. Which is the same lesson Anthropic's Opus 4.6 system
card teaches from the other direction (10.3 points across effort tiers, versus a
7.2-point harness delta on the same 89 tasks). **Effort is the bigger lever, and
it must be pinned before a harness number means anything.**

### What the arm must set, and why each one

```bash
./run_bench.py --agent osa \
  --dataset-key tb2.0 \          # cline ran 2.0. 2.1 corrects 26 tasks -> different denominator
  --timeout-multiplier 2.0 \     # the GLOBAL one, as cline used. Not --agent-timeout-multiplier
  --effort <tier> \              # recorded; see below for whether it reaches the wire
  --ollama-think true            # the dial that DOES reach the wire on our path
```

`--effort` and `--ollama-think` are two dials because they are not one dial.
`--effort` pins OSA's own ladder via `~/.osa/config.toml` `[model].effort`
(toml-only; `ConfigFile.effort/0` has no json or env equivalent), which governs
`max_iterations` and internal gating and reaches the wire on Anthropic
(`output_config.effort`) and OpenAI-compat (`reasoning_effort`). **It does not
reach the wire on Ollama at all** — `Providers.Ollama` has no effort→thinking
wiring, only a boolean `think` field read from `OLLAMA_THINK`. Measured against
the live daemon on `glm-5.2:cloud`: the same prompt costs 137 output tokens at
`think: true` and 3 at `think: false`, and unset behaves as on.

### Differences that will remain, and must be published with the number

These cannot be closed on this machine, so the honest move is to name them
rather than to imply they are absent.

| | cline | us |
|---|---|---|
| serving path | OpenRouter `z-ai/glm-5.2` | **`ollama/glm-5.2:cloud`** |
| advertised context | 1M | 976K |
| quantisation / tool template | OpenRouter's | Ollama's, unknown |
| reasoning control | `reasoning: medium` | boolean `think` — **no medium tier exists** |
| trials | 1 (pass@1) | 1 (pass@1) |
| date | 2026-06-24/25 | 7+ weeks later |

There is no OpenRouter key on this machine, so the serving path is not a choice
we are making — it is the only one available. **cline's 68.5% is therefore not a
number we are entitled to expect**, in either direction: the quantisation and
tool-call template differ, and GLM-5.2 has documented, model-specific tool-call
defects (template tokens leaking into `function.name`, streamed argument
corruption producing valid JSON with wrong values, missing tool-call deltas —
see `docs/research/benchmark-models.md` §7.4) whose incidence is a property of
the serving path, not of the harness.

### And the arm is still one run

89 tasks, pass@1. At 60% that is a 95% Wilson interval of roughly ±10 points —
`summary.md` prints it. **cline's 68.5% sits inside the interval of anything we
score from about 58% upward**, so a result in that band is not a gap and must
not be reported as one. What n=89 buys is not precision; it is that one task
flipping is no longer the whole result, which at n=6 it was.

---

## Usage

```bash
# one-time: harness + task definitions + the OSA release artefact
python3 -m venv .venv && ./.venv/bin/pip install harbor
./datasets.py sync                      # all Hub datasets into tasks/
./build_release.sh                      # ~5 min, produces dist/*.tar.gz

# controls FIRST. No model, no cost. Nothing below is interpretable without them
./controls.py run --dataset-key tb2.1
./controls.py status

# does OSA even install in the task images? costs no tokens
./run_bench.py --agent osa --install-only --difficulty hard --limit 5

# the real thing, on the CURRENT task set
./run_bench.py --agent osa --difficulty hard --limit 8

# the cheap cross-agent instrument
./run_bench.py --dataset-key harbor-index --agent osa --limit 8

# the standing cost probe (same 8 tasks every time)
./run_bench.py --agent osa --probe

# a long run needs a witness for the provider. See "quota death", below
./quota_watch.py watch --out runs/<run-id>/quota-watch.jsonl &

# and then, before quoting anything
./controls.py gate runs/<run-id>
./quota_watch.py report runs/<run-id>/quota-watch.jsonl
```

Rebuild `dist/` with `./build_release.sh --force` whenever OSA changes —
**the release is a snapshot, and a stale one silently benchmarks old code.**

### Quota death

A provider that stops serving mid-run does not announce itself. Every trial
after the cutoff still gets scheduled, still writes a trial directory, and still
scores zero — and in `results.json` those zeros are indistinguishable from a
model that tried and failed. On a run that takes most of a day, an exhaustion at
hour three converts the back half of the dataset into fabricated model failures,
and the whole thing reads as a bad score rather than as a broken run.

`quota_watch.py` samples the provider on a fixed interval and appends one
timestamped line per sample; `report` folds the failures into outage windows.
Any trial overlapping a window has a zero that is not attributable to the model.
A 200 serving an empty completion counts as down — that is the shape quota
exhaustion takes on some gateways, and treating it as healthy is how the failure
gets missed.

It deliberately does **not** abort the run. Killing hours of work on one failed
probe is a judgement call, and probes fail for reasons a run survives; what this
buys is the ability to make that judgement afterwards, which a run that merely
died does not.

### Disk

Task images are pulled on demand and are smaller than they look: 11 tasks
(including the two largest hard ones) came to **6.7 GB** total —
`make-mips-interpreter` 2.1 GB and `path-tracing` 1.5 GB are the outliers, the
median is ~120 MB. Extrapolating, a full 89-task run needs roughly **50–60 GB**
of image cache. Disk is not the binding constraint on this machine; wall-clock
and tokens are. `docker builder prune -f` reclaims the release-build cache
(~9 GB) without touching task images.

### Provider configuration

OSA inside the container reads `~/.osa/.env` and `~/.osa/config.json`, both
written by the adapter from the host process environment. For a host-local
Ollama:

```bash
OSA_DEFAULT_PROVIDER=ollama \
OLLAMA_URL=http://host.docker.internal:11434 \
OLLAMA_MODEL=glm-5.2:cloud \
./run_bench.py --agent osa --tasks regex-log
```

`host.docker.internal` does not resolve in Harbor's compose network by default;
`compose-host-provider.yaml` adds the host-gateway alias and is passed
automatically for the `osa` agent. Leave it off for a hosted API — it widens what
the task container can reach, which a benchmark should do deliberately.

---

## What the numbers mean

`results.json` / `summary.md` carry the same honesty flags as `bench/swebench`:

* **`dataset_key` / `dataset_label` / `dataset_status`** — which task set this
  is, stamped from the run config. `benchmark` is no longer the hard-coded
  string `terminal-bench-2.0` on every artefact regardless of what ran.
* **`is_full_dataset_run`** — false unless every task in *that dataset* ran
  (89 for 2.x, 80 for Harbor-Index, 74 for TB3). A subset is a pipeline and
  regression signal, never a score.
* **the cost columns** — `input_tokens_per_task`, `in_out_ratio`,
  `cache_hit_rate`, `cost_usd_per_task`. These are the four the field
  publishes. `cache_hit_rate` is `None` when the adapter emitted no cache
  counter and `0.0` when it emitted one and it was zero; those are different
  facts and the summary renders them differently.
* **the controls** — separate from `results.json` and, deliberately, not
  produced by the run itself. `controls.py gate` is what says whether the tasks
  in this run were sound. A run that has not been gated is not a result.
* **`fault_owner_counts`** — the important one. `model` means OSA worked and the
  answer was wrong; `harness` means OSA or this adapter broke and the episode
  never had a fair chance; `ambiguous` is timeouts, where a real internal
  ceiling and a slow model are indistinguishable from outside.
* **`harness_fault_rate`** — anything above zero means the headline accuracy is
  understated by that much.
* **`self_inflicted_totals`** — markers scraped from OSA's own log inside each
  container (compaction ran, tool result truncated, dispatch died, stall
  detector fired, turn ended without a terminal frame). A **signal, not a
  verdict**; one that recurs across tasks is a bug report waiting to be written.

Per-task raw material is kept: `runs/<id>/harbor/<job>/<trial>/agent/` holds
`osa-serve.log` (OSA's full boot + run log), `osa-events.jsonl` (every SSE
frame), `osa-telemetry.json` and `osa-driver.log`.
