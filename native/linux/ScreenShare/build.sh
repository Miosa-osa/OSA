#!/usr/bin/env bash
set -euo pipefail

if [[ $(uname -s) != Linux ]]; then
  echo 'Build the Wayland helper on Linux, against the oldest supported runtime libraries.' >&2
  exit 1
fi
for package in gstreamer-1.0 gstreamer-app-1.0 gstreamer-video-1.0; do
  pkg-config --atleast-version=1.20 "$package" || {
    echo "Missing development dependency: $package >= 1.20" >&2
    exit 1
  }
done
source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
target_dir="${CARGO_TARGET_DIR:-$source_dir/target}"
case "$target_dir" in /*) ;; *) echo 'CARGO_TARGET_DIR must be absolute for release packaging' >&2; exit 1 ;; esac
cargo build --locked --release --manifest-path "$source_dir/Cargo.toml"
echo "Build complete: $target_dir/release/osa-screen-capture-wayland"
echo 'Run stage.sh before mix release and verify-package.sh against the resulting tarball.'
