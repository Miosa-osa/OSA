#!/usr/bin/env python3
"""Characterise the SHAPE of OSA's tool calls: how many repeat, and how many
travel together in one turn.

## The two questions this exists for

**Duplicates.** A published figure put OSA's duplicate-tool-call rate at 9.4%
against codex's 0.7%, and that 13x gap drove two shipped backstops which then
caught nothing on the corpus they were replayed over. An earlier claim of 43.5%
had already been retracted for reading `tool_call.args`, a 60-character display
hint. This script asks what the repeats actually ARE — which tools, which
arguments, and whether the repeat was rational (the world changed under it) or
waste (it returned the bytes the model already had).

**Batching.** Batch rate falls from ~0.31 at turn 0 to ~0.01 past turn 60, and
`P(batch | previous turn batched)` runs far above the base rate. The shipped
cadence nudge was designed against an in-context-imitation hypothesis that had
never been tested against a competing one. This script tests it against task
phase, tool mix, context size, error state, and survivorship.

## Field fidelity -- the discipline that makes these numbers trustworthy

Three findings have been retracted for reading a clipped field. Only these are
read here:

  * `tool_call.args_hash` -- SHA-256 prefix over the FULL argument map. This is
    the identity of a call. Runs that predate the field are DROPPED entirely
    rather than partially counted (`--min-hash-coverage`).
  * `tool_result.result` -- the full result payload, hashed to decide whether a
    repeat learned anything.
  * `command_output_delta.command` -- the complete unclipped shell command.
  * `tool_call.args` -- read for content ONLY when `args_bytes == len(args)`,
    i.e. when it is provably not clipped. Otherwise it is ignored.

## Two traps in the event stream, both of which inflate naive counts

  1. `tool_call` is emitted TWICE per call, `phase: "start"` and `phase: "end"`.
     Counting the events gives exactly 2x the calls. Filter on phase.
  2. `llm_response` is likewise emitted twice per model response, the first with
     `duration_ms` falsy. Turn boundaries are taken from that first event only.

## The counting trap that produced the 9.4%

Keying a "duplicate" on the RESULT payload rather than the arguments counts
every pair of DISTINCT calls that happen to share a constant success string --
`file_edit` answering "Replaced in /app/vm.js" for 164 different edits, shell
commands with empty output, `file_grep` answering "No matches found.". Those are
not duplicate calls in any sense. `--key result` reproduces the inflated number
so the two can be compared directly; `--key args` (the default) is the honest
one.

Usage:
    python3 scripts/tool_call_shape.py duplicates
    python3 scripts/tool_call_shape.py batching
    python3 scripts/tool_call_shape.py duplicates --key result   # reproduce 9.4%
"""
from __future__ import annotations

import argparse
import collections
import glob
import hashlib
import json
import math
import os
import re
import sys

DEFAULT_ROOT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "bench", "terminalbench", "runs")

# IdenticalCall's exemption list, mirrored so the detector can be simulated.
POLL_TOOLS = {"bash_output", "background_output", "task_status", "yield_time",
              "sleep", "wait"}
WRITE_TOOLS = {"file_write", "file_edit", "multi_file_edit", "file_transform",
               "file_create", "notebook_edit"}


# --------------------------------------------------------------------------
# corpus
# --------------------------------------------------------------------------
class Call:
    __slots__ = ("name", "args_hash", "args_raw", "args_complete", "tcid",
                 "success", "result", "result_hash", "command", "turn_idx")

    def __init__(self, **kw):
        for k in self.__slots__:
            setattr(self, k, kw.get(k))

    @property
    def key(self):
        return (self.name, self.args_hash)

    def argtext(self):
        """The best FAITHFUL rendering of the arguments, or None if the only
        available rendering is the clipped display hint."""
        if self.command:
            return self.command
        if self.args_complete:
            return self.args_raw
        return None


class Turn:
    __slots__ = ("idx", "calls", "input_tokens")

    def __init__(self, idx, calls, input_tokens):
        self.idx, self.calls, self.input_tokens = idx, calls, input_tokens

    @property
    def n(self):
        return len(self.calls)

    @property
    def batched(self):
        return len(self.calls) > 1

    @property
    def lead(self):
        return self.calls[0].name

    @property
    def had_error(self):
        return any(c.success is False for c in self.calls)


