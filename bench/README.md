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
    diagnose.py        failure taxonomy: which failures are OSA's fault
    airgap.py          denies the web tools, and PROVES the denial by probe
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

### Step 2 — start a benchmark OSA backend, airgapped

Use a dedicated port so you do not disturb your everyday daemon (default 9089),
and point it at the deny list that stops the agent looking the fix up (§5):

```bash
cd bench/swebench
./.venv/bin/python run_bench.py --write-airgap-settings ./airgap-settings.json

export PATH="$HOME/.asdf/shims:$HOME/.asdf/bin:$PATH"
cd /path/to/OSA && \
  OSA_HTTP_PORT=19801 \
  OSA_SETTINGS=/path/to/OSA/bench/swebench/airgap-settings.json \
  mix osa.serve
```

`OSA_SETTINGS` is the `:flag` settings layer. It is process-wide, which is
exactly right here — the whole daemon is the benchmark — and it is the one
layer that is neither trust-gated nor bypassed by `overdrive`. **Never point
your everyday daemon at it**; it would deny your web tools too.

### Step 3 — run OSA

```bash
cd bench/swebench
./.venv/bin/python run_bench.py \
  --runner osa --osa-url http://127.0.0.1:19801 --airgap \
  --instances instances/smoke4.txt \
  --run-id osa-$(date +%Y%m%d) \
  --agent-timeout 900 --eval-workers 2
```

`--airgap` probes the backend *before* spending a single instance and **aborts
the run** unless it observes a refusal (exit 3). It is not a declaration; it is
a precondition. Omit it and the reporter's web-lookup BLOCK stands, correctly.

Useful flags: `--limit N`, `--repo psf/requests`, `--difficulty '<15 min fix'`,
`--instance-ids a b c`, `--dataset princeton-nlp/SWE-bench_Lite`,
`--skip-eval` (inference only), `--reuse-inference` (re-grade an existing run
without re-running the agent), `--keep-workspaces` (leave the checkouts on disk
for debugging), `--osa-mode cli` (drive `mix osa.run` instead of HTTP).

### Choosing a subset: `--sample`, not `--limit`

`--limit N` takes the first N rows in dataset order. That is not a sample and
the resulting number means nothing — it is kept only for quick smoke runs, and
`results.json` labels it `head-of-dataset-order (NOT a random sample)`.

```bash
--sample 40 --sample-seed 20260813 --sample-bias hard
```

`--sample` is **stratified by repo** — the repo mix of the subset matches the
dataset's, which matters because `django/django` is 231 of the 500 and any
accidental bias lands there — and, with `--sample-bias hard` (the default),
**weighted toward the hard end** within each repo. Hardness is
`0.40*difficulty + 0.25*min(files_in_gold_patch/4,1) +
0.20*min(len(PASS_TO_PASS)/250,1) + 0.15*min(len(patch)/6000,1)`, and the draw
weight is `(0.10 + hardness)**2`.

This is on purpose, and it cuts *against* the score. This harness exists to
find things to fix; an easy instance that passes teaches nothing. The whole
provenance block — seed, formula, and the resulting repo/difficulty mix next to
the population's — is written into `config.json` and quoted in `summary.md`, so
a subset can never be mistaken for a representative one.

### Reliability: `--attempts K`

`--attempts 3` runs three independent attempts at every instance and reports:

| metric | meaning |
|---|---|
| **pass@1** | mean resolve rate over the K attempts — the unbiased single-sample estimate |
| **pass@K** | resolved by *at least one* attempt — "can it do this at all" |
| **pass^K** | resolved by *every* attempt — the reliability figure |

The gap between pass@1 and pass@K is the interesting part: a wide gap means the
agent can solve the task but is unreliable, which is a different problem from
not being able to solve it. `pass^K` is the number that matters if you intend
to run the agent unattended, and almost nobody reports it. Token and wall-clock
totals are summed across all K attempts — pass@K is not free and the report
does not pretend otherwise.

### Parallelism and disk

`--infer-workers N` (default 2) runs N instances against the agent
concurrently; `--eval-workers N` is the official grader's own parallelism.
Inference concurrency is deliberately modest: every worker holds a container, a
workspace and an OSA session, and they all share one backend, so a high value
distorts the very per-task latencies being measured.

