#!/usr/bin/env bash
# Phase 1: can this competitor even be installed into a Terminal-Bench task
# container? `--install-only` runs the adapter's install() and stops, so it
# costs no tokens and no model time. It answers exactly one question -- "does
# the CLI land in the container" -- and deliberately not "does it talk to our
# provider", which only a real trial can establish.
#
# Usage: ./preflight.sh [task]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
TB="$HERE/../terminalbench"
TASK="${1:-regex-log}"
OUT="$HERE/preflight"
mkdir -p "$OUT"

AGENTS="codex opencode goose aider mini-swe-agent claude-code gemini-cli cursor-cli"

for a in $AGENTS; do
  echo "=================== $a ==================="
  timeout 900 "$TB/.venv/bin/harbor" run \
      -a "$a" -y --install-only \
      -p "$TB/tasks/terminal-bench-2" -i "$TASK" \
      -o "$OUT/$a" -n 1 \
      --extra-docker-compose "$TB/compose-host-provider.yaml" \
      >"$OUT/$a.log" 2>&1
  rc=$?
  # Harbor's exit code is not a reliable install verdict on its own; the trial
  # result.json is. Report both.
  res=$(find "$OUT/$a" -name result.json -mindepth 3 2>/dev/null | head -1)
  if [ -n "$res" ]; then
    python3 - "$res" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
setup = d.get("agent_setup") or {}
exc = d.get("exception_info") or {}
print("  setup_started :", bool(setup.get("started_at")))
print("  setup_finished:", bool(setup.get("finished_at")))
print("  agent_version :", (d.get("agent_info") or {}).get("version"))
print("  exception     :", exc.get("exception_type"), str(exc.get("exception_message"))[:200])
PY
  else
    echo "  no trial result.json produced"
  fi
  echo "  harbor_rc=$rc  log=$OUT/$a.log"
done
