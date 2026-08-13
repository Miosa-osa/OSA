# Head-to-head: OSA vs. competing harnesses, same tasks, same model

This runs OSA and several competing agent harnesses over **the same
Terminal-Bench 2.0 tasks, against the same model, under the same limits**, and
reports where each one won, where each one lost, and — the part that actually
matters — **whose fault each loss was**.

It is the only honest comparison available to us, and this file explains why.

---

## Why not just compare our number to a published one

Because a published number and our number are not measurements of the same
thing, and putting them side by side produces a difference that is mostly
methodology.

`bench/report/METHODOLOGY.md` documents this in detail. The short version:

* **Scaffold alone moves SWE-bench by 11–20 points for an identical model.**
  So a difference between two published numbers is, to first order, a
  difference between two scaffolds *and* two models *and* two harnesses, with
  no way to attribute it.
* **The denominators disagree.** 477 vs 484 vs 500 instances, depending on the
  lab. A percentage over an undisclosed subset is not comparable to a
  percentage over a different undisclosed subset.
* **The submission checklist forbids pass@k but permits best-of-k reported as
  pass@1.** Two numbers formatted identically can be produced by procedures
  that differ by a factor of k in test-time compute.

None of that is fixable by being careful with our own run. It is fixed by
**running the competitor ourselves**, on tasks we chose, with a model we pinned,
under limits we set. Then the difference between the arms is a difference
between the harnesses, because everything else was held.

## Why Terminal-Bench

Terminal-Bench grades **the final state of a container**, using the task's own
`tests/test.sh`, run after the agent stops. There is no patch to apply, no
diff to score, and nothing the agent *says* is read. That removes an entire
class of harness-level advantage (patch extraction, test-name leakage, output
parsing) and leaves the thing we want to measure: can this harness drive a
machine to a working state over a long horizon.

It also means an agent that writes a beautiful explanation and touches nothing
scores zero — correctly. That is tracked separately as
`completed_without_acting`.

---

## Phase 1 — what is actually runnable

### The shared provider

One Ollama daemon on the host at `:11434`, serving **`glm-5.2:cloud`** (1M
context, tool-calling, proxied to ollama.com). Verified before anything else:

| probe | result |
|---|---|
| `/v1/models` from the host | 46 models, `glm-5.2:cloud` present |
| `/v1/chat/completions` with a tool schema | returns a well-formed `tool_calls` |
| `/v1/responses` | HTTP 200 |
| `/v1/models` from inside a task container (with the compose overlay) | 46 models, `glm-5.2:cloud` present |

Harbor puts each trial on its own compose network with no host-gateway alias,
so `host.docker.internal` does not resolve by default.
`bench/terminalbench/compose-host-provider.yaml` adds it — and it is passed to
**every arm**, not just OSA. An overlay applied to one arm and not another is a
difference in the environment under test.

### Runnable arms

Every one of these was verified to **install** into a live task container via
`--install-only` (costs no tokens):

| arm | version installed | `-m` | wire protocol |
|---|---|---|---|
| `osa` | 1.0.96 (snapshot release) | `ollama/glm-5.2:cloud` | Ollama-native `/api/chat` |
| `codex` | 0.147.0 | `openai/glm-5.2:cloud` | OpenAI **Responses** `/v1/responses` |
| `opencode` | 1.18.18 | `openai/glm-5.2:cloud` | OpenAI chat-completions |
| `goose` | 1.46.0 | `openai/glm-5.2:cloud` | OpenAI chat-completions |
| `mini-swe-agent` | 2.4.6 | `openai/glm-5.2:cloud` | OpenAI chat-completions |
| `aider` | 0.86.2 | `openai/openai/glm-5.2:cloud` | OpenAI chat-completions |

Three of these needed a non-obvious fix, all recorded in `arms.py`:

* **codex** — recent versions **removed `wire_api = "chat"`**; `WireApi` has a
  single variant, `Responses`. There is no chat-completions route left in the
  CLI. It reaches the shared daemon only through its built-in `ollama`
  provider (`--ak config='{"model_provider":"ollama"}'` plus
  `CODEX_OSS_BASE_URL`), which is Responses-over-HTTP. Ollama serves
  `/v1/responses`, so this works — but it is a **third serialisation path**,
  and it is declared rather than hidden.
* **aider** — its adapter passes the *post-split* model name to the CLI, so
  `openai/glm-5.2:cloud` arrives as the bare `glm-5.2:cloud` and LiteLLM
  cannot infer a provider. The model string is deliberately double-prefixed.
* **mini-swe-agent** — the key must be `OPENAI_API_KEY`, not `MSWEA_API_KEY`.
  If `MSWEA_API_KEY` resolves first, Harbor exports *only* that name, which
  upstream mini-swe-agent never reads, and LiteLLM ends up with no key at all.

### Blocked arms — and what that does and does not mean

`run_h2h.py --list-arms` prints these with full reasons. They are recorded in
every `results.json` under `honesty.arms_blocked_not_beaten`.

