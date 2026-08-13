# OSA benchmark harness

Measures OSA against **externally-recognised evaluations**, using **their**
grading code, not ours.

The rule this directory is built around: *a benchmark we invent, that OSA
passes, is worth nothing*. So the only thing in here that we wrote is the part
that **drives OSA and records what it cost**. Deciding whether OSA's patch was
correct is delegated wholesale to the official `swebench` harness running in
Docker — the same code path the public leaderboard uses.

```
bench/
  README.md            <- you are here
  swebench/
    setup.sh           create the Python venv (swebench + datasets)
    run_bench.py       orchestrator: select -> prepare -> infer -> evaluate -> report
    runners.py         the task-runner interface + gold/empty control runners
    osa_runner.py      drives OSA headlessly (HTTP SSE, or `mix osa.run`)
    workspace.py       materialises an instance as an editable host workspace
    evaluate.py        wrapper around the official swebench grading harness
    report.py          merges telemetry + grading -> results.json / summary.md
    instances/         curated instance-id subsets
    runs/<run_id>/     all output (gitignored)
```

---

## 1. What SWE-bench actually is, mechanically

Ignore the marketing framing ("can AI fix real bugs"). The protocol is narrow
and precise.

**Each instance is a row** in the `princeton-nlp/SWE-bench_Verified` dataset
(500 human-validated instances drawn from 12 Python repos; `django/django`
alone is 231 of them). The fields that matter:

| field | meaning |
|---|---|
| `instance_id` | e.g. `psf__requests-1921` |
| `repo`, `base_commit` | the checkout the agent starts from |
| `problem_statement` | the GitHub issue title + body — **this is the entire task input** |
| `patch` | the *gold* fix (agent never sees it) |
| `test_patch` | the tests that prove the fix (agent never sees it) |
| `FAIL_TO_PASS` | JSON list of test node ids that must flip from failing to passing |
| `PASS_TO_PASS` | JSON list that must stay passing |

**What the harness receives from the agent**: exactly one artefact per
instance — a unified diff. Nothing else is graded. Predictions are JSONL:

```json
{"instance_id": "psf__requests-1921", "model_name_or_path": "osa", "model_patch": "diff --git ..."}
```

**How correctness is decided**, per instance, in a fresh container:

1. check out `repo` at `base_commit`;
2. apply `model_patch`;
3. **revert every test file to `base_commit`** and apply the hidden
   `test_patch` (this is why agent edits to tests are pointless — they are
   thrown away);
4. run `FAIL_TO_PASS` and `PASS_TO_PASS`;
5. `resolved` **iff every F2P test passes AND every P2P test passes**.

It is all-or-nothing. There is no partial credit, and a patch that fixes the
bug but breaks one unrelated pre-existing test scores exactly the same as a
patch that does nothing. In our very first OSA run, that is precisely what
happened: F2P flipped, two P2P tests broke, score 0.

The reported figure is **pass@1 = resolved / 500** — the "% Resolved" column on
the leaderboard.

**Why Docker is non-negotiable**: these are 2019-2023 checkouts of scientific
Python libraries with pinned, now-unbuildable dependency sets. SWE-bench ships
a three-layer image stack (base → ~60 env images → one instance image each).
Instance images are prebuilt and public as
`swebench/sweb.eval.x86_64.<instance_id>:latest`, with `__` rewritten to
`_1776_` (Docker tags disallow the doubled underscore); a mirror exists at
`ghcr.io/epoch-research/swe-bench.eval.x86_64.<instance_id>`. They are
**3-5 GB each**. Building them yourself instead of pulling takes hours. Full
SWE-bench Verified at `--cache-level instance` will consume on the order of
2 TB; `env` (our default) keeps it to roughly 100-120 GB in flight.

### Related benchmarks, and why only SWE-bench is wired up here

- **SWE-bench Lite** (300 instances) / **full** (2294): same protocol, just
  swap `--dataset`. Already supported by this harness.
- **Terminal-Bench 2.0** (89 hard terminal tasks, run by the *Harbor* harness):
  a genuinely different shape. The agent must be **installed inside the task
  container**, and grading inspects the *final container state* rather than a
  patch. Adapting OSA means shipping an Elixir runtime into each task image, or
  writing a `BaseAgent` subclass that proxies out to an OSA daemon on the host.
  That is a real project, and it is **not built here**. See §6.
- **SWE-bench Multimodal / Multilingual, SWE-Lancer, SWE-bench Pro**: same
  submission shape, different datasets and image registries.

### Metrics that matter beyond pass rate

Pass rate alone is not comparable across harnesses, because harnesses buy
accuracy with tokens and time. Every serious 2026 comparison reports the price
alongside the score, so this harness records, per task:

