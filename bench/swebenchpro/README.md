# bench/swebenchpro

SWE-bench Pro (public split, 731 instances) for OSA. Grading is delegated to
the official harness; nothing here decides whether a patch is correct.

Sibling of `bench/swebench` (SWE-bench Verified) and deliberately shaped like
it: same `Task`/`RunResult` contracts, same results schema, same reporter under
`bench/report/`. Read that directory's `METHODOLOGY.md` before quoting a number
from either.

## Why this benchmark

SWE-bench Verified is saturated and, by construction, short-horizon: its own
human effort labels put **194 of 500** instances under 15 minutes and only
**3** above four hours. It cannot measure long-horizon behaviour because it
does not contain much.

Pro is harder and unsaturated. Measured on the dataset itself
(`python dataset.py`):

| | Verified | Pro (public) |
|---|---|---|
| instances | 500 | **731** |
| files touched by the gold patch (median) | ~1 | **4** (mean 5.07) |
| gold patch size (median) | ~1 kB | **7.8 kB** |
| languages | python | **go 280, python 266, js 165, ts 20** |
| repos | 12 | 11 |
| top public score | ~75%+ | **~59%** |

It is also the most direct probe we have of the thing this project has been
fixing. Pro ships two context columns beyond `problem_statement` —
`requirements` (a prose spec of intended behaviour) and `interface` (the
signatures the fix should introduce) — and the published ablation puts the
score at roughly a third of its value without them. `--context-mode no-spec`
runs that ablation as a first-class mode.

## Real mechanics

**Dataset.** `ScaleAI/SWE-bench_Pro`, split `test`, 731 rows, `gated=False`,
no token needed. Columns: `repo, instance_id, base_commit, patch, test_patch,
problem_statement, requirements, interface, repo_language, fail_to_pass,
pass_to_pass, issue_specificity, issue_categories, before_repo_set_cmd,
selected_test_files_to_run, dockerhub_tag`. `fail_to_pass`/`pass_to_pass`/
`selected_test_files_to_run` are Python literals, not JSON — the official
harness `eval()`s them; we parse with `ast.literal_eval` (see
`dataset._literal_list`, and the apostrophe test that motivates it).

**Contamination control.** The public split is drawn from copyleft (GPL/AGPL)
repositories, so training on the solutions is a licensing problem for whoever
does it; the commercial split is held with Scale under commercial-use
agreements and is not published at all. There is no gate, no encryption and no
token on the public half — the control is legal, not cryptographic.

**Images.** Prebuilt, one per instance, on Docker Hub at
`jefzda/sweap-images:<dockerhub_tag>`. Use the dataset column, not
`helper_code/image_uri.get_dockerhub_image_uri`: 211 of 731 tags are truncated
at Docker Hub's 128-character limit, so the function cannot reconstruct them
from the instance_id. (Verified: the column and the function agree on all 731
*today*, and no two instances collide onto one tag — `test_dockerhub_tags_are_unique`
pins the second property, which is the one that would silently grade an
instance in the wrong environment.) Measured size 2.0–2.7 GB each on this host;
upstream's full catalogue is ~1.4 TB compressed. Images have not been rebuilt
since 2025-10-01.

The repo is at **`/app`**, not `/testbed`, and the images set
`ENTRYPOINT ["/bin/bash"]` — every `docker run`/`create` must pass
`--entrypoint` or the command becomes an argument to bash.

**Grading.** `harness/swe_bench_pro_eval.py --use_local_docker`, unmodified,
pinned by commit in `config.json`. Per instance it writes our patch plus the
instance's own `run_script.sh` and `parser.py` into `/workspace` and runs:

```
cd /app
git reset --hard <base_commit>
git checkout <base_commit>
git apply -v /workspace/patch.diff
git checkout <fix_commit> -- <test files>     # last line of before_repo_set_cmd
bash /workspace/run_script.sh <selected_test_files_to_run>
python /workspace/parser.py stdout.log stderr.log output.json
```

then scores `resolved = (fail_to_pass | pass_to_pass) ⊆ {t : t.status == PASSED}`.
Note this is stricter than Verified's: a **SKIPPED or absent** test counts as
not-passed, not as neutral.