| arm | blocker | why |
|---|---|---|
| `claude-code` | protocol + credential | Speaks the Anthropic Messages API. Ollama serves `/api/chat`, `/v1/chat/completions` and `/v1/responses` — **not** `/v1/messages`. No base URL points it at `glm-5.2`, and there is no `ANTHROPIC_API_KEY` here. |
| `gemini-cli` | protocol + credential | Google generative-language API only; no OpenAI-compatible path in the adapter, no Google key. |
| `cursor-cli` | subscription | Hard-requires `CURSOR_API_KEY`; the model is chosen server-side. |
| `copilot-cli` | subscription | Copilot-entitled `GITHUB_TOKEN`; model chosen server-side. |
| `grok-build` | credential | Requires `XAI_API_KEY`. |
| `devin` | subscription | Hosted; runs on Cognition's infrastructure and model. |

**An arm we could not point at the shared model is an arm we did not measure.**
Nothing here is a result about Claude Code, Gemini CLI or Cursor. The reason is
always a *missing thing*, never a judgement.

Running any of them on *their* model would produce a **model comparison, not a
harness comparison**. The whole design collapses the moment the model differs,
so that option was rejected rather than taken and caveated.

### Was the model held fixed? Yes — with one declared asymmetry

Every arm hits **one daemon** serving **one model**. But not over one wire:

* OSA → `/api/chat` (Ollama-native)
* codex → `/v1/responses`
* everything else → `/v1/chat/completions`

Same weights, same daemon, three serialisations. This is real and it is
declared in `config.model_fixed_caveat`, in every report, and here.

It is also the *smallest* available asymmetry. The alternative — running OSA
through its own `openai_compat` provider to match the others — would have moved
OSA off its default configuration, which is a bigger confound than a
serialisation format. If you want that control arm, it is one line in
`arms.py`.

---

## Phase 2 — running it

```bash
cd bench/headtohead

# what can run, and why the rest cannot
./run_h2h.py --list-arms

# prove the pipeline first: one cheap task, every arm
./run_h2h.py --run-id smoke1 --arms osa codex opencode goose mini-swe-agent aider \
             --tasks regex-log --n-concurrent 1

# the comparison
./run_h2h.py --run-id h2h-1 --arms osa codex opencode goose mini-swe-agent \
             --task-set default6
```

### What "same limits" means

**Only one limit is available to every arm: wall clock**, from the task's own
`agent.timeout_sec` scaled by `--agent-timeout-multiplier`.

Turn caps exist on *some* arms (`goose --max-turns`, `mini-swe-agent`
`step_limit`) and not on others — codex, opencode and OSA expose no turn flag
at all. Capping only the arms that can be capped would be a difference in the
**experiment**, not in the **systems**, so no turn caps are set. This is
recorded as `limits.turn_cap: null` with the reasoning attached, so nobody has
to infer it from an absence.

Arms run **sequentially**. They share one Ollama daemon and one Docker host;
running them concurrently would turn one arm's queueing into another arm's
latency, and wall clock is one of the things being measured.

### Task selection is *declared*, not randomised

`TASK_SETS` in `run_h2h.py` are curated: locally-cached images (so a mid-run
pull failure cannot hand one arm a different task set), 900–2400 s timeouts,
mixed difficulty and category, and excluding the two bullseye tasks
(`qemu-startup`, `qemu-alpine-ssh`) where OSA's release artefact cannot start
at all.

A convenience sample is a convenience sample. Passing a seed to a shuffle would
not make it a random sample of Terminal-Bench 2.0, and calling it one would be
worse than admitting what it is. `--seed` is recorded for provenance and only
affects `--shuffle` (which shuffles *order*, shared across arms).

### Integrity checks that run automatically

* **Provider probe before and after.** A daemon that died halfway through
  produces a silent, direction-biased failure: arms that ran first look fine,
  arms that ran later look broken. Both readings are recorded.
* **Contamination probe** (`bench/terminalbench/contamination_probe.py`)
  against **live containers**, not assumptions. Terminal-Bench images are not
  supposed to ship their solutions — SWE-bench Pro's do — and this is checked
  the same way egress is: by probing.
* **OSA release provenance.** The `osa` arm runs a *snapshot* OTP release, not
  the working tree. `osa_release_provenance` records the build time and every
  `lib/` commit made since, so a stale artefact is visible instead of silently
  benchmarking old code.
* **Disk.** Checked before the run; refuses below 40 GB.

---

## Phase 3 — reading the report

### The headline is a limit, not a score

`honesty.claim_label` reads e.g.

> PIPELINE / DIAGNOSTIC RUN over 6 of 89 Terminal-Bench 2.0 tasks — DOES NOT
> SUPPORT A RANKING

`ranking_supported` is computed, not asserted. On these sample sizes it is
`False`, and the report says so at the top rather than in a footnote.

### Confidence intervals, and why n=6 cannot rank anything

Every arm gets a Wilson 95% interval (from `bench/report/stats.py`, used
read-only). At n=6 those intervals are roughly 50 percentage points wide and
overlap nearly everything.