wall-clock, tokens in / out / cache-read / cache-write, cost, tool-call count,
LLM turn count, and a **failure reason** — and aggregates
**tokens-per-resolved-task** and **cost-per-resolved-task**, which are the
numbers that actually separate harnesses at similar pass rates.

---

## 2. How to run it

### Prerequisites

- Docker running, x86_64, **≥150 GB free disk** for a small subset.
- Python 3.10+.
- An OSA backend you are willing to point at a benchmark.

```bash
cd bench/swebench
./setup.sh          # creates .venv, installs swebench + datasets, checks Docker
```

### Step 1 — prove the pipeline before trusting any OSA number

```bash
./.venv/bin/python run_bench.py --runner gold  --instances instances/smoke2.txt --run-id gold-check  --no-test-bridge
./.venv/bin/python run_bench.py --runner empty --instances instances/smoke2.txt --run-id empty-check --no-test-bridge
```

`gold` submits the dataset's own fix and **must score 100%**. `empty` submits
nothing and **must score 0%**. If either is wrong, the harness is broken and no
OSA number from it means anything. Do this on every new machine.

### Step 2 — start a benchmark OSA backend

Use a dedicated port so you do not disturb your everyday daemon (default 9089):

```bash
export PATH="$HOME/.asdf/shims:$HOME/.asdf/bin:$PATH"
cd /path/to/OSA && OSA_HTTP_PORT=19801 mix osa.serve
```

### Step 3 — run OSA

```bash
cd bench/swebench
./.venv/bin/python run_bench.py \
  --runner osa --osa-url http://127.0.0.1:19801 \
  --instances instances/smoke4.txt \
  --run-id osa-$(date +%Y%m%d) \
  --agent-timeout 900 --eval-workers 2
```

Useful flags: `--limit N`, `--repo psf/requests`, `--difficulty '<15 min fix'`,
`--instance-ids a b c`, `--dataset princeton-nlp/SWE-bench_Lite`,
`--skip-eval` (inference only), `--reuse-inference` (re-grade an existing run
without re-running the agent), `--keep-workspaces` (leave the checkouts on disk
for debugging), `--osa-mode cli` (drive `mix osa.run` instead of HTTP).

### Output

```
runs/<run_id>/
  config.json        exactly how the run was parameterised
  inference.jsonl    one record per task, as the agent left it
  predictions.jsonl  the official submission format
  eval/              the official harness's own report + per-instance logs
  logs/*.jsonl       raw SSE event stream per task
  results.json       <- machine readable, schema_version 1
  summary.md         <- human readable
```

---

## 3. How OSA is driven

Two transports, both existing OSA entry points — nothing in OSA was modified to
support benchmarking.

**`--osa-mode http`** (default). `osa serve` exposes the headless backend. Per
task the runner:

1. opens `GET /api/v1/stream/<session>` **first** (the terminal `done` frame is
   not replayed, so subscribing after dispatch can hang forever);
2. `POST /api/v1/commands/execute` with `permission_mode overdrive`, because
   headless permissions **fail closed** — without this every mutating tool is
   auto-rejected and OSA scores zero for reasons that have nothing to do with
   its ability;
3. `POST /api/v1/orchestrate` with `input`, `session_id`, and `working_dir`
   pointing at the prepared workspace;
4. consumes SSE until `done`, counting `tool_call` frames with `phase=="start"`
   and summing `cost_update` frames.

**`--osa-mode cli`** drives `mix osa.run --format stream-json`, which is
genuinely synchronous and needs no daemon, but emits no usage frames — token
numbers then come only from the on-disk sidecar. Source checkouts only.

### The workspace, and the test bridge

SWE-bench environments are only reproducible inside their image, but OSA is an
Elixir app on the host. So we invert the usual arrangement: `/testbed` is copied
out of the instance image onto the host, then a container is started from that
same image with the host directory **bind-mounted back over `/testbed`**.

OSA edits ordinary host files; the container still has the fully installed
environment pointing at those same inodes. A `run_tests.sh` dropped into the
workspace lets the agent actually run the project's suite — which is how a real
engineer works, and withholding it would understate the harness. Pass
`--no-test-bridge` to measure the blind, one-shot case instead.

Grading never touches this container. The patch is extracted with `git diff`
(test-file changes stripped, since the grader discards them anyway) and handed
to a fresh official container.

### Where the numbers come from

Token and cost accounting is read from **two independent sources** and both are
recorded in `results.json` under `raw`, so a divergence is visible rather than
silently reconciled:

- `~/.osa/sessions/<id>.spend.json` — OSA's own cumulative per-session ledger,
  treated as authoritative;
- the sum of SSE `cost_update` frames — the cross-check.

In the runs to date these agree to within about 6%.

---