The entryscript has no `set -e`, so a failed `git apply` does **not** stop the
run — the tests execute against an unpatched tree and the instance scores as an
ordinary miss. `evaluate.py` re-separates that case from stderr.

**The revert list.** `bench/swebench/runners.test_patch_files` documents why
this must never be guessed: a substring heuristic (`"test/" in path`) matched
`src/_pytest/` and destroyed 19 of 500 Verified gold patches while reporting
them as "the agent produced no patch". Pro hands us the grader's own command,
so `dataset.graded_away_paths()` **parses the `git checkout <sha> -- <paths>`
line out of `before_repo_set_cmd`** rather than inferring anything, and raises
rather than defaulting if that line is ever shaped differently. As a standing
cross-check it is compared against the `test_patch` file list; the two agree on
all 731 instances today, and a disagreement is reported on the run rather than
silently resolved.

## The leak this harness closes

**Every published image ships the answer in its own git history.** Measured:

```
$ docker run --rm --entrypoint /bin/bash --network none \
    jefzda/sweap-images:flipt-io.flipt-...-518ec324b66a07fdd95464a5e9ca5fe7681ad8f9 \
    -c 'cd /app && git show 518ec324b66a07fdd95464a5e9ca5fe7681ad8f9 --stat'
commit 518ec324b66a07fdd95464a5e9ca5fe7681ad8f9
    fix(config/cors): use strings.Fields for string to string slice fields (#1179)
 internal/config/config.go             | 22 +++++++++++++++++++++-
```

That is the gold patch, from a local command, with the network off. The images
carry the origin remote and ~237 refs including the fix commit, and for most
instances the fix SHA is the tail of the instance_id. **No network control
touches this** — airgapping the agent does nothing about it.

`workspace.strip_future_history()` removes the origin remote, every ref but
base, the reflog, and then the unreachable objects, and `prepare()` **refuses
to hand over a workspace** where the fix commit is still readable. The full
ancestry of `base_commit` is kept on purpose: a real engineer fixing this bug
would have the project's past, and taking that away measures something else.

Upstream knows (issue #93 reports a scanner with a 100% hit rate; PR #94
proposes this exact cleanup across all 731 Dockerfiles) but the PR is unmerged
and the images are frozen at 2025-10-01, so the leak is live in everything on
Docker Hub today. Any Pro result produced without this step — including
published ones — is an upper bound of unknown tightness.

**Residual, stated because it is not closed:** OSA runs on the host with
`shell_execute`, so an agent that thought of it could `docker run` the instance
image directly and read the history out of the *image* rather than the
workspace. Closing that needs the images pruned or docker denied, and denying
docker would remove the test bridge. It is recorded, not solved.

## Use

```bash
./setup.sh                    # venv + pinned clone of the official harness

# controls first, on any new machine — run BOTH
./run_bench.py --runner gold-apply --sample 12 --run-id ctrl-gold
./run_bench.py --runner empty --instances runs/ctrl-gold/instances.txt --run-id ctrl-empty

# the agent
./run_bench.py --write-airgap-settings airgap-settings.json
OSA_SETTINGS=$PWD/airgap-settings.json OSA_HTTP_PORT=19853 mix osa.serve &
./run_bench.py --runner osa --airgap --osa-url http://127.0.0.1:19853 \
               --instances runs/ctrl-gold/instances.txt

# the ablation this benchmark is uniquely good for
./run_bench.py --runner osa --airgap --context-mode no-spec \
               --instances runs/ctrl-gold/instances.txt

# report / gate
python ../report/cli.py summarise runs/<run-id>
python ../report/cli.py gate runs/<run-id>

./.venv/bin/python test_swebenchpro.py --live
```

`gold-apply` must score ~100% and `empty` exactly 0%. `gold-apply` is the one
that matters: plain `gold` returns the dataset patch directly and never
exercises workspace preparation or `git_diff()`, so it cannot catch an
extraction bug — which is exactly the bug that hid on Verified.

## Layout

