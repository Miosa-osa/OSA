#!/usr/bin/env bash
#
# One entry point for the benchmark loop: run → find issues → fix → run again.
#
# WHY A SCRIPT AND NOT A README STEP
# ----------------------------------
# Every benchmark number produced here is only meaningful if the controls ran
# too. A gold arm that does not score ~100% and an empty arm that does not score
# ~0% mean the pipeline is broken and the OSA number measures nothing. Left to a
# checklist, the controls are the step people skip when they are in a hurry —
# which is exactly when a wrong number does the most damage.
#
# So this script runs them, and REFUSES to run the OSA arm if they fail.
#
# WHAT IT DOES NOT DO
# -------------------
# It does not print a headline rate. `bench/report/cli.py gate` decides whether
# a run is quotable, and today every run we have is blocked on sample size. That
# is correct and this script will not route around it.
#
# USAGE
#   bench/run-all.sh smoke              # controls only, ~15 min, proves the pipeline
#   bench/run-all.sh swebench  [N]      # SWE-bench Verified, N instances (default 40)
#   bench/run-all.sh pro       [N]      # SWE-bench Pro, N instances (default 12)
#   bench/run-all.sh terminal  [N]      # Terminal-Bench, N tasks (default 10)
#   bench/run-all.sh recovery           # Recovery-Bench, both arms
#   bench/run-all.sh report             # re-gate everything already on disk
#
set -uo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$BENCH_DIR/.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"

# A port that is not 9089. The user's live daemon lives there and a benchmark
# must never evict it.
export OSA_HTTP_PORT="${OSA_HTTP_PORT:-19951}"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { printf '\n\033[31mFAILED: %s\033[0m\n' "$*" >&2; exit 1; }

require_disk() {
  local need_gb="$1"
  local free_gb
  free_gb=$(df -BG --output=avail "$REPO_ROOT" | tail -1 | tr -dc '0-9')
  if [ "${free_gb:-0}" -lt "$need_gb" ]; then
    die "need ~${need_gb}GB free, have ${free_gb}GB. Instance images are 2-5GB each; prune with 'docker image prune -a'."
  fi
  say "disk ok: ${free_gb}GB free"
}

# Controls first, always. A run whose controls did not pass is not evidence.
run_controls() {
  local suite="$1" n="$2"
  say "controls for $suite (gold must be ~100%, empty must be 0%)"

  python3 "$BENCH_DIR/$suite/run_bench.py" --runner gold-apply -n "$n" \
    --run-id "ctrl-gold-$STAMP" || die "gold control did not complete"
  python3 "$BENCH_DIR/$suite/run_bench.py" --runner empty -n "$n" \
    --run-id "ctrl-empty-$STAMP" || die "empty control did not complete"

  python3 "$BENCH_DIR/report/cli.py" controls \
    --gold "$BENCH_DIR/$suite/runs/ctrl-gold-$STAMP" \
    --empty "$BENCH_DIR/$suite/runs/ctrl-empty-$STAMP" \
    || die "controls did not behave — the pipeline is broken, and any OSA number from it is meaningless"
}

run_osa() {
  local suite="$1" n="$2"
  say "OSA arm for $suite (airgapped; the run aborts if the airgap probe fails)"
  python3 "$BENCH_DIR/$suite/run_bench.py" --runner osa -n "$n" --airgap \
    --run-id "osa-$STAMP" || die "OSA arm did not complete"
}

gate() {
  say "gate — decides whether anything here is quotable"
  python3 "$BENCH_DIR/report/cli.py" gate --run "$1" || {
    printf '\n\033[33mThe gate refused to publish a rate. That is usually CORRECT.\033[0m\n'
    printf 'Read the rules it fired. Do not route around it — fix the finding or state the caveat.\n'
  }
}

cmd="${1:-}"; n="${2:-}"

case "$cmd" in
  smoke)
    require_disk 60
    run_controls swebench "${n:-3}"
    say "pipeline proven. Run a real arm next."
    ;;
  swebench)
    require_disk 250
    run_controls swebench "${n:-40}"
    run_osa swebench "${n:-40}"
    gate "$BENCH_DIR/swebench/runs/osa-$STAMP"
    ;;
  pro)
    require_disk 120
    run_controls swebenchpro "${n:-12}"
    run_osa swebenchpro "${n:-12}"
    gate "$BENCH_DIR/swebenchpro/runs/osa-$STAMP"
    ;;
  terminal)
    require_disk 80
    say "Terminal-Bench (oracle arm validates the harness; it must score 1.0)"
    python3 "$BENCH_DIR/terminalbench/run_bench.py" -n "${n:-10}" --run-id "tb-$STAMP" \
      || die "Terminal-Bench did not complete"
    say "contamination probe — task images must not ship their solutions"
    python3 "$BENCH_DIR/terminalbench/contamination_probe.py" --all || true
    ;;
  recovery)
    require_disk 80
    say "Recovery-Bench — BOTH arms, model held fixed. The delta is the deliverable."
    python3 "$BENCH_DIR/recoverybench/run_bench.py" --run-id "rb-$STAMP" \
      || die "Recovery-Bench did not complete"
    ;;
  report)
    say "re-gating every run on disk"
    python3 "$BENCH_DIR/report/cli.py" summarize --all
    ;;
  *)
    sed -n '/^# USAGE/,/^set -uo/p' "${BASH_SOURCE[0]}" | sed 's/^#\s\?//;$d'
    exit 2
    ;;
esac

say "done. Findings worth acting on go in bench/FINDINGS.md"