Instance images are 3-5 GB each. `--min-free-gb` (default 40) aborts an
instance rather than filling the disk, and `--prune-images` deletes this run's
instance images afterwards while keeping the shared base and env layers that
make the next run fast.

### Output

```
runs/<run_id>/
  config.json        exactly how the run was parameterised, INCLUDING sampling
  inference.jsonl    one record per task, as the agent left it
  predictions.jsonl  the official submission format
  eval/              the official harness's own report + per-instance logs
  logs/*.jsonl       raw SSE event stream per task
  transcripts/<sid>/ OSA's own session files, copied out of ~/.osa/sessions
  failures/*.md      one dossier per failed instance  <- read these first
  results.json       <- machine readable, schema_version 2
  summary.md         <- human readable
```

With `--attempts K > 1` the per-attempt artefacts move under `attempt1/`,
`attempt2/`, … and `results.json` / `summary.md` at the top level are the
merged pass@K report.

---

## 3a. The failure taxonomy — the actually useful output

The pass rate is the least useful number here. What you want from a run is a
ranked list of things to fix, and that requires separating two failures that
look identical in a score:

- **model failure** — OSA worked correctly and the model still produced a wrong
  or incomplete patch. Nothing to fix in OSA.
- **harness failure** — OSA got in the model's way: a tool errored, a result
  came back truncated past usefulness, the context meter was broken so
  compaction could never fire, the stream died, the turn ended early. **These
  are OSA bugs and they are the reason for running this at all.**

`diagnose.py` puts every failure in exactly one named bucket and tags it
`model` / `harness` / `bench`. `summary.md` leads with the split and with
`probable_osa_bugs` — any harness-fault bucket seen more than once in a single
run, which is a bug report rather than bad luck.

The evidence comes from `osa_signals`, mined from the SSE stream per task: tool
failure counts by tool name, truncated/offloaded tool results, compaction
events, peak context utilisation and the window OSA *thought* it had, the
longest gap between frames (a stall detector), and the agent's final message.
Every failed instance also gets `failures/<instance_id>.md` carrying the
submitted patch, exactly which F2P/P2P tests moved, the signals, and a pointer
to the copied OSA session transcript — enough to diagnose it weeks later,
which `~/.osa/sessions/` alone is not, because later runs overwrite it.

The split is deliberately conservative: an instance is only called a harness
failure on positive evidence of OSA misbehaving. Over-claiming OSA bugs would
make the tool useless in the other direction.

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
| `gold-apply`, the 40-instance set | **40/40 resolved** | the set is fully winnable, and patch extraction is correct through the real workspace path |
| `empty`, the 40-instance set | **0/40 resolved** | no accidental credit |
| `osa`, 40 hard-weighted instances, **airgapped** | **23/40** pass@1 | `runs/osa-hard40-airgap` — the current number |
| `osa`, the same 40, **not** airgapped | 24/40 | `runs/osa-hard40-v2` — superseded; the agent could look the fix up |
| `osa`, `--osa-mode cli`, 1 instance | 1/1 | the CLI transport, executed for the first time |

**The current run (`runs/osa-hard40-airgap`)**, seed 20260813, stratified by
repo and hard-weighted (mean hardness 0.443 vs 0.297 for the full dataset; only
4 of 40 are `<15 min fix`, against 39% of the dataset), with web lookup denied
and the denial probed before the run started (§5, "Web lookup"):

| | |
|---|---|
| resolved | **23 / 40** pass@1, single attempt |
| 95% interval | 42.2% – 71.5% (29 points wide — this ranks nothing) |
| wall clock | 5527 s of agent time, 2 workers |
| tokens | 76.7M in / 286k out, **0 cache reads** |
| cost | **$46.66** — real, for the first time; the `model: nil` defect that made this $0.00 has been fixed |
| tool calls | 1612 total, 40.3 mean/task |
| failures | **17, all classified `model`. Zero harness faults, down from 4.** |

**What changed against `osa-hard40-v2`, and why the headline moved so little.**
24 → 23 is a two-point drop that hides two much larger, opposing movements,
because two things changed at once — the airgap went on, *and* OSA itself was
patched between the runs (`ca8f4827` → `82a61cc4` plus a working tree). The
difference is **+2.5 pp, 95% CI [−18.3, +23.0]**, i.e. statistically
indistinguishable; the decomposition is the informative part:

