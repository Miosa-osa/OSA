#!/usr/bin/env bash
# One sweep arm, end to end: model-forcing proxy + isolated backend + bench.
#
# The arm is only meaningful if the model you asked for is the model that ran,
# and on an OpenAI-compatible provider OSA cannot make that true by itself (see
# model_proxy.py for the measurement). So this script does not trust the
# configuration: it reads the proxy's counters afterwards and writes them next
# to the results as `wire-evidence.json`. An arm whose evidence shows the wrong
# model on the wire is void, and says so.
#
# usage: run_arm.sh <model-slug> <run-id> [instances-file]
set -euo pipefail

MODEL="${1:?model slug required}"
RUN_ID="${2:?run id required}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTANCES="${3:-$REPO/bench/swebenchpro/runs/osa-s12-full/instances.txt}"

PORT="${ARM_PORT:-19981}"
PROXY_PORT="${PROXY_PORT:-19990}"
SLUG="$(echo "$MODEL" | tr '/:.' '___')"
PROXY_OUT="/tmp/msproxy-$SLUG"

cleanup() {
  for p in "$PROXY_PORT" "$PORT"; do
    pid=$(ss -ltnp 2>/dev/null | grep "127.0.0.1:$p" | sed -n 's/.*pid=\([0-9]*\).*/\1/p' || true)
    # Never signal the operator's live daemon (:9089) or a sibling bench run.
    if [[ -n "$pid" && "$p" != "9089" ]]; then kill "$pid" 2>/dev/null || true; fi
  done
}
trap cleanup EXIT

echo "== arm $MODEL -> $RUN_ID =="
python3 "$REPO/bench/modelsweep/model_proxy.py" --port "$PROXY_PORT" \
  --force-model "$MODEL" --outdir "$PROXY_OUT" &
sleep 3

OPENROUTER_BASE_URL="http://127.0.0.1:$PROXY_PORT/v1" \
OSA_SETTINGS="$REPO/bench/swebenchpro/airgap-settings.json" \
  "$REPO/bench/modelsweep/serve_arm.sh" "$MODEL" "$PORT" "/tmp/osa-arm-$SLUG.log"

for _ in $(seq 1 60); do
  curl -s --max-time 3 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
  sleep 3
done

cd "$REPO/bench/swebenchpro"
.venv/bin/python run_bench.py --runner osa --airgap \
  --osa-url "http://127.0.0.1:$PORT" --instances "$INSTANCES" --run-id "$RUN_ID" \
  --agent-timeout 2400 --max-turns 120 --infer-workers 2 --eval-workers 2

# Wire evidence: what actually ran, not what was configured.
curl -s "http://127.0.0.1:$PROXY_PORT/v1/__stats" \
  > "runs/$RUN_ID/wire-evidence.json" || true
echo "wire evidence -> runs/$RUN_ID/wire-evidence.json"
cat "runs/$RUN_ID/wire-evidence.json"
