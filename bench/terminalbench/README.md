# Terminal-Bench 2.0 for OSA

A harness that runs OSA against [Terminal-Bench 2.0](https://www.tbench.ai) —
89 tasks, graded by the official [Harbor](https://www.harborframework.com)
harness, inside the real task containers.

This exists as a **diagnostic instrument**, not a scoreboard. Terminal-Bench is
long-horizon terminal work judged on the final state of a machine, which is
precisely the shape of work where OSA's own defects show up. A low score on hard
tasks is a useful outcome. A score that quietly hides a broken agent install is
not, which is why the reporter separates *the model got it wrong* from *OSA got
in its own way* and refuses to pool them.

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
   tasks. Verified by running the artefact in each base image:

   | base image | glibc | `osagent version` |
   |---|---|---|
   | `ubuntu:24.04` | 2.39 | ok |
   | `python:3.13-slim-bookworm` | 2.36 | ok |
   | `python:3.11-slim` | 2.41 | ok |
   | `debian:13.0-slim` | 2.41 | ok |
   | `debian:bullseye-slim` | 2.31 | **fails** |

   The bullseye failure is hard and unambiguous:

   ```
   erts-14.2.5/bin/erlexec: /lib/x86_64-linux-gnu/libc.so.6:
     version `GLIBC_2.34' not found
   ```

   That is the two `qemu-startup` and `qemu-alpine-ssh` tasks. They are out of
   reach for this artefact and are reported as unsupported rather than silently
   skipped. Fixing it means a second release built on bullseye (or on a
   manylinux-style base), which is a build-matrix change, not a code change.

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

## Usage

```bash
# one-time: harness + task definitions + the OSA release artefact
python3 -m venv .venv && ./.venv/bin/pip install harbor
git clone --depth 1 https://github.com/harbor-framework/terminal-bench-2 tasks/terminal-bench-2
./build_release.sh                      # ~5 min, produces dist/*.tar.gz

# sanity: the oracle solutions must score 1.0, or the harness is broken
./run_bench.py --agent oracle --tasks regex-log

# does OSA even install in the task images? costs no tokens
./run_bench.py --agent osa --install-only --difficulty hard --limit 5

# the real thing
./run_bench.py --agent osa --difficulty hard --limit 8
```

Rebuild `dist/` with `./build_release.sh --force` whenever OSA changes —
**the release is a snapshot, and a stale one silently benchmarks old code.**

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

* **`is_full_dataset_run`** — false unless all 89 tasks ran. A subset is a
  pipeline and regression signal, never a Terminal-Bench 2.0 score.
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