| flip | instances | attribution |
|---|---|---|
| resolved → failed | `django-16263`, `pydata__xarray-7229`, `sympy-22080` | **all three had used `web_fetch` in the unairgapped run.** Denying the lookup cost exactly these. |
| failed → resolved | `matplotlib-25311`, `scikit-learn-14629`, `scikit-learn-26323` | all three were *harness* faults before — one workspace-permissions error and two prompt-injection refusals (§7.8, §7.7). OSA fixes, not model gains. |
| both directions, unattributed | `django-11532` (−), `django-14631` (+), `sympy-13877` (−) | run-to-run noise; this is the best estimate of it available |

So the airgap cost 3 instances and the OSA fixes recovered 3, with one instance
of noise on top. **A −2.5 pp headline understates the effect of preventing web
lookup**, and anyone quoting the delta as "the airgap barely mattered" would be
wrong.

Two further observations from the airgapped run:

- **The agent still tried.** `web_search` ×5 and `web_fetch` ×2 across five
  instances, refused every time (0–11 ms, `Blocked: … is denied by a saved
  permission rule`). Reaching for a lookup on 5 of 40 hard instances is itself
  a measurement of how much the earlier number rested on retrieval.
- **It costs more to work it out.** Input tokens rose 59.9M → 76.7M (+28%) and
  tool calls 1510 → 1612 for one fewer resolved instance.

`bench/report/cli.py gate` now emits **one** blocking finding —
`subset_not_a_dataset_score`, 40 of 500 — which no amount of engineering can
close short of running all 500. The web-lookup block is closed on evidence.
The number must still not be quoted as OSA's SWE-bench Verified score.

Every layer — dataset, workspace, agent, patch extraction, official grading,
report — has run against real data. Nothing in the pipeline is mocked.

### The correctness audit — read this before trusting any earlier number

An audit of this harness found that **every number it produced before
2026-08-14 was wrong in both directions at once**. Three of the four defects
were the harness misrepresenting the agent, which is the failure mode a
measurement tool must never have:

| defect | direction | status |
|---|---|---|
| `_is_test_path` substring-matched `"test/"`, which is inside `src/_pytest/` — 19 of the 500 gold patches were stripped **in full**, ceiling 96.2%, and the result was reported as the agent's `no_patch_produced` | deflates, and blames the agent | **fixed** |
| FAIL_TO_PASS node ids baked into `run_tests.sh`, where test names state the required behaviour | inflates | **fixed** (now `--f2p-hint`, default off) |
| pass@k reported in `instances_resolved` | inflates | **fixed** (pass@1 primary; the field is `null` for k>1) |
| gold control bypassed workspace prep and `git_diff()`, so it could not see defect 1 | hides defects | **fixed** (`--runner gold-apply`) |
| web lookup of the published fix not prevented | inflates | **fixed** (`airgap.py`, probed) — see below |

The stripping predicate is now derived from the instance's own `test_patch`
rather than guessed from filenames. That is exact by construction: the grader
reverts precisely the files in `test_patch`, so the recorded patch and the
graded patch cannot drift. Verified against all 500 gold patches: 0 damaged,
ceiling 100.0%.

**Web lookup — closed, by a deny list that is proved before every run.**
The prompt names the repo and the exact base commit, and the upstream fix is a
public commit. The test container is `--network none`, but OSA runs on the
*host* in `overdrive`, with `web_search` / `web_fetch` / `download` / `browser`
all available. In `runs/osa-hard40-v2` this was not hypothetical: six instances
called `web_fetch` and all six resolved, and two of them additionally shelled
out to `curl https://raw.githubusercontent.com/...` and `python3 -c "import
urllib.request; url='https://raw.githubusercontent.com/sympy/...'"`.

*What did not work*: a `PreToolUse` deny hook in the workspace's
`.osa/settings.local.json`. Probed live — `web_search` ran normally, because
`Settings.layer(:local)` resolves through the process-global `Workspace.Cwd`
and a per-request `working_dir` cannot move it. Kept as a documented negative
result in `workspace.py:write_airgap`, default off.

