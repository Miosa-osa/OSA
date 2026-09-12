#!/usr/bin/env bash
# Automated build/protocol/package checks. Never requests native desktop access.
set -euo pipefail
source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
case "$(uname -m)" in
  x86_64) export OSA_TEST_ARCH=x64 ;;
  aarch64) export OSA_TEST_ARCH=arm64 ;;
  *) echo 'Unsupported native test architecture' >&2; exit 1 ;;
esac
cargo fmt --manifest-path "$source_dir/Cargo.toml" --check
cargo clippy --locked --manifest-path "$source_dir/Cargo.toml" --all-targets -- -D warnings
cargo test --locked --manifest-path "$source_dir/Cargo.toml"
bash "$source_dir/build.sh"
python3 "$source_dir/tests/package_test.py"