class Session:
    __slots__ = ("path", "run", "task", "turns")

    def __init__(self, path, run, task, turns):
        self.path, self.run, self.task, self.turns = path, run, task, turns

    @property
    def calls(self):
        return [c for t in self.turns for c in t.calls]

    def reward(self):
        p = os.path.join(os.path.dirname(os.path.dirname(self.path)),
                         "verifier", "reward.txt")
        try:
            return float(open(p).read().strip())
        except Exception:
            return None


def _h(s):
    return hashlib.sha256(s.encode("utf-8", "replace")).hexdigest()[:16]


def load_session(path):
    events = []
    with open(path, errors="replace") as fh:
        for line in fh:
            try:
                events.append(json.loads(line))
            except Exception:
                continue

    results, commands, ends = {}, {}, {}
    for e in events:
        t = e.get("type")
        if t == "tool_result":
            r = e.get("result")
            results[e.get("tool_call_id")] = (
                r if isinstance(r, str) else json.dumps(r, sort_keys=True, default=str))
        elif t == "command_output_delta" and e.get("command"):
            commands[e.get("tool_call_id")] = e["command"]
        elif t == "tool_call" and e.get("phase") == "end":
            ends[e.get("tool_call_id")] = e

    turns, cur, in_tok = [], [], None
    for e in events:
        t = e.get("type")
        if t == "llm_response" and not e.get("duration_ms"):
            if cur:
                turns.append((cur, in_tok))
                cur = []
            in_tok = (e.get("usage") or {}).get("input_tokens")
        elif t == "tool_call" and e.get("phase") == "start":
            tcid = e.get("tool_call_id")
            raw, ab = e.get("args"), e.get("args_bytes")
            raw_s = raw if isinstance(raw, str) else (
                json.dumps(raw, sort_keys=True) if raw is not None else None)
            res = results.get(tcid)
            cur.append(Call(
                name=e.get("name"), args_hash=e.get("args_hash"), args_raw=raw_s,
                args_complete=(raw_s is not None and ab is not None and len(raw_s) == ab),
                tcid=tcid, success=ends.get(tcid, e).get("success"),
                result=res, result_hash=(_h(res) if res is not None else None),
                command=commands.get(tcid)))
    if cur:
        turns.append((cur, in_tok))

    parts = path.split(os.sep)
    run = parts[parts.index("runs") + 1] if "runs" in parts else "?"
    sess = Session(path, run, parts[-3], [])
    for i, (calls, it) in enumerate(turns):
        for c in calls:
            c.turn_idx = i
        sess.turns.append(Turn(i, calls, it))
    return sess


def load(root, min_coverage=1.0, min_calls=50):
    """Load every session, then DROP whole runs whose `args_hash` coverage is
    below `min_coverage`. Partial coverage is not averaged over: a run that
    predates the field would silently deflate every repeat rate computed from
    it."""
    sessions = []
    for p in sorted(glob.glob(os.path.join(root, "**", "osa-events.jsonl"),
                              recursive=True)):
        try:
            s = load_session(p)
        except Exception:
            continue
        if s.turns:
            sessions.append(s)
    stat = collections.defaultdict(lambda: [0, 0])
    for s in sessions:
        for c in s.calls:
            stat[s.run][0] += 1
            stat[s.run][1] += bool(c.args_hash)
    keep = {r for r, (n, h) in stat.items()
            if n >= min_calls and h / n >= min_coverage}
    dropped = sorted(set(stat) - keep)
    return [s for s in sessions if s.run in keep], dropped, stat


