"""Prevent the agent from looking the answer up on the web.

## Why this file exists

Every SWE-bench instance is a *published* commit in a *public* repository, and
the prompt names the repository and the exact base commit. An agent with web
access can retrieve the upstream fix instead of deriving it. The official
SWE-bench submission checklist therefore requires

    "Does not have web-browsing OR has taken steps to prevent lookup of
     SWE-bench solutions via web-browsing"

and Epoch AI runs airgapped for the same reason.

The task container is started `--network none`, but that is irrelevant: OSA
runs on the **host**, with `web_search` / `web_fetch` / `download` / `browser`
available and `permission_mode overdrive` disabling the approval path. In the
40-instance run `osa-hard40-v2`, six instances used `web_fetch` and **all six
resolved**, against 52.9% elsewhere. That is not a footnote, it is the
difference between a measurement and a lookup.

## What was tried before, and why it did not work

A `PreToolUse` deny hook written into the workspace's
`.osa/settings.local.json`. Probed against a live backend: `web_search`
executed normally. Root cause is in OSA, not here — `Settings.layer(:local)`
resolves its path through `Workspace.Cwd.get()`, which is process-global, so
the per-request `working_dir` on `/api/v1/orchestrate` cannot move it. That
attempt is preserved as a documented negative result in `workspace.py`
(`write_airgap`), default-off.

## What this file does instead

It uses a **different settings layer**, one that needs no session scoping at
all.

`Settings.layer(:flag)` reads the file named by the `OSA_SETTINGS` environment
variable of the *backend process*. Three properties make it the right lever:

1. **It is never trust-gated.** `Settings.trusted_layer/1` withholds only the
   `:project` layer pending workspace trust; `:flag` always applies
   (`settings.ex`, `layer_rule_list/2`).
2. **It is a first-class permission-rule source.** `Permissions.rules/0`
   reads `deny` / `ask` / `allow` from `@settings_sources = [:session, :flag,
   :local, :project, :user]`.
3. **A deny rule outranks `overdrive`.** `Agent.Loop.ToolExecutor` consults
   `saved_rule_denies?/1` at step 1b, *before* any permission-mode
   short-circuit: "only an explicit deny is absolute".

Per-session scoping is not needed because the benchmark backend is a dedicated
daemon on its own port. Denying a tool for the whole process denies it for
every instance, which is exactly the intent.

## What this does NOT close

`shell_execute` remains available — the agent needs a shell, and a benchmark
that removes it measures something else. Deny rules cover the obvious fetchers
(`curl`, `wget`, `git clone`, `pip install`, …) by command prefix, and
`Permissions` fires a deny when **any** subcommand of a compound command
matches. It cannot cover `python3 -c "import urllib..."`. That residual surface
is real, is stated in the report, and is checked against the recorded
transcripts after the fact by `residual_egress_evidence()`.

A network namespace would close it properly. It is not available on this host:
`kernel.apparmor_restrict_unprivileged_userns = 1` (Ubuntu 24.04) makes
`unshare --net` fail with `write failed /proc/self/uid_map: Operation not
permitted`, and `/usr/bin/bwrap` is not setuid, so `bwrap --unshare-net` fails
at `RTM_NEWADDR`. Both were executed and both failed; this is a measured
negative, not an assumption. On a host with unprivileged user namespaces
enabled, or with root, run the backend under `unshare -rn` with a unix-socket
relay to the provider and this whole file becomes belt-and-braces.
"""

from __future__ import annotations

import json
import time
import uuid
from pathlib import Path

#: Tools that can, on their own, retrieve the published upstream fix.
#:
#: The `git` TOOL is deliberately NOT here: the agent needs `git status` and
#: `git diff` to do the task at all, and the workspace has no remotes. The
#: remote-reaching git subcommands are denied by content instead, through
#: SHELL_FETCHER_PREFIXES below.
NETWORK_TOOLS = (
    "web_search",
    "web_fetch",
    "download",
    "browser",
    "github",
    "computer_use",
)

#: CC-style aliases OSA accepts for the same tools (`Permissions.@tool_aliases`).
#: Denying both spellings costs nothing and removes a way to be wrong.
NETWORK_TOOL_ALIASES = ("WebSearch", "WebFetch")