Arms are compared with an **exact McNemar test**, because two arms over the
same tasks are one sample measured twice, not two independent samples. Only
**discordant pairs** — tasks one arm solved and the other did not — carry
information.

The arithmetic is unforgiving and the report prints it:

| discordant pairs | best attainable two-sided *p* |
|---|---|
| 2 | 0.5 |
| 4 | 0.125 |
| 5 | 0.0625 |
| **6** | **0.031** ← first value that can reach p<0.05 |

So a 6-task run needs a *clean 6–0 sweep* before any difference is
statistically visible at all. Anything less is "not distinguishable", and that
is a statement about the experiment's size, not about the arms.

The report also counts **discriminating tasks** — those where the arms
disagreed. Tasks every arm solved, or no arm solved, contribute nothing, so the
effective sample is always smaller than the task count.

### The failure split is the actual comparison

A harness cannot make the model smarter. What it controls is whether the model
ever got a fair attempt. `attribution.py` assigns exactly one owner per task:

| owner | meaning |
|---|---|
| `resolved` | the verifier scored 1.0 |
| `model` | the arm worked, reached the model, finished — and the answer was wrong |
| `harness` | install failed, it never started, it never reached the model, it crashed, or the grader never ran. **The episode never had a fair chance.** |
| `ambiguous` | timeout. A real internal ceiling and a slow model are indistinguishable from outside, so this is never silently assigned to either. |
| `grader` | the verifier itself failed — *our* harness, not the agent's |

**`harness_fault_rate` is the number to read.** Anything above zero means that
arm's accuracy is understated by that much, and that the fix belongs in the
harness rather than the model.

#### Why attribution had to be rewritten for this

`bench/terminalbench/report.py` attributes faults from OSA's own telemetry
(`metadata.osa_status`, `osa_saw_done`, `osa_tool_calls`). That is correct when
OSA is the only thing measured and **catastrophically wrong here**: a Codex
trial has no `osa_status`, so that reporter would classify every non-OSA trial
as `no_telemetry_written` → a 100% harness-fault rate for every competitor.

An attribution rule that flatters OSA by construction is worse than none, so
`attribution.py` derives the split only from fields every Harbor agent
produces. Per-agent telemetry may *refine* a classification the generic rules
already made, never *make* one — so OSA's richer instrumentation cannot move
OSA's own number.

The `agent_never_reached_model` rule (0 input **and** 0 output tokens) exists
for the same reason: a competitor we misconfigured must not be scored as a
competitor that was wrong.

### Self-inflicted markers

Scraped per arm from its own logs, into a per-arm namespace so a cross-arm
total is never accidentally summed over different meanings. These are a
**signal, not a verdict** — they never move fault attribution. A marker that
recurs across tasks is a bug report waiting to be written. (This is how OSA's
`ESSENTIAL context block dropped` defect was found.)

### Cost is *not* comparable across these arms

`-` means **not measured**. Never `0`.

* **aider** — `populate_context_post_run` is literally `pass`. No tokens, no
  cost, ever. Its empty row must not be read as "cheap".
* **mini-swe-agent** — always reports `$0`: `glm-5.2:cloud` is not in
  LiteLLM's price map and `MSWEA_COST_TRACKING=ignore_errors` swallows the
  lookup failure. Tokens are real.
* **codex / opencode** — return `None` for an unpriced model.

`tokens_comparable` is `false` for any arm that failed to report tokens on even
one task, because a total built from a subset is not a total.

---

## What this can and cannot support

**Can:**
- the harness-vs-model failure split per arm, on identical tasks with an
  identical model — the one thing a harness actually controls
- whether an arm can complete a long-horizon terminal task at all
- wall-clock cost of an attempt
- token cost, for the arms whose `tokens_comparable` is true

**Cannot:**
- rank the arms (see the McNemar table)
- produce a Terminal-Bench 2.0 score — any subset run is a pipeline signal
- say anything whatsoever about the arms listed as blocked
- compare cost across arms with missing telemetry
- separate a harness's ceiling from a slow model on the `ambiguous` rows

---

## Files

| file | what it is |
|---|---|
| `arms.py` | the arm table: runnable arms with their exact config, blocked arms with reasons |
| `run_h2h.py` | the runner. Sequential arms, shared task list, integrity probes |
| `attribution.py` | agent-agnostic fault attribution + per-arm marker scraping |
| `paired.py` | exact McNemar, and the minimum-discordant-pairs arithmetic |
| `report_h2h.py` | `results.json` + `report.md`, schema-compatible with `bench/report` |
| `preflight.sh` | `--install-only` probe: does each CLI land in a container (no tokens) |
| `runs/<id>/` | per-run artefacts: `config.json`, `results.json`, `report.md`, per-arm Harbor job dirs |

Raw material is kept per trial under
`runs/<id>/arms/<arm>/harbor/<job>/<trial>/` — each arm's own logs, its
trajectory, and the verifier's `reward.txt`.