*What works*: `permissions.deny` in the **backend process's `OSA_SETTINGS`**
file — the `:flag` layer. It is never trust-gated, `Permissions.rules/0` reads
it, and `ToolExecutor` consults deny rules *before* any permission-mode
short-circuit, so `overdrive` does not bypass it. No OSA change was needed, and
no per-session scoping is needed either, because the benchmark backend is a
dedicated daemon. `airgap.py` writes the file; `--airgap` refuses to start the
run until a live probe confirms it.

*The probe is differential and the run aborts if it fails.* One session, four
steps: `web_fetch` on a public URL (must be refused), a `python3 -c "import
urllib..."` through `shell_execute` (must be refused), `echo` through
`shell_execute` (must **succeed** — proving the blunt substring rules did not
swallow the shell the agent needs), `dir_list` (must succeed — proving the
backend is alive). Observed, in `overdrive`: refusals at 0 ms and 2 ms with
`Blocked: <tool> is denied by a saved permission rule` in the backend log;
successes at 25 ms and 4 ms. Against a backend started *without* `OSA_SETTINGS`
the same probe returns `web_fetch success=true, 225 ms` and the page body — the
probe can fail, which is the only reason a pass means anything.

*Residual surface, stated because it is not zero.* `shell_execute` stays
available; the rules cover it by command prefix and by egress substring, which
is a filter, not a boundary. An egress path mentioning none of the listed
tokens is not prevented — it is *detected*: every recorded SSE stream is scanned
afterwards (`residual_egress_evidence`), the result is in
`results.json:network_tool_use.residual_shell_egress`, and any hit re-blocks the
run. A network namespace would make this a boundary. It is unavailable on this
host and both routes were executed rather than assumed: `unshare --net` fails
with `write failed /proc/self/uid_map: Operation not permitted`
(`kernel.apparmor_restrict_unprivileged_userns = 1` on Ubuntu 24.04), and
`/usr/bin/bwrap` is not setuid so `bwrap --unshare-net` fails at `RTM_NEWADDR`.

*One more thing the split buys.* Attempts and successes are now counted
separately. The first airgapped run recorded seven network-tool calls, all
refused — and the gate initially called that a breach, because the counter
measured attempts. A denied call cannot carry information, so only a
*succeeded* call invalidates a score; the attempts stay in the record because
"the agent reached for a lookup on 5 of 40 instances" is a finding in its own
right.

**Not proven / stubbed:**

- **Full dataset.** Nothing has been run at N=500. Expect image-pull volume
  (~2 TB at `--cache-level instance`) and long-tail agent timeouts there.
- **Terminal-Bench**: a separate harness now exists under `bench/terminalbench`;
  it has run 10 hard tasks, not the full 89. See its own README.
- **Variance.** Every OSA number here is a single run. Vendors average over
  5–10 trials for this reason; the intervals quoted cover sampling over *tasks*
  only and say nothing about run-to-run variation on the same tasks. Nine of
  the forty instances flipped verdict between two runs of the same set, in both
  directions.
- **Prompt caching.** `cache_read_tokens` is 0 on every task in every run. Not
  established whether that is OSA not requesting caching or the Ollama path not
  reporting it; it must be checked against a hosted provider before being
  called an OSA bug.
- **Cost in dollars** — *resolved*, and worth recording as an example of what
  this harness is for. Every earlier run reported $0.00 because the agent
  loop's state carried `model: nil`, so `Pricing.cost/2` priced every turn at
  $0.00 and logged `[Pricing] No price for model nil`, while `glm-5.2:cloud`
  *is* priced {0.60, 2.20}. `runs/osa-hard40-airgap` is the first run to report
  a real figure: **$46.66**, $2.03 per resolved instance. The reporter's rule
  that produced the old wording ("0 USD means unpriced, i.e. a subscription")
  was itself wrong, and now distinguishes an unpriced model from a priced model
  reporting zero — the second is a defect, not a caveat.
- **Grader determinism.** Some instances have network-dependent tests:
  `psf__requests-1921` failed and then passed on an identical re-run of the
  *gold* patch (`test_DIGESTAUTH_WRONG_HTTP_401_GET`). The official grader is
  not deterministic on those, which is a further reason single-sample numbers
  are noisy.

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
   `Budget.get_status/0` does not return. *(Fixed in 7e44213a.)*