| file | role |
|---|---|
| `dataset.py` | Dataset access, the grader's revert list, sampling, descriptive stats |
| `workspace.py` | `/app` extraction, bind-mount container, test bridge, **history stripping** |
| `runners.py` | Prompt + context ablation, gold / gold-apply / empty controls, OSA adapter |
| `evaluate.py` | Delegation to the official harness, and the adapter into the shared results schema |
| `run_bench.py` | Phase orchestration, selection provenance, airgap gate |
| `shared.py` | Loads the reusable halves of `bench/swebench` under non-colliding names |
| `test_swebenchpro.py` | 40 tests, one per way this pipeline can lie |
| `harness/` | Pinned clone of scaleapi/SWE-bench_Pro-os (gitignored) |

## Measured during the first real run (`runs/osa-s12-full`)

Two things the automated checks do **not** catch. Both are recorded here
because a reader of that run's `summary.md` would otherwise conclude more than
the evidence supports.

**1. The airgap does not stop toolchain egress.** `bench/report`'s gate reports
`web_lookup_prevention_verified`, and that claim is sound *for lookup of the
fix*: `web_search` was attempted twice and `web_fetch` once, and all three were
refused. But the deny list matches shell commands by prefix, and `go build` /
`go test` are not fetchers by name. Three instances show `go: downloading
github.com/...` in their recorded output — real outbound network from
`shell_execute` on the host, pulling pinned module versions. It does not
retrieve the solution (the modules are dependencies at fixed versions, and the
repo history no longer contains the fix), so the score stands, but "no network
egress occurred" would be false and `residual_shell_egress` did not flag it.
Its scanner looks for `urllib` / `requests.get` / github URLs *in commands*,
and `go build` contains none of those. Closing it properly needs a network
namespace, which this host cannot provide (see `bench/swebench/airgap.py` for
the measured reasons).

**2. `shell_execute` did not always run in the session's `working_dir`.**
The runner sends `working_dir` on every `/api/v1/orchestrate` call. Measured in
the transcripts: in 4 of 12 instances a `pwd` through `shell_execute` returned
`/home/miosa/projects/osa/OSA` — the backend's own boot directory — rather than
the instance workspace. In another instance a *relative* `./run_tests.sh`
resolved correctly and succeeded 36 times out of 36, so the behaviour is not
uniform and not simply "working_dir is ignored". None of the 253 recorded shell
commands used an absolute workspace path, so where the cwd was wrong the
command silently operated on the wrong tree.

This can only depress a score, never inflate it: an agent whose shell lands in
the wrong repository cannot run the project's tests and cannot inspect its own
edits. It also means the `git log` calls seen in two transcripts read *OSA's*
history, not the task repository's — so it is not a leak.

The mechanism is **not established**. `Workspace.Cwd.get/0` is the source both
`shell_execute` and the test bridge consult, and `turn_pipeline` publishes the
session's `working_dir` into the process dictionary of the Loop process; a tool
executing outside that process would miss the override and fall back to the
boot directory. That is a hypothesis consistent with the evidence, not a
diagnosis — it has not been reproduced in isolation, and a sequential probe
written to confirm it hit an unrelated failure
(`:ets.lookup(:osa_permission_responses, ...)` on a table that did not exist).
Reproducing it is the next step, not a claim to carry forward.

## Known upstream defects

Carried here so a reader of a run does not have to rediscover them.

| ref | effect | our status |
|---|---|---|
| #93 / PR #94 | git history in every image contains the fix commit | **closed by `strip_future_history`**; PR unmerged upstream |
| PR #111 | `docker.from_env()` 60 s read timeout makes long suites score as model failures | **measured NOT present** at docker-py 7.2.0 (`wait()` passes `timeout=None`); pinned by `TestDockerWaitTimeout` |
| #45 | ~40 flipt instances whose gold patch contains test data belonging to the test patch | unsolvable by construction; not excluded |
| #13/#14 | 5 rows with NULL `problem_statement`/`requirements`/`interface` | prompt degrades rather than crashes |
| #74 | one binary hunk zeroed a whole patch | fixed upstream (`strip_binary_hunks`), present in our pin |
| #108 | audit finds 109/728 tasks grade behaviour not pinned by anything the solver is given | a ceiling on any score, ours included |
| — | 3 instances whose own gold patch fails the grader | ours is a subset run; watch for them in `gold-apply` |

Timing, from upstream and consistent with what we measured: median ~13 min per
instance end to end, and ~13% of instances cannot be graded inside 600 s at
1 vCPU / 4 GB. `--eval-workers` defaults to 2 for that reason.
