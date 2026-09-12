#!/usr/bin/env bash
# Stage build outputs for mix release, never modify a running installation.
set -euo pipefail
source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
target_dir="${CARGO_TARGET_DIR:-$source_dir/target}"
case "$target_dir" in /*) ;; *) echo 'CARGO_TARGET_DIR must be absolute for release packaging' >&2; exit 1 ;; esac
binary="$target_dir/release/osa-screen-capture-wayland"
destination="${1:-$source_dir/../../../priv/helpers}"
[[ $# -le 1 ]] || { echo 'Usage: stage.sh [helper-directory]' >&2; exit 64; }
[[ -s "$binary" && -x "$binary" ]] || { echo "Missing built helper: $binary" >&2; exit 1; }
version="$(timeout 5 "$binary" --version </dev/null)"
[[ "$version" == 'osa-screen-capture-wayland '* ]] || { echo 'Invalid helper version response' >&2; exit 1; }
mkdir -p -- "$destination"
temporary="$(mktemp "$destination/.osa-wayland-stage.XXXXXX")"
trap 'rm -f -- "$temporary"' EXIT
install -m 0755 -- "$binary" "$temporary"
mv -f -- "$temporary" "$destination/osa-screen-capture-wayland"
install -m 0644 -- "$source_dir/runtime-requirements.md" "$destination/osa-screen-capture-wayland.runtime.md"
cmp -- "$binary" "$destination/osa-screen-capture-wayland"
echo "Staged $version into $destination"