2. `<id>.spend.json` is never reset for a session id, so any tool that reuses a
   session id accumulates across runs. This harness works around it by putting
   the run id in the session id and clearing the sidecar first.
3. **The agent loop's state carried `model: nil`.** *(FIXED between
   `runs/osa-hard40-v2` and `runs/osa-hard40-airgap`; the latter reports a real
   $46.66. Kept here because the two silent consequences below are the reason
   it mattered, and because the reporter still checks for the symptom.)* Every `cost_update` frame
   ships `"model": null`, and the daemon logs `[Pricing] No price for model nil
   — cost recorded as $0.0` once per turn. Two independent consequences, both
   silent:
   - **all cost accounting is dead.** `glm-5.2:cloud` is priced
     {0.60, 2.20} per 1M in `Agent.Pricing`, so a 40-instance run that really
     cost single-digit dollars reports $0.00. `max_budget_usd` is therefore
     unenforceable in headless mode — the cap can never trip.
   - **compaction thresholds are dead.** `Telemetry.emit_context_pressure/1`
     starts `provider_context_window(state)`, which returns `0` when the model
     is nil. Every frame reads `max=0 util=0.0% percent_left=100`, so
     `above_compact` and `at_blocking_limit` can never become true no matter
     how large the transcript grows. Observed live: `[ctx] estimated=42538
     max=0 util=0.0%`. `/health` reports the model and a 1,000,000 context
     window correctly, so this is state population, not configuration.
4. **`mix osa.run --format stream-json` is not a stream.** It registers Bus
   handlers for `:tool_call` and streaming tokens, but a full run emitted
   exactly one JSON line — the terminal `{"type":"result",...}`. Zero
   `tool_use` frames across a 39-second, multi-tool session. Anything consuming
   the documented event stream gets nothing.
5. **`Settings.layer(:local)` is not session-scoped.** It resolves through a
   process-global `Workspace.Cwd`, so the per-request `working_dir` on
   `/api/v1/orchestrate` cannot scope a policy file. *Still true as far as this
   harness knows — it was not re-tested, because the benchmark stopped needing
   it: the `:flag` layer (`OSA_SETTINGS`) is process-wide, which is the right
   granularity for a dedicated benchmark daemon (§5).* It remains a real gap
   for anything that genuinely needs per-session policy, such as a multi-tenant
   backend.
6. **`~/.osa/permission_mode.json` has no eviction.** One row per session id,
   for ever; it is already several hundred entries. This harness cleans up its
   own rows on `close()`.
7. **The prompt-injection guard hard-refused ordinary bug reports.** *(Appears
   FIXED: this cost 3 of 40 instances in `runs/osa-hard40-v2` and cost 0 of the
   same 40 in `runs/osa-hard40-airgap`; two of the three now resolve. Not
   independently re-tested against the 15 matching issue bodies.)* The
   structural detector in `Agent.Safety.PromptInjection` matches
   `/(?:^|\n)\s*(?:system|assistant|user)\s*:/i`, and scikit-learn's and
   matplotlib's issue templates paste an environment block that begins with a
   bare `System:` line — the header of `sklearn.show_versions()`. OSA replies
   `"I can't share my internal configuration or system instructions."` and ends
   the turn: **zero tool calls, zero LLM turns, ~1 second**. It cost 3 of 40
   instances in the run above, and the pattern matches **15 of the 500**
   SWE-bench Verified issue bodies (3.0%).

   The blast radius is much wider than this benchmark: any pasted log, version
   dump, stack trace or chat transcript containing a line that starts with
   `System:`, `User:` or `Assistant:` gets the user's request refused outright.
   A structural marker in the *middle of quoted third-party text* is not a user
   trying to extract the system prompt — OSA's own
   `@untrusted_directive_patterns` comment already makes exactly this argument
   ("refusing the user's turn is the wrong response"), but the structural tier
   does not follow it.
8. **The bind-mounted workspace can become unwritable to the host.** One
   instance (`matplotlib__matplotlib-25311`) died in `git add -A` with
   `insufficient permission for adding an object to repository database
   .git/objects`. The test container runs as root over the same inodes, so a
   tool run inside it can leave root-owned objects that the host user can no
   longer write. `PreparedWorkspace.teardown` chowns back, but only at the end
   — too late for the extraction that happens first.