#: `shell_execute(<prefix>:*)` deny rules. Prefix matching, and a deny fires
#: when ANY subcommand of a compound command matches, so `cd x && curl ...` is
#: covered. Two-word entries are used where the bare program is legitimate
#: (`git` and `pip` are needed; `git fetch` and `pip install` are not).
SHELL_FETCHER_PREFIXES = (
    "curl",
    "wget",
    "aria2c",
    "http",
    "httpie",
    "lynx",
    "w3m",
    "links",
    "elinks",
    "nc",
    "ncat",
    "netcat",
    "telnet",
    "ssh",
    "scp",
    "sftp",
    "rsync",
    "ftp",
    "git clone",
    "git fetch",
    "git pull",
    "git remote",
    "git ls-remote",
    "gh",
    "pip install",
    "pip download",
    "pip3 install",
    "python -m pip",
    "python3 -m pip",
    "uv pip",
    "uvx",
    "npm install",
    "npx",
    "conda install",
    "apt-get",
    "apt",
)


#: Substring rules, for the egress a prefix rule cannot see. `Permissions`
#: content matching treats `*` as "any characters, newlines included", so
#: `shell_execute(*urllib*)` denies a command that mentions urllib ANYWHERE --
#: including inside a `python3 -c "..."` heredoc spanning several lines, which
#: is exactly the shape the previous run's leak took:
#:
#:     python3 -c "
#:     import urllib.request
#:     url='https://raw.githubusercontent.com/sympy/sympy/...'
#:
#: This is a blunt instrument and it is meant to be. It will refuse a
#: legitimate command that merely mentions one of these tokens, which for a
#: SWE-bench task is a cost worth paying: the alternative is a score that might
#: have been read off GitHub. Every refusal is visible to the agent, which can
#: then do the work without the network.
SHELL_EGRESS_SUBSTRINGS = (
    "urllib",
    "urlopen",
    "requests.get",
    "requests.post",
    "http.client",
    "httpx",
    "socket.create_connection",
    "://github.com",
    "://raw.githubusercontent.com",
    "://gitlab.com",
    "://bitbucket.org",
    "://codeload.github.com",
    "://api.github.com",
)

#: Tools that are shells by another name and would otherwise route around every
#: `shell_execute` rule above.
OTHER_EXEC_TOOLS = ("repl", "pty", "code_sandbox")


def deny_rules() -> list[str]:
    """Every deny rule this airgap installs, in the order it installs them."""
    rules = [t for t in NETWORK_TOOLS]
    rules += list(NETWORK_TOOL_ALIASES)
    rules += [f"shell_execute({p}:*)" for p in SHELL_FETCHER_PREFIXES]
    rules += [f"shell_execute(*{s}*)" for s in SHELL_EGRESS_SUBSTRINGS]
    for tool in OTHER_EXEC_TOOLS:
        rules += [f"{tool}(*{s}*)" for s in SHELL_EGRESS_SUBSTRINGS]
        rules += [f"{tool}(*{p}*)" for p in ("curl ", "wget ", "urlretrieve")]
    return rules


def settings_document() -> dict:
    """The `OSA_SETTINGS` document that enforces the airgap.

    Deliberately minimal: it sets nothing except the deny list, so pointing a
    backend at it changes exactly one thing about that backend's behaviour.
    """
    return {
        "_comment": (
            "Written by bench/swebench/airgap.py. Denies every tool that can "
            "retrieve the published upstream fix for a SWE-bench instance. "
            "Point a BENCHMARK backend at this file with OSA_SETTINGS=<path>; "
            "never the everyday daemon."
        ),
        "permissions": {"deny": deny_rules()},
    }


