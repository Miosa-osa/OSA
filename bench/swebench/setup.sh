#!/usr/bin/env bash
# Create the Python venv used by the SWE-bench pipeline.
# Everything Python lives in bench/swebench/.venv and is gitignored.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$HERE/.venv"

python3 -m venv "$VENV"
"$VENV/bin/pip" install --upgrade pip >/dev/null
"$VENV/bin/pip" install "swebench>=4.0.0" datasets requests

echo
echo "venv ready: $VENV"
"$VENV/bin/python" -c "import swebench; print('swebench', swebench.__version__)"
echo
echo "Docker check:"
docker version --format '  server {{.Server.Version}}' || {
  echo "  docker unavailable -- evaluation will not work" >&2
  exit 1
}
