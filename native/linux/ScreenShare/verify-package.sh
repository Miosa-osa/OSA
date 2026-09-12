#!/usr/bin/env bash
set -euo pipefail
source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ $# == 2 ]] || { echo 'Usage: verify-package.sh release.tar.gz x64|arm64' >&2; exit 64; }
target_dir="${CARGO_TARGET_DIR:-$source_dir/target}"
case "$target_dir" in /*) ;; *) echo 'CARGO_TARGET_DIR must be absolute for release packaging' >&2; exit 1 ;; esac
python3 "$source_dir/verify_package.py" "$1" "$2" "$target_dir/release/osa-screen-capture-wayland" "$source_dir/runtime-requirements.md"