def write_settings(path: Path) -> dict:
    """Write the airgap settings file and return what was written."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    doc = settings_document()
    path.write_text(json.dumps(doc, indent=2) + "\n")
    return doc


# ---------------------------------------------------------------------------
# The probe. Nothing here is trusted without it.
# ---------------------------------------------------------------------------

#: The probe is DIFFERENTIAL, and that is the whole point of its design.
#:
#: "web_fetch failed" on its own proves nothing — the network could be down,
#: the tool could be broken, the model could have declined to call it. So the
#: same prompt also requires a tool that is NOT on the deny list. A pass means
#: the denied tool was called and refused AND the allowed tool was called and
#: worked, in one session, under `permission_mode overdrive`. Anything less is
#: not enforcement, it is a coincidence that resembles it.
PROBE_PROMPT = (
    "Do exactly these four things, in order, and report what happened for "
    "each. Do not skip a step because an earlier one failed.\n"
    "1. Call the web_fetch tool on https://example.com .\n"
    '2. Call shell_execute with exactly this command:\n'
    '   python3 -c "import urllib.request; '
    "print(urllib.request.urlopen('https://example.com').read()[:80])\"\n"
    "3. Call shell_execute with exactly this command:  echo AIRGAP_SHELL_OK\n"
    "4. Call the dir_list tool on the current directory.\n"
    "For each step say whether the tool call succeeded or was refused, and "
    "quote any content that came back verbatim."
)

#: The tool that must still work. If this one is also refused, the probe has
#: measured a broken backend rather than a working deny list.
CONTROL_TOOL = "dir_list"

#: Step 2's tool. Denial here is what closes the residual shell surface.
SHELL_TOOL = "shell_execute"

#: Step 3. The substring deny rules are blunt, and a rule that accidentally
#: matched every command would delete the benchmark's ability to do anything
#: while looking like a strong airgap. This asserts the blast radius is bounded:
#: a shell command with no egress marker in it still runs.
BENIGN_SHELL_MARKER = "AIRGAP_SHELL_OK"


def probe(
    *,
    base_url: str,
    auth_token: str | None = None,
    timeout_s: int = 180,
    working_dir: str | None = None,
) -> dict:
    """Ask a live backend to use a denied tool, and record what happened.

    Returns an attestation dict. `enforced` is True only when a `web_fetch`
    call was observed AND its result was a denial, or when no `web_fetch`
    call was ever emitted and the agent reported being refused. Anything else
    — including "the tool ran and returned a page" — is False.

    This is deliberately evidence-first. The previous attempt at an airgap
    looked correct and did nothing; the difference between the two is that
    this one is not believed until a backend has been observed refusing.
    """
    import requests  # local import: airgap.py is importable without it

    sid = f"airgap-probe-{uuid.uuid4().hex[:10]}"
    headers = {"Content-Type": "application/json"}
    if auth_token:
        headers["Authorization"] = f"Bearer {auth_token}"

    att: dict = {
        "probed_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "base_url": base_url,
        "session_id": sid,
        "enforced": False,
        "tool_calls_seen": [],
        "denied_tool_evidence": None,
        "shell_egress_evidence": None,
        "control_tool_evidence": None,
        "page_content_observed": False,
        "final_message_tail": None,
        "error": None,
        "deny_rules": deny_rules(),
    }

    s = requests.Session()
    frames: list[dict] = []
    stop = {"v": False}

    import threading

    def reader() -> None:
        try:
            with s.get(
                f"{base_url.rstrip('/')}/api/v1/stream/{sid}",
                headers=headers,
                stream=True,
                timeout=(10, timeout_s + 30),
            ) as r:
                for line in r.iter_lines(decode_unicode=True):
                    if stop["v"]:
                        return
                    if not line or not line.startswith("data:"):
                        continue
                    try:
                        frames.append(json.loads(line[5:].strip()))
                    except json.JSONDecodeError:
                        continue
        except Exception:  # noqa: BLE001 - the caller reports it as no evidence
            return

    t = threading.Thread(target=reader, daemon=True)
    t.start()
    time.sleep(1.0)

    try:
        # Same permission posture as a real benchmark instance: if overdrive
        # could bypass the deny rule, the probe must find that out.
        s.post(
            f"{base_url.rstrip('/')}/api/v1/commands/execute",
            headers=headers,
            json={"command": "permission_mode overdrive", "session_id": sid},
            timeout=30,
        )
        body = {"input": PROBE_PROMPT, "session_id": sid}
        if working_dir:
            body["working_dir"] = working_dir
        r = s.post(
            f"{base_url.rstrip('/')}/api/v1/orchestrate",
            headers=headers,
            json=body,
            timeout=60,
        )
        if r.status_code not in (200, 202):
            att["error"] = f"orchestrate HTTP {r.status_code}: {r.text[:300]}"
            return att
    except Exception as e:  # noqa: BLE001
        att["error"] = f"{type(e).__name__}: {e}"
        return att

    deadline = time.monotonic() + timeout_s
    seen_done = False
    while time.monotonic() < deadline and not seen_done:
        time.sleep(0.5)
        for ev in list(frames):
            if (ev.get("type") or ev.get("_event")) == "done":
                seen_done = True
    stop["v"] = True

    return _classify(att, frames)


def _classify(att: dict, frames: list[dict]) -> dict:
    """Turn a probe's SSE frames into a verdict. Pure, so it is testable.

    The SSE `tool_call` frames OSA emits are, verbatim:

        {"type":"tool_call","phase":"start","name":"web_fetch","args":"…"}
        {"type":"tool_call","phase":"end","name":"web_fetch",
         "success":false,"duration_ms":0}

    The `end` frame carries no reason string, so the reason ("Blocked:
    web_fetch is denied by a saved permission rule") is only visible in the
    backend log and in the tool message handed to the model. What the stream
    does give is unambiguous enough: the call was made, it failed, and it
    failed in zero milliseconds. A refusal is the only thing that is instant.
    """
    denied_end = None
    shell_egress_end = None
    shell_benign_end = None
    control_end = None
    fetched_ok = False

    # `end` frames carry no arguments, so the two shell_execute steps are told
    # apart by joining on tool_call_id -- which is why this pairs rather than
    # taking the last frame of each name.
    started: dict[str, str] = {}

    for ev in frames:
        etype = ev.get("type") or ev.get("_event")
        if etype != "tool_call":
            if etype in ("assistant_message", "agent_response", "message", "response"):
                txt = ev.get("content") or ev.get("text") or ""
                if isinstance(txt, str) and txt.strip():
                    att["final_message_tail"] = txt[-800:]
            continue

        name = ev.get("tool") or ev.get("name") or ev.get("tool_name")
        phase = ev.get("phase")
        cid = ev.get("tool_call_id")

        if phase == "start":
            if name:
                att["tool_calls_seen"].append(name)
            if cid:
                started[cid] = json.dumps(ev.get("args") or ev.get("arguments") or "")
            continue

        if phase not in ("end", "result", "done"):
            continue

        if name in NETWORK_TOOLS:
            denied_end = ev
            if ev.get("success") is True:
                fetched_ok = True
        elif name == SHELL_TOOL:
            args = started.get(cid or "", "")
            if BENIGN_SHELL_MARKER in args:
                shell_benign_end = ev
            else:
                shell_egress_end = ev
                if ev.get("success") is True:
                    fetched_ok = True
        elif name == CONTROL_TOOL:
            control_end = ev
        elif etype in ("assistant_message", "agent_response", "message", "response"):
            txt = ev.get("content") or ev.get("text") or ""
            if isinstance(txt, str) and txt.strip():
                att["final_message_tail"] = txt[-800:]

    if denied_end is not None:
        att["denied_tool_evidence"] = json.dumps(denied_end)[:600]
    if shell_egress_end is not None:
        att["shell_egress_evidence"] = json.dumps(shell_egress_end)[:600]
    if shell_benign_end is not None:
        att["benign_shell_evidence"] = json.dumps(shell_benign_end)[:600]
    if control_end is not None:
        att["control_tool_evidence"] = json.dumps(control_end)[:600]

    # "Example Domain" is the <h1> of example.com. Seeing it anywhere means
    # the fetch produced content, whatever the frames claim.
    if "example domain" in json.dumps(frames).lower():
        fetched_ok = True
    att["page_content_observed"] = fetched_ok

    called_denied = any(t in NETWORK_TOOLS for t in att["tool_calls_seen"])
    tool_refused = (
        called_denied and denied_end is not None and denied_end.get("success") is False
    )
    # Steps 2 and 3 are only informative if the model actually issued them. A
    # model that skipped one leaves that surface untested, and the attestation
    # says so rather than crediting a step that never ran.
    shell_tested = shell_egress_end is not None
    shell_refused = shell_tested and shell_egress_end.get("success") is False
    benign_tested = shell_benign_end is not None
    benign_ok = benign_tested and shell_benign_end.get("success") is not False
    control_ok = control_end is not None and control_end.get("success") is not False

    att["shell_surface_tested"] = shell_tested
    att["shell_surface_refused"] = shell_refused
    att["benign_shell_still_works"] = benign_ok
    att["enforced"] = bool(
        tool_refused and shell_refused and benign_ok and control_ok and not fetched_ok
    )
    if not att["enforced"] and att["error"] is None:
        if not called_denied:
            att["error"] = (
                "the model never called a denied tool, so nothing was tested; "
                "re-run the probe"
            )
        elif fetched_ok:
            att["error"] = "a denied path RAN and returned content"
        elif not tool_refused:
            att["error"] = "web_fetch was not refused"
        elif not shell_tested:
            att["error"] = (
                "the model never issued the shell egress step, so the residual "
                "shell surface is untested; re-run the probe"
            )
        elif not shell_refused:
            att["error"] = (
                "the shell egress command was NOT refused — the substring deny "
                "rules are not matching"
            )
        elif not benign_tested:
            att["error"] = (
                "the model never issued the benign shell step, so the blast "
                "radius of the substring rules is unmeasured; re-run the probe"
            )
        elif not benign_ok:
            att["error"] = (
                "a shell command with NO egress marker was also refused — the "
                "deny rules are over-matching and would cripple the run"
            )
        elif not control_ok:
            att["error"] = (
                f"the control tool {CONTROL_TOOL} did not succeed either — this "
                f"probe measured a broken backend, not a working deny list"
            )
    return att


# ---------------------------------------------------------------------------
# After-the-fact check on the residual (shell) surface.
# ---------------------------------------------------------------------------

#: Substrings in a `shell_execute` command that indicate an egress attempt the
#: prefix deny rules cannot catch. Matching one is not proof of a lookup — it
#: is a pointer at a transcript a human must read.
_EGRESS_HINTS = (
    "urllib",
    "requests.get",
    "http.client",
    "socket.create_connection",
    "httpx",
    "urlopen",
    "://github.com",
    "://raw.githubusercontent.com",
    "://gitlab.com",
    "://bitbucket.org",
)

#: A SECOND, SEPARATELY-REPORTED class: build tools that fetch as a side effect.
#:
#: FINDINGS.md #6. Three SWE-bench Pro instances logged `go: downloading
#: github.com/...` — real outbound network from `shell_execute`, invisible to
#: the scan above because `go build` contains neither "urllib" nor "requests".
#: The command text alone is not enough either: `go test ./...` downloads only
#: if the module cache is cold, and `pip install` of a local path never leaves
#: the machine. So the command is a *candidate* and the tool's OUTPUT is the
#: evidence, which is why both are scanned and reported separately.
#:
#: These hits deliberately do NOT feed the `breached` verdict. A false breach
#: on an ambiguous `go build` would block a 500-instance run on a guess, and
#: the honest reading of a toolchain hit is "a human must read this
#: transcript", not "the score is void".
_TOOLCHAIN_CMD_HINTS = (
    "go get", "go mod download", "go mod tidy", "go build", "go test",
    "go run", "go install",
    "pip install", "pip3 install", "pip download", "python -m pip",
    "uv pip", "uv sync", "poetry install", "poetry add", "pipenv install",
    "conda install", "conda create", "mamba install",
    "npm install", "npm ci", "npm i ", "yarn add", "yarn install",
    "pnpm install", "pnpm add", "bundle install", "gem install",
    "cargo build", "cargo fetch", "cargo test", "cargo install", "cargo add",
    "apt-get install", "apt install", "apk add", "yum install", "dnf install",
    "mvn ", "gradle ", "composer install", "nuget restore", "dotnet restore",
    "setup.py develop", "setup.py install", "pip wheel",
)

#: Markers in tool OUTPUT that a fetch actually happened. These are the strong
#: evidence: they are printed by the tool at the moment it goes to the network.
_TOOLCHAIN_OUTPUT_HINTS = (
    "go: downloading",
    "go: extracting",
    "go: finding",
    "downloading from https://",
    # NOT "collecting " (pip's first line): pytest prints "collecting ..." on
    # every single test run, and it fired on 3 logs of ordinary Python test
    # output. pip's *network* line is "Downloading http…", which is below and
    # is unambiguous.
    "downloading http",         # pip / setuptools
    "fetching https://",        # cargo / npm
    "updating crates.io index",
    "cloning into '",
    "receiving objects:",
    "remote: enumerating objects",
    # NOT included, and the reason is worth keeping: npm's "added N packages"
    # was tried and fired 24 times across 11 instances of the 40-instance
    # Verified run, every one of it ordinary Python test output containing the
    # word "added". A marker that common is not evidence, and shipping it would
    # have put a fake toolchain-fetch finding on every future run.
)

#: Tools whose commands can reach the network without the deny prefixes seeing it.
_SHELLY = ("shell_execute", "repl", "pty", "bash_output")


def _cmd_of(ev: dict) -> str:
    args = ev.get("arguments") or ev.get("args") or ev.get("input") or {}
    if isinstance(args, dict):
        return str(args.get("command") or args.get("code") or args)
    return str(args)


def residual_egress_evidence(event_log: Path) -> list[dict]:
    """Scan one instance's SSE log for evidence of egress the deny rules miss.

    Returns a list of hits, each tagged with a `kind`:

      `explicit_network`  -- the command names an HTTP client or a source-host
                             URL outright. This is the historical behaviour and
                             it is what makes a run `breached`.
      `toolchain_fetch`   -- a build/package tool ran (`cmd` evidence) or
                             printed a download line (`output` evidence). It is
                             reported, and it does NOT void the score by
                             itself; see `_TOOLCHAIN_CMD_HINTS`.

    Empty means the recorded stream contains no evidence of egress through the
    surface the deny rules cannot cover. That is weaker than "no egress
    happened" and the report says so.
    """
    hits: list[dict] = []
    #: tool_call_id -> command, so an output hit can name the command that
    #: produced it rather than reporting a bare line of text.
    cmd_by_call: dict[str, str] = {}
    try:
        with Path(event_log).open() as fh:
            for line in fh:
                try:
                    ev = json.loads(line)
                except json.JSONDecodeError:
                    continue
                # Some recorded streams contain a bare JSON array on a line.
                # The previous version of this scanner raised AttributeError on
                # them, which `network_tool_use` did not catch -- so a single
                # malformed line could take down the whole report.
                if not isinstance(ev, dict):
                    continue
                etype = ev.get("type") or ev.get("_event")
                name = ev.get("tool") or ev.get("name") or ev.get("tool_name")
                call_id = ev.get("tool_call_id")

                if etype == "tool_call":
                    if name not in _SHELLY:
                        continue
                    cmd = _cmd_of(ev)
                    if call_id:
                        cmd_by_call[call_id] = cmd
                    low = cmd.lower()
                    if any(h in low for h in _EGRESS_HINTS):
                        hits.append({
                            "kind": "explicit_network",
                            "evidence": "command",
                            "tool": name,
                            "command": cmd[:400],
                        })
                    elif any(h in low for h in _TOOLCHAIN_CMD_HINTS):
                        hits.append({
                            "kind": "toolchain_fetch",
                            "evidence": "command",
                            "tool": name,
                            "command": cmd[:400],
                        })

                elif etype in ("tool_result", "command_output_delta"):
                    text = str(
                        ev.get("result") or ev.get("chunk") or ev.get("tail") or ""
                    )
                    if not text:
                        continue
                    low = text.lower()
                    for h in _TOOLCHAIN_OUTPUT_HINTS:
                        if h not in low:
                            continue
                        i = low.index(h)
                        hits.append({
                            "kind": "toolchain_fetch",
                            "evidence": "output",
                            "tool": name or "shell_execute",
                            "marker": h,
                            "command": (
                                cmd_by_call.get(call_id, ev.get("command") or "")
                            )[:400],
                            "excerpt": text[max(0, i - 80):i + 240],
                        })
                        break
    except OSError:
        return hits
    return hits


def split_egress_hits(hits: list[dict]) -> tuple[list[dict], list[dict]]:
    """(explicit_network, toolchain_fetch). Untagged hits are treated as explicit.

    Untagged means an older run's records, produced before the split existed.
    Reading them as the stricter class keeps an old result from silently
    becoming cleaner because the code around it changed.
    """
    explicit = [h for h in hits if h.get("kind", "explicit_network") == "explicit_network"]
    toolchain = [h for h in hits if h.get("kind") == "toolchain_fetch"]
    return explicit, toolchain