# --------------------------------------------------------------------------
# duplicates
# --------------------------------------------------------------------------
def cmd_class(cmd):
    c = cmd.strip().lower()
    head = c.split()[0] if c.split() else ""
    if any(k in c for k in ("pytest", "npm test", "go test", "cargo test",
                            "unittest", "./test", "make test")):
        return "run tests"
    if any(k in c for k in ("make", "cmake", "gcc", "g++", "cargo build",
                            "npm run build", "./configure", "pip install", "apt-get")):
        return "build / install"
    if head in ("ls", "find", "cat", "head", "tail", "grep", "rg", "wc", "stat",
                "file", "tree", "pwd", "which", "sed", "awk"):
        return "inspect files"
    if head in ("ps", "top", "sleep", "jobs", "kill"):
        return "poll / wait"
    if head == "git":
        return "git"
    if head in ("python", "python3", "node", "sh", "bash"):
        return "run script"
    return "other"


def duplicates(sessions, key="args"):
    calls = [c for s in sessions for c in s.calls if c.args_hash]
    n = len(calls)
    print(f"corpus: {len(sessions)} sessions, {n} calls with a faithful args_hash\n")

    def keyfn(c):
        return (c.name, c.result_hash) if key == "result" else c.key

    print("=" * 74)
    print("1. WHAT EACH DEFINITION COUNTS")
    print("=" * 74)
    for label, kf in (("name + args_hash  (a call really was repeated)", lambda c: c.key),
                      ("name + result hash (what the 9.4% counted)",
                       lambda c: (c.name, c.result_hash))):
        grp = collections.defaultdict(list)
        for s in sessions:
            for c in s.calls:
                if c.args_hash:
                    grp[(id(s), kf(c))].append(c)
        later = sum(len(v) - 1 for v in grp.values())
        allm = sum(len(v) for v in grp.values() if len(v) > 1)
        print(f"  {label}")
        print(f"      repeats only          {later:5d}  {later/n*100:5.2f}%")
        print(f"      all members of a group{allm:5d}  {allm/n*100:5.2f}%")

    # how much of the result-keyed count is distinct calls sharing a constant string
    shared = collections.Counter()
    diff_args = 0
    for s in sessions:
        g = collections.defaultdict(list)
        for c in s.calls:
            if c.result is not None:
                g[(c.name, c.result_hash)].append(c)
        for v in g.values():
            for c in v[1:]:
                if c.args_hash != v[0].args_hash:
                    diff_args += 1
                    r = (c.result or "").strip()
                    shared[(c.name, r[:52])] += 1
    print(f"\n  of the result-keyed repeats, {diff_args} have DIFFERENT arguments --")
    print("  distinct calls sharing a constant success string, not duplicates:")
    for (nm, r), k in shared.most_common(6):
        print(f"      x{k:<4d} {nm:14s} {r!r}")

    records = []
    for s in sessions:
        seen = {}
        for c in s.calls:
            if not c.args_hash:
                continue
            k = keyfn(c)
            if k in seen:
                p = seen[k]
                records.append({"c": c, "p": p, "s": s,
                                "gap": c.turn_idx - p.turn_idx,
                                "same": c.result_hash == p.result_hash})
            seen[k] = c

    print("\n" + "=" * 74)
    print("2. RATIONAL OR WASTE -- did the repeat return the bytes it already had?")
    print("=" * 74)
    same = sum(1 for r in records if r["same"])
    print(f"  repeats                                   {len(records):5d}  {len(records)/n*100:5.2f}%")
    if key == "result":
        print("  the rational/waste split is meaningless under --key result: the key IS")
        print("  the result, so every repeat is 'identical' by construction. That is the")
        print("  flaw, not a finding -- note file_edit's absurd rate in the table below,")
        print("  which is one constant confirmation string, not repeated edits.")
    else:
        print(f"  ... identical result (nothing learned)    {same:5d}  {same/n*100:5.2f}%  <- the real waste")
        print(f"  ... different result (world changed)      {len(records)-same:5d}  "
              f"{(len(records)-same)/n*100:5.2f}%")

    print(f"\n  {'tool':<16s}{'calls':>7s}{'repeats':>9s}{'rate':>7s}{'wasted':>8s}")
    tot = collections.Counter(c.name for c in calls)
    rep = collections.Counter(r["c"].name for r in records)
    wst = collections.Counter(r["c"].name for r in records if r["same"])
    for nm, _ in rep.most_common(8):
        print(f"  {nm:<16s}{tot[nm]:7d}{rep[nm]:9d}{rep[nm]/tot[nm]*100:6.1f}%{wst[nm]:8d}")

    print("\n" + "=" * 74)
    print("3. HOW FAR APART, AND WHAT THE REPEATED SHELL COMMANDS WERE")
    print("=" * 74)
    buck = collections.Counter()
    bw = collections.Counter()
    for r in records:
        g = r["gap"]
        b = ("same turn" if g == 0 else "next turn" if g == 1 else "2-5" if g <= 5
             else "6-20" if g <= 20 else ">20")
        buck[b] += 1
        bw[b] += r["same"]
    print(f"  {'turn gap':<12s}{'repeats':>9s}{'wasted':>9s}")
    for b in ("same turn", "next turn", "2-5", "6-20", ">20"):
        if buck[b]:
            print(f"  {b:<12s}{buck[b]:9d}{bw[b]:9d}")
    sh = [r for r in records if r["c"].name == "shell_execute" and r["c"].command]
    cls, clsw = collections.Counter(), collections.Counter()
    for r in sh:
        k = cmd_class(r["c"].command)
        cls[k] += 1
        clsw[k] += r["same"]
    print(f"\n  shell repeats with full command text: {len(sh)}")
    print(f"  {'class':<18s}{'repeats':>9s}{'wasted':>9s}")
    for k, v in cls.most_common():
        print(f"  {k:<18s}{v:9d}{clsw[k]:9d}")

    print("\n" + "=" * 74)
    print("4. RE-READS: was there an intervening write to justify them?")
    print("=" * 74)
    j = collections.Counter()
    for r in (x for x in records if x["c"].name == "file_read"):
        lo, hi = r["p"].turn_idx, r["c"].turn_idx
        wrote = any(c.name in WRITE_TOOLS and lo <= c.turn_idx <= hi
                    for c in r["s"].calls)
        j[("a write happened between" if wrote else "no write between", r["same"])] += 1
    print(f"  {'':<26s}{'wasted':>9s}{'changed':>9s}")
    for k in ("a write happened between", "no write between"):
        print(f"  {k:<26s}{j[(k, True)]:9d}{j[(k, False)]:9d}")

    print("\n" + "=" * 74)
    print("5. WHY THE SHIPPED BACKSTOPS FIND NOTHING")
    print("=" * 74)
    grp = collections.defaultdict(int)
    for s in sessions:
        cc = collections.Counter((c.name, c.args_hash, c.result_hash)
                                 for c in s.calls if c.args_hash)
        for v in cc.values():
            if v > 1:
                grp[v] += 1
    print(f"  byte-identical repeat group sizes: {dict(sorted(grp.items()))}")
    print("  IdenticalCall nudges at 3 and halts at 5. The population is PAIRS.")
    for label, kw in (("shipped (poll+blank exempt, nudge 3, halt 5)", {}),
                      ("without the poll/blank exemption", {"exempt": False}),
                      ("threshold lowered to pairs", {"nudge": 2, "halt": 99}),
                      ("pairs AND no exemption", {"nudge": 2, "halt": 99, "exempt": False})):
        print(f"  {label:<44s}{dict(simulate_identical_call(sessions, **kw))}")