## 4. What the numbers can and cannot be used to claim

**Can:**

- *"On these N instances, graded by the official SWE-bench harness, OSA
  resolved K."* Subset-qualified, with the instance list attached.
- Regression and A/B signal: same instances, same model, before vs after an OSA
  change. This is the harness's highest-value use.
- Efficiency comparisons at fixed pass rate — tokens and tool calls per
  resolved task are meaningful even on small subsets.

**Cannot:**

- **A "SWE-bench Verified score."** That term means all 500 instances. A subset
  run is not one, and `results.json` records `is_full_dataset_run: false`
  specifically so nobody can quote it as one by accident. On 4 instances the
  95% confidence interval spans essentially the whole leaderboard.
- **A comparison against published numbers of other agents**, unless you match
  the model, the token budget, the turn limit, the retry policy, whether tests
  were runnable, and the cache accounting. Published pass rates for the *same*
  model differ by tens of points across harnesses. Compare OSA to OSA.
- **Evidence about anything SWE-bench does not contain.** It is 12 Python
  repos, issue-shaped bugs, with a hidden test oracle that already knows the
  answer. It says nothing about greenfield work, non-Python languages,
  multi-file features, UI, ops, or long-horizon autonomy.
- **A cost claim, when `cost_usd` is 0.** A subscription or local provider
  (e.g. the `ollama` path) reports zero cost with entirely real token counts.
  Zero means "no per-token bill", not "free". Absent means unknown; the schema
  keeps `null` and `0` distinct on purpose.
- **A statement about determinism.** LLM sampling is not fixed here; re-running
  the same instance can produce different patches. What *is* deterministic is
  the reporting: given a fixed `inference.jsonl`, grading and the report are
  reproducible (`--reuse-inference`).

---

## 5. Status — what is proven, and what is not

**Executed and verified on this machine** (x86_64, Docker 29.3, swebench 4.1.0,
SWE-bench Verified, OSA v1.0.95 backend, provider `ollama`, model
`glm-5.2:cloud`):

| run | result | meaning |
|---|---|---|
| `gold`, 2 instances | **2/2 resolved** | pipeline correct end to end |
| `empty`, 2 instances | **0/2 resolved** | no accidental credit |
| `osa`, `psf__requests-1921` | 0/1, `regression_pass_to_pass_broke` | failure taxonomy works on a real failure |
| `osa`, 2 instances | **2/2 resolved**, 80.6 s, 716k tokens, 25 tool calls | full loop with real telemetry |

Every layer — dataset, workspace, agent, patch extraction, official grading,
report — has run against real data. Nothing in the pipeline is mocked.

**Not proven / stubbed:**

- **Scale.** The largest run so far is 4 instances. Nothing has been run at
  N=100 or N=500; expect to hit image-pull volume, disk, and long-tail agent
  timeouts there. The 2/2 OSA result is a pipeline demonstration, not a score.
- **`--osa-mode cli`** is implemented but **never executed**. Only the HTTP
  transport has been exercised.
- **Parallel inference is not implemented.** Tasks run strictly sequentially
  (grading is parallel via `--eval-workers`). Concurrency would need one OSA
  session per worker and has not been tested.
- **Non-Python repos**: the test bridge's default `python -m pytest` invocation
  is wrong for `django/django`, which uses its own runner. Django tasks still
  grade correctly (grading is independent), but `run_tests.sh` will not work
  for the agent on those instances.
- **Terminal-Bench**: researched, documented in §1, **not built**.
- **Cost in dollars** has never been observed non-zero, because the configured
  provider does not price per token. The cost path is therefore untested
  against a real bill.
- **Retry / pass@k** is not implemented; every task gets exactly one attempt.

---

## 6. If you want Terminal-Bench next

The work is: subclass Harbor's `BaseAgent`, and in its `run` either (a) install
an OSA release into the task container and drive `osa` locally, or (b) mount
the container's filesystem and drive a host-side OSA daemon over the same HTTP
API this harness already uses. (b) reuses `osa_runner.py` almost unchanged; (a)
is more faithful to what the benchmark intends to measure, since terminal tasks
grade final container state and an agent reaching in from outside changes the
threat model of the task.

---

## 7. Note for maintainers

Nothing outside `bench/` was modified to build this. Two OSA-side observations
worth acting on independently, found while wiring it up:

1. `mix osa.run --format json` reports `"cost": 0` always — `get_session_cost/0`
   in `lib/mix/tasks/osa.run.ex` reads a `:total_cost_usd` key that
   `Budget.get_status/0` does not return. The sidecar has the real numbers.
2. `<id>.spend.json` is never reset for a session id, so any tool that reuses a
   session id accumulates across runs. This harness works around it by putting
   the run id in the session id and clearing the sidecar first.
