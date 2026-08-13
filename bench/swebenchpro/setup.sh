#!/usr/bin/env bash
# Create the venv and vendor the OFFICIAL SWE-bench Pro evaluation harness.
#
# Everything this benchmark needs that is not ours lives under bench/swebenchpro/
# and is gitignored:
#
#   .venv/    python deps (datasets, pandas, tqdm, docker sdk)
#   harness/  a clone of github.com/scaleapi/SWE-bench_Pro-os, pinned by commit
#
# We clone rather than reimplement on purpose. Grading is decided by
# `harness/swe_bench_pro_eval.py`, unmodified -- see evaluate.py.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$HERE/.venv"
HARNESS="$HERE/harness"

# The upstream harness has no tags and no releases. Pin the commit so a
# re-grade months from now is the same grade; bump it deliberately, never
# implicitly, and record the bump in the run's config.json (evaluate.py reads
# the checked-out SHA back out of git, so a drifted clone is visible).
HARNESS_REPO="https://github.com/scaleapi/SWE-bench_Pro-os.git"
HARNESS_REF="${SWEBENCHPRO_HARNESS_REF:-main}"

python3 -m venv "$VENV"
"$VENV/bin/pip" install --upgrade pip >/dev/null
# The harness's own requirements.txt, minus modal: we grade with local Docker.
"$VENV/bin/pip" install \
  "datasets>=2.14.0" "pandas>=1.5.0" "tqdm>=4.64.0" "docker>=6.0.0" \
  "huggingface_hub>=0.16.0" requests

if [ ! -d "$HARNESS/.git" ]; then
  # --no-recurse-submodules: the SWE-agent / mini-swe-agent submodules are
  # scaffolds for generating patches. We generate patches with OSA; pulling
  # them would add ~1 GB of code we never execute.
  git clone --no-recurse-submodules "$HARNESS_REPO" "$HARNESS"
fi
git -C "$HARNESS" fetch origin "$HARNESS_REF" --depth 50
git -C "$HARNESS" checkout -q FETCH_HEAD

echo
echo "venv:    $VENV"
echo "harness: $HARNESS @ $(git -C "$HARNESS" rev-parse HEAD)"

# The three asset trees the official grader reads per instance. If any of these
# is short, grading silently degrades to "instance not found" rather than
# failing, so count them here where it is loud.
for d in run_scripts dockerfiles/base_dockerfile dockerfiles/instance_dockerfile; do
  printf '  %-38s %s dirs\n' "$d" "$(ls "$HARNESS/$d" | wc -l)"
done

echo
echo "Docker check:"
docker version --format '  server {{.Server.Version}}' || {
  echo "  docker unavailable -- evaluation will not work" >&2
  exit 1
}