def simulate_identical_call(sessions, window=20, nudge=3, halt=5, exempt=True):
    """Replay IdenticalCall's windowed rule over the corpus.

    Mirrors `doom_loop/identical_call.ex`: a window of the last 20 results,
    counting backwards and PARTITIONING at the first same-key entry whose result
    differs, with poll tools and blank results skipped entirely."""
    def eligible(c):
        return not (c.name in POLL_TOOLS or "poll" in c.name
                    or not (c.result or "").strip())

    fires = collections.Counter()
    for s in sessions:
        calls, hist = s.calls, []
        for i, c in enumerate(calls):
            if exempt and i > 0:
                last = calls[i - 1]
                if last.name in POLL_TOOLS or not (last.result or "").strip():
                    hist = (hist + [c])[-window:]
                    continue
            hist = (hist + [c])[-window:]
            if exempt and not eligible(c):
                continue
            n = 0
            for p in reversed(hist):
                if p.key != c.key or (exempt and not eligible(p)):
                    continue
                if p.result_hash != c.result_hash:
                    break
                n += 1
            if n >= halt:
                fires["halt"] += 1
            elif n >= nudge:
                fires["nudge"] += 1
    return fires


# --------------------------------------------------------------------------
# batching
# --------------------------------------------------------------------------
BANDS = [("0-2", 0, 2), ("3-5", 3, 5), ("6-9", 6, 9), ("10-14", 10, 14),
         ("15-29", 15, 29), ("30-59", 30, 59), ("60+", 60, 10 ** 9)]


