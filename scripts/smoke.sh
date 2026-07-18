#!/usr/bin/env bash
# OSA end-to-end smoke test — verifies the critical flows against a running
# backend (start it first: `mix osa.serve` or `osa`).
#
# Covers: health/model resolution, command registry, provider list, a real
# agent turn (cloud), and `osa doctor`. Exit non-zero if any critical flow fails.
set -uo pipefail
PORT="${OSA_HTTP_PORT:-9089}"
BASE="http://127.0.0.1:${PORT}"
pass=0 fail=0
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; pass=$((pass+1)); }
bad()  { printf "  \033[31m✗\033[0m %s\n" "$1"; fail=$((fail+1)); }

echo "OSA smoke test → ${BASE}"

# 1. Health + model resolution
H=$(curl -s --max-time 5 "${BASE}/health" 2>/dev/null)
MODEL=$(printf '%s' "$H" | python3 -c "import sys,json;print(json.load(sys.stdin).get('model',''))" 2>/dev/null)
[ -n "$MODEL" ] && ok "health: model=${MODEL}" || { bad "health endpoint (is the backend running?)"; echo "FAILED: no backend"; exit 1; }

# 2. Command registry (powers /help, Ctrl+K, slash menu)
NC=$(curl -s --max-time 5 "${BASE}/api/v1/commands" 2>/dev/null | python3 -c "import sys,json
d=json.load(sys.stdin); c=d if isinstance(d,list) else d.get('commands',d.get('data',[])); print(len(c))" 2>/dev/null)
[ "${NC:-0}" -ge 10 ] 2>/dev/null && ok "command registry: ${NC} commands" || bad "command registry (${NC:-0})"

# 3. Provider list (powers the model/provider picker)
NP=$(curl -s --max-time 5 "${BASE}/onboarding/status" 2>/dev/null | python3 -c "import sys,json;print(len(json.load(sys.stdin).get('providers',[])))" 2>/dev/null)
[ "${NP:-0}" -ge 1 ] 2>/dev/null && ok "provider list: ${NP} providers" || bad "provider list (${NP:-0})"

# 4. A real agent turn — the whole loop end to end
SID="smoke-$$"
curl -s -X POST "${BASE}/api/v1/orchestrate" -H 'Content-Type: application/json' \
  -d "{\"input\":\"Reply with exactly: it works\",\"session_id\":\"${SID}\"}" --max-time 10 >/dev/null 2>&1
REPLY=""
for _ in $(seq 1 25); do
  sleep 2
  R=$(curl -s --max-time 5 "${BASE}/api/v1/sessions/${SID}" 2>/dev/null | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin); msgs=d.get('messages',[])
  a=[m for m in msgs if m.get('role')=='assistant' and m.get('content','').strip() not in ('','...')]
  print(a[-1]['content'][:60] if a else '')
except: print('')" 2>/dev/null)
  [ -n "$R" ] && { REPLY="$R"; break; }
done
[ -n "$REPLY" ] && ok "agent turn: real reply ('${REPLY}')" || bad "agent turn returned no real content (empty/'...')"

# 5. Doctor
if command -v osa >/dev/null 2>&1; then
  osa doctor >/dev/null 2>&1 && ok "osa doctor ran" || bad "osa doctor"
fi

echo
echo "smoke: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