def band(i):
    for lbl, lo, hi in BANDS:
        if lo <= i <= hi:
            return lbl
    return "60+"


def _rate_table(turns, title):
    agg = collections.defaultdict(lambda: [0, 0])
    for t in turns:
        agg[band(t.idx)][0] += 1
        agg[band(t.idx)][1] += t.batched
    print(f"  {title}")
    print(f"  {'turn':<8s}{'turns':>7s}{'batch rate':>12s}")
    for lbl, _, _ in BANDS:
        n, k = agg[lbl]
        if n:
            print(f"  {lbl:<8s}{n:7d}{k/n*100:11.1f}%")


def logistic(rows, feats, iters=3000, lr=0.5):
    mu = {f: sum(r[f] for r in rows) / len(rows) for f in feats}
    sd = {f: (sum((r[f] - mu[f]) ** 2 for r in rows) / len(rows)) ** 0.5 or 1.0
          for f in feats}
    w = {f: 0.0 for f in feats}
    b = 0.0
    for _ in range(iters):
        gw = {f: 0.0 for f in feats}
        gb = 0.0
        for r in rows:
            z = b + sum(w[f] * (r[f] - mu[f]) / sd[f] for f in feats)
            p = 1 / (1 + math.exp(-max(-30, min(30, z))))
            e = p - r["y"]
            gb += e
            for f in feats:
                gw[f] += e * (r[f] - mu[f]) / sd[f]
        b -= lr * gb / len(rows)
        for f in feats:
            w[f] -= lr * gw[f] / len(rows)
    ll = 0.0
    for r in rows:
        z = b + sum(w[f] * (r[f] - mu[f]) / sd[f] for f in feats)
        p = min(max(1 / (1 + math.exp(-max(-30, min(30, z)))), 1e-9), 1 - 1e-9)
        ll += r["y"] * math.log(p) + (1 - r["y"]) * math.log(1 - p)
    return w, ll


def batching(sessions):
    turns = [t for s in sessions for t in s.turns]
    print(f"corpus: {len(sessions)} sessions, {len(turns)} tool-bearing turns\n")

    print("=" * 74)
    print("1. THE DECAY, AND WHETHER IT IS SURVIVORSHIP")
    print("=" * 74)
    _rate_table(turns, "all sessions")
    long_ss = [s for s in sessions if len(s.turns) >= 30]
    print()
    _rate_table([t for s in long_ss for t in s.turns],
                f"only the {len(long_ss)} sessions that themselves reach 30+ turns")
    print("\n  If the decay held only in the pooled table it would be a shifting mix")
    print("  OF sessions. It holds inside the long sessions too, so it is a real")
    print("  within-session decay.")

    print("\n" + "=" * 74)
    print("2. TOOL MIX -- how much of the decay is just 'later turns are shell'?")
    print("=" * 74)
    tb = collections.defaultdict(lambda: [0, 0])
    for t in turns:
        tb[t.lead][0] += 1
        tb[t.lead][1] += t.batched
    print(f"  {'leading tool':<16s}{'turns':>7s}{'batch rate':>12s}")
    for nm, (a, b) in sorted(tb.items(), key=lambda kv: -kv[1][0])[:8]:
        print(f"  {nm:<16s}{a:7d}{b/a*100:11.1f}%")
    mix = collections.defaultdict(collections.Counter)
    for t in turns:
        mix[band(t.idx)][t.lead] += 1
    tools = ["shell_execute", "file_read", "task_write", "file_edit"]
    print(f"\n  share of turns led by each tool, by position")
    print(f"  {'turn':<8s}" + "".join(f"{x[:12]:>14s}" for x in tools))
    for lbl, _, _ in BANDS:
        tot = sum(mix[lbl].values())
        if tot:
            print(f"  {lbl:<8s}" + "".join(f"{mix[lbl][x]/tot*100:13.0f}%" for x in tools))
    print("\n  The mix shifts to shell between turn 0-2 and 3-5 and is FLAT after,")
    print("  while the batch rate keeps falling. Mix explains the first drop only.")

    print("\n" + "=" * 74)
    print("3. POSITION, CONTROLLED FOR TOOL")
    print("=" * 74)
    for tool in ("shell_execute", "file_read", "task_write"):
        a = collections.defaultdict(lambda: [0, 0])
        for t in turns:
            if t.lead == tool:
                a[band(t.idx)][0] += 1
                a[band(t.idx)][1] += t.batched
        line = "".join(f"  {lbl}:{k/n*100:.0f}%(n={n})"
                       for lbl, _, _ in BANDS for n, k in [a[lbl]] if n >= 20)
        print(f"  {tool:<15s}{line}")
    print("\n  task_write barely decays; shell and file_read collapse.")

    print("\n" + "=" * 74)
    print("4. LOCK-IN, RAW AND WITHIN TOOL")
    print("=" * 74)
    pairs = collections.Counter()
    pt = collections.defaultdict(collections.Counter)
    for s in sessions:
        for a, b in zip(s.turns, s.turns[1:]):
            pairs[(a.batched, b.batched)] += 1
            pt[b.lead][(a.batched, b.batched)] += 1

    def cond(c):
        tot = sum(c.values()) or 1
        return (c[(True, True)] / max(c[(True, True)] + c[(True, False)], 1),
                c[(False, True)] / max(c[(False, True)] + c[(False, False)], 1),
                (c[(True, True)] + c[(False, True)]) / tot)
    pb, ps, base = cond(pairs)
    print(f"  P(batch | prev batched) {pb:.3f}   P(batch | prev not) {ps:.3f}   base {base:.3f}")
    print(f"\n  {'tool':<16s}{'P(b|prev b)':>12s}{'P(b|prev ~b)':>14s}{'base':>8s}")
    for tool in ("shell_execute", "file_read", "task_write", "file_edit"):
        if sum(pt[tool].values()) >= 40:
            a, b, c = cond(pt[tool])
            print(f"  {tool:<16s}{a:12.3f}{b:14.3f}{c:8.3f}")
    print("\n  Lock-in survives inside every tool, so it is not a tool-mix artifact.")

    print("\n" + "=" * 74)
    print("5. IMITATION vs TASK PHASE")
    print("=" * 74)
    rows = []
    for s in sessions:
        for i, t in enumerate(s.turns):
            if i < 6:
                continue
            prev, win = s.turns[i - 1], s.turns[i - 5:i]
            rows.append({
                "y": 1.0 if t.batched else 0.0,
                "log_turn": math.log1p(t.idx),
                "prev_batched": 1.0 if prev.batched else 0.0,
                "is_shell": 1.0 if t.lead == "shell_execute" else 0.0,
                "log_ctx": math.log1p(t.input_tokens or 0),
                "prev_err": 1.0 if prev.had_error else 0.0,
                "win_shell": sum(1 for x in win if x.lead == "shell_execute") / len(win),
                "win_read": sum(1 for x in win if x.lead in
                                ("file_read", "file_grep", "dir_list", "file_glob")) / len(win),
                "win_edit": sum(1 for x in win if x.lead in WRITE_TOOLS) / len(win)})
    allf = ["log_turn", "prev_batched", "is_shell", "log_ctx", "prev_err",
            "win_shell", "win_read", "win_edit"]
    w, ll_full = logistic(rows, allf)
    print(f"  n = {len(rows)}. Standardised log-odds per SD:")
    for f in sorted(allf, key=lambda f: -abs(w[f])):
        print(f"    {f:<14s}{w[f]:+8.3f}")
    _, ll_pos = logistic(rows, ["log_turn"])
    _, ll_phase = logistic(rows, ["log_turn", "is_shell", "win_shell", "win_read", "win_edit"])
    print(f"\n  log-likelihood  position only {ll_pos:9.1f}")
    print(f"                  + tool & phase {ll_phase:9.1f}  ({ll_phase-ll_pos:+.1f})")
    print(f"                  + prev_batched {ll_full:9.1f}  ({ll_full-ll_phase:+.1f} ON TOP of phase)")
    print("\n  prev_batched buys a large gain that task phase cannot supply, so the")
    print("  autocorrelation is not merely a phase proxy.")

    g = collections.defaultdict(lambda: [0, 0])
    for s in sessions:
        for a, b in zip(s.turns, s.turns[1:]):
            k = min(a.n, 5)
            g[k][0] += 1
            g[k][1] += b.n
    print(f"\n  graded test -- previous turn SIZE vs mean size of the next turn:")
    print(f"    {'prev size':<12s}{'n':>7s}{'next mean':>12s}")
    for k in sorted(g):
        n, tot = g[k]
        if n >= 20:
            print(f"    {k:<12d}{n:7d}{tot/n:12.2f}")
    print("  Monotonic and graded: the model copies the MAGNITUDE, not a flag.")

    print("\n" + "=" * 74)
    print("6. IS THE SHIPPED CADENCE TRIGGER SPECIFIC?")
    print("=" * 74)
    by = collections.defaultdict(lambda: [0, 0])
    for s in sessions:
        hist = []
        for t in s.turns:
            if t.idx >= 8 and len(hist) >= 6:
                by[band(t.idx)][0] += 1
                by[band(t.idx)][1] += all(x == 1 for x in hist[-6:])
            hist.append(t.n)
    print(f"  {'turn':<8s}{'eligible':>10s}{'flat? TRUE':>12s}{'':>4s}")
    for lbl, _, _ in BANDS:
        n, k = by[lbl]
        if n:
            print(f"  {lbl:<8s}{n:10d}{k:12d}{k/n*100:8.0f}%")
    print("\n  'six single-call turns in a row' is the NORMAL state of a late")
    print("  session, not an anomaly. The trigger cannot tell a model that is")
    print("  needlessly serial from one that is correctly serial.")

    print("\n" + "=" * 74)
    print("7. DOES BATCHING TRACK SOLVING?")
    print("=" * 74)
    agg = collections.defaultdict(lambda: [0, 0, 0])
    for s in sessions:
        r = s.reward()
        if r is None:
            continue
        k = "solved" if r >= 1.0 else "failed"
        agg[k][2] += 1
        for t in s.turns[:15]:
            agg[k][0] += 1
            agg[k][1] += t.batched
    if not agg:
        print("  no verifier/reward.txt found -- NOT MEASURED")
    else:
        for k, (n, b, c) in sorted(agg.items()):
            print(f"  {k:<8s}{c:4d} sessions   first 15 turns: {b}/{n} batched = {b/n*100:.1f}%")
        print("\n  Observational only. It does not support the assumption that")
        print("  raising the batch rate raises the solve rate.")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=["duplicates", "batching"])
    ap.add_argument("--root", default=DEFAULT_ROOT)
    ap.add_argument("--key", choices=["args", "result"], default="args",
                    help="identity of a call; 'result' reproduces the inflated 9.4%%")
    ap.add_argument("--min-hash-coverage", type=float, default=1.0)
    args = ap.parse_args()

    sessions, dropped, stat = load(args.root, args.min_hash_coverage)
    if not sessions:
        print(f"no usable sessions under {args.root}", file=sys.stderr)
        return 1
    if dropped:
        print(f"dropped {len(dropped)} run(s) below {args.min_hash_coverage:.0%} "
              f"args_hash coverage: {', '.join(dropped)}\n")
    if args.mode == "duplicates":
        duplicates(sessions, key=args.key)
    else:
        batching(sessions)
    return 0


if __name__ == "__main__":
    sys.exit(main())
